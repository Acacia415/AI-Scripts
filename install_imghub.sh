#!/bin/bash

set -o pipefail

# ImgHub Bot 一键安装脚本
# 支持系统: Debian/Ubuntu 及其衍生版

# --- 配置 ---
PYTHON_SCRIPT_PATH="/opt/imghub_bot/imghub_bot.py"
PYTHON_SCRIPT_DIR=$(dirname "${PYTHON_SCRIPT_PATH}")
CONFIG_FILE_PATH="/etc/imghub/config.ini"
DATA_DIR="/var/lib/imghub"
SERVICE_NAME="imghub_bot"

# --- 颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Python 脚本内容 ---
PYTHON_SCRIPT_CONTENT=$(cat <<'END_OF_PYTHON_SCRIPT'
#!/usr/bin/python3
import os
import json
import logging
import asyncio
import configparser
import tempfile
from datetime import datetime
from signal import SIGTERM # Not directly used in this version for shutdown, but good for reference
from telegram import Update, Bot, InputFile
from telegram.ext import (
    Application,
    CommandHandler,
    MessageHandler,
    filters,
    ContextTypes,
)
from aiohttp import web
from io import BytesIO
from pathlib import Path # <--- 确保导入 pathlib

# 配置日志记录
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler()]
)
logger = logging.getLogger(__name__)

# 全局配置
CONFIG_PATH = '/etc/imghub/config.ini'
BASE_URL_FALLBACK = "https://example.com" # Fallback, should be overridden by config
MAX_UPLOAD_BYTES = 20 * 1024 * 1024

class BotConfigError(Exception):
    """自定义配置异常"""
    pass

class ImageHostingService:
    def __init__(self, bot):
        """初始化图床服务

        Args:
            bot: Telegram Bot实例
        """
        self.bot = bot
        self.file_records = {}  # 存储文件记录 {file_id: (channel_part, message_id, original_file_id, mime_type)}
        self.db_path = "/var/lib/imghub/records.json"
        # 加载已有记录
        self.load_records()

        # 设置Web应用
        self.app = web.Application()
        self.app['bot'] = bot  # 保存bot实例到应用上下文
        self.app.add_routes([web.get('/i/{file_id}', self.handle_image_request)])
        self.runner = None
        self.site = None

    def load_records(self):
        """从文件加载记录"""
        try:
            if os.path.exists(self.db_path):
                with open(self.db_path, 'r') as f:
                    self.file_records = json.load(f)
                logger.info(f"成功加载了 {len(self.file_records)} 条文件记录")
        except Exception as e:
            logger.error(f"加载记录失败: {str(e)}")

    def save_records(self):
        """保存记录到文件"""
        try:
            os.makedirs(os.path.dirname(self.db_path), exist_ok=True)
            db_dir = os.path.dirname(self.db_path)
            with tempfile.NamedTemporaryFile('w', dir=db_dir, delete=False) as f:
                json.dump(self.file_records, f, indent=4)
                f.flush()
                os.fsync(f.fileno())
                temp_name = f.name
            os.replace(temp_name, self.db_path)
            logger.info(f"成功保存了 {len(self.file_records)} 条文件记录")
        except Exception as e:
            logger.error(f"保存记录失败: {str(e)}")

    async def handle_image_request(self, request):
        """处理图片请求 - 直接返回图片内容"""
        file_id = request.match_info.get('file_id')
        if file_id not in self.file_records:
            return web.Response(status=404, text="Image not found")

        try:
            record = self.file_records[file_id]
            # channel_part = record[0] # Not directly used for fetching file
            # message_id = record[1] # Not directly used for fetching file
            original_file_id = record[2]
            mime_type = record[3]

            # 通过原始文件ID获取文件
            file = await self.bot.get_file(original_file_id)
            file_content_bytearray = await file.download_as_bytearray()

            # 返回图片内容
            return web.Response(
                body=bytes(file_content_bytearray),
                content_type=mime_type,
                headers={
                    'Cache-Control': 'public, max-age=31536000',  # 缓存一年
                    'ETag': file_id
                }
            )
        except Exception as e:
            logger.error(f"获取图片失败 ({file_id}): {str(e)}", exc_info=True)

            # 备用方案: 返回Telegram链接重定向
            try:
                if file_id in self.file_records:
                    record = self.file_records[file_id]
                    return web.Response(
                        status=302,
                        headers={
                            'Location': f'https://t.me/c/{record[0]}/{record[1]}'
                        }
                    )
            except Exception as fallback_e:
                logger.error(f"备用重定向失败 ({file_id}): {str(fallback_e)}", exc_info=True)

            # 所有尝试都失败
            return web.Response(status=500, text="无法获取图片，请稍后重试")

    async def run_web_server(self):
        """启动Web服务器（异步版本）"""
        self.runner = web.AppRunner(self.app)
        await self.runner.setup()
        self.site = web.TCPSite(self.runner, '127.0.0.1', 8080)
        await self.site.start()
        logger.info("Web服务器已启动在 127.0.0.1:8080")

        # 定期保存记录
        while True:
            await asyncio.sleep(300)  # 每5分钟保存一次
            self.save_records()

    async def stop_web_server(self):
        """停止Web服务器"""
        # 保存记录
        self.save_records()

        # 停止服务
        if self.site:
            await self.site.stop()
            logger.info("Web TCPSite 已停止.")
        if self.runner:
            await self.runner.cleanup()
            logger.info("Web AppRunner 已清理.")
        logger.info("Web服务器已停止.")


def load_config() -> tuple:
    """加载配置文件"""
    try:
        config = configparser.ConfigParser()
        if not os.path.exists(CONFIG_PATH):
             raise FileNotFoundError(f"重要: 配置文件 {CONFIG_PATH} 未找到! 请确保已正确创建并配置.")
        if not config.read(CONFIG_PATH):
            # This case might be less common if os.path.exists passed, but good for robustness
            raise BotConfigError(f"配置文件 {CONFIG_PATH} 为空或无法读取.")


        bot_token = config.get('telegram', 'bot_token').strip()
        channel_id_str = config.get('telegram', 'channel_id').strip()
        channel_username = config.get('telegram', 'channel_username', fallback="").strip()
        
        allowed_users_str = config.get('access', 'allowed_users', fallback="").strip()
        allowed_users = [int(uid.strip()) for uid in allowed_users_str.split(',') if uid.strip()]
        
        base_url = config.get('server', 'base_url', fallback=BASE_URL_FALLBACK).strip()

        if not bot_token:
            raise BotConfigError("配置错误: bot_token 不能为空.")
        if not channel_id_str:
            raise BotConfigError("配置错误: channel_id 不能为空.")
        # It's fine if allowed_users is empty, meaning no one is explicitly allowed initially by this check.
        # The bot logic handles this.
        if not base_url:
            raise BotConfigError("配置错误: base_url 不能为空.")
            
        return (
            bot_token,
            channel_id_str, # Keep as string, convert to int later where needed
            channel_username,  # 添加频道用户名
            allowed_users,
            base_url
        )
    except (configparser.NoSectionError, configparser.NoOptionError, ValueError) as e:
        raise BotConfigError(f"配置文件格式错误或值无效: {str(e)}") from e
    except FileNotFoundError as e:
        raise BotConfigError(str(e)) from e


async def safe_shutdown(application: Application, img_service: ImageHostingService):
    """安全关闭流程"""
    logger.info("正在关闭服务...")

    # Stop the web server first
    if img_service:
        logger.info("正在停止内部Web服务器...")
        await img_service.stop_web_server()

    # Then stop the Telegram bot application
    try:
        if application:
            if application.updater and application.updater.running:
                logger.info("正在停止 Telegram Updater...")
                await application.updater.stop()
            if application.running: # Check if application itself is marked as running
                logger.info("正在停止 Telegram Application...")
                await application.stop()
            logger.info("正在关闭 Telegram Application...")
            await application.shutdown()
        logger.info("----- 服务已安全关闭 -----")
    except Exception as e:
        logger.error(f"关闭过程中出错: {str(e)}", exc_info=True)


async def start_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """处理/start命令"""
    allowed_users = context.bot_data.get('allowed_users', [])
    if update.effective_user.id not in allowed_users:
        logger.warning(f"未授权用户 {update.effective_user.id} 尝试 /start")
        await update.message.reply_text("❌ 您没有权限使用此命令。")
        return

    base_url = context.bot_data.get('base_url', BASE_URL_FALLBACK)
    await update.message.reply_text(
        f"🖼️ ImgHub 图床机器人\n\n"
        f"发送图片即可获取直链。\n\n"
        f"请以文件格式发送图片避免压缩。\n\n"
        f"图片直链格式：<code>{base_url}/i/文件ID</code>\n\n",
        parse_mode='HTML'
    )

async def handle_media(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    logger.info("🔔 handle_media 被触发")

    user = update.effective_user
    allowed_users = context.bot_data.get('allowed_users', [])
    if user.id not in allowed_users:
        logger.warning(f"❌ 未授权用户 {user.id} ({user.username or 'N/A'}) 试图上传")
        await update.message.reply_text("❌ 未经授权的用户，无法上传图片。")
        return

    downloaded_file_path_str = None
    try:
        bot: Bot = context.bot
        img_service: ImageHostingService = context.bot_data['img_service']
        channel_id = int(context.bot_data['channel_id']) # Convert here
        channel_username = context.bot_data.get('channel_username', '')  # 从配置获取
        base_url = context.bot_data.get('base_url', BASE_URL_FALLBACK)
        
        # 检查Bot权限
        try:
            bot_member = await bot.get_chat_member(channel_id, bot.id)
            if bot_member.status not in ['administrator', 'creator']:
                logger.warning(f"Bot 在频道 {channel_id} 中不是管理员")
                await update.message.reply_text(
                    "⚠️ Bot 需要在频道中拥有管理员权限才能正常工作。\n"
                    "请将 Bot 添加为频道管理员后重试。"
                )
                return
        except Exception as e:
            logger.error(f"检查频道状态失败: {str(e)}")

        file_to_process = None
        mime_type = "image/jpeg" # Default
        file_name_for_caption = "image"

        if update.message.photo:
            logger.info("📷 收到照片")
            photo = update.message.photo[-1]
            if photo.file_size and photo.file_size > MAX_UPLOAD_BYTES:
                await update.message.reply_text("❌ 文件超过 20 MiB 限制。")
                return
            file_to_process = await photo.get_file()
            mime_type = "image/jpeg" # Telegram converts photos to jpeg
            file_name_for_caption = f"photo_{file_to_process.file_unique_id}.jpg"
        elif update.message.document:
            doc = update.message.document
            logger.info(f"📎 收到文档: {doc.file_name}, MIME: {doc.mime_type}")
            if doc.file_size and doc.file_size > MAX_UPLOAD_BYTES:
                await update.message.reply_text("❌ 文件超过 20 MiB 限制。")
                return
            file_name_for_caption = doc.file_name or f"document_{doc.file_unique_id}"
            
            # Check for supported image MIME types for documents
            supported_doc_mime_types = ["image/jpeg", "image/png", "image/gif", "image/webp"]
            if doc.mime_type and any(doc.mime_type.startswith(t) for t in supported_doc_mime_types):
                file_to_process = await doc.get_file()
                mime_type = doc.mime_type
            else:
                logger.warning(f"⚠️ 不支持的文档MIME类型: {doc.mime_type}")
                await update.message.reply_text(f"❌ 不支持的文件格式 ({doc.mime_type})。请上传 JPEG, PNG, GIF, 或 WebP 格式的图片文件。")
                return
        else:
            logger.warning("⚠️ 未识别的消息类型")
            await update.message.reply_text("❌ 请发送图片或支持的图片格式文档。")
            return

        if not file_to_process:
            logger.warning("⚠️ 文件对象为空 (可能是因为不支持的类型后没有返回)")
            await update.message.reply_text("❌ 文件处理失败，未能获取文件对象。")
            return

        original_file_id = file_to_process.file_id # This is the temporary file_id from TG server
        logger.info(f"📦 获取文件成功，临时 file_id: {original_file_id}, MIME: {mime_type}")

        # Download the file to a local path ONCE
        downloaded_file_path_str = await file_to_process.download_to_drive()
        logger.info(f"💾 文件下载到本地完成，路径：{downloaded_file_path_str}")

        file_path_obj_to_send = Path(downloaded_file_path_str)
        
        caption_text = f"Uploaded by: {user.id} ({user.username or 'N/A'})\nOriginal Filename: {file_name_for_caption}\nMIME: {mime_type}\nTimestamp: {datetime.now().isoformat()}"
        if update.message.caption:
            caption_text = f"{update.message.caption}\n-----\n{caption_text}"

        sent_message = None
        with open(file_path_obj_to_send, "rb") as file_object_to_send: 
            if mime_type.startswith("image/gif"):
                 logger.info(f"准备以动画形式发送 {mime_type}...")
                 sent_message = await bot.send_animation(
                    chat_id=channel_id,
                    animation=file_object_to_send, 
                    caption=caption_text
                )
            elif mime_type.startswith("image/png") or \
                 mime_type.startswith("image/jpeg") or \
                 mime_type.startswith("image/webp"):
                logger.info(f"准备以文档形式发送 {mime_type} 以保证质量...")
                sent_message = await bot.send_document(
                    chat_id=channel_id,
                    document=file_object_to_send, 
                    caption=caption_text,
                    filename=file_name_for_caption 
                )
            else: 
                 logger.warning(f"尝试将MIME类型 {mime_type} 作为通用文档发送。")
                 sent_message = await bot.send_document(
                    chat_id=channel_id,
                    document=file_object_to_send, 
                    caption=caption_text,
                    filename=file_name_for_caption
                )
        
        try:
            os.remove(downloaded_file_path_str)
            logger.info(f"🗑️ 临时文件 {downloaded_file_path_str} 已删除。")
        except OSError as e:
            logger.error(f"删除临时文件 {downloaded_file_path_str} 失败: {e}")

        if not sent_message or not (sent_message.photo or sent_message.animation or sent_message.document): 
            logger.error("图片未能成功发送到频道或返回消息中不包含媒体信息。")
            await update.message.reply_text("⚠️ 上传失败，无法将图片存入频道。请稍后重试。")
            return
            
        persistent_file_id_for_retrieval = ""
        if sent_message.photo: 
            persistent_file_id_for_retrieval = sent_message.photo[-1].file_id
        elif sent_message.animation: 
            persistent_file_id_for_retrieval = sent_message.animation.file_id
        elif sent_message.document: 
            persistent_file_id_for_retrieval = sent_message.document.file_id

        logger.info(f"📤 图片已发送至频道，message_id: {sent_message.message_id}, 持久化 file_id: {persistent_file_id_for_retrieval}")
        
        base_id_str = f"{sent_message.chat.id}_{sent_message.message_id}"
        import hashlib
        url_file_id = hashlib.sha1(base_id_str.encode()).hexdigest()[:8]

        import random
        import string
        id_candidate = url_file_id
        collision_count = 0
        while id_candidate in img_service.file_records:
            collision_count += 1
            suffix = ''.join(random.choices(string.ascii_lowercase + string.digits, k=2))
            id_candidate = f"{url_file_id[:8-len(suffix)]}{suffix}" 
            if collision_count > 10: 
                id_candidate = hashlib.sha1(f"{base_id_str}_{random.random()}".encode()).hexdigest()[:10]
                logger.warning(f"多次File ID碰撞后生成了更长的随机ID: {id_candidate}")
            if collision_count > 20: 
                 logger.error("无法生成唯一的File ID，存在严重问题。")
                 await update.message.reply_text("⚠️ 上传失败，无法生成唯一文件标识。")
                 return

        final_url_file_id = id_candidate

        # 修复：正确处理频道ID以生成有效的备用链接
        # Telegram 私有频道ID格式通常是 -100XXXXXXXXXX
        # 对于 t.me/c/ 链接，需要去掉前面的 -100
        channel_id_str = str(channel_id)
        if channel_id_str.startswith("-100"):
            # 去掉 -100 前缀
            channel_part_for_link = channel_id_str[4:]
        elif channel_id_str.startswith("-"):
            # 如果只是负数但不是 -100 开头，去掉负号
            channel_part_for_link = channel_id_str[1:]
        else:
            # 如果是正数，直接使用
            channel_part_for_link = channel_id_str

        img_service.file_records[final_url_file_id] = (
            channel_part_for_link,  # 存储处理后的频道ID部分
            sent_message.message_id,
            persistent_file_id_for_retrieval, 
            mime_type
        )

        logger.info(f"📝 文件记录保存: url_file_id={final_url_file_id}, channel_part={channel_part_for_link}, message_id={sent_message.message_id}")
        img_service.save_records() 

        direct_link = f"{base_url}/i/{final_url_file_id}"
        
        # 根据配置生成备用链接
        if channel_username:
            # 使用配置中的用户名（公开频道）
            # 去掉可能存在的 @ 符号
            clean_username = channel_username.lstrip('@')
            backup_link = f"https://t.me/{clean_username}/{sent_message.message_id}"
            link_note = "（公开频道链接，所有人可访问）"
        else:
            # 私有频道，使用 c/ 格式
            backup_link = f"https://t.me/c/{channel_part_for_link}/{sent_message.message_id}"
            link_note = "（私有频道链接，仅频道成员可访问）"

        response_text = (
            f"✅ 图片上传成功!\n\n"
            f"🔗 直链地址: {direct_link}\n"
            f"📎 备用地址: {backup_link}\n"
            f"   {link_note}\n\n"
        )
        
        # 如果是私有频道，添加提示
        if not channel_username:
            response_text += (
                f"💡 提示：备用链接仅对频道成员有效。\n"
                f"   如需公开访问，请使用直链地址。\n"
            )

        await update.message.reply_text(
            response_text,
            disable_web_page_preview=True,
            reply_to_message_id=update.message.message_id
        )

    except Exception as e:
        logger.error(f"❗媒体处理异常: {str(e)}", exc_info=True)
        await update.message.reply_text("⚠️ 上传过程中发生内部错误，请稍后重试。")
    finally:
        if downloaded_file_path_str and os.path.exists(downloaded_file_path_str):
            try:
                os.remove(downloaded_file_path_str)
            except OSError as cleanup_error:
                logger.error(f"清理临时文件失败: {cleanup_error}")


def setup_handlers(application: Application) -> None:
    """注册处理器"""
    application.add_handler(CommandHandler('start', start_command))
    application.add_handler(
        MessageHandler(filters.PHOTO | filters.Document.IMAGE, handle_media)
    )

async def main() -> None:
    """主函数"""
    application_instance = None 
    img_service_instance = None 

    try:
        # 修复：正确接收5个返回值
        bot_token, channel_id_str, channel_username, allowed_users, base_url = load_config()
        try:
            channel_id = int(channel_id_str)
        except ValueError:
            logger.critical(f"配置错误: channel_id '{channel_id_str}' 不是有效的整数。")
            return

        os.makedirs(os.path.dirname(ImageHostingService(None).db_path), exist_ok=True)

        application_builder = Application.builder().token(bot_token)
        application_instance = application_builder.build()
        img_service_instance = ImageHostingService(application_instance.bot)

        application_instance.bot_data['img_service'] = img_service_instance
        application_instance.bot_data['channel_id'] = channel_id
        application_instance.bot_data['channel_username'] = channel_username  # 添加到bot_data
        application_instance.bot_data['allowed_users'] = allowed_users
        application_instance.bot_data['base_url'] = base_url
        setup_handlers(application_instance)

        web_server_task = None
        try:
            logger.info("正在初始化 Telegram Application...")
            await application_instance.initialize()
            
            # 在启动前检查Bot权限和频道信息
            logger.info("正在检查Bot在频道中的权限...")
            try:
                chat = await application_instance.bot.get_chat(channel_id)
                bot_member = await application_instance.bot.get_chat_member(channel_id, application_instance.bot.id)
                
                if bot_member.status in ['administrator', 'creator']:
                    logger.info(f"✅ Bot 在频道中拥有 {bot_member.status} 权限")
                    
                    # 检查配置的用户名是否匹配
                    if chat.username:
                        logger.info(f"📢 检测到公开频道: @{chat.username}")
                        if channel_username and channel_username.lstrip('@') != chat.username:
                            logger.warning(f"⚠️ 配置的用户名 {channel_username} 与实际用户名 @{chat.username} 不匹配")
                            logger.warning(f"将使用配置的用户名 {channel_username}")
                    else:
                        logger.info(f"🔒 检测到私有频道")
                        if channel_username:
                            logger.warning(f"⚠️ 配置了用户名 {channel_username}，但频道是私有的")
                else:
                    logger.warning(f"⚠️ Bot 在频道中的权限为: {bot_member.status}")
                    logger.warning("请将 Bot 设置为频道管理员以确保正常工作")
            except Exception as e:
                logger.error(f"无法检查频道权限: {str(e)}")
                logger.error("请确保：")
                logger.error("1. 频道ID配置正确")
                logger.error("2. Bot 已被添加到频道")
                logger.error("3. Bot 在频道中拥有管理员权限")
            
            logger.info("正在启动 Telegram Application Polling...")
            await application_instance.start()
            if application_instance.updater:
                await application_instance.updater.start_polling()
            else:
                logger.error("Updater 未初始化, polling 无法启动。")
                return

            logger.info("准备启动内部 Web 服务器...")
            web_server_task = asyncio.create_task(img_service_instance.run_web_server())

            logger.info(f"----- 图床服务已成功启动 (PID: {os.getpid()}) -----")
            logger.info(f"监听频道ID: {channel_id}")
            logger.info(f"频道用户名: {'@' + channel_username if channel_username else '未设置（私有频道）'}")
            logger.info(f"授权用户列表: {allowed_users if allowed_users else '无 (请在配置文件中设置!)'}")
            logger.info(f"图床基础URL: {base_url}")
            logger.info(f"已加载 {len(img_service_instance.file_records)} 个文件记录 (来自 {img_service_instance.db_path})")

            if web_server_task:
                 await web_server_task 

        except asyncio.CancelledError:
            logger.info("主任务被取消 (可能在关闭流程中).")
        except Exception as e:
            logger.critical(f"运行时发生严重错误: {str(e)}", exc_info=True)
        finally:
            logger.info("开始执行主程序退出前的清理...")
            if web_server_task and not web_server_task.done():
                logger.info("正在取消 Web 服务器任务...")
                web_server_task.cancel()
                try:
                    await web_server_task
                except asyncio.CancelledError:
                    logger.info("Web 服务器任务已成功取消.")
                except Exception as e_wst_cancel:
                    logger.error(f"取消Web服务器任务时发生错误: {e_wst_cancel}", exc_info=True)
            
            if application_instance and img_service_instance: 
                 await safe_shutdown(application_instance, img_service_instance)
            elif img_service_instance: 
                 await img_service_instance.stop_web_server() 
            logger.info("主程序清理完成.")

    except BotConfigError as e:
        logger.critical(f"机器人配置错误: {str(e)}")
    except Exception as e:
        logger.critical(f"启动过程中发生未处理的严重错误: {str(e)}", exc_info=True)

if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("接收到终止信号 (KeyboardInterrupt)，正在关闭...")
    except SystemExit as e:
        logger.info(f"系统退出信号 ({e.code})，正在关闭...")
    finally:
        logger.info("程序最终退出。")

END_OF_PYTHON_SCRIPT
)

# --- Systemd Service 文件内容 ---
SYSTEMD_SERVICE_CONTENT=$(cat <<END_OF_SYSTEMD_SERVICE
[Unit]
Description=ImgHub Telegram Bot Service
After=network.target

[Service]
User=imghub
Group=imghub
WorkingDirectory=${PYTHON_SCRIPT_DIR}
ExecStart=${PYTHON_SCRIPT_DIR}/venv/bin/python ${PYTHON_SCRIPT_PATH}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${DATA_DIR}
# 考虑增加 TimeoutStopSec=30 来给与程序足够的时间来优雅关闭
# Environment="PYTHONUNBUFFERED=1" # 可选，用于无缓冲输出

[Install]
WantedBy=multi-user.target
END_OF_SYSTEMD_SERVICE
)

# --- 函数定义 ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：此脚本需要以 root 用户权限运行。${NC}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${GREEN}正在更新软件包列表...${NC}"
    if ! apt-get update -y; then
        echo -e "${RED}错误：无法更新软件包列表。请检查您的网络连接和软件源配置。${NC}"
        exit 1
    fi

    echo -e "${GREEN}正在检查并安装系统依赖 (python3, python3-pip, python3-venv)...${NC}"
    if ! apt-get install -y python3 python3-pip python3-venv; then
        echo -e "${RED}错误：无法安装系统依赖。${NC}"
        exit 1
    fi

    echo -e "${GREEN}正在安装 Python 依赖 (python-telegram-bot[job-queue], aiohttp)...${NC}"
    mkdir -p "${PYTHON_SCRIPT_DIR}"
    python3 -m venv "${PYTHON_SCRIPT_DIR}/venv"
    if ! "${PYTHON_SCRIPT_DIR}/venv/bin/pip" install --upgrade pip "python-telegram-bot[job-queue]" aiohttp; then
        echo -e "${RED}错误：无法安装 Python 依赖。${NC}"
        exit 1
    fi
    echo -e "${GREEN}Python 依赖安装完成。${NC}"
}

setup_config_interactive() {
    echo -e "${YELLOW}--- ImgHub Bot 配置向导 ---${NC}"
    
    local bot_token
    while true; do
        read -r -s -p "请输入您的 Telegram Bot Token: " bot_token
        echo
        if [[ "${bot_token}" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
            break
        else
            echo -e "${RED}Bot Token 格式无效，请重新输入。${NC}"
        fi
    done

    local channel_id
    while true; do
        read -p "请输入您的 Telegram 频道 ID (通常为负数，例如 -1001234567890): " channel_id
        if [[ "${channel_id}" =~ ^-?[0-9]+$ ]]; then # 检查是否为有效数字 (可带负号)
            break
        else
            echo -e "${RED}频道 ID 格式不正确，应为纯数字 (可带负号)，请重新输入。${NC}"
        fi
    done

    local channel_username
    echo -e "${YELLOW}频道类型配置：${NC}"
    echo "如果您的频道是公开频道（有 @username），请输入用户名"
    echo "如果是私有频道，直接按回车跳过"
    read -p "请输入频道用户名 (例如 @imghub7788，可留空): " channel_username
    # 清理用户名格式（去掉可能的@符号，保持一致性）
    if [[ -n "${channel_username}" ]]; then
        channel_username="${channel_username#@}"  # 去掉开头的@
        if [[ ! "${channel_username}" =~ ^[A-Za-z0-9_]{5,32}$ ]]; then
            echo -e "${RED}频道用户名格式无效。${NC}"
            return 1
        fi
        echo -e "${GREEN}已设置公开频道用户名: @${channel_username}${NC}"
    else
        echo -e "${YELLOW}未设置用户名，将作为私有频道处理${NC}"
    fi

    local allowed_users
    while true; do
        read -p "请输入授权使用此 Bot 的用户 ID (多个 ID 请用英文逗号隔开, 例如 12345678,87654321): " allowed_users
        if [[ -n "${allowed_users}" ]]; then # 允许为空，但提示一下
             if [[ ! "${allowed_users}" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                echo -e "${RED}授权用户 ID 列表格式不正确。应为纯数字，多个用英文逗号隔开。请重新输入。${NC}"
                continue
             fi
        else
            echo -e "${YELLOW}警告：授权用户列表为空，这意味着在配置完成前可能无人能使用 Bot 的上传功能。${NC}"
        fi
        break
    done
    
    local base_url
    while true; do
        read -p "请输入您图床的完整基础 URL (必须以 http:// 或 https:// 开头, 例如 https://img.yourdomain.com): " base_url
        if [[ "${base_url}" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[-A-Za-z0-9._~/?#=&%]*)?$ ]]; then
            break
        else
            echo -e "${RED}基础 URL 格式不正确，必须以 http:// 或 https:// 开头。请重新输入。${NC}"
        fi
    done

    echo -e "${GREEN}正在生成配置文件: ${CONFIG_FILE_PATH}${NC}"
    cat > "${CONFIG_FILE_PATH}" <<EOL
[telegram]
bot_token = ${bot_token}
channel_id = ${channel_id}
channel_username = ${channel_username}

[access]
allowed_users = ${allowed_users}

[server]
base_url = ${base_url}
EOL
    # 设置配置文件权限，确保root可读写，其他用户无权访问
    chown root:imghub "${CONFIG_FILE_PATH}"
    chmod 640 "${CONFIG_FILE_PATH}"
    echo -e "${GREEN}配置文件已生成并设置权限。${NC}"
}

# --- 主逻辑 ---
main() {
    check_root

    local backup_dir
    backup_dir="/var/backups/ai-scripts/imghub/$(date +%Y%m%d-%H%M%S)"
    install -d -m 700 "$backup_dir"
    [[ -f $PYTHON_SCRIPT_PATH ]] && cp -a "$PYTHON_SCRIPT_PATH" "$backup_dir/" || touch "$backup_dir/no-python-script"
    [[ -f $CONFIG_FILE_PATH ]] && cp -a "$CONFIG_FILE_PATH" "$backup_dir/" || touch "$backup_dir/no-config"
    [[ -f /etc/systemd/system/${SERVICE_NAME}.service ]] && cp -a "/etc/systemd/system/${SERVICE_NAME}.service" "$backup_dir/" || touch "$backup_dir/no-service"
    systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null && touch "$backup_dir/service-active"
    systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null && touch "$backup_dir/service-enabled"
    id imghub >/dev/null 2>&1 || useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin imghub

    echo -e "${GREEN}开始安装 ImgHub Bot...${NC}"

    # 检查是否已有服务在运行
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        echo -e "${YELLOW}检测到 ${SERVICE_NAME} 服务正在运行。${NC}"
        read -p "是否要停止现有服务并继续安装？[y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}正在停止现有服务...${NC}"
            systemctl stop "${SERVICE_NAME}"
            
            # 备份现有数据
            if [ -f "/var/lib/imghub/records.json" ]; then
                echo -e "${YELLOW}正在备份现有记录...${NC}"
                local records_backup
                records_backup="/var/lib/imghub/records.json.bak.$(date +%Y%m%d_%H%M%S)"
                cp /var/lib/imghub/records.json "$records_backup"
            fi
        else
            echo -e "${RED}安装已取消。${NC}"
            exit 0
        fi
    fi

    install_dependencies

    echo -e "${GREEN}正在创建数据目录: ${DATA_DIR}${NC}"
    mkdir -p "${DATA_DIR}"
    chown imghub:imghub "${DATA_DIR}"
    # 可选：设置数据目录权限，如果服务不是以root运行，需要调整
    # chown youruser:yourgroup "${DATA_DIR}"

    echo -e "${GREEN}正在创建 Python 脚本目录: ${PYTHON_SCRIPT_DIR}${NC}"
    mkdir -p "${PYTHON_SCRIPT_DIR}"
    mkdir -p "$(dirname "$CONFIG_FILE_PATH")"

    echo -e "${GREEN}正在写入 Python 脚本到: ${PYTHON_SCRIPT_PATH}${NC}"
    if ! printf '%s\n' "${PYTHON_SCRIPT_CONTENT}" | "${PYTHON_SCRIPT_DIR}/venv/bin/python" -c 'import ast,sys; ast.parse(sys.stdin.read())'; then
        echo -e "${RED}内嵌 Python 脚本语法检查失败，原文件未覆盖。${NC}"
        return 1
    fi
    local python_tmp
    python_tmp=$(mktemp "${PYTHON_SCRIPT_DIR}/.imghub_bot.XXXXXX") || return 1
    printf '%s\n' "${PYTHON_SCRIPT_CONTENT}" > "$python_tmp"
    chmod 755 "$python_tmp"
    mv -f -- "$python_tmp" "${PYTHON_SCRIPT_PATH}"

    if [[ -f "$CONFIG_FILE_PATH" ]]; then
        read -r -p "检测到现有配置，是否重新配置？[y/N]: " reconfigure
        if [[ "$reconfigure" =~ ^[Yy]$ ]]; then setup_config_interactive || return 1; else echo -e "${YELLOW}已保留现有配置。${NC}"; fi
    else
        setup_config_interactive || return 1
    fi

    echo -e "${GREEN}正在创建 Systemd 服务 (${SERVICE_NAME}.service)...${NC}"
    printf '%s\n' "${SYSTEMD_SERVICE_CONTENT}" > "/etc/systemd/system/${SERVICE_NAME}.service"
    if command -v systemd-analyze >/dev/null 2>&1 && ! systemd-analyze verify "/etc/systemd/system/${SERVICE_NAME}.service"; then
        echo -e "${RED}systemd 服务文件校验失败，正在恢复。${NC}"
        [[ -f "$backup_dir/${SERVICE_NAME}.service" ]] && cp -a "$backup_dir/${SERVICE_NAME}.service" "/etc/systemd/system/${SERVICE_NAME}.service" || rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
        return 1
    fi

    echo -e "${GREEN}重新加载 Systemd 守护进程...${NC}"
    systemctl daemon-reload

    echo -e "${GREEN}启用 ${SERVICE_NAME} 服务 (开机自启)...${NC}"
    systemctl enable "${SERVICE_NAME}.service"

    echo -e "${GREEN}启动 ${SERVICE_NAME} 服务...${NC}"
    if systemctl start "${SERVICE_NAME}.service"; then
        echo -e "${GREEN}${SERVICE_NAME} 服务已成功启动！${NC}"
    else
        echo -e "${RED}错误：${SERVICE_NAME} 服务启动失败。请检查日志。${NC}"
        echo -e "${YELLOW}您可以使用 'journalctl -u ${SERVICE_NAME} -n 100 --no-pager' 查看服务日志。${NC}"
        echo -e "${YELLOW}同时检查：journalctl -u ${SERVICE_NAME} -n 100 --no-pager${NC}"
        [[ -f "$backup_dir/imghub_bot.py" ]] && cp -a "$backup_dir/imghub_bot.py" "$PYTHON_SCRIPT_PATH" || rm -f "$PYTHON_SCRIPT_PATH"
        [[ -f "$backup_dir/config.ini" ]] && cp -a "$backup_dir/config.ini" "$CONFIG_FILE_PATH" || rm -f "$CONFIG_FILE_PATH"
        [[ -f "$backup_dir/${SERVICE_NAME}.service" ]] && cp -a "$backup_dir/${SERVICE_NAME}.service" "/etc/systemd/system/${SERVICE_NAME}.service" || rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
        if [[ -f "$backup_dir/service-enabled" ]]; then systemctl enable "${SERVICE_NAME}.service" 2>/dev/null || true; else systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true; fi
        if [[ -f "$backup_dir/service-active" ]]; then systemctl restart "${SERVICE_NAME}.service" 2>/dev/null || true; fi
        echo -e "${YELLOW}已从 $backup_dir 恢复安装前文件。${NC}"
        return 1
    fi

    echo -e "\n${GREEN}🎉 ImgHub Bot 安装和初步配置完成！ 🎉${NC}\n"
    echo -e "${YELLOW}修改前备份：${backup_dir}${NC}"

    echo -e "${YELLOW}重要提示：反向代理设置${NC}"
    echo "---------------------------------------------------------------------"
    echo "ImgHub Bot 的内部 Web 服务现在仅运行在 ${GREEN}127.0.0.1:8080${NC}。"
    echo "您需要设置一个反向代理服务器（如 Nginx, Apache, Caddy 等）将您之前配置的"
    echo "基础 URL (${GREEN}$(grep base_url ${CONFIG_FILE_PATH} | cut -d '=' -f2 | xargs)${NC}) 指向到 ${GREEN}http://127.0.0.1:8080${NC}。"
    echo ""
    echo "例如，如果您使用 Nginx，并且您的基础 URL 是 ${GREEN}$(grep base_url ${CONFIG_FILE_PATH} | cut -d '=' -f2 | xargs)${NC},"
    echo "您的 Nginx 站点配置可能需要类似如下的片段："
    echo ""
    echo -e "${GREEN}server {${NC}"
    echo -e "${GREEN}    listen 80; # 如果是 HTTPS, 则为 listen 443 ssl;${NC}"
    
    # 尝试从 base_url 提取域名
    raw_base_url=$(grep base_url ${CONFIG_FILE_PATH} | cut -d '=' -f2 | xargs)
    # 移除 http:// 或 https://
    server_name_extracted=$(echo "${raw_base_url}" | sed -e 's%^https\?://%%') 
    # 移除路径部分 (如果存在)
    server_name_extracted=$(echo "${server_name_extracted}" | cut -d '/' -f 1)

    echo -e "${GREEN}    server_name ${server_name_extracted};${NC}"
    echo ""
    echo -e "${GREEN}    # 如果使用 HTTPS (推荐!), 请配置 SSL证书路径:${NC}"
    echo -e "${GREEN}    # ssl_certificate /path/to/your/fullchain.pem;${NC}"
    echo -e "${GREEN}    # ssl_certificate_key /path/to/your/privkey.pem;${NC}"
    echo -e "${GREEN}    # include /etc/letsencrypt/options-ssl-nginx.conf; # Let's Encrypt 推荐配置${NC}"
    echo -e "${GREEN}    # ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # Let's Encrypt 推荐配置${NC}"
    echo ""
    echo -e "${GREEN}    location / {${NC}"
    echo -e "${GREEN}        proxy_pass http://127.0.0.1:8080;${NC}"
    echo -e "${GREEN}        proxy_set_header Host \$host;${NC}"
    echo -e "${GREEN}        proxy_set_header X-Real-IP \$remote_addr;${NC}"
    echo -e "${GREEN}        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;${NC}"
    echo -e "${GREEN}        proxy_set_header X-Forwarded-Proto \$scheme;${NC}"
    echo -e "${GREEN}        proxy_http_version 1.1;${NC}"
    echo -e "${GREEN}        proxy_set_header Upgrade \$http_upgrade;${NC}"
    echo -e "${GREEN}        proxy_set_header Connection \"upgrade\";${NC}"
    echo -e "${GREEN}    }${NC}"
    echo -e "${GREEN}}${NC}"
    echo ""
    echo "请根据您的实际域名、HTTPS 设置以及所使用的反向代理软件调整配置。"
    echo "配置完成后，请确保您的防火墙允许外部访问您设置的域名和端口 (通常是 80/443)。"
    echo "---------------------------------------------------------------------"
    echo ""
    echo -e "${GREEN}其他常用命令:${NC}"
    echo -e "查看服务状态: ${YELLOW}systemctl status ${SERVICE_NAME}.service${NC}"
    echo -e "停止服务: ${YELLOW}systemctl stop ${SERVICE_NAME}.service${NC}"
    echo -e "启动服务: ${YELLOW}systemctl start ${SERVICE_NAME}.service${NC}"
    echo -e "重启服务: ${YELLOW}systemctl restart ${SERVICE_NAME}.service${NC}"
    echo -e "查看服务日志: ${YELLOW}journalctl -u ${SERVICE_NAME} -f --no-pager${NC}"
    echo -e "查看实时日志: ${YELLOW}journalctl -u ${SERVICE_NAME} -f -o cat${NC}"
    echo -e "编辑配置文件: ${YELLOW}nano ${CONFIG_FILE_PATH}${NC}"
    echo -e "Python脚本位置: ${YELLOW}${PYTHON_SCRIPT_PATH}${NC}"
    echo ""
    
    # 显示配置的频道信息
    configured_channel_username=$(grep channel_username ${CONFIG_FILE_PATH} | cut -d '=' -f2 | xargs)
    if [[ -n "${configured_channel_username}" ]]; then
        echo -e "${GREEN}配置的频道类型: 公开频道 @${configured_channel_username}${NC}"
        echo -e "${GREEN}备用链接格式: https://t.me/${configured_channel_username}/消息ID${NC}"
    else
        echo -e "${YELLOW}配置的频道类型: 私有频道${NC}"
        echo -e "${YELLOW}备用链接格式: https://t.me/c/频道ID/消息ID (仅成员可访问)${NC}"
    fi
}

# 执行主函数
main
