#!/bin/bash

# ImgHub Bot 一键安装/更新脚本（Debian/Ubuntu）

set -o pipefail

PYTHON_SCRIPT_PATH="${PYTHON_SCRIPT_PATH:-/opt/imghub_bot/imghub_bot.py}"
PYTHON_SCRIPT_DIR="${PYTHON_SCRIPT_DIR:-$(dirname -- "$PYTHON_SCRIPT_PATH")}"
CONFIG_FILE_PATH="${CONFIG_FILE_PATH:-/root/imghub_config.ini}"
DATA_DIR="${DATA_DIR:-/var/lib/imghub}"
CACHE_DIR="${CACHE_DIR:-/var/cache/imghub}"
SERVICE_NAME="${SERVICE_NAME:-imghub_bot}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/ai-scripts/imghub}"
BACKUP_KEEP="${BACKUP_KEEP:-5}"
STARTUP_ATTEMPTS="${STARTUP_ATTEMPTS:-30}"
STARTUP_INTERVAL="${STARTUP_INTERVAL:-2}"
HEALTH_PORT="${HEALTH_PORT:-8080}"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

PYTHON_SCRIPT_CONTENT=$(cat <<'END_OF_PYTHON_SCRIPT'
#!/usr/bin/python3
import asyncio
import configparser
import ipaddress
import json
import logging
import os
import re
import secrets
import signal
import tempfile
import threading
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

from aiohttp import web
from telegram import Bot, Update
from telegram.ext import Application, CommandHandler, ContextTypes, MessageHandler, filters

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[logging.StreamHandler()],
)
logger = logging.getLogger("imghub")

CONFIG_PATH = os.environ.get("IMGHUB_CONFIG_PATH", "/root/imghub_config.ini")
DATA_DIR = Path(os.environ.get("IMGHUB_DATA_DIR", "/var/lib/imghub"))
CACHE_DIR = Path(os.environ.get("IMGHUB_CACHE_DIR", "/var/cache/imghub"))
DB_PATH = DATA_DIR / "records.json"
DB_BACKUP_PATH = DATA_DIR / "records.json.last-good"
CHECK_CONFIG_ONLY = os.environ.get("IMGHUB_CHECK_CONFIG_ONLY") == "1"
RECORD_ID_RE = re.compile(r"^[0-9a-f]{8,32}$")
CHANNEL_USERNAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{4,31}$")
BOT_TOKEN_RE = re.compile(r"^[0-9]{5,15}:[A-Za-z0-9_-]{30,}$")
ALLOWED_MIME_TYPES = {"image/jpeg", "image/png", "image/gif", "image/webp"}


class BotConfigError(RuntimeError):
    pass


class RecordsCorruptionError(RuntimeError):
    pass


def _bounded_int(config, section, key, default, minimum, maximum):
    try:
        value = config.getint(section, key, fallback=default)
    except ValueError as exc:
        raise BotConfigError(f"{section}.{key} 必须是整数") from exc
    if not minimum <= value <= maximum:
        raise BotConfigError(f"{section}.{key} 必须在 {minimum}-{maximum} 之间")
    return value


def _validate_base_url(value):
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise BotConfigError("server.base_url 必须是完整的 http/https URL")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise BotConfigError("server.base_url 不允许用户名、密码、查询参数或片段")
    if parsed.path not in {"", "/"}:
        raise BotConfigError("server.base_url 不允许包含路径")
    try:
        port = parsed.port
    except ValueError as exc:
        raise BotConfigError("server.base_url 端口无效") from exc
    if port is not None and not 1 <= port <= 65535:
        raise BotConfigError("server.base_url 端口无效")
    if any(char in value for char in "\r\n\t"):
        raise BotConfigError("server.base_url 包含非法控制字符")
    hostname = parsed.hostname
    try:
        ipaddress.ip_address(hostname)
    except ValueError:
        labels = hostname.split(".")
        if len(labels) < 2 or any(
            not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
            for label in labels
        ):
            raise BotConfigError("server.base_url 主机名格式无效")
    return value.rstrip("/")


def load_config():
    config = configparser.ConfigParser(interpolation=None)
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as config_file:
            config.read_file(config_file)
    except FileNotFoundError as exc:
        raise BotConfigError(f"配置文件不存在: {CONFIG_PATH}") from exc
    except (OSError, configparser.Error) as exc:
        raise BotConfigError(f"配置文件无法读取或格式错误: {exc}") from exc

    try:
        bot_token = config.get("telegram", "bot_token").strip()
        channel_id_text = config.get("telegram", "channel_id").strip()
        channel_username = config.get("telegram", "channel_username", fallback="").strip().lstrip("@")
        allowed_users_text = config.get("access", "allowed_users").strip()
        base_url = _validate_base_url(config.get("server", "base_url").strip())
    except (configparser.NoSectionError, configparser.NoOptionError) as exc:
        raise BotConfigError(f"缺少必要配置: {exc}") from exc

    if not BOT_TOKEN_RE.fullmatch(bot_token):
        raise BotConfigError("telegram.bot_token 格式无效")
    if not re.fullmatch(r"-100[0-9]{6,16}", channel_id_text):
        raise BotConfigError("telegram.channel_id 必须是以 -100 开头的频道 ID")
    if channel_username and not CHANNEL_USERNAME_RE.fullmatch(channel_username):
        raise BotConfigError("telegram.channel_username 格式无效")
    if not re.fullmatch(r"[1-9][0-9]*(,[1-9][0-9]*)*", allowed_users_text):
        raise BotConfigError("access.allowed_users 必须是逗号分隔的正整数")
    allowed_users = [int(item) for item in allowed_users_text.split(",")]
    if len(set(allowed_users)) != len(allowed_users):
        raise BotConfigError("access.allowed_users 不允许重复")

    listen_host = config.get("server", "listen_host", fallback="127.0.0.1").strip()
    if listen_host not in {"127.0.0.1", "::1", "0.0.0.0", "::"}:
        raise BotConfigError("server.listen_host 仅支持回环或明确的全局监听地址")
    listen_port = _bounded_int(config, "server", "listen_port", 8080, 1, 65535)
    max_file_bytes = _bounded_int(config, "limits", "max_file_bytes", 20 * 1024 * 1024, 1024, 20 * 1024 * 1024)
    max_concurrency = _bounded_int(config, "limits", "max_concurrency", 4, 1, 32)
    cache_max_bytes = _bounded_int(config, "cache", "max_bytes", 256 * 1024 * 1024, max_file_bytes, 2 * 1024 * 1024 * 1024)
    cache_ttl_seconds = _bounded_int(config, "cache", "ttl_seconds", 86400, 60, 604800)

    return {
        "bot_token": bot_token,
        "channel_id": int(channel_id_text),
        "channel_username": channel_username,
        "allowed_users": allowed_users,
        "base_url": base_url,
        "listen_host": listen_host,
        "listen_port": listen_port,
        "max_file_bytes": max_file_bytes,
        "max_concurrency": max_concurrency,
        "cache_max_bytes": cache_max_bytes,
        "cache_ttl_seconds": cache_ttl_seconds,
    }


def _fsync_directory(directory):
    if os.name != "posix":
        return
    descriptor = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _validate_records(data):
    if not isinstance(data, dict):
        raise RecordsCorruptionError("记录库根节点不是对象")
    normalized = {}
    for file_id, record in data.items():
        if not isinstance(file_id, str) or not RECORD_ID_RE.fullmatch(file_id):
            raise RecordsCorruptionError(f"记录 ID 无效: {file_id!r}")
        if not isinstance(record, (list, tuple)) or len(record) != 4:
            raise RecordsCorruptionError(f"记录结构无效: {file_id}")
        channel_part, message_id, telegram_file_id, mime_type = record
        if not isinstance(channel_part, str) or not channel_part.isdigit():
            raise RecordsCorruptionError(f"频道记录无效: {file_id}")
        if not isinstance(message_id, int) or message_id <= 0:
            raise RecordsCorruptionError(f"消息 ID 无效: {file_id}")
        if not isinstance(telegram_file_id, str) or not telegram_file_id:
            raise RecordsCorruptionError(f"Telegram 文件 ID 无效: {file_id}")
        if mime_type not in ALLOWED_MIME_TYPES:
            raise RecordsCorruptionError(f"MIME 类型无效: {file_id}")
        normalized[file_id] = (channel_part, message_id, telegram_file_id, mime_type)
    return normalized


def _read_records_file(path):
    with open(path, "r", encoding="utf-8") as records_file:
        return _validate_records(json.load(records_file))


def _atomic_write_json(path, records):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        if hasattr(os, "fchmod"):
            os.fchmod(descriptor, 0o600)
        else:
            os.chmod(temp_name, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as temp_file:
            json.dump(records, temp_file, ensure_ascii=False, separators=(",", ":"))
            temp_file.write("\n")
            temp_file.flush()
            os.fsync(temp_file.fileno())
        os.replace(temp_name, path)
        os.chmod(path, 0o600)
        _fsync_directory(path.parent)
    except Exception:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise


class ImageHostingService:
    def __init__(self, bot, runtime_config):
        self.bot = bot
        self.config = runtime_config
        self.db_path = DB_PATH
        self.db_backup_path = DB_BACKUP_PATH
        self.file_records = {}
        self.records_writable = True
        self.records_dirty = False
        self.records_lock = threading.RLock()
        self.download_semaphore = asyncio.Semaphore(runtime_config["max_concurrency"])
        self.app = web.Application(client_max_size=1024)
        self.app.add_routes([
            web.get("/healthz", self.handle_health_request),
            web.get("/i/{file_id}", self.handle_image_request),
        ])
        self.runner = None
        self.site = None
        self.load_records()
        CACHE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)

    def load_records(self):
        if not self.db_path.exists():
            self.file_records = {}
            return
        try:
            self.file_records = _read_records_file(self.db_path)
            logger.info("成功加载 %d 条文件记录", len(self.file_records))
        except Exception as exc:
            self.records_writable = False
            hint = (
                f"记录库 {self.db_path} 已损坏，服务拒绝写入以防覆盖历史。"
                f"请检查 {self.db_backup_path}，确认后手动恢复并重启服务。"
            )
            logger.critical("%s 原因: %s", hint, exc)
            raise RecordsCorruptionError(hint) from exc

    def save_records(self):
        with self.records_lock:
            if not self.records_writable:
                raise RecordsCorruptionError("记录库处于只读保护状态")
            if self.db_path.exists():
                try:
                    previous_records = _read_records_file(self.db_path)
                except Exception as exc:
                    self.records_writable = False
                    raise RecordsCorruptionError("现有记录库校验失败，拒绝覆盖") from exc
                _atomic_write_json(self.db_backup_path, previous_records)
            _atomic_write_json(self.db_path, self.file_records)
            self.records_dirty = False

    def add_record(self, file_id, record):
        with self.records_lock:
            self.file_records[file_id] = record
            self.records_dirty = True
            try:
                self.save_records()
            except Exception:
                self.file_records.pop(file_id, None)
                self.records_dirty = False
                raise

    def get_record(self, file_id):
        with self.records_lock:
            return self.file_records.get(file_id)

    async def handle_health_request(self, _request):
        return web.json_response({
            "status": "ok",
            "records": len(self.file_records),
            "records_writable": self.records_writable,
        })

    def _cache_path(self, file_id):
        return CACHE_DIR / f"{file_id}.bin"

    def _valid_cache_path(self, file_id):
        cache_path = self._cache_path(file_id)
        try:
            stat_result = cache_path.stat()
        except FileNotFoundError:
            return None
        age = datetime.now(timezone.utc).timestamp() - stat_result.st_mtime
        if not cache_path.is_file() or stat_result.st_size <= 0 or age > self.config["cache_ttl_seconds"]:
            cache_path.unlink(missing_ok=True)
            return None
        return cache_path

    def _prune_cache(self, exclude=None):
        entries = []
        total_size = 0
        now = datetime.now(timezone.utc).timestamp()
        for cache_path in CACHE_DIR.glob("*.bin"):
            if not cache_path.is_file():
                continue
            try:
                stat_result = cache_path.stat()
            except FileNotFoundError:
                continue
            if now - stat_result.st_mtime > self.config["cache_ttl_seconds"]:
                cache_path.unlink(missing_ok=True)
                continue
            if cache_path == exclude:
                total_size += stat_result.st_size
                continue
            entries.append((stat_result.st_mtime, stat_result.st_size, cache_path))
            total_size += stat_result.st_size
        max_bytes = self.config["cache_max_bytes"]
        for _mtime, size, cache_path in sorted(entries):
            if total_size <= max_bytes:
                break
            cache_path.unlink(missing_ok=True)
            total_size -= size

    async def _download_to_cache(self, file_id, telegram_file_id):
        cached = self._valid_cache_path(file_id)
        if cached:
            return cached
        try:
            await asyncio.wait_for(self.download_semaphore.acquire(), timeout=1.0)
        except asyncio.TimeoutError as exc:
            raise web.HTTPServiceUnavailable(text="Too many concurrent downloads") from exc
        temp_name = None
        try:
            cached = self._valid_cache_path(file_id)
            if cached:
                return cached
            telegram_file = await self.bot.get_file(telegram_file_id)
            remote_size = getattr(telegram_file, "file_size", None)
            if remote_size and remote_size > self.config["max_file_bytes"]:
                raise web.HTTPRequestEntityTooLarge(
                    max_size=self.config["max_file_bytes"], actual_size=remote_size
                )
            descriptor, temp_name = tempfile.mkstemp(prefix=".download.", dir=CACHE_DIR)
            os.close(descriptor)
            os.chmod(temp_name, 0o600)
            await telegram_file.download_to_drive(custom_path=temp_name)
            actual_size = os.path.getsize(temp_name)
            if actual_size <= 0 or actual_size > self.config["max_file_bytes"]:
                raise web.HTTPRequestEntityTooLarge(
                    max_size=self.config["max_file_bytes"], actual_size=actual_size
                )
            cache_path = self._cache_path(file_id)
            os.replace(temp_name, cache_path)
            temp_name = None
            os.chmod(cache_path, 0o600)
            _fsync_directory(CACHE_DIR)
            self._prune_cache(exclude=cache_path)
            return cache_path
        finally:
            self.download_semaphore.release()
            if temp_name:
                try:
                    os.unlink(temp_name)
                except FileNotFoundError:
                    pass

    async def _stream_file(self, request, cache_path, file_id, mime_type):
        etag = f'"{file_id}"'
        if request.headers.get("If-None-Match") == etag:
            return web.Response(status=304, headers={"ETag": etag})
        response = web.StreamResponse(
            status=200,
            headers={
                "Content-Type": mime_type,
                "Content-Length": str(cache_path.stat().st_size),
                "Cache-Control": "public, max-age=86400, immutable",
                "ETag": etag,
                "X-Content-Type-Options": "nosniff",
            },
        )
        await response.prepare(request)
        with open(cache_path, "rb") as cached_file:
            while True:
                chunk = cached_file.read(64 * 1024)
                if not chunk:
                    break
                await response.write(chunk)
        await response.write_eof()
        return response

    async def handle_image_request(self, request):
        file_id = request.match_info.get("file_id", "")
        if not RECORD_ID_RE.fullmatch(file_id):
            return web.Response(status=404, text="Image not found")
        record = self.get_record(file_id)
        if not record:
            return web.Response(status=404, text="Image not found")
        try:
            cache_path = await self._download_to_cache(file_id, record[2])
            return await self._stream_file(request, cache_path, file_id, record[3])
        except web.HTTPException:
            raise
        except Exception as exc:
            logger.error("获取图片失败 (%s): %s", file_id, exc, exc_info=True)
            return web.Response(status=502, text="Image temporarily unavailable")

    async def start_web_server(self):
        self.runner = web.AppRunner(self.app, access_log=None)
        await self.runner.setup()
        self.site = web.TCPSite(
            self.runner,
            self.config["listen_host"],
            self.config["listen_port"],
        )
        await self.site.start()
        logger.info(
            "Web 服务已启动在 %s:%s",
            self.config["listen_host"],
            self.config["listen_port"],
        )

    async def stop_web_server(self):
        if self.records_dirty and self.records_writable:
            await asyncio.to_thread(self.save_records)
        if self.site:
            await self.site.stop()
        if self.runner:
            await self.runner.cleanup()


async def start_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id not in context.bot_data["allowed_users"]:
        await update.message.reply_text("❌ 您没有权限使用此命令。")
        return
    await update.message.reply_text(
        "🖼️ ImgHub 图床机器人\n\n发送图片或图片文件即可获取直链。"
    )


async def handle_media(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    if user.id not in context.bot_data["allowed_users"]:
        await update.message.reply_text("❌ 未经授权，无法上传图片。")
        return
    downloaded_path = None
    try:
        bot: Bot = context.bot
        service: ImageHostingService = context.bot_data["img_service"]
        channel_id = context.bot_data["channel_id"]
        channel_username = context.bot_data["channel_username"]
        base_url = context.bot_data["base_url"]
        media = None
        mime_type = "image/jpeg"
        filename = "image.jpg"
        source_size = 0

        if update.message.photo:
            media = update.message.photo[-1]
            source_size = media.file_size or 0
            filename = f"photo_{media.file_unique_id}.jpg"
        elif update.message.document and update.message.document.mime_type in ALLOWED_MIME_TYPES:
            media = update.message.document
            mime_type = media.mime_type
            source_size = media.file_size or 0
            filename = media.file_name or f"image_{media.file_unique_id}"
        else:
            await update.message.reply_text("❌ 仅支持 JPEG、PNG、GIF 或 WebP 图片。")
            return
        if source_size > service.config["max_file_bytes"]:
            await update.message.reply_text("❌ 文件超过允许的大小限制。")
            return

        telegram_file = await media.get_file()
        upload_tmp_dir = DATA_DIR / "tmp"
        upload_tmp_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor, downloaded_path = tempfile.mkstemp(prefix="upload.", dir=upload_tmp_dir)
        os.close(descriptor)
        os.chmod(downloaded_path, 0o600)
        await telegram_file.download_to_drive(custom_path=downloaded_path)
        actual_size = os.path.getsize(downloaded_path)
        if actual_size <= 0 or actual_size > service.config["max_file_bytes"]:
            await update.message.reply_text("❌ 下载后的文件大小无效或超过限制。")
            return

        caption = (
            f"Uploaded by: {user.id} ({user.username or 'N/A'})\n"
            f"Original Filename: {filename}\nMIME: {mime_type}\n"
            f"Timestamp: {datetime.now(timezone.utc).isoformat()}"
        )
        if update.message.caption:
            caption = f"{update.message.caption}\n-----\n{caption}"
        with open(downloaded_path, "rb") as upload_file:
            if mime_type == "image/gif":
                sent_message = await bot.send_animation(
                    chat_id=channel_id, animation=upload_file, caption=caption
                )
            else:
                sent_message = await bot.send_document(
                    chat_id=channel_id,
                    document=upload_file,
                    caption=caption,
                    filename=filename,
                )
        if not sent_message:
            raise RuntimeError("Telegram 频道未返回消息")
        if sent_message.animation:
            persistent_file_id = sent_message.animation.file_id
        elif sent_message.document:
            persistent_file_id = sent_message.document.file_id
        elif sent_message.photo:
            persistent_file_id = sent_message.photo[-1].file_id
        else:
            raise RuntimeError("Telegram 频道消息不包含媒体")

        channel_text = str(channel_id)
        channel_part = channel_text[4:] if channel_text.startswith("-100") else channel_text.lstrip("-")
        while True:
            public_id = secrets.token_hex(6)
            if not service.get_record(public_id):
                break
        record = (channel_part, sent_message.message_id, persistent_file_id, mime_type)
        await asyncio.to_thread(service.add_record, public_id, record)

        direct_link = f"{base_url}/i/{public_id}"
        if channel_username:
            backup_link = f"https://t.me/{channel_username}/{sent_message.message_id}"
        else:
            backup_link = f"https://t.me/c/{channel_part}/{sent_message.message_id}"
        await update.message.reply_text(
            f"✅ 图片上传成功!\n\n🔗 直链地址: {direct_link}\n📎 备用地址: {backup_link}",
            disable_web_page_preview=True,
            reply_to_message_id=update.message.message_id,
        )
    except Exception as exc:
        logger.error("媒体处理失败: %s", exc, exc_info=True)
        await update.message.reply_text("⚠️ 上传失败，记录库未修改，请检查服务日志。")
    finally:
        if downloaded_path:
            try:
                os.unlink(downloaded_path)
            except FileNotFoundError:
                pass
            except OSError as exc:
                logger.error("清理上传临时文件失败 %s: %s", downloaded_path, exc)


def setup_handlers(application):
    application.add_handler(CommandHandler("start", start_command))
    application.add_handler(MessageHandler(filters.PHOTO | filters.Document.IMAGE, handle_media))


async def safe_shutdown(application, service):
    if service:
        try:
            await service.stop_web_server()
        except Exception as exc:
            logger.error("停止 Web 服务失败: %s", exc, exc_info=True)
    if application:
        try:
            if application.updater and application.updater.running:
                await application.updater.stop()
            if application.running:
                await application.stop()
            await application.shutdown()
        except Exception as exc:
            logger.error("停止 Telegram Application 失败: %s", exc, exc_info=True)


async def main():
    runtime_config = load_config()
    if CHECK_CONFIG_ONLY:
        print("ImgHub configuration OK")
        return
    DATA_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    CACHE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    if runtime_config["listen_host"] in {"0.0.0.0", "::"}:
        logger.warning("Web 服务被明确配置为全局监听，请确保外部访问受到反向代理或防火墙保护")

    application = None
    service = None
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signal_name in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(signal_name, stop_event.set)
        except (NotImplementedError, RuntimeError):
            pass
    try:
        application = Application.builder().token(runtime_config["bot_token"]).build()
        service = ImageHostingService(application.bot, runtime_config)
        application.bot_data.update({
            "img_service": service,
            "channel_id": runtime_config["channel_id"],
            "channel_username": runtime_config["channel_username"],
            "allowed_users": runtime_config["allowed_users"],
            "base_url": runtime_config["base_url"],
        })
        setup_handlers(application)
        await application.initialize()
        chat = await application.bot.get_chat(runtime_config["channel_id"])
        member = await application.bot.get_chat_member(
            runtime_config["channel_id"], application.bot.id
        )
        if member.status not in {"administrator", "creator"}:
            raise BotConfigError("Bot 必须是目标频道的管理员")
        configured_username = runtime_config["channel_username"]
        if configured_username and (
            not chat.username or configured_username.lower() != chat.username.lower()
        ):
            raise BotConfigError("配置的频道用户名与 Telegram 返回值不匹配")
        await application.start()
        if not application.updater:
            raise RuntimeError("Telegram updater 未初始化")
        await application.updater.start_polling()
        await service.start_web_server()
        logger.info(
            "ImgHub 已启动；监听 %s:%s，已加载 %d 条记录",
            runtime_config["listen_host"],
            runtime_config["listen_port"],
            len(service.file_records),
        )
        await stop_event.wait()
    finally:
        await safe_shutdown(application, service)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("收到键盘中断，正在退出")
    except Exception as exc:
        logger.critical("ImgHub 启动或运行失败: %s", exc, exc_info=True)
        raise SystemExit(1) from exc
END_OF_PYTHON_SCRIPT
)

SYSTEMD_SERVICE_CONTENT=$(cat <<END_OF_SYSTEMD_SERVICE
[Unit]
Description=ImgHub Telegram Bot Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${PYTHON_SCRIPT_DIR}
Environment=PYTHONUNBUFFERED=1
Environment=IMGHUB_CONFIG_PATH=${CONFIG_FILE_PATH}
Environment=IMGHUB_DATA_DIR=${DATA_DIR}
Environment=IMGHUB_CACHE_DIR=${CACHE_DIR}
ExecStart=/usr/bin/python3 ${PYTHON_SCRIPT_PATH}
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
END_OF_SYSTEMD_SERVICE
)

print_info() { echo -e "${CYAN}[信息]${NC} $1"; }
print_success() { echo -e "${GREEN}[成功]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error() { echo -e "${RED}[错误]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限执行。"
        return 1
    fi
}

validate_runtime_settings() {
    [[ "$BACKUP_KEEP" =~ ^[1-9][0-9]*$ ]] || { print_error "备份数量无效。"; return 1; }
    [[ "$STARTUP_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || { print_error "启动检查次数无效。"; return 1; }
    [[ "$STARTUP_INTERVAL" =~ ^[0-9]+$ ]] || { print_error "启动检查间隔无效。"; return 1; }
    if [[ ! "$HEALTH_PORT" =~ ^[1-9][0-9]*$ ]] || ((10#$HEALTH_PORT > 65535)); then
        print_error "健康检查端口无效。"
        return 1
    fi
}

atomic_install_file() {
    local source_file="$1" target_file="$2" mode="$3" target_dir temp_file
    target_dir=$(dirname -- "$target_file")
    install -d -m 755 "$target_dir" || return 1
    temp_file=$(mktemp "$target_dir/.imghub-install.XXXXXXXX") || return 1
    if ! install -m "$mode" "$source_file" "$temp_file" || ! mv -f -- "$temp_file" "$target_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
}

snapshot_optional_file() {
    local source_file="$1" backup_file="$2" missing_file="$3"
    if [[ -e "$source_file" || -L "$source_file" ]]; then
        [[ -f "$source_file" && ! -L "$source_file" ]] || return 1
        cp -a -- "$source_file" "$backup_file"
    else
        : > "$missing_file"
    fi
}

restore_optional_file() {
    local target_file="$1" backup_file="$2" missing_file="$3" fallback_mode="$4" mode
    if [[ -f "$missing_file" ]]; then
        rm -f -- "$target_file"
    elif [[ -f "$backup_file" ]]; then
        mode=$(stat -c '%a' "$backup_file" 2>/dev/null) || mode="$fallback_mode"
        atomic_install_file "$backup_file" "$target_file" "$mode"
    else
        return 1
    fi
}

prune_transaction_backups() {
    local index
    local -a backups=()
    mapfile -t backups < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
        -name 'transaction.*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    for ((index=BACKUP_KEEP; index<${#backups[@]}; index++)); do
        [[ "${backups[$index]}" == "$BACKUP_ROOT/transaction."* ]] || continue
        rm -rf -- "${backups[$index]}"
    done
}

create_transaction_backup() {
    local backup_dir active=false enabled=false
    umask 077
    install -d -m 700 "$BACKUP_ROOT" || return 1
    backup_dir=$(mktemp -d "$BACKUP_ROOT/transaction.XXXXXXXX") || return 1
    chmod 700 "$backup_dir" || return 1
    snapshot_optional_file "$PYTHON_SCRIPT_PATH" "$backup_dir/imghub_bot.py" "$backup_dir/python.missing" || return 1
    snapshot_optional_file "$CONFIG_FILE_PATH" "$backup_dir/imghub_config.ini" "$backup_dir/config.missing" || return 1
    snapshot_optional_file "$SERVICE_FILE" "$backup_dir/imghub.service" "$backup_dir/service.missing" || return 1
    snapshot_optional_file "$DATA_DIR/records.json" "$backup_dir/records.json" "$backup_dir/records.missing" || return 1
    snapshot_optional_file "$DATA_DIR/records.json.last-good" "$backup_dir/records.last-good" "$backup_dir/records.last-good.missing" || return 1
    systemctl is-active --quiet "$SERVICE_NAME.service" 2>/dev/null && active=true
    systemctl is-enabled --quiet "$SERVICE_NAME.service" 2>/dev/null && enabled=true
    printf '%s\n' "$active" > "$backup_dir/service.active"
    printf '%s\n' "$enabled" > "$backup_dir/service.enabled"
    prune_transaction_backups
    printf '%s\n' "$backup_dir"
}

restore_service_state() {
    local backup_dir="$1" was_active was_enabled status=0
    was_active=$(< "$backup_dir/service.active")
    was_enabled=$(< "$backup_dir/service.enabled")
    systemctl daemon-reload >/dev/null 2>&1 || status=1
    if [[ -f "$backup_dir/service.missing" ]]; then
        systemctl disable "$SERVICE_NAME.service" >/dev/null 2>&1 || true
        systemctl stop "$SERVICE_NAME.service" >/dev/null 2>&1 || true
        return "$status"
    fi
    if [[ "$was_enabled" == true ]]; then
        systemctl enable "$SERVICE_NAME.service" >/dev/null 2>&1 || status=1
    else
        systemctl disable "$SERVICE_NAME.service" >/dev/null 2>&1 || status=1
    fi
    if [[ "$was_active" == true ]]; then
        systemctl restart "$SERVICE_NAME.service" >/dev/null 2>&1 || status=1
    else
        systemctl stop "$SERVICE_NAME.service" >/dev/null 2>&1 || status=1
    fi
    return "$status"
}

restore_transaction_backup() {
    local backup_dir="$1" status=0
    restore_optional_file "$PYTHON_SCRIPT_PATH" "$backup_dir/imghub_bot.py" "$backup_dir/python.missing" 755 || status=1
    restore_optional_file "$CONFIG_FILE_PATH" "$backup_dir/imghub_config.ini" "$backup_dir/config.missing" 600 || status=1
    restore_optional_file "$SERVICE_FILE" "$backup_dir/imghub.service" "$backup_dir/service.missing" 644 || status=1
    restore_optional_file "$DATA_DIR/records.json" "$backup_dir/records.json" "$backup_dir/records.missing" 600 || status=1
    restore_optional_file "$DATA_DIR/records.json.last-good" "$backup_dir/records.last-good" "$backup_dir/records.last-good.missing" 600 || status=1
    restore_service_state "$backup_dir" || status=1
    return "$status"
}

INSTALL_TRANSACTION_ACTIVE=false
INSTALL_FILES_COMMITTED=false
INSTALL_BACKUP_DIR=''

rollback_active_transaction() {
    local exit_status="${1:-1}"
    [[ "$INSTALL_TRANSACTION_ACTIVE" == true ]] || return "$exit_status"
    INSTALL_TRANSACTION_ACTIVE=false
    if [[ "$INSTALL_FILES_COMMITTED" == true ]]; then
        print_warning "安装未完成，正在恢复旧脚本、配置、服务和记录库。"
        restore_transaction_backup "$INSTALL_BACKUP_DIR" \
            || print_error "自动恢复未完全成功，请使用备份: $INSTALL_BACKUP_DIR"
    else
        print_warning "安装在提交前停止，旧服务和文件未修改。"
    fi
    return "$exit_status"
}

transaction_exit_trap() {
    local exit_status=$?
    rollback_active_transaction "$exit_status" || true
}

transaction_signal_trap() {
    rollback_active_transaction 130 || true
    exit 130
}

install_dependencies() {
    print_info "正在安装系统和 Python 依赖；此阶段不会停止旧服务。"
    DEBIAN_FRONTEND=noninteractive apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-pip python3-venv curl || return 1
    pip3 install --upgrade "python-telegram-bot[job-queue]" aiohttp --break-system-packages || return 1
}

is_valid_bot_token() {
    [[ "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *$'\t'* \
        && "$1" =~ ^[0-9]{5,15}:[A-Za-z0-9_-]{30,}$ ]]
}

is_valid_channel_id() {
    [[ "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *$'\t'* \
        && "$1" =~ ^-100[0-9]{6,16}$ ]]
}

is_valid_channel_username() {
    [[ "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *$'\t'* ]] || return 1
    [[ -z "$1" || "$1" =~ ^[A-Za-z][A-Za-z0-9_]{4,31}$ ]]
}

is_valid_allowed_users() {
    local user_id
    local -A seen=()
    local -a user_ids=()
    [[ "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *$'\t'* ]] || return 1
    [[ "$1" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]] || return 1
    IFS=',' read -r -a user_ids <<< "$1"
    for user_id in "${user_ids[@]}"; do
        [[ -z "${seen[$user_id]:-}" ]] || return 1
        seen["$user_id"]=1
    done
}

is_valid_base_url() {
    local value="$1" host port label octet
    local -a labels=() octets=()
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]] || return 1
    [[ "$value" =~ ^https?://([^/:]+)(:([0-9]+))?/?$ ]] || return 1
    host=${BASH_REMATCH[1]}
    port=${BASH_REMATCH[3]:-}
    if [[ -n "$port" ]]; then
        [[ "$port" =~ ^[1-9][0-9]*$ ]] && ((${#port} <= 5)) && ((10#$port <= 65535)) || return 1
    fi
    if [[ "$host" =~ ^[0-9]+([.][0-9]+){3}$ ]]; then
        IFS='.' read -r -a octets <<< "$host"
        for octet in "${octets[@]}"; do
            [[ "$octet" == 0 || "$octet" != 0* ]] || return 1
            ((10#$octet <= 255)) || return 1
        done
        return 0
    fi
    IFS='.' read -r -a labels <<< "$host"
    ((${#labels[@]} >= 2)) || return 1
    for label in "${labels[@]}"; do
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
        ((${#label} <= 63)) || return 1
    done
}

write_config_candidate() {
    local output_file="$1" bot_token="$2" channel_id="$3" channel_username="$4" allowed_users="$5" base_url="$6"
    cat > "$output_file" <<EOF
[telegram]
bot_token = $bot_token
channel_id = $channel_id
channel_username = $channel_username

[access]
allowed_users = $allowed_users

[server]
base_url = ${base_url%/}
listen_host = 127.0.0.1
listen_port = $HEALTH_PORT

[limits]
max_file_bytes = 20971520
max_concurrency = 4

[cache]
max_bytes = 268435456
ttl_seconds = 86400
EOF
    chmod 600 "$output_file"
}

setup_config_interactive() {
    local output_file="$1" bot_token channel_id channel_username allowed_users base_url
    print_info "--- ImgHub Bot 配置向导 ---"
    while true; do
        read -r -p "请输入 Telegram Bot Token: " bot_token
        is_valid_bot_token "$bot_token" && break
        print_error "Bot Token 格式无效。"
    done
    while true; do
        read -r -p "请输入 Telegram 频道 ID（以 -100 开头）: " channel_id
        is_valid_channel_id "$channel_id" && break
        print_error "频道 ID 格式无效。"
    done
    while true; do
        read -r -p "请输入公开频道用户名（可留空，不含 @）: " channel_username
        channel_username=${channel_username#@}
        is_valid_channel_username "$channel_username" && break
        print_error "频道用户名必须为 5-32 位字母、数字或下划线，并以字母开头。"
    done
    while true; do
        read -r -p "请输入授权用户 ID（多个用英文逗号分隔）: " allowed_users
        is_valid_allowed_users "$allowed_users" && break
        print_error "授权用户必须是逗号分隔的正整数，且不能为空。"
    done
    while true; do
        read -r -p "请输入完整基础 URL（不含路径）: " base_url
        is_valid_base_url "$base_url" && break
        print_error "基础 URL 必须是无路径、查询参数和片段的 http/https URL。"
    done
    write_config_candidate "$output_file" "$bot_token" "$channel_id" "$channel_username" "$allowed_users" "$base_url"
}

write_stage_files() {
    local stage_dir="$1"
    printf '%s\n' "$PYTHON_SCRIPT_CONTENT" > "$stage_dir/imghub_bot.py" || return 1
    printf '%s\n' "$SYSTEMD_SERVICE_CONTENT" > "$stage_dir/imghub.service" || return 1
    chmod 755 "$stage_dir/imghub_bot.py"
    chmod 644 "$stage_dir/imghub.service"
}

validate_stage_files() {
    local stage_dir="$1"
    python3 -m py_compile "$stage_dir/imghub_bot.py" || {
        print_error "Python 主程序语法检查失败。"
        return 1
    }
    IMGHUB_CONFIG_PATH="$stage_dir/imghub_config.ini" \
        IMGHUB_DATA_DIR="$DATA_DIR" IMGHUB_CACHE_DIR="$CACHE_DIR" \
        IMGHUB_CHECK_CONFIG_ONLY=1 python3 "$stage_dir/imghub_bot.py" >/dev/null || {
            print_error "候选配置运行时校验失败。"
            return 1
        }
    grep -Fxq "ExecStart=/usr/bin/python3 $PYTHON_SCRIPT_PATH" "$stage_dir/imghub.service" || return 1
    grep -Fxq "Environment=IMGHUB_CONFIG_PATH=$CONFIG_FILE_PATH" "$stage_dir/imghub.service" || return 1
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze verify "$stage_dir/imghub.service" >/dev/null 2>&1 || {
            print_error "候选 systemd service 校验失败。"
            return 1
        }
    fi
}

wait_for_stable_service() {
    local attempt active_restarts previous_restarts='' healthy_streak=0
    for ((attempt=1; attempt<=STARTUP_ATTEMPTS; attempt++)); do
        if systemctl is-active --quiet "$SERVICE_NAME.service"; then
            active_restarts=$(systemctl show "$SERVICE_NAME.service" -p NRestarts --value 2>/dev/null || echo unknown)
            if curl -fsS --max-time 2 "http://127.0.0.1:${HEALTH_PORT}/healthz" >/dev/null 2>&1 \
                && [[ -n "$active_restarts" && "$active_restarts" != unknown ]] \
                && { [[ -z "$previous_restarts" ]] || [[ "$active_restarts" == "$previous_restarts" ]]; }; then
                healthy_streak=$((healthy_streak + 1))
                ((healthy_streak >= 2)) && return 0
            else
                healthy_streak=0
            fi
            previous_restarts="$active_restarts"
        else
            healthy_streak=0
        fi
        sleep "$STARTUP_INTERVAL"
    done
    return 1
}

commit_stage_files() {
    local stage_dir="$1"
    install -d -m 755 "$PYTHON_SCRIPT_DIR" || return 1
    install -d -m 700 "$DATA_DIR" "$CACHE_DIR" || return 1
    INSTALL_FILES_COMMITTED=true
    systemctl stop "$SERVICE_NAME.service" >/dev/null 2>&1 || true
    atomic_install_file "$stage_dir/imghub_bot.py" "$PYTHON_SCRIPT_PATH" 755 || return 1
    atomic_install_file "$stage_dir/imghub_config.ini" "$CONFIG_FILE_PATH" 600 || return 1
    atomic_install_file "$stage_dir/imghub.service" "$SERVICE_FILE" 644 || return 1
    systemctl daemon-reload || return 1
    systemctl enable "$SERVICE_NAME.service" || return 1
    systemctl start "$SERVICE_NAME.service" || return 1
    wait_for_stable_service || {
        print_error "服务未通过稳定性和 HTTP 健康检查。"
        journalctl -u "$SERVICE_NAME.service" -n 100 --no-pager 2>/dev/null || true
        return 1
    }
}

show_completion() {
    local base_url channel_username
    base_url=$(sed -n 's/^[[:space:]]*base_url[[:space:]]*=[[:space:]]*//p' "$CONFIG_FILE_PATH" | head -n 1)
    channel_username=$(sed -n 's/^[[:space:]]*channel_username[[:space:]]*=[[:space:]]*//p' "$CONFIG_FILE_PATH" | head -n 1)
    print_success "ImgHub Bot 安装/更新完成。"
    print_info "内部 Web 服务仅监听 http://127.0.0.1:${HEALTH_PORT}"
    print_info "请将反向代理的 $base_url 指向 http://127.0.0.1:${HEALTH_PORT}"
    [[ -z "$channel_username" ]] || print_info "公开频道: @$channel_username"
    echo -e "查看状态: ${YELLOW}systemctl status ${SERVICE_NAME}.service${NC}"
    echo -e "查看日志: ${YELLOW}journalctl -u ${SERVICE_NAME}.service -f --no-pager${NC}"
    echo -e "编辑配置: ${YELLOW}$CONFIG_FILE_PATH${NC}"
    echo -e "Python 脚本: ${YELLOW}$PYTHON_SCRIPT_PATH${NC}"
}

main() {
    local confirm stage_dir result=0
    check_root || return 1
    validate_runtime_settings || return 1
    if systemctl is-active --quiet "$SERVICE_NAME.service" 2>/dev/null; then
        print_warning "检测到旧服务正在运行；验证候选文件期间不会停止它。"
        read -r -p "确认继续更新？[y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { print_warning "已取消。"; return 0; }
    fi
    stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/imghub-stage.XXXXXXXX") || return 1
    write_stage_files "$stage_dir" || { rm -rf -- "$stage_dir"; return 1; }
    if ! setup_config_interactive "$stage_dir/imghub_config.ini"; then
        rm -rf -- "$stage_dir"
        return 1
    fi
    INSTALL_BACKUP_DIR=$(create_transaction_backup) || {
        rm -rf -- "$stage_dir"
        print_error "无法创建完整安装前备份。"
        return 1
    }
    INSTALL_TRANSACTION_ACTIVE=true
    INSTALL_FILES_COMMITTED=false
    trap transaction_exit_trap EXIT
    trap transaction_signal_trap INT TERM
    print_info "完整安装前备份: $INSTALL_BACKUP_DIR"
    if ! install_dependencies \
        || ! validate_stage_files "$stage_dir" \
        || ! commit_stage_files "$stage_dir"; then
        result=1
    fi
    rm -rf -- "$stage_dir"
    if ((result != 0)); then
        rollback_active_transaction "$result" || true
        trap - EXIT INT TERM
        return "$result"
    fi
    INSTALL_TRANSACTION_ACTIVE=false
    trap - EXIT INT TERM
    show_completion
}

if [[ ${IMGHUB_INSTALLER_SOURCE_ONLY:-0} != 1 ]]; then
    main "$@"
fi
