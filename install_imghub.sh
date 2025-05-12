#!/bin/bash

# ImgHub Bot 一键安装脚本
# 支持系统: Debian/Ubuntu 及其衍生版

# --- 配置 ---
PYTHON_SCRIPT_PATH="/opt/imghub_bot/imghub_bot.py"
PYTHON_SCRIPT_DIR=$(dirname "${PYTHON_SCRIPT_PATH}")
CONFIG_FILE_PATH="/root/imghub_config.ini"
DATA_DIR="/var/lib/imghub"
LOG_FILE="/var/log/imghub.log" # Python脚本内指定的日志文件
SERVICE_NAME="imghub_bot"

# --- 颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Python 脚本内容 ---
# 注意: 这里的 Python 脚本是之前讨论中您确认的那个版本
PYTHON_SCRIPT_CONTENT=$(cat <<'END_OF_PYTHON_SCRIPT'
#!/usr/bin/python3
import os
import json
import logging
import asyncio
import configparser
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
    handlers=[
        logging.FileHandler('/var/log/imghub.log'), # Ensure this path is writable by the user running the script
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# 全局配置
CONFIG_PATH = '/root/imghub_config.ini' # This is read by the script
BASE_URL_FALLBACK = "https://example.com" # Fallback, should be overridden by config

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
            with open(self.db_path, 'w') as f:
                json.dump(self.file_records, f, indent=4) # Added indent for readability
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
        self.site = web.TCPSite(self.runner, '0.0.0.0', 8080) # Listens on port 8080
        await self.site.start()
        logger.info("Web服务器已启动在 0.0.0.0:8080")

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

    try:
        bot: Bot = context.bot
        img_service: ImageHostingService = context.bot_data['img_service']
        channel_id = int(context.bot_data['channel_id']) # Convert here
        base_url = context.bot_data.get('base_url', BASE_URL_FALLBACK)

        file_to_process = None
        mime_type = "image/jpeg" # Default
        file_name_for_caption = "image"

        if update.message.photo:
            logger.info("📷 收到照片")
            file_to_process = await update.message.photo[-1].get_file()
            mime_type = "image/jpeg" # Telegram converts photos to jpeg
            file_name_for_caption = f"photo_{file_to_process.file_unique_id}.jpg"
        elif update.message.document:
            doc = update.message.document
            logger.info(f"📎 收到文档: {doc.file_name}, MIME: {doc.mime_type}")
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

        # Download the file to a local path
        downloaded_file_path_str = await file_to_process.download_to_drive()
        logger.info(f"💾 文件下载到本地完成，路径：{downloaded_file_path_str}")

        file_path_obj_to_send = Path(downloaded_file_path_str)
        
        # Determine caption for the channel message
        caption_text = f"Uploaded by: {user.id} ({user.username or 'N/A'})\nOriginal Filename: {file_name_for_caption}\nMIME: {mime_type}\nTimestamp: {datetime.now().isoformat()}"
        if update.message.caption:
            caption_text = f"{update.message.caption}\n-----\n{caption_text}"


        sent_message = None
        with open(file_path_obj_to_send, "rb") as photo_file_object:
            if mime_type.startswith("image/gif"):
                 sent_message = await bot.send_animation(
                    chat_id=channel_id,
                    animation=photo_file_object,
                    caption=caption_text
                )
            elif mime_type.startswith("image/"): # For other images (jpeg, png, webp)
                sent_message = await bot.send_photo(
                    chat_id=channel_id,
                    photo=photo_file_object,
                    caption=caption_text
                )
            else: # Fallback, should not happen if type check is robust
                 sent_message = await bot.send_document(
                    chat_id=channel_id,
                    document=photo_file_object,
                    caption=caption_text
                )
        
        # Clean up the downloaded temporary file
        try:
            os.remove(downloaded_file_path_str)
            logger.info(f"🗑️ 临时文件 {downloaded_file_path_str} 已删除。")
        except OSError as e:
            logger.error(f"删除临时文件 {downloaded_file_path_str} 失败: {e}")


        if not sent_message or not (sent_message.photo or sent_message.animation or sent_message.document):
            logger.error("图片未能成功发送到频道或返回消息中不包含媒体信息。")
            await update.message.reply_text("⚠️ 上传失败，无法将图片存入频道。请稍后重试。")
            return
            
        # Use the file_id of the message in the channel for our records
        # The file_id of the photo/document within the sent_message is more persistent
        persistent_file_id_for_retrieval = ""
        if sent_message.photo:
            persistent_file_id_for_retrieval = sent_message.photo[-1].file_id
        elif sent_message.animation:
            persistent_file_id_for_retrieval = sent_message.animation.file_id
        elif sent_message.document: # Should be an image document
            persistent_file_id_for_retrieval = sent_message.document.file_id


        logger.info(f"📤 图片已发送至频道，message_id: {sent_message.message_id}, 持久化 file_id: {persistent_file_id_for_retrieval}")

        # Generate a short, unique ID for the URL
        # Using parts of message_id and unique_id can create more robust short IDs
        # For simplicity, we'll stick to a similar method as before but ensure it's reasonably unique.
        # A more robust system might involve a small local database (like SQLite) for ID generation if scale is a concern.
        
        # Let's use a portion of the channel message ID hex and a random suffix.
        # Example: <hex_msg_id_part><random_suffix>
        # Ensure file_id is based on something from the *channel* message
        
        base_id_str = f"{sent_message.chat.id}_{sent_message.message_id}"
        import hashlib
        # Create a short hash, e.g., first 8 chars of sha1 of a unique string
        url_file_id = hashlib.sha1(base_id_str.encode()).hexdigest()[:8]

        import random
        import string
        id_candidate = url_file_id
        collision_count = 0
        while id_candidate in img_service.file_records:
            collision_count += 1
            suffix = ''.join(random.choices(string.ascii_lowercase + string.digits, k=2))
            id_candidate = f"{url_file_id[:8-len(suffix)]}{suffix}" # Ensure it stays short
            if collision_count > 10: # Highly unlikely, but a safeguard
                id_candidate = hashlib.sha1(f"{base_id_str}_{random.random()}".encode()).hexdigest()[:10]
                logger.warning(f"多次File ID碰撞后生成了更长的随机ID: {id_candidate}")
            if collision_count > 20: # Extremely unlikely
                 logger.error("无法生成唯一的File ID，存在严重问题。")
                 await update.message.reply_text("⚠️ 上传失败，无法生成唯一文件标识。")
                 return


        final_url_file_id = id_candidate

        # Store record with the persistent file_id for retrieval
        img_service.file_records[final_url_file_id] = (
            str(abs(channel_id))[4:] if abs(channel_id) >= 10000 else str(abs(channel_id)), # Channel part for t.me link
            sent_message.message_id,
            persistent_file_id_for_retrieval, # Use this for get_file later
            mime_type
        )

        logger.info(f"📝 文件记录保存: url_file_id={final_url_file_id}, persistent_file_id={persistent_file_id_for_retrieval}")
        img_service.save_records() # Save immediately

        direct_link = f"{base_url}/i/{final_url_file_id}"
        # Backup link using channel ID and message ID
        channel_id_part_for_url = img_service.file_records[final_url_file_id][0]
        backup_link = f"https://t.me/c/{channel_id_part_for_url}/{sent_message.message_id}"

        await update.message.reply_text(
            f"✅ 图片上传成功!\n\n"
            f"🔗 直链地址: {direct_link}\n"
            f"备用地址: {backup_link}\n\n"
            f"图片可直接嵌入网页或在浏览器中打开。",
            disable_web_page_preview=True,
            reply_to_message_id=update.message.message_id
        )

    except Exception as e:
        logger.error(f"❗媒体处理异常: {str(e)}", exc_info=True)
        await update.message.reply_text("⚠️ 上传过程中发生内部错误，请稍后重试。")


def setup_handlers(application: Application) -> None:
    """注册处理器"""
    application.add_handler(CommandHandler('start', start_command))
    application.add_handler(
        MessageHandler(filters.PHOTO | filters.Document.IMAGE, handle_media)
    )

async def main() -> None:
    """主函数"""
    application_instance = None # Define application_instance to ensure it's in scope for finally
    img_service_instance = None # Define img_service_instance

    try:
        # 加载配置
        bot_token, channel_id_str, allowed_users, base_url = load_config()
        # Convert channel_id to int. It should be a public channel ID (like -100xxxx) or a private channel numeric ID.
        # For private channels, the bot must be an admin.
        # Ensure channel_id is correctly formatted (e.g. for private channels, it might start with -100)
        try:
            channel_id = int(channel_id_str)
        except ValueError:
            logger.critical(f"配置错误: channel_id '{channel_id_str}' 不是有效的整数。")
            return


        # 确保数据和日志目录存在 (日志目录由basicConfig处理, 数据目录在这里创建)
        os.makedirs(os.path.dirname(ImageHostingService(None).db_path), exist_ok=True) # Pass None for bot temporarily

        # 初始化Telegram机器人
        application_builder = Application.builder().token(bot_token)
        # Configure connection pool size if needed, e.g. for many concurrent requests
        # application_builder.connection_pool_size(512) 
        application_instance = application_builder.build()

        # 初始化服务
        img_service_instance = ImageHostingService(application_instance.bot)

        # 存储全局变量到bot_data
        application_instance.bot_data['img_service'] = img_service_instance
        application_instance.bot_data['channel_id'] = channel_id
        application_instance.bot_data['allowed_users'] = allowed_users
        application_instance.bot_data['base_url'] = base_url

        # 注册消息处理器
        setup_handlers(application_instance)

        web_server_task = None
        try:
            # 初始化和启动应用
            logger.info("正在初始化 Telegram Application...")
            await application_instance.initialize()
            logger.info("正在启动 Telegram Application Polling...")
            await application_instance.start()
            if application_instance.updater:
                await application_instance.updater.start_polling()
            else:
                logger.error("Updater 未初始化, polling 无法启动。")
                # Potentially raise an error or exit if polling is essential
                return

            # 启动Web服务器
            logger.info("准备启动内部 Web 服务器...")
            web_server_task = asyncio.create_task(img_service_instance.run_web_server())

            logger.info(f"----- 图床服务已成功启动 (PID: {os.getpid()}) -----")
            logger.info(f"监听频道ID: {channel_id}")
            logger.info(f"授权用户列表: {allowed_users if allowed_users else '无 (请在配置文件中设置!)'}")
            logger.info(f"图床基础URL: {base_url}")
            logger.info(f"已加载 {len(img_service_instance.file_records)} 个文件记录 (来自 {img_service_instance.db_path})")

            # Keep the main function alive indefinitely until shutdown signal or error
            # await asyncio.Event().wait() # This would keep it running until an unhandled exception or signal
            # Or, if web_server_task is the primary long-running task aside from polling:
            if web_server_task:
                 await web_server_task # This will keep main alive as long as web_server_task is running

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
            
            if application_instance and img_service_instance: # Ensure they exist
                 await safe_shutdown(application_instance, img_service_instance)
            elif img_service_instance: # If only img_service was initialized
                 await img_service_instance.stop_web_server() # Try to stop it
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
User=root
Group=root
WorkingDirectory=${PYTHON_SCRIPT_DIR}
ExecStart=/usr/bin/python3 ${PYTHON_SCRIPT_PATH}
Restart=always
RestartSec=5
StandardOutput=append:${LOG_FILE} # 将标准输出追加到日志文件
StandardError=append:${LOG_FILE}  # 将标准错误追加到日志文件
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
    # 使用 --break-system-packages (用户要求)
    if ! pip3 install "python-telegram-bot[job-queue]" aiohttp --break-system-packages; then
        echo -e "${RED}错误：无法安装 Python 依赖。${NC}"
        exit 1
    fi
    echo -e "${GREEN}Python 依赖安装完成。${NC}"
}

setup_config_interactive() {
    echo -e "${YELLOW}--- ImgHub Bot 配置向导 ---${NC}"
    
    local bot_token
    while true; do
        read -p "请输入您的 Telegram Bot Token: " bot_token
        if [[ -n "${bot_token}" ]]; then
            break
        else
            echo -e "${RED}Bot Token 不能为空，请重新输入。${NC}"
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
        if [[ "${base_url}" =~ ^https?:// ]]; then
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

[access]
allowed_users = ${allowed_users}

[server]
base_url = ${base_url}
EOL
    # 设置配置文件权限，确保root可读写，其他用户无权访问
    chmod 600 "${CONFIG_FILE_PATH}"
    echo -e "${GREEN}配置文件已生成并设置权限。${NC}"
}

# --- 主逻辑 ---
main() {
    check_root

    echo -e "${GREEN}开始安装 ImgHub Bot...${NC}"

    install_dependencies

    echo -e "${GREEN}正在创建数据目录: ${DATA_DIR}${NC}"
    mkdir -p "${DATA_DIR}"
    # 可选：设置数据目录权限，如果服务不是以root运行，需要调整
    # chown youruser:yourgroup "${DATA_DIR}"

    echo -e "${GREEN}正在创建 Python 脚本目录: ${PYTHON_SCRIPT_DIR}${NC}"
    mkdir -p "${PYTHON_SCRIPT_DIR}"

    echo -e "${GREEN}正在写入 Python 脚本到: ${PYTHON_SCRIPT_PATH}${NC}"
    echo "${PYTHON_SCRIPT_CONTENT}" > "${PYTHON_SCRIPT_PATH}"
    chmod +x "${PYTHON_SCRIPT_PATH}" # 使脚本可执行

    setup_config_interactive # 调用交互式配置

    echo -e "${GREEN}正在创建 Systemd 服务 (${SERVICE_NAME}.service)...${NC}"
    echo "${SYSTEMD_SERVICE_CONTENT}" > "/etc/systemd/system/${SERVICE_NAME}.service"

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
        echo -e "${YELLOW}同时检查Python脚本日志 '${LOG_FILE}'。${NC}"
        exit 1
    fi

    echo -e "\n${GREEN}🎉 ImgHub Bot 安装和初步配置完成！ 🎉${NC}\n"

    echo -e "${YELLOW}重要提示：反向代理设置${NC}"
    echo "---------------------------------------------------------------------"
    echo "ImgHub Bot 的内部 Web 服务现在运行在 ${GREEN}0.0.0.0:8080${NC}。"
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
    echo -e "查看Python脚本日志: ${YELLOW}tail -f ${LOG_FILE}${NC}"
    echo -e "配置文件位置: ${YELLOW}${CONFIG_FILE_PATH}${NC}"
    echo -e "Python脚本位置: ${YELLOW}${PYTHON_SCRIPT_PATH}${NC}"
}

# 执行主函数
main
