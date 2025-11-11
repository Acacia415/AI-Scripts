#!/bin/bash
# =====================================================
# Hexo 博客一键管理脚本
# 兼容：Debian/Ubuntu (x86_64/ARM/ARM64)
# 功能：部署、卸载、备份、同步、Web配置
# Author: Iris & Cascade
# =====================================================

set -e

# 配置文件路径
CONFIG_FILE="$HOME/.hexo_manager.conf"

# 默认配置
DEFAULT_BLOG_DIR="/var/www/hexo-blog"
DEFAULT_BACKUP_DIR="/var/backups/hexo-blog"
DEFAULT_PORT=4000
NODE_VERSION_REQUIRED=20
SCRIPT_VERSION="1.0.0"

# 全局变量（将从配置文件加载）
BLOG_DIR=""
BACKUP_DIR=""
HEXO_PORT=""

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印带颜色的消息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 显示横幅
show_banner() {
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════╗"
    echo "║   Hexo 博客一键管理脚本 v${SCRIPT_VERSION}    ║"
    echo "║   支持：部署 | 卸载 | 备份 | 同步      ║"
    echo "╚════════════════════════════════════════╝"
    echo -e "${NC}"
}

# 显示主菜单
show_menu() {
    echo ""
    echo -e "${GREEN}请选择操作：${NC}"
    echo "1) 部署 Hexo 博客"
    echo "2) 卸载 Hexo 博客"
    echo "3) 备份博客数据"
    echo "4) 恢复备份数据"
    echo "5) 同步博客（Git）"
    echo "6) 本地文章上传"
    echo "7) 后台服务管理（systemd/PM2）"
    echo "8) Web 服务器配置（Caddy/Nginx）"
    echo "9) 启动 Hexo 服务器（前台测试）"
    echo "10) 生成静态文件"
    echo ""
    echo -e "${YELLOW}扩展功能：${NC}"
    echo "p) 插件管理（SEO/RSS/搜索/相册等）"
    echo "t) 主题管理（安装/切换主题）"
    echo "i) 图床配置说明"
    echo ""
    echo "a) 查看博客状态"
    echo "c) 查看/修改配置"
    echo "0) 退出"
    echo ""
}

# 检查是否以root运行
check_root() {
    if [ "$EUID" -eq 0 ]; then
        print_warning "检测到以root用户运行，建议使用普通用户+sudo"
    fi
}

# 加载配置文件
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        print_info "已加载配置文件: $CONFIG_FILE"
    else
        # 使用默认配置
        BLOG_DIR="$DEFAULT_BLOG_DIR"
        BACKUP_DIR="$DEFAULT_BACKUP_DIR"
        HEXO_PORT="$DEFAULT_PORT"
    fi
    
    # 确保端口有值
    if [ -z "$HEXO_PORT" ]; then
        HEXO_PORT="$DEFAULT_PORT"
    fi
}

# 保存配置文件
save_config() {
    cat > "$CONFIG_FILE" << EOF
# Hexo Manager 配置文件
# 自动生成于 $(date)

# 博客目录
BLOG_DIR="$BLOG_DIR"

# 备份目录
BACKUP_DIR="$BACKUP_DIR"

# Hexo 端口
HEXO_PORT="$HEXO_PORT"
EOF
    print_success "配置已保存到: $CONFIG_FILE"
}

# 显示当前配置
show_config() {
    echo ""
    print_info "当前配置："
    echo "  博客目录: $BLOG_DIR"
    echo "  备份目录: $BACKUP_DIR"
    echo "  Hexo 端口: $HEXO_PORT"
    echo "  配置文件: $CONFIG_FILE"
    echo ""
}

# 1. 部署 Hexo 博客
deploy_hexo() {
    print_info "开始部署 Hexo 博客..."
    echo ""
    
    # 重新加载配置（如果配置文件被删除，重置为默认值）
    if [ ! -f "$CONFIG_FILE" ]; then
        BLOG_DIR="$DEFAULT_BLOG_DIR"
        BACKUP_DIR="$DEFAULT_BACKUP_DIR"
        HEXO_PORT="$DEFAULT_PORT"
    fi
    
    # 让用户选择目录和端口
    show_config
    read -p "使用默认目录？(Y/n): " use_default
    
    if [[ "$use_default" =~ ^[Nn]$ ]]; then
        read -p "请输入博客目录（绝对路径）: " custom_dir
        if [ -n "$custom_dir" ]; then
            BLOG_DIR="$custom_dir"
            # 备份目录也相应调整
            BACKUP_DIR="${BLOG_DIR}_backups"
            print_info "使用自定义目录: $BLOG_DIR"
        fi
    else
        print_info "使用配置目录: $BLOG_DIR"
    fi
    
    # 选择端口
    echo ""
    read -p "Hexo 服务端口（默认 $HEXO_PORT）: " custom_port
    if [ -n "$custom_port" ] && [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        HEXO_PORT="$custom_port"
        print_info "使用端口: $HEXO_PORT"
    else
        print_info "使用默认端口: $HEXO_PORT"
    fi
    
    # 保存配置
    save_config
    
    echo ""
    
    # 检查并安装 Node.js
    print_info "检查 Node.js 版本..."
    if command -v node >/dev/null 2>&1; then
        NODE_VER=$(node -v | grep -oE '[0-9]+' | head -1)
        print_info "检测到 Node.js v$NODE_VER"
        if [ "$NODE_VER" -lt "$NODE_VERSION_REQUIRED" ]; then
            print_warning "Node.js 版本过低，正在升级到 v$NODE_VERSION_REQUIRED..."
            sudo apt remove -y nodejs npm || true
            curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION_REQUIRED}.x | sudo -E bash -
            sudo apt install -y nodejs
        else
            print_success "Node.js 版本符合要求"
        fi
    else
        print_info "未检测到 Node.js，正在安装 v$NODE_VERSION_REQUIRED..."
        curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION_REQUIRED}.x | sudo -E bash -
        sudo apt install -y nodejs
    fi
    
    # 验证 npm
    if ! command -v npm >/dev/null 2>&1; then
        print_error "npm 安装失败！"
        exit 1
    fi
    
    print_success "Node.js $(node -v) 和 npm $(npm -v) 已就绪"
    
    # 安装基础依赖
    print_info "安装基础工具..."
    sudo apt update
    sudo apt install -y git curl wget build-essential
    
    # 创建博客目录
    print_info "创建博客目录: $BLOG_DIR"
    sudo mkdir -p "$BLOG_DIR"
    sudo chown "$USER:$USER" "$BLOG_DIR"
    cd "$BLOG_DIR"
    
    # 检查是否已存在 Hexo 项目
    if [ -f "$BLOG_DIR/package.json" ]; then
        print_warning "检测到现有 Hexo 项目"
        read -p "是否重新安装？这将覆盖现有配置 (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            print_info "备份现有配置..."
            backup_hexo
            print_info "清理现有项目..."
            rm -rf node_modules package-lock.json
        else
            print_info "更新现有项目依赖..."
            npm install
            npx hexo clean
            npx hexo generate
            print_success "项目更新完成！"
            return
        fi
    fi
    
    # 初始化 Hexo 项目
    print_info "初始化 Hexo 博客..."
    if [ -z "$(ls -A $BLOG_DIR)" ]; then
        npx hexo init .
    else
        npx hexo init temp_hexo
        mv temp_hexo/* .
        mv temp_hexo/.* . 2>/dev/null || true
        rm -rf temp_hexo
    fi
    
    print_info "安装依赖..."
    npm install
    
    # 安装常用插件（可选）
    print_info "安装常用插件..."
    npm install hexo-server hexo-deployer-git --save
    
    # 生成静态文件
    print_info "生成静态文件..."
    npx hexo clean
    npx hexo generate
    
    # 设置文件权限，确保 Web 服务器可读取
    if [ -d "$BLOG_DIR/public" ]; then
        print_info "设置静态文件权限..."
        chmod -R 755 "$BLOG_DIR"
        chmod -R 755 "$BLOG_DIR/public"
        find "$BLOG_DIR/public" -type f -exec chmod 644 {} \; 2>/dev/null
        find "$BLOG_DIR/public" -type d -exec chmod 755 {} \; 2>/dev/null
        print_success "文件权限已设置"
    fi
    
    print_success "=========================================="
    print_success "Hexo 博客部署完成！"
    print_success "=========================================="
    print_info "博客目录：$BLOG_DIR"
    print_info "静态文件：$BLOG_DIR/public"
    print_info "配置文件：$BLOG_DIR/_config.yml"
    echo ""
    print_info "常用命令："
    echo "  启动服务器: cd $BLOG_DIR && npx hexo server"
    echo "  新建文章:   cd $BLOG_DIR && npx hexo new \"文章标题\""
    echo "  生成文件:   cd $BLOG_DIR && npx hexo generate"
    echo ""
    
    read -p "是否立即启动 Hexo 服务器测试？(y/N): " start_server
    if [[ "$start_server" =~ ^[Yy]$ ]]; then
        start_hexo_server
    fi
}

# 2. 卸载 Hexo 博客
uninstall_hexo() {
    print_warning "=========================================="
    print_warning "Hexo 博客卸载工具"
    print_warning "=========================================="
    echo ""
    
    echo "卸载选项："
    echo "1) 完全卸载（删除所有文件，包括博客数据）"
    echo "2) 仅卸载程序（保留博客源文件和配置）"
    echo "3) 深度清理（清理所有相关文件和缓存）"
    echo "0) 取消"
    echo ""
    read -p "请选择 [0-3]: " uninstall_option
    
    case $uninstall_option in
        1)
            print_warning "完全卸载将删除: $BLOG_DIR"
            echo ""
            read -p "是否在删除前备份数据？(Y/n): " backup_first
            if [[ ! "$backup_first" =~ ^[Nn]$ ]]; then
                backup_hexo
            fi
            
            echo ""
            print_warning "警告：这将永久删除所有博客数据！"
            read -p "确认删除所有数据？输入 'YES' 继续: " final_confirm
            if [ "$final_confirm" = "YES" ]; then
                print_info "删除博客目录..."
                sudo rm -rf "$BLOG_DIR"
                print_success "Hexo 博客已完全卸载"
            else
                print_info "已取消卸载操作"
                return
            fi
            ;;
        2)
            print_info "仅卸载程序文件，保留源文件..."
            echo ""
            read -p "是否先备份数据？(Y/n): " backup_first
            if [[ ! "$backup_first" =~ ^[Nn]$ ]]; then
                backup_hexo
            fi
            
            if [ -d "$BLOG_DIR" ]; then
                cd "$BLOG_DIR"
                print_info "删除 node_modules 和依赖文件..."
                rm -rf node_modules package-lock.json .deploy_git public db.json
                print_success "程序文件已删除"
                print_info "保留的文件: source/, themes/, _config.yml 等"
                print_info "文件位置: $BLOG_DIR"
            fi
            ;;
        3)
            print_warning "深度清理将删除所有相关文件"
            echo ""
            read -p "是否先备份数据？(Y/n): " backup_first
            if [[ ! "$backup_first" =~ ^[Nn]$ ]]; then
                backup_hexo
            fi
            
            echo ""
            print_warning "将清理以下内容："
            echo "  - 博客目录: $BLOG_DIR"
            echo "  - 备份目录: $BACKUP_DIR"
            echo "  - npm 全局缓存"
            echo "  - Hexo CLI 全局包"
            echo "  - Web 服务器日志"
            echo ""
            read -p "确认执行深度清理？输入 'YES' 继续: " deep_confirm
            
            if [ "$deep_confirm" != "YES" ]; then
                print_info "已取消深度清理"
                return
            fi
            
            # 删除博客目录
            if [ -d "$BLOG_DIR" ]; then
                print_info "删除博客目录..."
                sudo rm -rf "$BLOG_DIR"
                print_success "博客目录已删除"
            fi
            
            # 清理备份目录
            if [ -d "$BACKUP_DIR" ]; then
                BACKUP_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "0")
                BACKUP_COUNT=$(ls "$BACKUP_DIR"/hexo_backup_*.tar.gz 2>/dev/null | wc -l || echo "0")
                print_info "备份目录: $BACKUP_DIR"
                print_info "  备份数量: $BACKUP_COUNT 个"
                print_info "  总大小: $BACKUP_SIZE"
                echo ""
                read -p "是否删除所有备份？(y/N): " remove_backups
                if [[ "$remove_backups" =~ ^[Yy]$ ]]; then
                    sudo rm -rf "$BACKUP_DIR"
                    print_success "备份目录已删除"
                else
                    print_info "保留备份目录"
                fi
            fi
            
            # 清理 npm 缓存
            print_info "清理 npm 缓存..."
            npm cache clean --force 2>/dev/null || true
            print_success "npm 缓存已清理"
            
            # 卸载 Hexo CLI
            if npm list -g hexo-cli >/dev/null 2>&1; then
                print_info "卸载 Hexo CLI 全局包..."
                npm uninstall -g hexo-cli 2>/dev/null || true
                print_success "Hexo CLI 已卸载"
            fi
            
            # 清理 Web 服务器日志
            print_info "清理 Web 服务器日志..."
            sudo rm -f /var/log/caddy/hexo-blog*.log 2>/dev/null || true
            sudo rm -f /var/log/nginx/hexo-blog*.log 2>/dev/null || true
            print_success "Web 服务器日志已清理"
            
            ;;
        0)
            print_info "已取消卸载"
            return
            ;;
        *)
            print_error "无效选项"
            return 1
            ;;
    esac
    
    echo ""
    print_info "=========================================="
    print_info "清理后台服务和配置文件"
    print_info "=========================================="
    echo ""
    
    # 清理 systemd 服务
    if [ -f "/etc/systemd/system/hexo-blog.service" ]; then
        print_info "[①] 清理 systemd 服务..."
        sudo systemctl stop hexo-blog 2>/dev/null || true
        sudo systemctl disable hexo-blog 2>/dev/null || true
        sudo rm -f /etc/systemd/system/hexo-blog.service
        sudo systemctl daemon-reload
        print_success "  ✓ systemd 服务已清理"
    fi
    
    # 清理 PM2 服务
    if command -v pm2 >/dev/null 2>&1; then
        if pm2 list | grep -q "hexo-blog" 2>/dev/null; then
            print_info "[②] 清理 PM2 服务..."
            pm2 delete hexo-blog 2>/dev/null || true
            pm2 save 2>/dev/null || true
            print_success "  ✓ PM2 服务已清理"
        fi
    fi
    
    # 清理 nohup 进程
    if pgrep -f "hexo server" > /dev/null 2>&1; then
        print_info "[③] 停止 Hexo 进程..."
        pkill -f "hexo server" 2>/dev/null || true
        print_success "  ✓ Hexo 进程已停止"
    fi
    
    # 清理 Caddy 配置
    if [ -f "/etc/caddy/hexo-blog.caddy" ]; then
        print_info "[④] 清理 Caddy 配置..."
        sudo rm -f /etc/caddy/hexo-blog.caddy
        
        if [ -f "/etc/caddy/Caddyfile" ]; then
            sudo sed -i '/import hexo-blog.caddy/d' /etc/caddy/Caddyfile 2>/dev/null || true
            sudo sed -i '/# Hexo Blog/d' /etc/caddy/Caddyfile 2>/dev/null || true
        fi
        
        if command -v caddy >/dev/null 2>&1; then
            sudo systemctl restart caddy 2>/dev/null || true
        fi
        print_success "  ✓ Caddy 配置已清理"
    fi
    
    # 清理 Nginx 配置
    if [ -f "/etc/nginx/sites-available/hexo-blog" ]; then
        print_info "[⑤] 清理 Nginx 配置..."
        sudo rm -f /etc/nginx/sites-enabled/hexo-blog
        sudo rm -f /etc/nginx/sites-available/hexo-blog
        
        if command -v nginx >/dev/null 2>&1; then
            sudo systemctl restart nginx 2>/dev/null || true
        fi
        print_success "  ✓ Nginx 配置已清理"
    fi
    
    # 清理配置文件
    if [ -f "$CONFIG_FILE" ]; then
        echo ""
        read -p "是否删除管理脚本配置文件？(y/N): " remove_config
        if [[ "$remove_config" =~ ^[Yy]$ ]]; then
            rm -f "$CONFIG_FILE"
            print_success "配置文件已删除: $CONFIG_FILE"
        fi
    fi
    
    # 卸载 Node.js
    echo ""
    read -p "是否同时卸载 Node.js？(y/N): " remove_node
    if [[ "$remove_node" =~ ^[Yy]$ ]]; then
        print_info "卸载 Node.js 和 npm..."
        sudo apt remove -y nodejs npm 2>/dev/null || true
        sudo apt autoremove -y 2>/dev/null || true
        print_success "Node.js 已卸载"
    fi
    
    echo ""
    print_success "=========================================="
    print_success "卸载完成！"
    print_success "=========================================="
    echo ""
    
    if [ "$uninstall_option" = "2" ]; then
        print_info "提示：源文件和配置已保留在: $BLOG_DIR"
        print_info "重新部署：进入目录后运行 npm install"
    fi
    
    echo ""
    read -p "按 Enter 返回..."
}

# 3. 备份博客数据
backup_hexo() {
    print_info "=========================================="
    print_info "Hexo 博客备份工具"
    print_info "=========================================="
    echo ""
    
    if [ ! -d "$BLOG_DIR" ]; then
        print_error "博客目录不存在: $BLOG_DIR"
        return 1
    fi
    
    # 选择备份模式
    echo "备份模式："
    echo "1) 快速备份（仅源文件和配置，适合日常备份）"
    echo "2) 完整备份（包含所有配置、主题、脚本，推荐）"
    echo "3) 迁移备份（包含Git仓库和Web配置，用于完整迁移）"
    echo ""
    echo -e "${YELLOW}轻量化备份（推荐）：${NC}"
    echo "4) 纯内容备份（排除照片和视频，轻量快速）"
    echo "5) 仅媒体备份（仅备份照片和视频文件）"
    echo "0) 返回"
    echo ""
    read -p "请选择 [0-5]: " backup_mode
    
    EXCLUDE_MEDIA=false
    MEDIA_ONLY=false
    
    case $backup_mode in
        1)
            BACKUP_TYPE="quick"
            print_info "已选择：快速备份（包含所有文件）"
            ;;
        2)
            BACKUP_TYPE="full"
            print_info "已选择：完整备份（包含所有文件）"
            ;;
        3)
            BACKUP_TYPE="migrate"
            print_info "已选择：迁移备份（包含所有文件）"
            ;;
        4)
            BACKUP_TYPE="content_only"
            EXCLUDE_MEDIA=true
            print_info "已选择：纯内容备份（排除照片和视频）"
            print_info "  → 适合日常文章备份，文件小速度快"
            ;;
        5)
            BACKUP_TYPE="media_only"
            MEDIA_ONLY=true
            print_info "已选择：仅媒体备份（仅备份照片和视频）"
            print_info "  → 适合添加照片后的增量备份"
            ;;
        0)
            return
            ;;
        *)
            print_error "无效选项"
            return 1
            ;;
    esac
    
    echo ""
    print_info "开始备份..."
    
    # 创建备份目录
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    BACKUP_PATH="$BACKUP_DIR/hexo_backup_${BACKUP_TYPE}_$TIMESTAMP"
    sudo mkdir -p "$BACKUP_PATH"
    sudo chown "$USER:$USER" "$BACKUP_PATH"
    
    print_info "备份目标: $BACKUP_PATH"
    echo ""
    
    # 备份关键文件和目录
    cd "$BLOG_DIR"
    
    # === 所有模式都备份的基础文件 ===
    print_info "[①] 备份源文件..."
    
    if [ "$MEDIA_ONLY" = true ]; then
        # 仅备份媒体文件
        print_info "  → 仅备份媒体文件（照片和视频）"
        mkdir -p "$BACKUP_PATH/source"
        
        if [ -d "source/img" ]; then
            print_info "  → 复制照片目录..."
            cp -r source/img "$BACKUP_PATH/source/"
            IMG_COUNT=$(find source/img -type f 2>/dev/null | wc -l)
            IMG_SIZE=$(du -sh source/img 2>/dev/null | cut -f1)
            print_success "  ✓ 照片: $IMG_COUNT 个文件，大小: $IMG_SIZE"
        else
            print_warning "  ⚠ 未找到照片目录 (source/img)"
        fi
        
        if [ -d "source/videos" ]; then
            print_info "  → 复制视频目录..."
            cp -r source/videos "$BACKUP_PATH/source/"
            VIDEO_COUNT=$(find source/videos -type f 2>/dev/null | wc -l)
            VIDEO_SIZE=$(du -sh source/videos 2>/dev/null | cut -f1)
            print_success "  ✓ 视频: $VIDEO_COUNT 个文件，大小: $VIDEO_SIZE"
        else
            print_warning "  ⚠ 未找到视频目录 (source/videos)"
        fi
        
    elif [ "$EXCLUDE_MEDIA" = true ]; then
        # 排除媒体文件的备份
        print_info "  → 备份源文件（排除照片和视频）"
        
        if command -v rsync >/dev/null 2>&1; then
            # 使用rsync排除媒体目录
            rsync -av --exclude='img/' --exclude='videos/' source/ "$BACKUP_PATH/source/" >/dev/null 2>&1
            print_success "  ✓ 已使用rsync排除媒体文件"
        else
            # 手动排除：复制除img和videos外的所有内容
            mkdir -p "$BACKUP_PATH/source"
            cd source
            for item in *; do
                if [ "$item" != "img" ] && [ "$item" != "videos" ]; then
                    cp -r "$item" "$BACKUP_PATH/source/" 2>/dev/null || true
                fi
            done
            cd ..
            print_success "  ✓ 已手动排除媒体文件"
        fi
        
        # 显示排除的媒体文件统计
        if [ -d "source/img" ]; then
            IMG_COUNT=$(find source/img -type f 2>/dev/null | wc -l)
            IMG_SIZE=$(du -sh source/img 2>/dev/null | cut -f1)
            print_info "  → 已排除照片: $IMG_COUNT 个，$IMG_SIZE"
        fi
        
        if [ -d "source/videos" ]; then
            VIDEO_COUNT=$(find source/videos -type f 2>/dev/null | wc -l)
            VIDEO_SIZE=$(du -sh source/videos 2>/dev/null | cut -f1)
            print_info "  → 已排除视频: $VIDEO_COUNT 个，$VIDEO_SIZE"
        fi
        
    else
        # 完整备份（包含所有文件）
        print_info "  → 完整备份（包含所有文件）"
        [ -d "source" ] && cp -r source "$BACKUP_PATH/"
        
        # 显示媒体文件统计
        if [ -d "source/img" ]; then
            IMG_COUNT=$(find source/img -type f 2>/dev/null | wc -l)
            IMG_SIZE=$(du -sh source/img 2>/dev/null | cut -f1)
            print_info "  ✓ 包含照片: $IMG_COUNT 个，$IMG_SIZE"
        fi
        
        if [ -d "source/videos" ]; then
            VIDEO_COUNT=$(find source/videos -type f 2>/dev/null | wc -l)
            VIDEO_SIZE=$(du -sh source/videos 2>/dev/null | cut -f1)
            print_info "  ✓ 包含视频: $VIDEO_COUNT 个，$VIDEO_SIZE"
        fi
    fi
    
    print_info "[②] 备份主配置文件 (_config.yml)..."
    [ -f "_config.yml" ] && cp _config.yml "$BACKUP_PATH/"
    
    print_info "[③] 备份依赖清单 (package.json)..."
    [ -f "package.json" ] && cp package.json "$BACKUP_PATH/"
    [ -f "package-lock.json" ] && cp package-lock.json "$BACKUP_PATH/" 2>/dev/null || true
    
    # === 完整备份和迁移备份需要的额外文件 ===
    # 仅媒体备份不需要这些文件
    if [ "$MEDIA_ONLY" != true ] && ([ "$BACKUP_TYPE" = "full" ] || [ "$BACKUP_TYPE" = "migrate" ] || [ "$BACKUP_TYPE" = "content_only" ]); then
        print_info "[④] 备份主题文件 (themes/)..."
        [ -d "themes" ] && cp -r themes "$BACKUP_PATH/"
        
        print_info "[⑤] 备份所有主题配置文件 (_config.*.yml)..."
        for config_file in _config.*.yml; do
            if [ -f "$config_file" ]; then
                cp "$config_file" "$BACKUP_PATH/"
                print_info "  ✓ $config_file"
            fi
        done
        
        print_info "[⑥] 备份文章模板 (scaffolds/)..."
        [ -d "scaffolds" ] && cp -r scaffolds "$BACKUP_PATH/" 2>/dev/null || true
        
        print_info "[⑦] 备份自定义脚本 (scripts/)..."
        [ -d "scripts" ] && cp -r scripts "$BACKUP_PATH/" 2>/dev/null || true
        
        print_info "[⑧] 备份管理脚本 (*.sh)..."
        for sh_file in *.sh; do
            if [ -f "$sh_file" ]; then
                cp "$sh_file" "$BACKUP_PATH/"
                print_info "  ✓ $sh_file"
            fi
        done
        
        print_info "[⑨] 备份数据库文件 (db.json)..."
        [ -f "db.json" ] && cp db.json "$BACKUP_PATH/" 2>/dev/null || true
        
        print_info "[⑩] 备份 README 和说明文档..."
        [ -f "README.md" ] && cp README.md "$BACKUP_PATH/" 2>/dev/null || true
        [ -f ".gitignore" ] && cp .gitignore "$BACKUP_PATH/" 2>/dev/null || true
    fi
    
    # === 迁移备份需要的额外文件 ===
    if [ "$BACKUP_TYPE" = "migrate" ]; then
        print_info "[⑪] 备份Git仓库 (.git/)..."
        if [ -d ".git" ]; then
            cp -r .git "$BACKUP_PATH/"
            GIT_SIZE=$(du -sh "$BACKUP_PATH/.git" | cut -f1)
            print_info "  ✓ Git仓库大小: $GIT_SIZE"
        else
            print_warning "  ⚠ 未检测到Git仓库"
        fi
        
        print_info "[⑫] 备份Web服务器配置..."
        mkdir -p "$BACKUP_PATH/web_configs"
        
        # Caddy配置
        if [ -f "/etc/caddy/hexo-blog.caddy" ]; then
            sudo cp /etc/caddy/hexo-blog.caddy "$BACKUP_PATH/web_configs/" 2>/dev/null || true
            print_info "  ✓ Caddy配置"
        fi
        
        # Nginx配置
        if [ -f "/etc/nginx/sites-available/hexo-blog" ]; then
            sudo cp /etc/nginx/sites-available/hexo-blog "$BACKUP_PATH/web_configs/" 2>/dev/null || true
            print_info "  ✓ Nginx配置"
        fi
        
        # systemd服务
        if [ -f "/etc/systemd/system/hexo-blog.service" ]; then
            sudo cp /etc/systemd/system/hexo-blog.service "$BACKUP_PATH/web_configs/" 2>/dev/null || true
            print_info "  ✓ systemd服务配置"
        fi
        
        print_info "[⑬] 备份管理脚本配置..."
        [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "$BACKUP_PATH/" 2>/dev/null || true
    fi
    
    echo ""
    
    # 创建备份信息文件
    print_info "生成备份信息文件..."
    cat > "$BACKUP_PATH/backup_info.txt" << EOF
=========================================
Hexo 博客备份信息
=========================================
备份时间: $(date)
备份类型: $BACKUP_TYPE
博客路径: $BLOG_DIR
Node版本: $(node -v 2>/dev/null || echo "未安装")
npm版本: $(npm -v 2>/dev/null || echo "未安装")
Hexo版本: $(npx hexo -v 2>/dev/null | head -1 || echo "未安装")

备份内容：
EOF

    if [ "$BACKUP_TYPE" = "media_only" ]; then
        cat >> "$BACKUP_PATH/backup_info.txt" << EOF
- source/img/ (照片文件)
- source/videos/ (视频文件)

说明：仅包含媒体文件，不包含文章和配置
EOF
    elif [ "$BACKUP_TYPE" = "content_only" ]; then
        cat >> "$BACKUP_PATH/backup_info.txt" << EOF
- source/ (文章源文件，不含img/和videos/)
- themes/ (主题文件)
- _config.yml 和 _config.*.yml (所有配置文件)
- package.json (依赖清单)
- scaffolds/ (文章模板)
- scripts/ (自定义脚本)
- *.sh (管理脚本)
- db.json (数据库)

说明：不包含照片和视频，备份文件小速度快
EOF
    elif [ "$BACKUP_TYPE" = "quick" ]; then
        cat >> "$BACKUP_PATH/backup_info.txt" << EOF
- source/ (文章源文件，含照片和视频)
- _config.yml (主配置)
- package.json (依赖清单)
EOF
    elif [ "$BACKUP_TYPE" = "full" ]; then
        cat >> "$BACKUP_PATH/backup_info.txt" << EOF
- source/ (文章源文件)
- themes/ (主题文件)
- _config.yml 和 _config.*.yml (所有配置文件)
- package.json (依赖清单)
- scaffolds/ (文章模板)
- scripts/ (自定义脚本)
- *.sh (管理脚本)
- db.json (数据库)
- README.md, .gitignore
EOF
    else
        cat >> "$BACKUP_PATH/backup_info.txt" << EOF
- 完整备份的所有内容
- .git/ (Git仓库)
- web_configs/ (Web服务器配置)
- systemd/PM2 服务配置
- 管理脚本配置
EOF
    fi
    
    cat >> "$BACKUP_PATH/backup_info.txt" << EOF

恢复方法：
1. 解压备份文件
2. 复制文件到目标目录
3. 运行: npm install
4. 运行: npx hexo clean && npx hexo generate
=========================================
EOF
    
    # 压缩备份
    print_info "压缩备份文件..."
    cd "$BACKUP_DIR"
    tar -czf "hexo_backup_${BACKUP_TYPE}_$TIMESTAMP.tar.gz" "hexo_backup_${BACKUP_TYPE}_$TIMESTAMP"
    
    BACKUP_SIZE=$(du -sh "hexo_backup_${BACKUP_TYPE}_$TIMESTAMP.tar.gz" | cut -f1)
    
    echo ""
    print_success "=========================================="
    print_success "备份完成！"
    print_success "=========================================="
    print_info "备份类型: $BACKUP_TYPE"
    print_info "备份文件: $BACKUP_DIR/hexo_backup_${BACKUP_TYPE}_$TIMESTAMP.tar.gz"
    print_info "文件大小: $BACKUP_SIZE"
    print_info "备份目录: $BACKUP_PATH"
    echo ""
    
    read -p "是否删除未压缩的备份目录？(Y/n): " remove_uncompressed
    if [[ ! "$remove_uncompressed" =~ ^[Nn]$ ]]; then
        rm -rf "$BACKUP_PATH"
        print_info "已删除未压缩备份"
    fi
    
    # 清理旧备份
    echo ""
    read -p "是否清理旧备份（保留最近5个）？(Y/n): " clean_old
    if [[ ! "$clean_old" =~ ^[Nn]$ ]]; then
        print_info "清理旧备份..."
        ls -t "$BACKUP_DIR"/hexo_backup_*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
        REMAINING=$(ls "$BACKUP_DIR"/hexo_backup_*.tar.gz 2>/dev/null | wc -l)
        print_success "清理完成，剩余 $REMAINING 个备份文件"
    fi
    
    echo ""
    read -p "按 Enter 返回..."
}

# 4. 恢复备份数据
restore_hexo() {
    print_info "=========================================="
    print_info "Hexo 博客恢复工具"
    print_info "=========================================="
    echo ""
    
    if [ ! -d "$BACKUP_DIR" ]; then
        print_error "备份目录不存在: $BACKUP_DIR"
        return 1
    fi
    
    # 显示注意事项
    print_warning "=========================================="
    print_warning "⚠️  恢复前请仔细阅读以下注意事项"
    print_warning "=========================================="
    echo ""
    
    print_info "📦 恢复功能说明："
    echo "  • 恢复将使用备份文件覆盖现有文件"
    echo "  • 支持完全恢复、合并恢复、预览模式"
    echo "  • 完全恢复会删除现有数据，请谨慎操作"
    echo ""
    
    print_info "🛠️  必需工具和环境："
    echo ""
    echo "  1️⃣  Node.js (v14+) 和 npm"
    if command -v node >/dev/null 2>&1; then
        print_success "     ✓ 已安装: Node.js $(node -v), npm $(npm -v 2>/dev/null || echo 'N/A')"
    else
        print_warning "     ✗ 未安装 (恢复时可自动安装)"
    fi
    echo ""
    
    echo "  2️⃣  Web 服务器 (Caddy 或 Nginx)"
    WEB_SERVER_INSTALLED=false
    if command -v caddy >/dev/null 2>&1; then
        print_success "     ✓ Caddy 已安装"
        WEB_SERVER_INSTALLED=true
    elif command -v nginx >/dev/null 2>&1; then
        print_success "     ✓ Nginx 已安装"
        WEB_SERVER_INSTALLED=true
    else
        print_warning "     ✗ 未安装 Web 服务器"
        print_info "     提示：恢复后需手动安装 Caddy 或 Nginx"
    fi
    echo ""
    
    echo "  3️⃣  其他工具"
    print_success "     ✓ Git, curl, tar (系统内置)"
    echo ""
    
    print_info "📝 恢夏范围："
    echo "  • 博客源文件 (source/)"
    echo "  • 主题文件 (themes/)"
    echo "  • 所有配置文件 (_config*.yml)"
    echo "  • 依赖清单 (package.json)"
    echo "  • 自定义脚本和模板"
    if [ "$WEB_SERVER_INSTALLED" = true ]; then
        echo "  • Web 服务器配置文件"
    fi
    echo ""
    
    print_warning "⚠️  重要提示："
    echo "  • Web 服务器仅恢复配置文件，不包括软件本身"
    echo "  • 如果已卸载 Caddy/Nginx，请先重新安装："
    echo "    sudo apt install -y caddy"
    echo "    # 或"
    echo "    sudo apt install -y nginx"
    echo "  • 建议在恢复前备份现有数据"
    echo ""
    
    print_info "=========================================="
    read -p "确认继续恢复操作？(y/N): " confirm_restore
    echo ""
    
    if [[ ! "$confirm_restore" =~ ^[Yy]$ ]]; then
        print_info "已取消恢复操作"
        echo ""
        read -p "按 Enter 返回..."
        return
    fi
    
    print_success "开始执行恢复操作..."
    echo ""
    
    # 查找所有备份文件
    BACKUP_FILES=($(ls -t "$BACKUP_DIR"/hexo_backup_*.tar.gz 2>/dev/null))
    
    if [ ${#BACKUP_FILES[@]} -eq 0 ]; then
        print_error "未找到任何备份文件"
        print_info "备份目录: $BACKUP_DIR"
        echo ""
        read -p "按 Enter 返回..."
        return 1
    fi
    
    # 显示可用备份
    print_info "可用的备份文件："
    echo ""
    
    for i in "${!BACKUP_FILES[@]}"; do
        BACKUP_FILE="${BACKUP_FILES[$i]}"
        BACKUP_NAME=$(basename "$BACKUP_FILE")
        BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
        BACKUP_DATE=$(echo "$BACKUP_NAME" | grep -oE '[0-9]{8}_[0-9]{6}' | sed 's/_/ /' | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\) \([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
        
        # 检测备份类型
        BACKUP_TYPE="未知"
        if [[ "$BACKUP_NAME" =~ "quick" ]]; then
            BACKUP_TYPE="快速备份"
        elif [[ "$BACKUP_NAME" =~ "full" ]]; then
            BACKUP_TYPE="完整备份"
        elif [[ "$BACKUP_NAME" =~ "migrate" ]]; then
            BACKUP_TYPE="迁移备份"
        fi
        
        echo "$((i+1))) $BACKUP_TYPE - $BACKUP_DATE ($BACKUP_SIZE)"
        echo "   $BACKUP_NAME"
        echo ""
    done
    
    echo "0) 取消恢复"
    echo ""
    
    # 选择备份
    read -p "请选择要恢复的备份 [0-${#BACKUP_FILES[@]}]: " backup_choice
    
    if [ "$backup_choice" = "0" ] || [ -z "$backup_choice" ]; then
        print_info "已取消恢复"
        return
    fi
    
    if [ "$backup_choice" -lt 1 ] || [ "$backup_choice" -gt ${#BACKUP_FILES[@]} ]; then
        print_error "无效的选择"
        return 1
    fi
    
    SELECTED_BACKUP="${BACKUP_FILES[$((backup_choice-1))]}"
    SELECTED_NAME=$(basename "$SELECTED_BACKUP")
    
    echo ""
    print_info "已选择: $SELECTED_NAME"
    echo ""
    
    # 选择恢复模式
    echo "恢复模式："
    echo "1) 完全恢复（清空目标目录后恢复，推荐）"
    echo "2) 合并恢复（保留现有文件，只覆盖同名文件）"
    echo "3) 预览备份（仅解压查看，不恢复）"
    echo "0) 取消"
    echo ""
    read -p "请选择 [0-3]: " restore_mode
    
    case $restore_mode in
        1)
            RESTORE_TYPE="full"
            print_info "已选择：完全恢复"
            ;;
        2)
            RESTORE_TYPE="merge"
            print_info "已选择：合并恢复"
            ;;
        3)
            RESTORE_TYPE="preview"
            print_info "已选择：预览备份"
            ;;
        0)
            print_info "已取消恢复"
            return
            ;;
        *)
            print_error "无效选项"
            return 1
            ;;
    esac
    
    echo ""
    
    # 解压备份
    RESTORE_TEMP="$BACKUP_DIR/restore_temp_$$"
    print_info "解压备份文件..."
    mkdir -p "$RESTORE_TEMP"
    
    cd "$BACKUP_DIR"
    tar -xzf "$SELECTED_BACKUP" -C "$RESTORE_TEMP" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        print_error "解压失败！"
        rm -rf "$RESTORE_TEMP"
        return 1
    fi
    
    # 找到解压后的目录
    BACKUP_EXTRACTED=$(find "$RESTORE_TEMP" -maxdepth 1 -type d -name "hexo_backup_*" | head -1)
    
    if [ -z "$BACKUP_EXTRACTED" ] || [ ! -d "$BACKUP_EXTRACTED" ]; then
        print_error "无法找到备份数据！"
        rm -rf "$RESTORE_TEMP"
        return 1
    fi
    
    # 显示备份信息
    if [ -f "$BACKUP_EXTRACTED/backup_info.txt" ]; then
        echo ""
        print_info "备份信息："
        cat "$BACKUP_EXTRACTED/backup_info.txt"
        echo ""
    fi
    
    # 预览模式
    if [ "$RESTORE_TYPE" = "preview" ]; then
        print_info "备份内容："
        ls -lh "$BACKUP_EXTRACTED/"
        echo ""
        print_success "预览完成，文件位于: $BACKUP_EXTRACTED"
        print_info "提示：可以手动查看该目录中的文件"
        echo ""
        read -p "按 Enter 返回..."
        return
    fi
    
    # 恢复前确认
    echo ""
    if [ "$RESTORE_TYPE" = "full" ]; then
        print_warning "=========================================="
        print_warning "警告：完全恢复将删除现有数据！"
        print_warning "=========================================="
        echo ""
        print_warning "将删除的内容："
        echo "  - $BLOG_DIR/source/"
        echo "  - $BLOG_DIR/themes/"
        echo "  - $BLOG_DIR/_config*.yml"
        echo "  - $BLOG_DIR/package.json"
        echo ""
        read -p "是否先备份现有数据？(Y/n): " backup_current
        if [[ ! "$backup_current" =~ ^[Nn]$ ]]; then
            print_info "正在备份现有数据..."
            backup_hexo
        fi
        echo ""
        read -p "确认执行完全恢复？输入 'YES' 继续: " restore_confirm
        if [ "$restore_confirm" != "YES" ]; then
            print_info "已取消恢复"
            rm -rf "$RESTORE_TEMP"
            return
        fi
    else
        read -p "确认执行合并恢复？(y/N): " restore_confirm
        if [[ ! "$restore_confirm" =~ ^[Yy]$ ]]; then
            print_info "已取消恢复"
            rm -rf "$RESTORE_TEMP"
            return
        fi
    fi
    
    echo ""
    print_info "开始恢复..."
    
    # 确保目标目录存在
    sudo mkdir -p "$BLOG_DIR"
    sudo chown "$USER:$USER" "$BLOG_DIR"
    
    # 完全恢复模式：先清空
    if [ "$RESTORE_TYPE" = "full" ]; then
        print_info "[①] 清空目标目录..."
        cd "$BLOG_DIR"
        rm -rf source themes _config*.yml package*.json scaffolds scripts db.json README.md .gitignore *.sh 2>/dev/null || true
        print_success "  ✓ 目标目录已清空"
    fi
    
    # 恢复文件
    print_info "[②] 恢复文件..."
    
    cd "$BACKUP_EXTRACTED"
    
    # 恢复 source
    if [ -d "source" ]; then
        print_info "  - 恢复 source/"
        cp -rf source "$BLOG_DIR/"
    fi
    
    # 恢复 themes
    if [ -d "themes" ]; then
        print_info "  - 恢复 themes/"
        cp -rf themes "$BLOG_DIR/"
    fi
    
    # 恢复配置文件
    print_info "  - 恢复配置文件"
    for config in _config*.yml; do
        if [ -f "$config" ]; then
            cp -f "$config" "$BLOG_DIR/"
            print_info "    ✓ $config"
        fi
    done
    
    # 恢复 package.json
    if [ -f "package.json" ]; then
        print_info "  - 恢复 package.json"
        cp -f package.json "$BLOG_DIR/"
    fi
    
    if [ -f "package-lock.json" ]; then
        cp -f package-lock.json "$BLOG_DIR/" 2>/dev/null || true
    fi
    
    # 恢复 scaffolds
    if [ -d "scaffolds" ]; then
        print_info "  - 恢复 scaffolds/"
        cp -rf scaffolds "$BLOG_DIR/" 2>/dev/null || true
    fi
    
    # 恢复 scripts
    if [ -d "scripts" ]; then
        print_info "  - 恢复 scripts/"
        cp -rf scripts "$BLOG_DIR/" 2>/dev/null || true
    fi
    
    # 恢复脚本文件
    for sh_file in *.sh; do
        if [ -f "$sh_file" ]; then
            cp -f "$sh_file" "$BLOG_DIR/"
            chmod +x "$BLOG_DIR/$sh_file" 2>/dev/null || true
        fi
    done
    
    # 恢复其他文件
    [ -f "db.json" ] && cp -f db.json "$BLOG_DIR/" 2>/dev/null || true
    [ -f "README.md" ] && cp -f README.md "$BLOG_DIR/" 2>/dev/null || true
    [ -f ".gitignore" ] && cp -f .gitignore "$BLOG_DIR/" 2>/dev/null || true
    
    # 恢复Git仓库（迁移备份）
    if [ -d ".git" ]; then
        print_info "  - 恢复 Git 仓库"
        cp -rf .git "$BLOG_DIR/" 2>/dev/null || true
    fi
    
    # 恢复Web配置（迁移备份）
    CADDY_RESTORED=false
    NGINX_RESTORED=false
    SYSTEMD_RESTORED=false
    
    if [ -d "web_configs" ]; then
        print_info "  - 恢复 Web 服务器配置"
        
        # 恢复 Caddy 配置
        if [ -f "web_configs/hexo-blog.caddy" ]; then
            sudo cp -f web_configs/hexo-blog.caddy /etc/caddy/ 2>/dev/null || true
            print_info "    ✓ Caddy 配置已恢复"
            
            # 检查主配置文件是否已包含 import 语句
            if [ -f "/etc/caddy/Caddyfile" ]; then
                if ! grep -q "import hexo-blog.caddy" /etc/caddy/Caddyfile 2>/dev/null; then
                    print_info "    → 添加 import 到 Caddyfile"
                    echo "" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
                    echo "# Hexo Blog" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
                    echo "import hexo-blog.caddy" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
                fi
            fi
            CADDY_RESTORED=true
        fi
        
        # 恢复 Nginx 配置
        if [ -f "web_configs/hexo-blog" ]; then
            sudo cp -f web_configs/hexo-blog /etc/nginx/sites-available/ 2>/dev/null || true
            sudo ln -sf /etc/nginx/sites-available/hexo-blog /etc/nginx/sites-enabled/ 2>/dev/null || true
            print_info "    ✓ Nginx 配置已恢复"
            NGINX_RESTORED=true
        fi
        
        # 恢复 systemd 服务
        if [ -f "web_configs/hexo-blog.service" ]; then
            sudo cp -f web_configs/hexo-blog.service /etc/systemd/system/ 2>/dev/null || true
            sudo systemctl daemon-reload 2>/dev/null || true
            print_info "    ✓ systemd 服务配置已恢复"
            SYSTEMD_RESTORED=true
        fi
    fi
    
    print_success "  ✓ 文件恢复完成"
    
    # 清理临时文件
    print_info "[③] 清理临时文件..."
    rm -rf "$RESTORE_TEMP"
    print_success "  ✓ 临时文件已清理"
    
    # 重新安装依赖
    echo ""
    read -p "是否立即重新安装依赖？(Y/n): " install_deps
    if [[ ! "$install_deps" =~ ^[Nn]$ ]]; then
        # 检查Node.js是否安装
        if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
            print_warning "=========================================="
            print_warning "检测到 Node.js 未安装！"
            print_warning "=========================================="
            echo ""
            print_info "恢复功能需要 Node.js 环境"
            echo ""
            read -p "是否立即安装 Node.js v20？(Y/n): " install_node
            
            if [[ ! "$install_node" =~ ^[Nn]$ ]]; then
                print_info "[④] 安装 Node.js v20..."
                curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
                sudo apt install -y nodejs
                
                if command -v node >/dev/null 2>&1; then
                    print_success "  ✓ Node.js $(node -v) 安装完成"
                    print_success "  ✓ npm $(npm -v) 安装完成"
                else
                    print_error "  ✗ Node.js 安装失败！"
                    print_info "请手动安装 Node.js 后再继续"
                    echo ""
                    read -p "按 Enter 返回..."
                    return 1
                fi
            else
                print_info "已跳过 Node.js 安装"
                print_warning "请手动安装 Node.js 后运行："
                echo "  cd $BLOG_DIR"
                echo "  npm install"
                echo "  npx hexo clean && npx hexo generate"
                echo ""
                read -p "按 Enter 返回..."
                return
            fi
        fi
        
        cd "$BLOG_DIR"
        print_info "[⑤] 安装依赖..."
        npm install
        print_success "  ✓ 依赖安装完成"
        
        print_info "[⑥] 生成静态文件..."
        npx hexo clean
        npx hexo generate
        print_success "  ✓ 静态文件生成完成"
    fi
    
    # 重启 Web 服务器
    echo ""
    if [ "$CADDY_RESTORED" = true ] || [ "$NGINX_RESTORED" = true ] || [ "$SYSTEMD_RESTORED" = true ]; then
        print_info "[⑧] 重启 Web 服务..."
        
        # 重启 Caddy
        if [ "$CADDY_RESTORED" = true ]; then
            if command -v caddy >/dev/null 2>&1; then
                if sudo systemctl restart caddy 2>/dev/null; then
                    print_success "  ✓ Caddy 服务已重启"
                else
                    print_warning "  ⚠ Caddy 重启失败，请手动重启: sudo systemctl restart caddy"
                fi
            else
                print_warning "  ⚠ Caddy 未安装，配置已恢复但需先安装 Caddy"
            fi
        fi
        
        # 重启 Nginx
        if [ "$NGINX_RESTORED" = true ]; then
            if command -v nginx >/dev/null 2>&1; then
                if sudo systemctl restart nginx 2>/dev/null; then
                    print_success "  ✓ Nginx 服务已重启"
                else
                    print_warning "  ⚠ Nginx 重启失败，请手动重启: sudo systemctl restart nginx"
                fi
            else
                print_warning "  ⚠ Nginx 未安装，配置已恢复但需先安装 Nginx"
            fi
        fi
        
        # 启动 systemd 服务
        if [ "$SYSTEMD_RESTORED" = true ]; then
            if systemctl list-unit-files | grep -q "hexo-blog.service" 2>/dev/null; then
                read -p "是否启动 Hexo 后台服务？(y/N): " start_service
                if [[ "$start_service" =~ ^[Yy]$ ]]; then
                    sudo systemctl enable hexo-blog 2>/dev/null || true
                    if sudo systemctl start hexo-blog 2>/dev/null; then
                        print_success "  ✓ Hexo 后台服务已启动"
                    else
                        print_warning "  ⚠ 服务启动失败，请手动检查: sudo systemctl status hexo-blog"
                    fi
                else
                    print_info "  → 跳过服务启动，可手动启动: sudo systemctl start hexo-blog"
                fi
            fi
        fi
    fi
    
    echo ""
    print_success "=========================================="
    print_success "恢复完成！"
    print_success "=========================================="
    print_info "恢复位置: $BLOG_DIR"
    echo ""
    
    if [[ "$install_deps" =~ ^[Nn]$ ]]; then
        print_warning "提示：请手动运行以下命令完成恢复："
        echo "  cd $BLOG_DIR"
        echo "  npm install"
        echo "  npx hexo clean && npx hexo generate"
        echo ""
    fi
    
    read -p "按 Enter 返回..."
}

# 5. 同步博客（Git）
sync_hexo() {
    print_info "Hexo 博客 Git 同步工具"
    echo ""
    echo "同步选项："
    echo "1) 推送到远程仓库 (Push)"
    echo "2) 从远程仓库拉取 (Pull)"
    echo "3) 克隆远程仓库到本地"
    echo "4) 初始化 Git 仓库"
    echo "0) 返回主菜单"
    echo ""
    read -p "请选择 [0-4]: " sync_option
    
    case $sync_option in
        1)
            git_push
            ;;
        2)
            git_pull
            ;;
        3)
            git_clone_repo
            ;;
        4)
            git_init_repo
            ;;
        0)
            return
            ;;
        *)
            print_error "无效选项"
            ;;
    esac
}

# Git Push
git_push() {
    if [ ! -d "$BLOG_DIR" ]; then
        print_error "博客目录不存在: $BLOG_DIR"
        return 1
    fi
    
    cd "$BLOG_DIR"
    
    if [ ! -d ".git" ]; then
        print_error "当前目录不是 Git 仓库，请先初始化"
        read -p "是否现在初始化？(y/N): " init_now
        if [[ "$init_now" =~ ^[Yy]$ ]]; then
            git_init_repo
        fi
        return
    fi
    
    print_info "准备推送到远程仓库..."
    
    # 显示当前状态
    echo ""
    git status
    echo ""
    
    read -p "输入提交信息 (默认: Update blog): " commit_msg
    commit_msg=${commit_msg:-"Update blog"}
    
    print_info "添加文件..."
    git add .
    
    print_info "提交更改..."
    git commit -m "$commit_msg" || print_warning "没有需要提交的更改"
    
    print_info "推送到远程仓库..."
    git push || {
        print_error "推送失败"
        print_info "尝试设置上游分支..."
        read -p "输入分支名称 (默认: main): " branch_name
        branch_name=${branch_name:-"main"}
        git push -u origin "$branch_name"
    }
    
    print_success "推送完成！"
}

# Git Pull
git_pull() {
    if [ ! -d "$BLOG_DIR" ]; then
        print_error "博客目录不存在: $BLOG_DIR"
        return 1
    fi
    
    cd "$BLOG_DIR"
    
    if [ ! -d ".git" ]; then
        print_error "当前目录不是 Git 仓库"
        return 1
    fi
    
    print_info "从远程仓库拉取更新..."
    
    # 备份当前改动
    if ! git diff-index --quiet HEAD --; then
        print_warning "检测到未提交的更改"
        read -p "是否暂存当前更改？(Y/n): " stash_changes
        if [[ ! "$stash_changes" =~ ^[Nn]$ ]]; then
            git stash
            STASHED=true
        fi
    fi
    
    git pull || {
        print_error "拉取失败，可能存在冲突"
        return 1
    }
    
    if [ "$STASHED" = true ]; then
        print_info "恢复暂存的更改..."
        git stash pop
    fi
    
    print_info "重新安装依赖..."
    npm install
    
    print_info "重新生成静态文件..."
    npx hexo clean
    npx hexo generate
    
    print_success "同步完成！"
}

# Git Clone
git_clone_repo() {
    read -p "输入 Git 仓库地址: " repo_url
    
    if [ -z "$repo_url" ]; then
        print_error "仓库地址不能为空"
        return 1
    fi
    
    if [ -d "$BLOG_DIR" ] && [ "$(ls -A $BLOG_DIR)" ]; then
        print_warning "目标目录已存在且不为空: $BLOG_DIR"
        read -p "是否备份现有数据并覆盖？(y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            backup_hexo
            sudo rm -rf "$BLOG_DIR"
        else
            return
        fi
    fi
    
    print_info "克隆仓库..."
    sudo mkdir -p "$BLOG_DIR"
    sudo chown "$USER:$USER" "$BLOG_DIR"
    git clone "$repo_url" "$BLOG_DIR"
    
    cd "$BLOG_DIR"
    
    if [ -f "package.json" ]; then
        print_info "安装依赖..."
        npm install
        
        print_info "生成静态文件..."
        npx hexo clean
        npx hexo generate
        
        print_success "克隆并初始化完成！"
    else
        print_warning "未检测到 package.json，可能不是 Hexo 项目"
    fi
}

# Git Init
git_init_repo() {
    if [ ! -d "$BLOG_DIR" ]; then
        print_error "博客目录不存在: $BLOG_DIR"
        return 1
    fi
    
    cd "$BLOG_DIR"
    
    # 检查是否已存在Git仓库
    if [ -d ".git" ]; then
        print_warning "==========================================="
        print_warning "检测到 Git 仓库已存在"
        print_warning "==========================================="
        echo ""
        print_info "重新初始化将会："
        echo "  ⚠️  删除所有 Git 历史记录"
        echo "  ⚠️  删除所有分支信息"
        echo "  ⚠️  删除远程仓库配置"
        echo "  ⚠️  需要重新配置所有 Git 设置"
        echo ""
        print_warning "这个操作不可恢复！"
        echo ""
        read -p "确认重新初始化？输入 'YES' 继续: " confirm
        
        if [ "$confirm" != "YES" ]; then
            print_info "已取消操作"
            read -p "按 Enter 返回..."
            return
        fi
        
        print_info "删除现有 Git 仓库..."
        rm -rf .git
        print_success "现有仓库已删除"
    fi
    
    print_info "==========================================="
    print_info "开始初始化 Git 仓库"
    print_info "==========================================="
    echo ""
    
    # 步骤1：配置Git用户信息
    print_info "步骤 1/5: 配置 Git 用户信息"
    echo ""
    
    # 检查全局Git配置（避免 set -e 导致退出）
    GIT_USER_NAME=$(git config --global user.name 2>/dev/null || true)
    GIT_USER_EMAIL=$(git config --global user.email 2>/dev/null || true)
    
    if [ -z "$GIT_USER_NAME" ] || [ -z "$GIT_USER_EMAIL" ]; then
        print_warning "未检测到 Git 用户配置"
        echo ""
        print_info "请输入你的 Git 用户信息："
        echo ""
        
        read -p "Git 用户名 (如: Zhang San): " git_name
        read -p "Git 邮箱 (如: zhangsan@example.com): " git_email
        
        if [ -z "$git_name" ] || [ -z "$git_email" ]; then
            print_error "用户名和邮箱不能为空"
            return 1
        fi
        
        print_info "设置 Git 用户配置..."
        git config --global user.name "$git_name"
        git config --global user.email "$git_email"
        print_success "Git 用户信息已配置"
    else
        print_info "当前 Git 用户配置："
        echo "  用户名: $GIT_USER_NAME"
        echo "  邮箱: $GIT_USER_EMAIL"
        echo ""
        read -p "是否使用此配置？(Y/n): " use_current
        
        if [[ "$use_current" =~ ^[Nn]$ ]]; then
            read -p "Git 用户名: " git_name
            read -p "Git 邮箱: " git_email
            git config --global user.name "$git_name"
            git config --global user.email "$git_email"
            print_success "Git 用户信息已更新"
        fi
    fi
    
    echo ""
    
    # 步骤2：初始化仓库
    print_info "步骤 2/5: 初始化 Git 仓库"
    echo ""
    read -p "默认分支名称 (main/master，默认: main): " default_branch
    default_branch=${default_branch:-"main"}
    
    git init -b "$default_branch" 2>/dev/null || git init
    print_success "Git 仓库已初始化（分支: $default_branch）"
    echo ""
    
    # 步骤3：创建.gitignore
    print_info "步骤 3/5: 创建 .gitignore 文件"
    echo ""
    
    if [ -f ".gitignore" ]; then
        print_warning ".gitignore 文件已存在"
        read -p "是否覆盖？(y/N): " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            print_info "保留现有 .gitignore"
            echo ""
        else
            create_gitignore
        fi
    else
        create_gitignore
    fi
    
    # 步骤4：首次提交
    print_info "步骤 4/5: 添加文件并首次提交"
    echo ""
    
    print_info "添加所有文件到暂存区..."
    git add .
    
    print_info "创建初始提交..."
    git commit -m "Initial commit: Initialize Hexo blog" || {
        print_error "提交失败"
        return 1
    }
    print_success "初始提交完成"
    echo ""
    
    # 步骤5：配置远程仓库
    print_info "步骤 5/5: 配置远程仓库（可选）"
    echo ""
    print_info "远程仓库用于备份和多设备同步"
    echo ""
    
    read -p "是否现在添加远程仓库？(Y/n): " add_remote
    
    if [[ ! "$add_remote" =~ ^[Nn]$ ]]; then
        echo ""
        print_info "常见的远程仓库服务："
        echo "  • GitHub: https://github.com/username/repo.git"
        echo "  • GitLab: https://gitlab.com/username/repo.git"
        echo "  • Gitee: https://gitee.com/username/repo.git"
        echo ""
        
        read -p "输入远程仓库地址 (SSH/HTTPS): " remote_url
        
        if [ -n "$remote_url" ]; then
            print_info "添加远程仓库..."
            git remote add origin "$remote_url" || {
                print_error "添加远程仓库失败，可能地址格式错误"
                return 1
            }
            print_success "远程仓库已添加: origin"
            
            echo ""
            read -p "是否立即推送到远程仓库？(Y/n): " push_now
            
            if [[ ! "$push_now" =~ ^[Nn]$ ]]; then
                print_info "推送到远程仓库..."
                git push -u origin "$default_branch" || {
                    print_error "推送失败"
                    print_info "可能的原因："
                    echo "  1. 远程仓库不存在或无权限"
                    echo "  2. 需要先在 GitHub/GitLab 创建空仓库"
                    echo "  3. SSH 密钥未配置（如使用 SSH 地址）"
                    echo ""
                    print_info "你可以稍后手动推送："
                    echo "  git push -u origin $default_branch"
                    echo ""
                    read -p "按 Enter 继续..."
                    return 1
                }
                print_success "推送成功！"
            else
                print_info "稍后可手动推送："
                echo "  git push -u origin $default_branch"
            fi
        else
            print_info "已跳过远程仓库配置"
            print_info "稍后可手动添加："
            echo "  git remote add origin <仓库地址>"
            echo "  git push -u origin $default_branch"
        fi
    else
        print_info "已跳过远程仓库配置"
    fi
    
    echo ""
    print_success "=========================================="
    print_success "Git 仓库初始化完成！"
    print_success "=========================================="
    echo ""
    print_info "你现在可以："
    echo "  • 使用选项 4-1 推送更新到远程仓库"
    echo "  • 使用选项 4-2 从远程仓库拉取更新"
    echo "  • 查看状态: git status"
    echo "  • 查看日志: git log"
    echo ""
    
    read -p "按 Enter 返回主菜单..."
}

# 创建.gitignore文件
create_gitignore() {
    cat > .gitignore << 'EOF'
# Hexo 缓存和生成文件
.DS_Store
Thumbs.db
db.json
*.log
node_modules/
public/
.deploy*/
.deploy_git*/

# 编辑器
.idea/
.vscode/
*.swp
*.swo
*~

# 系统文件
.DS_Store
Thumbs.db

# 临时文件
*.tmp
*.temp
EOF
    print_success ".gitignore 已创建"
    echo ""
}

# 5. 本地文章上传（从 Windows/Mac 上传到 VPS）
upload_local_posts() {
    print_info "=========================================="
    print_info "从本地电脑上传文章到 VPS 的方法"
    print_info "=========================================="
    echo ""
    
    if [ ! -d "$BLOG_DIR" ]; then
        print_warning "博客目录不存在: $BLOG_DIR"
        print_info "请先部署 Hexo 博客（选项1）"
        read -p "按 Enter 返回..."
        return 1
    fi
    
    show_upload_commands
}

# 显示上传命令（从 Windows/Mac 上传到 VPS）
show_upload_commands() {
    # 获取服务器信息
    SERVER_IP=$(hostname -I | awk '{print $1}')
    SERVER_USER="$USER"
    
    echo ""
    print_info "=================================================="
    print_info "方法一：Windows PowerShell / CMD （推荐）"
    print_info "=================================================="
    echo ""
    print_info "1. 在 Windows 上打开 PowerShell 或 CMD"
    print_info "2. 执行以下命令："
    echo ""
    echo "  上传单个文件："
    echo -e "  ${GREEN}scp D:\\com\\BLOG\\测试.MD ${SERVER_USER}@${SERVER_IP}:$BLOG_DIR/source/_posts/${NC}"
    echo ""
    echo "  上传整个文件夹："
    echo -e "  ${GREEN}scp -r D:\\com\\BLOG\\posts\\* ${SERVER_USER}@${SERVER_IP}:$BLOG_DIR/source/_posts/${NC}"
    echo ""
    print_warning "注意：Windows 路径需要使用双反斜杠 \\\\ 或正斜杠 /"
    echo ""
    
    print_info "=================================================="
    print_info "方法二：使用 WinSCP 图形化工具 （最简单）"
    print_info "=================================================="
    echo ""
    print_info "1. 下载 WinSCP: https://winscp.net/"
    print_info "2. 连接信息："
    echo "   主机: $SERVER_IP"
    echo "   端口: 22"
    echo "   用户名: $SERVER_USER"
    echo "   协议: SFTP"
    print_info "3. 连接后导航到：$BLOG_DIR/source/_posts"
    print_info "4. 直接拖拽 .md 文件到右侧窗口上传"
    echo ""
    
    print_info "=================================================="
    print_info "方法三：VS Code Remote-SSH （开发者推荐）"
    print_info "=================================================="
    echo ""
    print_info "1. 安装 VS Code 插件: Remote-SSH"
    print_info "2. 连接到服务器: ${SERVER_USER}@${SERVER_IP}"
    print_info "3. 打开文件夹: $BLOG_DIR/source/_posts"
    print_info "4. 直接在 VS Code 中编辑和上传文件"
    echo ""
    
    print_info "=================================================="
    print_info "方法四：MacOS/Linux 终端"
    print_info "=================================================="
    echo ""
    echo "  上传单个文件："
    echo -e "  ${GREEN}scp ~/Documents/article.md ${SERVER_USER}@${SERVER_IP}:$BLOG_DIR/source/_posts/${NC}"
    echo ""
    echo "  使用 rsync 同步（增量上传）："
    echo -e "  ${GREEN}rsync -avz --progress ~/blog/posts/ ${SERVER_USER}@${SERVER_IP}:$BLOG_DIR/source/_posts/${NC}"
    echo ""
    
    print_info "=================================================="
    print_info "上传后的操作"
    print_info "=================================================="
    echo ""
    echo "1. SSH 登录到 VPS: ssh ${SERVER_USER}@${SERVER_IP}"
    echo "2. 运行管理脚本: ./hexo_manager.sh"
    echo "3. 选择 ${GREEN}9${NC} - 生成静态文件"
    echo "4. 网站自动更新，无需重启服务"
    echo ""
    
    read -p "按 Enter 返回主菜单..."
}

# 6. 后台服务管理
manage_service() {
    print_info "Hexo 后台服务管理"
    echo ""
    echo "服务方案："
    echo "1) systemd 服务（推荐生产环境，开机自启）"
    echo "2) PM2 进程管理（Node.js 专用，功能强大）"
    echo "3) nohup 简单后台（临时方案）"
    echo "0) 返回主菜单"
    echo ""
    read -p "请选择 [0-3]: " service_option
    
    case $service_option in
        1)
            manage_systemd_service
            ;;
        2)
            manage_pm2_service
            ;;
        3)
            start_nohup_service
            ;;
        0)
            return
            ;;
        *)
            print_error "无效选项"
            ;;
    esac
}

# systemd 服务管理
manage_systemd_service() {
    echo ""
    echo "systemd 服务操作："
    echo "1) 创建并启动服务"
    echo "2) 启动服务"
    echo "3) 停止服务"
    echo "4) 重启服务"
    echo "5) 查看服务状态"
    echo "6) 查看服务日志"
    echo "7) 删除服务"
    echo "0) 返回"
    echo ""
    read -p "请选择 [0-7]: " systemd_option
    
    case $systemd_option in
        1)
            create_systemd_service
            ;;
        2)
            sudo systemctl start hexo-blog
            print_success "服务已启动"
            sudo systemctl status hexo-blog
            ;;
        3)
            sudo systemctl stop hexo-blog
            print_success "服务已停止"
            ;;
        4)
            sudo systemctl restart hexo-blog
            print_success "服务已重启"
            sudo systemctl status hexo-blog
            ;;
        5)
            sudo systemctl status hexo-blog
            ;;
        6)
            sudo journalctl -u hexo-blog -f
            ;;
        7)
            remove_systemd_service
            ;;
        0)
            return
            ;;
        *)
            print_error "无效选项"
            ;;
    esac
}

# 创建 systemd 服务
create_systemd_service() {
    if [ ! -d "$BLOG_DIR" ]; then
        print_error "博客目录不存在: $BLOG_DIR"
        return 1
    fi
    
    print_info "创建 systemd 服务配置..."
    
    # 创建服务文件
    sudo tee /etc/systemd/system/hexo-blog.service > /dev/null << EOF
[Unit]
Description=Hexo Blog Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$BLOG_DIR
ExecStart=$(which npx) hexo server -p $HEXO_PORT
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hexo-blog

# 环境变量
Environment=NODE_ENV=production
Environment=PATH=$(dirname $(which node)):$PATH

[Install]
WantedBy=multi-user.target
EOF
    
    print_success "服务文件已创建: /etc/systemd/system/hexo-blog.service"
    
    # 重载 systemd
    print_info "重载 systemd..."
    sudo systemctl daemon-reload
    
    # 启用开机自启
    read -p "是否设置开机自启？(Y/n): " enable_boot
    if [[ ! "$enable_boot" =~ ^[Nn]$ ]]; then
        sudo systemctl enable hexo-blog
        print_success "已设置开机自启"
    fi
    
    # 启动服务
    read -p "是否立即启动服务？(Y/n): " start_now
    if [[ ! "$start_now" =~ ^[Nn]$ ]]; then
        sudo systemctl start hexo-blog
        sleep 2
        sudo systemctl status hexo-blog
    fi
    
    print_success "=========================================="
    print_success "systemd 服务创建完成！"
    print_success "=========================================="
    print_info "服务名称: hexo-blog"
    print_info "访问地址: http://localhost:$HEXO_PORT"
    echo ""
    print_info "常用命令："
    echo "  启动服务: sudo systemctl start hexo-blog"
    echo "  停止服务: sudo systemctl stop hexo-blog"
    echo "  重启服务: sudo systemctl restart hexo-blog"
    echo "  查看状态: sudo systemctl status hexo-blog"
    echo "  查看日志: sudo journalctl -u hexo-blog -f"
}

# 删除 systemd 服务
remove_systemd_service() {
    print_warning "即将删除 hexo-blog systemd 服务"
    read -p "确认删除？(y/N): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_info "停止服务..."
        sudo systemctl stop hexo-blog 2>/dev/null || true
        
        print_info "禁用开机自启..."
        sudo systemctl disable hexo-blog 2>/dev/null || true
        
        print_info "删除服务文件..."
        sudo rm -f /etc/systemd/system/hexo-blog.service
        
        print_info "重载 systemd..."
        sudo systemctl daemon-reload
        
        print_success "服务已删除"
    else
        print_info "取消删除"
    fi
}

# PM2 进程管理
manage_pm2_service() {
    # 检查 PM2 是否安装
    if ! command -v pm2 >/dev/null 2>&1; then
        print_warning "PM2 未安装"
        read -p "是否立即安装 PM2？(Y/n): " install_pm2
        if [[ ! "$install_pm2" =~ ^[Nn]$ ]]; then
            print_info "安装 PM2..."
            sudo npm install -g pm2
            print_success "PM2 安装完成"
        else
            return
        fi
    fi
    
    echo ""
    echo "PM2 服务操作："
    echo "1) 启动 Hexo 服务"
    echo "2) 停止 Hexo 服务"
    echo "3) 重启 Hexo 服务"
    echo "4) 查看服务列表"
    echo "5) 查看日志"
    echo "6) 查看监控面板"
    echo "7) 设置开机自启"
    echo "8) 删除服务"
    echo "0) 返回"
    echo ""
    read -p "请选择 [0-8]: " pm2_option
    
    case $pm2_option in
        1)
            start_pm2_service
            ;;
        2)
            pm2 stop hexo-blog
            print_success "服务已停止"
            pm2 list
            ;;
        3)
            pm2 restart hexo-blog
            print_success "服务已重启"
            pm2 list
            ;;
        4)
            pm2 list
            ;;
        5)
            pm2 logs hexo-blog
            ;;
        6)
            pm2 monit
            ;;
        7)
            print_info "设置开机自启..."
            pm2 startup
            pm2 save
            print_success "已设置开机自启"
            ;;
        8)
            pm2 delete hexo-blog
            print_success "服务已删除"
            ;;
        0)
            return
            ;;
        *)
            print_error "无效选项"
            ;;
    esac
}

# 启动 PM2 服务
start_pm2_service() {
    if [ ! -d "$BLOG_DIR" ]; then
        print_error "博客目录不存在: $BLOG_DIR"
        return 1
    fi
    
    cd "$BLOG_DIR"
    
    print_info "启动 PM2 服务..."
    
    # 检查是否已存在
    if pm2 list | grep -q "hexo-blog"; then
        print_warning "服务已存在，将重启..."
        pm2 restart hexo-blog
    else
        # 启动新服务
        pm2 start npx --name "hexo-blog" -- hexo server -p $HEXO_PORT
    fi
    
    print_success "=========================================="
    print_success "PM2 服务启动完成！"
    print_success "=========================================="
    print_info "服务名称: hexo-blog"
    print_info "访问地址: http://localhost:$HEXO_PORT"
    echo ""
    pm2 list
    echo ""
    print_info "常用命令："
    echo "  查看列表: pm2 list"
    echo "  查看日志: pm2 logs hexo-blog"
    echo "  停止服务: pm2 stop hexo-blog"
    echo "  重启服务: pm2 restart hexo-blog"
    echo "  监控面板: pm2 monit"
}

# nohup 简单后台
start_nohup_service() {
    if [ ! -d "$BLOG_DIR" ]; then
        print_error "博客目录不存在: $BLOG_DIR"
        return 1
    fi
    
    cd "$BLOG_DIR"
    
    # 检查是否已在运行
    if pgrep -f "hexo server" > /dev/null; then
        print_warning "检测到 Hexo 服务器正在运行"
        read -p "是否停止现有服务？(y/N): " kill_existing
        if [[ "$kill_existing" =~ ^[Yy]$ ]]; then
            pkill -f "hexo server"
            sleep 2
            print_success "已停止现有服务"
        else
            return
        fi
    fi
    
    print_info "使用 nohup 启动后台服务..."
    
    # 创建日志目录
    mkdir -p "$BLOG_DIR/logs"
    
    # 启动服务
    nohup npx hexo server -p $HEXO_PORT > "$BLOG_DIR/logs/hexo.log" 2>&1 &
    
    sleep 2
    
    if pgrep -f "hexo server" > /dev/null; then
        PID=$(pgrep -f "hexo server")
        print_success "=========================================="
        print_success "Hexo 服务已后台启动！"
        print_success "=========================================="
        print_info "进程 PID: $PID"
        print_info "访问地址: http://localhost:$HEXO_PORT"
        print_info "日志文件: $BLOG_DIR/logs/hexo.log"
        echo ""
        print_info "停止服务命令："
        echo "  kill $PID"
        echo "  或 pkill -f 'hexo server'"
        echo ""
        print_info "查看日志命令："
        echo "  tail -f $BLOG_DIR/logs/hexo.log"
    else
        print_error "服务启动失败，请查看日志"
        tail -n 20 "$BLOG_DIR/logs/hexo.log"
    fi
}

# 6. Web 服务器配置管理
manage_webserver() {
    print_info "Web 服务器配置管理（静态文件托管）"
    echo ""
    
    # 检测已安装的服务器
    CADDY_INSTALLED=false
    NGINX_INSTALLED=false
    
    if command -v caddy >/dev/null 2>&1; then
        CADDY_INSTALLED=true
        print_success "检测到 Caddy: $(caddy version 2>&1 | head -1)"
    fi
    
    if command -v nginx >/dev/null 2>&1; then
        NGINX_INSTALLED=true
        print_success "检测到 Nginx: $(nginx -v 2>&1)"
    fi
    
    if [ "$CADDY_INSTALLED" = false ] && [ "$NGINX_INSTALLED" = false ]; then
        print_warning "未检测到 Caddy 或 Nginx"
    fi
    
    echo ""
    echo "选择操作："
    echo "1) 安装并配置 Caddy（推荐）"
    echo "2) 安装并配置 Nginx"
    echo "3) 配置现有 Caddy"
    echo "4) 配置现有 Nginx"
    echo "5) 查看 Caddy 配置"
    echo "6) 查看 Nginx 配置"
    echo "7) 删除 Hexo 站点配置"
    echo "0) 返回主菜单"
    echo ""
    read -p "请选择 [0-7]: " webserver_option
    
    case $webserver_option in
        1)
            install_and_configure_caddy
            ;;
        2)
            install_and_configure_nginx
            ;;
        3)
            if [ "$CADDY_INSTALLED" = true ]; then
                configure_caddy
            else
                print_error "Caddy 未安装"
            fi
            ;;
        4)
            if [ "$NGINX_INSTALLED" = true ]; then
                configure_nginx
            else
                print_error "Nginx 未安装"
            fi
            ;;
        5)
            view_caddy_config
            ;;
        6)
            view_nginx_config
            ;;
        7)
            remove_webserver_config
            ;;
        0)
            return
            ;;
        *)
            print_error "无效选项"
            ;;
    esac
}

# 安装并配置 Caddy
install_and_configure_caddy() {
    if command -v caddy >/dev/null 2>&1; then
        print_info "Caddy 已安装，跳过安装步骤"
        configure_caddy
        return
    fi
    
    print_info "开始安装 Caddy..."
    
    # 安装依赖
    sudo apt update
    sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
    
    # 添加 Caddy 官方源
    print_info "添加 Caddy 官方源..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    
    # 安装 Caddy
    print_info "安装 Caddy..."
    sudo apt update
    sudo apt install -y caddy
    
    print_success "Caddy 安装完成！"
    
    # 配置 Caddy
    configure_caddy
}

# 配置 Caddy
configure_caddy() {
    if [ ! -d "$BLOG_DIR" ]; then
        print_error "博客目录不存在: $BLOG_DIR"
        print_info "请先运行选项1部署 Hexo 博客"
        return 1
    fi
    
    if [ ! -d "$BLOG_DIR/public" ]; then
        print_warning "静态文件目录不存在"
        read -p "是否立即生成静态文件？(Y/n): " gen_static
        if [[ ! "$gen_static" =~ ^[Nn]$ ]]; then
            generate_static
        else
            return 1
        fi
    fi
    
    print_info "配置 Caddy..."
    echo ""
    
    # 获取域名
    read -p "输入域名（例如 blog.example.com，留空使用 localhost）: " domain_name
    domain_name=${domain_name:-localhost}
    
    # 备份现有配置
    if [ -f "/etc/caddy/Caddyfile" ]; then
        print_info "备份现有 Caddyfile..."
        sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.backup.$(date +%Y%m%d_%H%M%S)
    fi
    
    # 检查是否已有配置
    HEXO_CONF_EXISTS=false
    if [ -f "/etc/caddy/Caddyfile" ] && grep -q "hexo-blog" /etc/caddy/Caddyfile 2>/dev/null; then
        HEXO_CONF_EXISTS=true
        print_warning "检测到已有 Hexo 博客配置"
        read -p "是否覆盖现有配置？(y/N): " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            print_info "取消配置"
            return
        fi
    fi
    
    # 创建独立配置文件
    HEXO_CADDY_CONF="/etc/caddy/hexo-blog.caddy"
    
    print_info "创建 Hexo 博客配置文件..."
    sudo tee "$HEXO_CADDY_CONF" > /dev/null << EOF
# Hexo Blog Configuration
# 由 hexo_manager.sh 自动生成
# 生成时间: $(date)

$domain_name {
    # 静态文件根目录
    root * $BLOG_DIR/public
    
    # 启用文件服务器
    file_server
    
    # 启用压缩
    encode gzip zstd
    
    # 404 错误处理
    handle_errors {
        @404 {
            expression {http.error.status_code} == 404
        }
        rewrite @404 /404.html
        file_server
    }
    
    # 静态资源缓存策略
    @static {
        path *.css *.js *.jpg *.jpeg *.png *.gif *.ico *.svg *.woff *.woff2 *.ttf *.eot *.webp
    }
    header @static Cache-Control "public, max-age=31536000, immutable"
    
    # HTML 文件短缓存
    @html {
        path *.html
    }
    header @html Cache-Control "public, max-age=3600"
    
    # 日志配置
    log {
        output file /var/log/caddy/hexo-blog-access.log
        format json
    }
    
    # 安全头部
    header {
        # HSTS
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        # XSS 保护
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        X-XSS-Protection "1; mode=block"
        # 引用策略
        Referrer-Policy "strict-origin-when-cross-origin"
    }
}
EOF
    
    print_success "配置文件已创建: $HEXO_CADDY_CONF"
    
    # 更新主 Caddyfile
    print_info "更新主 Caddyfile..."
    
    # 检查主配置文件是否存在
    if [ ! -f "/etc/caddy/Caddyfile" ]; then
        # 创建新的 Caddyfile
        sudo tee /etc/caddy/Caddyfile > /dev/null << EOF
# Caddy 主配置文件
# 导入 Hexo 博客配置
import hexo-blog.caddy
EOF
    else
        # 检查是否已有 import 语句
        if ! grep -q "import hexo-blog.caddy" /etc/caddy/Caddyfile; then
            # 追加 import 语句
            echo "" | sudo tee -a /etc/caddy/Caddyfile > /dev/null
            echo "# Hexo Blog" | sudo tee -a /etc/caddy/Caddyfile > /dev/null
            echo "import hexo-blog.caddy" | sudo tee -a /etc/caddy/Caddyfile > /dev/null
            print_success "已添加 Hexo 配置导入语句"
        else
            print_info "配置导入语句已存在"
        fi
    fi
    
    # 创建日志目录并设置权限
    print_info "创建日志目录..."
    sudo mkdir -p /var/log/caddy
    
    # 检测 Caddy 运行用户
    if id caddy >/dev/null 2>&1; then
        sudo chown -R caddy:caddy /var/log/caddy
        print_info "日志目录所有者: caddy"
    elif id www-data >/dev/null 2>&1; then
        sudo chown -R www-data:www-data /var/log/caddy
        print_info "日志目录所有者: www-data"
    else
        sudo chown -R root:root /var/log/caddy
        print_info "日志目录所有者: root"
    fi
    
    # 设置目录权限（递归设置确保所有文件都有正确权限）
    sudo chmod -R 755 /var/log/caddy
    
    # 验证配置
    print_info "验证 Caddy 配置..."
    if sudo caddy validate --config /etc/caddy/Caddyfile; then
        print_success "配置验证成功！"
        
        # 重启 Caddy
        read -p "是否立即重启 Caddy 应用配置？(Y/n): " restart_caddy
        if [[ ! "$restart_caddy" =~ ^[Nn]$ ]]; then
            print_info "停止 Caddy 服务..."
            sudo systemctl stop caddy
            sleep 1
            
            print_info "启动 Caddy 服务..."
            if sudo systemctl start caddy; then
                sleep 2
                
                if sudo systemctl is-active --quiet caddy; then
                    # 修复 public 目录权限
                    print_info "设置静态文件权限..."
                    if [ -d "$BLOG_DIR/public" ]; then
                        # 让 caddy 用户可以读取所有文件
                        sudo chmod -R 755 "$BLOG_DIR/public"
                        # 确保文件对所有人可读
                        sudo find "$BLOG_DIR/public" -type f -exec chmod 644 {} \;
                        sudo find "$BLOG_DIR/public" -type d -exec chmod 755 {} \;
                        print_success "文件权限已修复"
                    fi
                    
                    print_success "=========================================="
                    print_success "Caddy 配置完成！"
                    print_success "=========================================="
                    print_info "访问地址: http://$domain_name"
                    if [ "$domain_name" != "localhost" ]; then
                        print_info "HTTPS 地址: https://$domain_name"
                        print_info "提示: Caddy 会自动申请 Let's Encrypt SSL 证书"
                    fi
                    print_info "配置文件: $HEXO_CADDY_CONF"
                    print_info "日志文件: /var/log/caddy/hexo-blog-access.log"
                    echo ""
                    print_info "更新博客内容后，执行："
                    echo "  选项9 - 生成静态文件"
                    echo "  Caddy 会自动读取更新，无需重启"
                else
                    print_error "Caddy 服务未能正常启动"
                    print_info "查看详细错误："
                    sudo journalctl -u caddy -n 30 --no-pager
                fi
            else
                print_error "Caddy 启动失败！"
                print_info "错误详情："
                sudo journalctl -u caddy -n 30 --no-pager
                echo ""
                print_info "常见问题排查："
                echo "1. 检查配置文件语法: sudo caddy validate --config /etc/caddy/Caddyfile"
                echo "2. 检查端口占用: sudo ss -tulpn | grep ':80\|:443'"
                echo "3. 查看完整日志: sudo journalctl -u caddy -f"
            fi
        fi
    else
        print_error "配置验证失败！"
        print_info "正在恢复备份..."
        LATEST_BACKUP=$(ls -t /etc/caddy/Caddyfile.backup.* 2>/dev/null | head -1)
        if [ -n "$LATEST_BACKUP" ]; then
            sudo cp "$LATEST_BACKUP" /etc/caddy/Caddyfile
            print_success "已恢复备份配置"
        fi
        return 1
    fi
}

# 安装并配置 Nginx
install_and_configure_nginx() {
    if command -v nginx >/dev/null 2>&1; then
        print_info "Nginx 已安装，跳过安装步骤"
        configure_nginx
        return
    fi
    
    print_info "开始安装 Nginx..."
    
    sudo apt update
    sudo apt install -y nginx
    
    print_success "Nginx 安装完成！"
    
    # 配置 Nginx
    configure_nginx
}

# 配置 Nginx
configure_nginx() {
    if [ ! -d "$BLOG_DIR" ]; then
        print_error "博客目录不存在: $BLOG_DIR"
        print_info "请先运行选项1部署 Hexo 博客"
        return 1
    fi
    
    if [ ! -d "$BLOG_DIR/public" ]; then
        print_warning "静态文件目录不存在"
        read -p "是否立即生成静态文件？(Y/n): " gen_static
        if [[ ! "$gen_static" =~ ^[Nn]$ ]]; then
            generate_static
        else
            return 1
        fi
    fi
    
    print_info "配置 Nginx..."
    echo ""
    
    # 获取域名和端口
    read -p "输入域名（例如 blog.example.com）: " domain_name
    if [ -z "$domain_name" ]; then
        print_error "域名不能为空"
        return 1
    fi
    
    read -p "监听端口（默认 80）: " listen_port
    listen_port=${listen_port:-80}
    
    # 配置文件路径
    NGINX_SITE_CONF="/etc/nginx/sites-available/hexo-blog"
    NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/hexo-blog"
    
    # 备份现有配置
    if [ -f "$NGINX_SITE_CONF" ]; then
        print_info "备份现有配置..."
        sudo cp "$NGINX_SITE_CONF" "${NGINX_SITE_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # 创建配置文件
    print_info "创建 Nginx 配置文件..."
    sudo tee "$NGINX_SITE_CONF" > /dev/null << EOF
# Hexo Blog Nginx Configuration
# 由 hexo_manager.sh 自动生成
# 生成时间: $(date)

server {
    listen $listen_port;
    listen [::]:$listen_port;
    server_name $domain_name;
    
    # 静态文件根目录
    root $BLOG_DIR/public;
    index index.html index.htm;
    
    # 访问日志
    access_log /var/log/nginx/hexo-blog-access.log;
    error_log /var/log/nginx/hexo-blog-error.log;
    
    # Gzip 压缩
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/rss+xml font/truetype font/opentype application/vnd.ms-fontobject image/svg+xml;
    
    # 主要位置配置
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # 静态资源缓存
    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot|webp)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
    
    # HTML 文件短缓存
    location ~* \.html\$ {
        expires 1h;
        add_header Cache-Control "public";
    }
    
    # 404 页面
    error_page 404 /404.html;
    location = /404.html {
        internal;
    }
    
    # 安全头部
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    
    # 禁止访问隐藏文件
    location ~ /\. {
        deny all;
    }
}
EOF
    
    print_success "配置文件已创建: $NGINX_SITE_CONF"
    
    # 创建软链接（如果不存在）
    if [ ! -L "$NGINX_SITE_ENABLED" ]; then
        print_info "启用站点配置..."
        sudo ln -s "$NGINX_SITE_CONF" "$NGINX_SITE_ENABLED"
        print_success "站点配置已启用"
    fi
    
    # 验证配置
    print_info "验证 Nginx 配置..."
    if sudo nginx -t; then
        print_success "配置验证成功！"
        
        # 重启 Nginx
        read -p "是否立即重启 Nginx 应用配置？(Y/n): " restart_nginx
        if [[ ! "$restart_nginx" =~ ^[Nn]$ ]]; then
            print_info "重启 Nginx..."
            sudo systemctl restart nginx
            sleep 2
            
            if sudo systemctl is-active --quiet nginx; then
                print_success "=========================================="
                print_success "Nginx 配置完成！"
                print_success "=========================================="
                print_info "访问地址: http://$domain_name:$listen_port"
                print_info "配置文件: $NGINX_SITE_CONF"
                print_info "访问日志: /var/log/nginx/hexo-blog-access.log"
                print_info "错误日志: /var/log/nginx/hexo-blog-error.log"
                echo ""
                print_info "更新博客内容后，执行："
                echo "  选项8 - 生成静态文件"
                echo "  Nginx 会自动读取更新，无需重启"
                echo ""
                print_info "配置 HTTPS (可选):"
                echo "  sudo apt install certbot python3-certbot-nginx"
                echo "  sudo certbot --nginx -d $domain_name"
            else
                print_error "Nginx 启动失败，请查看日志"
                sudo journalctl -u nginx -n 50 --no-pager
            fi
        fi
    else
        print_error "配置验证失败！"
        print_info "正在恢复备份..."
        LATEST_BACKUP=$(ls -t "${NGINX_SITE_CONF}.backup."* 2>/dev/null | head -1)
        if [ -n "$LATEST_BACKUP" ]; then
            sudo cp "$LATEST_BACKUP" "$NGINX_SITE_CONF"
            print_success "已恢复备份配置"
        fi
        return 1
    fi
}

# 查看 Caddy 配置
view_caddy_config() {
    if [ -f "/etc/caddy/hexo-blog.caddy" ]; then
        print_info "Hexo 博客 Caddy 配置："
        echo ""
        cat /etc/caddy/hexo-blog.caddy
        echo ""
        print_info "主配置文件：/etc/caddy/Caddyfile"
        print_info "Hexo 配置：/etc/caddy/hexo-blog.caddy"
    else
        print_warning "未找到 Hexo 博客配置文件"
    fi
}

# 查看 Nginx 配置
view_nginx_config() {
    if [ -f "/etc/nginx/sites-available/hexo-blog" ]; then
        print_info "Hexo 博客 Nginx 配置："
        echo ""
        cat /etc/nginx/sites-available/hexo-blog
        echo ""
        print_info "配置文件：/etc/nginx/sites-available/hexo-blog"
    else
        print_warning "未找到 Hexo 博客配置文件"
    fi
}

# 删除 Web 服务器配置
remove_webserver_config() {
    echo ""
    echo "选择要删除的配置："
    echo "1) Caddy 配置"
    echo "2) Nginx 配置"
    echo "0) 返回"
    echo ""
    read -p "请选择 [0-2]: " remove_option
    
    case $remove_option in
        1)
            remove_caddy_config
            ;;
        2)
            remove_nginx_config
            ;;
        0)
            return
            ;;
        *)
            print_error "无效选项"
            ;;
    esac
}

# 删除 Caddy 配置
remove_caddy_config() {
    if [ ! -f "/etc/caddy/hexo-blog.caddy" ]; then
        print_warning "未找到 Hexo 博客 Caddy 配置"
        return
    fi
    
    print_warning "即将删除 Hexo 博客 Caddy 配置"
    read -p "确认删除？(y/N): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 备份
        sudo cp /etc/caddy/hexo-blog.caddy /etc/caddy/hexo-blog.caddy.removed.$(date +%Y%m%d_%H%M%S)
        
        # 删除配置文件
        sudo rm -f /etc/caddy/hexo-blog.caddy
        
        # 从主配置文件中移除 import 语句
        if [ -f "/etc/caddy/Caddyfile" ]; then
            sudo sed -i '/import hexo-blog.caddy/d' /etc/caddy/Caddyfile
            sudo sed -i '/# Hexo Blog/d' /etc/caddy/Caddyfile
        fi
        
        # 重启 Caddy
        print_info "重启 Caddy..."
        sudo systemctl restart caddy
        
        print_success "Caddy 配置已删除"
    else
        print_info "取消删除"
    fi
}

# 删除 Nginx 配置
remove_nginx_config() {
    if [ ! -f "/etc/nginx/sites-available/hexo-blog" ]; then
        print_warning "未找到 Hexo 博客 Nginx 配置"
        return
    fi
    
    print_warning "即将删除 Hexo 博客 Nginx 配置"
    read -p "确认删除？(y/N): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 备份
        sudo cp /etc/nginx/sites-available/hexo-blog /etc/nginx/sites-available/hexo-blog.removed.$(date +%Y%m%d_%H%M%S)
        
        # 删除软链接
        sudo rm -f /etc/nginx/sites-enabled/hexo-blog
        
        # 删除配置文件
        sudo rm -f /etc/nginx/sites-available/hexo-blog
        
        # 重启 Nginx
        print_info "重启 Nginx..."
        sudo systemctl restart nginx
        
        print_success "Nginx 配置已删除"
    else
        print_info "取消删除"
    fi
}

# 7. 启动 Hexo 服务器（前台测试）
start_hexo_server() {
    if [ ! -d "$BLOG_DIR" ]; then
        print_error "博客目录不存在: $BLOG_DIR"
        return 1
    fi
    
    cd "$BLOG_DIR"
    
    if [ ! -f "package.json" ]; then
        print_error "未检测到 Hexo 项目"
        return 1
    fi
    
    print_info "启动 Hexo 服务器（前台模式，仅用于测试）..."
    print_info "访问地址: http://localhost:$HEXO_PORT"
    print_warning "按 Ctrl+C 停止服务器"
    print_warning "提示：生产环境请使用选项6的后台服务管理"
    echo ""
    
    npx hexo server -p $HEXO_PORT
}

# 8. 生成静态文件
generate_static() {
    if [ ! -d "$BLOG_DIR" ]; then
        print_error "博客目录不存在: $BLOG_DIR"
        return 1
    fi
    
    cd "$BLOG_DIR"
    
    print_info "清理缓存..."
    npx hexo clean
    
    print_info "生成静态文件..."
    npx hexo generate
    
    print_success "=========================================="
    print_success "静态文件生成完成！"
    print_success "=========================================="
    print_info "输出目录: $BLOG_DIR/public"
    
    if [ -d "public" ]; then
        FILE_COUNT=$(find public -type f | wc -l)
        DIR_SIZE=$(du -sh public | cut -f1)
        print_info "文件数量: $FILE_COUNT"
        print_info "目录大小: $DIR_SIZE"
        
        # 修复文件权限，确保 Web 服务器可读取
        print_info "设置文件权限..."
        chmod -R 755 "$BLOG_DIR/public" 2>/dev/null || sudo chmod -R 755 "$BLOG_DIR/public"
        find "$BLOG_DIR/public" -type f -exec chmod 644 {} \; 2>/dev/null || sudo find "$BLOG_DIR/public" -type f -exec chmod 644 {} \;
        find "$BLOG_DIR/public" -type d -exec chmod 755 {} \; 2>/dev/null || sudo find "$BLOG_DIR/public" -type d -exec chmod 755 {} \;
        print_success "文件权限已设置（所有人可读）"
    fi
}

# 9. 查看博客状态
show_status() {
    print_info "=========================================="
    print_info "Hexo 博客状态"
    print_info "=========================================="
    
    echo ""
    echo "📁 博客目录: $BLOG_DIR"
    if [ -d "$BLOG_DIR" ]; then
        echo "   ✅ 存在"
        BLOG_SIZE=$(du -sh "$BLOG_DIR" 2>/dev/null | cut -f1)
        echo "   📊 大小: $BLOG_SIZE"
    else
        echo "   ❌ 不存在"
    fi
    
    echo ""
    echo "⚙️  系统环境:"
    if command -v node >/dev/null 2>&1; then
        echo "   Node.js: $(node -v)"
    else
        echo "   Node.js: ❌ 未安装"
    fi
    
    if command -v npm >/dev/null 2>&1; then
        echo "   npm: $(npm -v)"
    else
        echo "   npm: ❌ 未安装"
    fi
    
    if command -v git >/dev/null 2>&1; then
        echo "   Git: $(git --version | cut -d' ' -f3)"
    else
        echo "   Git: ❌ 未安装"
    fi
    
    echo ""
    if [ -d "$BLOG_DIR" ] && [ -f "$BLOG_DIR/package.json" ]; then
        cd "$BLOG_DIR"
        echo "📦 Hexo 信息:"
        npx hexo version 2>/dev/null | head -5 || echo "   ❌ Hexo 未正确安装"
        
        echo ""
        echo "📝 文章统计:"
        if [ -d "source/_posts" ]; then
            POST_COUNT=$(find source/_posts -name "*.md" 2>/dev/null | wc -l)
            echo "   文章数量: $POST_COUNT"
        fi
        
        echo ""
        echo "🎨 主题:"
        if [ -d "themes" ]; then
            THEMES=$(ls -1 themes 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
            echo "   已安装: $THEMES"
        fi
        
        echo ""
        echo "🔄 Git 状态:"
        if [ -d ".git" ]; then
            BRANCH=$(git branch --show-current 2>/dev/null)
            echo "   ✅ Git 仓库已初始化"
            echo "   分支: $BRANCH"
            REMOTE=$(git remote -v 2>/dev/null | head -1 | awk '{print $2}')
            if [ -n "$REMOTE" ]; then
                echo "   远程: $REMOTE"
            fi
        else
            echo "   ❌ 未初始化 Git 仓库"
        fi
    else
        echo "❌ Hexo 项目未部署"
    fi
    
    echo ""
    echo "💾 备份记录:"
    if [ -d "$BACKUP_DIR" ]; then
        BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/hexo_backup_*.tar.gz 2>/dev/null | wc -l)
        if [ "$BACKUP_COUNT" -gt 0 ]; then
            echo "   备份数量: $BACKUP_COUNT"
            LATEST_BACKUP=$(ls -t "$BACKUP_DIR"/hexo_backup_*.tar.gz 2>/dev/null | head -1)
            if [ -n "$LATEST_BACKUP" ]; then
                BACKUP_DATE=$(basename "$LATEST_BACKUP" | grep -oE '[0-9]{8}_[0-9]{6}')
                echo "   最新备份: $BACKUP_DATE"
            fi
        else
            echo "   ⚠️  暂无备份"
        fi
    else
        echo "   ⚠️  备份目录不存在"
    fi
    
    echo ""
    echo "=========================================="
}

# 插件管理
manage_plugins() {
    if [ ! -d "$BLOG_DIR" ]; then
        print_error "博客目录不存在: $BLOG_DIR"
        print_info "请先运行选项1部署 Hexo 博客"
        read -p "按 Enter 返回..."
        return 1
    fi
    
    cd "$BLOG_DIR"
    
    print_info "=========================================="
    print_info "Hexo 插件库 (25+)"
    print_info "=========================================="
    echo ""
    
    echo "SEO 优化："
    echo "1)  hexo-generator-sitemap - 标准 sitemap"
    echo "2)  hexo-generator-baidu-sitemap - 百度 sitemap"
    echo "3)  hexo-generator-seo-friendly-sitemap - SEO 友好 sitemap"
    echo "4)  hexo-autonofollow - 自动 nofollow 外链"
    echo "5)  hexo-generator-robotstxt - 生成 robots.txt"
    echo ""
    echo "订阅与分享："
    echo "6)  hexo-generator-feed - RSS/Atom 订阅"
    echo "7)  hexo-abbrlink - 永久链接生成器"
    echo "8)  hexo-generator-json-content - JSON API"
    echo ""
    echo "搜索功能："
    echo "9)  hexo-generator-search - 本地搜索"
    echo "10) hexo-generator-searchdb - 搜索数据库"
    echo "11) hexo-algolia - Algolia 搜索引擎"
    echo ""
    echo "图片与多媒体："
    echo "12) hexo-lazyload-image - 图片懒加载"
    echo "13) hexo-asset-image - 本地图片管理"
    echo "14) hexo-filter-responsive-images - 响应式图片"
    echo "15) hexo-lightgallery - 灯箱相册"
    echo "16) hexo-tag-aplayer - 音乐播放器"
    echo "17) hexo-tag-dplayer - 视频播放器"
    echo ""
    echo "功能增强："
    echo "18) hexo-wordcount - 字数统计"
    echo "19) hexo-reading-time - 阅读时间"
    echo "20) hexo-generator-index-pin-top - 文章置顶"
    echo "21) hexo-hide-posts - 隐藏文章"
    echo "22) hexo-tag-cloud - 标签云"
    echo "23) hexo-related-posts - 相关文章推荐"
    echo ""
    echo "数学与代码："
    echo "24) hexo-renderer-mathjax - MathJax 数学公式"
    echo "25) hexo-renderer-kramed - Markdown 增强"
    echo "26) hexo-prism-plugin - Prism 代码高亮"
    echo "27) hexo-renderer-markdown-it - Markdown-it 渲染器"
    echo ""
    echo "其他工具："
    echo "28) hexo-neat - 压缩 HTML/CSS/JS"
    echo "29) hexo-generator-alias - URL 别名"
    echo "30) hexo-deployer-git - Git 部署器"
    echo ""
    echo "批量操作："
    echo "88) 安装推荐插件包（SEO+搜索+图片优化）"
    echo "99) 查看已安装插件"
    echo "0)  返回主菜单"
    echo ""
    read -p "请选择 [0-30/88/99]: " plugin_choice
    
    install_single_plugin "$plugin_choice"
}

# 统一插件安装函数
install_single_plugin() {
    local choice=$1
    local plugin_name=""
    local plugin_desc=""
    
    case $choice in
        1)
            plugin_name="hexo-generator-sitemap"
            plugin_desc="标准 sitemap 生成器"
            ;;
        2)
            plugin_name="hexo-generator-baidu-sitemap"
            plugin_desc="百度 sitemap"
            ;;
        3)
            plugin_name="hexo-generator-seo-friendly-sitemap"
            plugin_desc="SEO 友好 sitemap"
            ;;
        4)
            plugin_name="hexo-autonofollow"
            plugin_desc="自动 nofollow 外链"
            ;;
        5)
            plugin_name="hexo-generator-robotstxt"
            plugin_desc="robots.txt 生成器"
            ;;
        6)
            plugin_name="hexo-generator-feed"
            plugin_desc="RSS/Atom 订阅"
            ;;
        7)
            plugin_name="hexo-abbrlink"
            plugin_desc="永久链接生成器"
            ;;
        8)
            plugin_name="hexo-generator-json-content"
            plugin_desc="JSON API 生成器"
            ;;
        9)
            plugin_name="hexo-generator-search"
            plugin_desc="本地搜索"
            ;;
        10)
            plugin_name="hexo-generator-searchdb"
            plugin_desc="搜索数据库"
            ;;
        11)
            plugin_name="hexo-algolia"
            plugin_desc="Algolia 搜索引擎"
            ;;
        12)
            plugin_name="hexo-lazyload-image"
            plugin_desc="图片懒加载"
            ;;
        13)
            plugin_name="hexo-asset-image"
            plugin_desc="本地图片管理"
            ;;
        14)
            plugin_name="hexo-filter-responsive-images"
            plugin_desc="响应式图片"
            ;;
        15)
            plugin_name="hexo-lightgallery"
            plugin_desc="灯箱相册"
            ;;
        16)
            plugin_name="hexo-tag-aplayer"
            plugin_desc="音乐播放器"
            ;;
        17)
            plugin_name="hexo-tag-dplayer"
            plugin_desc="视频播放器"
            ;;
        18)
            plugin_name="hexo-wordcount"
            plugin_desc="字数统计"
            ;;
        19)
            plugin_name="hexo-reading-time"
            plugin_desc="阅读时间估算"
            ;;
        20)
            plugin_name="hexo-generator-index-pin-top"
            plugin_desc="文章置顶"
            ;;
        21)
            plugin_name="hexo-hide-posts"
            plugin_desc="隐藏文章"
            ;;
        22)
            plugin_name="hexo-tag-cloud"
            plugin_desc="标签云"
            ;;
        23)
            plugin_name="hexo-related-posts"
            plugin_desc="相关文章推荐"
            ;;
        24)
            plugin_name="hexo-renderer-mathjax"
            plugin_desc="MathJax 数学公式"
            ;;
        25)
            plugin_name="hexo-renderer-kramed"
            plugin_desc="Markdown 增强渲染器"
            ;;
        26)
            plugin_name="hexo-prism-plugin"
            plugin_desc="Prism 代码高亮"
            ;;
        27)
            plugin_name="hexo-renderer-markdown-it"
            plugin_desc="Markdown-it 渲染器"
            ;;
        28)
            plugin_name="hexo-neat"
            plugin_desc="压缩 HTML/CSS/JS"
            ;;
        29)
            plugin_name="hexo-generator-alias"
            plugin_desc="URL 别名"
            ;;
        30)
            plugin_name="hexo-deployer-git"
            plugin_desc="Git 部署器"
            ;;
        88)
            install_recommended_plugins
            return
            ;;
        99)
            show_installed_plugins
            return
            ;;
        0)
            return
            ;;
        *)
            print_error "无效选项"
            read -p "按 Enter 返回..."
            return
            ;;
    esac
    
    if [ -n "$plugin_name" ]; then
        echo ""
        print_info "正在安装: $plugin_name"
        print_info "描述: $plugin_desc"
        echo ""
        
        npm install "$plugin_name" --save
        
        if [ $? -eq 0 ]; then
            print_success "✅ $plugin_name 安装成功！"
            echo ""
            print_info "💡 提示：某些插件需要在 _config.yml 中配置"
            print_info "   修改配置后运行: hexo clean && hexo generate"
        else
            print_error "❌ 安装失败"
        fi
        
        echo ""
        read -p "按 Enter 返回插件列表..."
        manage_plugins
    fi
}

# 安装推荐插件包
install_recommended_plugins() {
    echo ""
    print_info "=========================================="
    print_info "安装推荐插件包"
    print_info "=========================================="
    echo ""
    print_info "将安装以下插件："
    echo "  ✓ hexo-generator-sitemap - SEO sitemap"
    echo "  ✓ hexo-generator-feed - RSS 订阅"
    echo "  ✓ hexo-generator-search - 本地搜索"
    echo "  ✓ hexo-lazyload-image - 图片懒加载"
    echo "  ✓ hexo-wordcount - 字数统计"
    echo "  ✓ hexo-abbrlink - 永久链接"
    echo ""
    
    read -p "确认安装？(Y/n): " confirm
    
    if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
        print_info "开始安装..."
        npm install hexo-generator-sitemap hexo-generator-feed hexo-generator-search hexo-lazyload-image hexo-wordcount hexo-abbrlink --save
        
        if [ $? -eq 0 ]; then
            print_success "=========================================="
            print_success "推荐插件包安装完成！"
            print_success "=========================================="
            echo ""
            print_info "下一步配置："
            echo ""
            echo "1. 编辑 _config.yml 添加插件配置"
            echo "2. 运行: hexo clean && hexo generate"
            echo "3. 查看效果"
        else
            print_error "安装失败，请检查网络连接"
        fi
    else
        print_info "已取消安装"
    fi
    
    echo ""
    read -p "按 Enter 返回..."
    manage_plugins
}

# 查看已安装插件
show_installed_plugins() {
    echo ""
    print_info "已安装的 Hexo 插件："
    echo ""
    
    if [ -f "package.json" ]; then
        echo "从 package.json 读取："
        cat package.json | grep -A 50 '"dependencies"' | grep 'hexo-' | sed 's/"//g' | sed 's/,//g'
    else
        print_error "未找到 package.json"
    fi
    
    echo ""
    read -p "按 Enter 返回..."
}

# 复制主题配置文件
copy_theme_config() {
    local theme_name=$1
    local config_source=""
    local config_target="_config.${theme_name}.yml"
    
    print_info "=========================================="
    print_info "配置主题配置文件"
    print_info "=========================================="
    echo ""
    
    # 检查主题配置文件位置
    if [ -f "themes/${theme_name}/_config.yml" ]; then
        config_source="themes/${theme_name}/_config.yml"
    elif [ -d "node_modules/hexo-theme-${theme_name}" ] && [ -f "node_modules/hexo-theme-${theme_name}/_config.yml" ]; then
        config_source="node_modules/hexo-theme-${theme_name}/_config.yml"
    else
        print_warning "未找到主题配置文件，跳过配置复制"
        return 0
    fi
    
    # 检查配置文件是否已存在
    if [ -f "$config_target" ]; then
        print_warning "配置文件已存在: $config_target"
        read -p "是否覆盖现有配置？(y/N): " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            print_info "保留现有配置文件"
            echo ""
            return 0
        fi
    fi
    
    # 复制配置文件
    print_info "复制主题配置文件..."
    cp "$config_source" "$config_target"
    
    if [ -f "$config_target" ]; then
        print_success "配置文件已创建: $config_target"
        echo ""
        print_info "=========================================="
        print_info "配置文件说明"
        print_info "=========================================="
        echo ""
        echo "📝 主题配置文件位置："
        echo "   $BLOG_DIR/$config_target"
        echo ""
        echo "📝 编辑配置文件："
        echo "   nano $config_target"
        echo "   或使用 FTP/SFTP 工具下载到本地编辑"
        echo ""
        echo "📚 常见配置项："
        echo "   • 网站基本信息（标题、描述、作者）"
        echo "   • 导航菜单"
        echo "   • 侧边栏设置"
        echo "   • 社交链接"
        echo "   • 评论系统"
        echo "   • 主题颜色和样式"
        echo ""
        print_info "💡 提示：修改配置后需要重新生成："
        echo "   hexo clean && hexo generate"
        echo "   或使用脚本选项 9"
        echo ""
    else
        print_error "配置文件创建失败"
        return 1
    fi
}

# 主题管理
manage_themes() {
    if [ ! -d "$BLOG_DIR" ]; then
        print_error "博客目录不存在: $BLOG_DIR"
        print_info "请先运行选项1部署 Hexo 博客"
        read -p "按 Enter 返回..."
        return 1
    fi
    
    cd "$BLOG_DIR"
    
    print_info "=========================================="
    print_info "Hexo 主题管理"
    print_info "=========================================="
    echo ""
    
    echo "操作选项："
    echo "1) 安装热门主题"
    echo "2) 查看已安装主题"
    echo "3) 切换主题"
    echo "4) 主题配置说明"
    echo "0) 返回"
    echo ""
    read -p "请选择 [0-4]: " theme_option
    
    case $theme_option in
        1) install_popular_themes ;;
        2) show_installed_themes ;;
        3) switch_theme ;;
        4) show_theme_config_guide ;;
        0) return ;;
        *) print_error "无效选项" ;;
    esac
}

# 安装热门主题
install_popular_themes() {
    echo ""
    print_info "=========================================="
    print_info "Hexo 热门主题列表 (20+)"
    print_info "=========================================="
    echo ""
    
    echo "精选推荐："
    echo "1)  NexT - 最流行，简洁优雅"
    echo "2)  Fluid - Material Design，响应式"
    echo "3)  Butterfly - 功能丰富，美观华丽"
    echo "4)  Icarus - 三栏布局，现代化"
    echo "5)  Matery - 材质设计，色彩丰富"
    echo ""
    echo "简洁风格："
    echo "6)  Cactus - 极简风，专注内容"
    echo "7)  Apollo - 简洁现代风"
    echo "8)  Minos - 简洁三栏布局"
    echo "9)  Anzhiyu - 简洁优雅"
    echo "10) Redefine - 简洁高级感"
    echo ""
    echo "特色主题："
    echo "11) Shoka - 漫画风格"
    echo "12) Stellar - 星空主题"
    echo "13) Volantis - 多功能主题"
    echo "14) Kratos - 二次元风格"
    echo "15) Stun - 简洁大气"
    echo ""
    echo "技术博客："
    echo "16) Keep - 极简技术博客"
    echo "17) Archer - 技术风"
    echo "18) Inside - GitHub 风格"
    echo "19) Hacker - 黑客风格"
    echo "20) Terminal - 终端风格"
    echo ""
    echo "其他选择："
    echo "21) Sakura - 樱花主题"
    echo "22) Yun - 云主题"
    echo "23) Chic - 时尚主题"
    echo "0)  返回"
    echo ""
    read -p "请选择 [0-23]: " theme_choice
    
    case $theme_choice in
        1)
            print_info "安装 NexT 主题..."
            git clone https://github.com/next-theme/hexo-theme-next themes/next
            print_success "NexT 主题已安装到 themes/next"
            THEME_NAME="next"
            ;;
        2)
            print_info "安装 Fluid 主题..."
            npm install hexo-theme-fluid --save
            print_success "Fluid 主题已安装"
            THEME_NAME="fluid"
            ;;
        3)
            print_info "安装 Butterfly 主题..."
            git clone -b master https://github.com/jerryc127/hexo-theme-butterfly.git themes/butterfly
            npm install hexo-renderer-pug hexo-renderer-stylus --save
            print_success "Butterfly 主题已安装到 themes/butterfly"
            THEME_NAME="butterfly"
            ;;
        4)
            print_info "安装 Icarus 主题..."
            npm install hexo-theme-icarus --save
            print_success "Icarus 主题已安装"
            THEME_NAME="icarus"
            ;;
        5)
            print_info "安装 Matery 主题..."
            git clone https://github.com/blinkfox/hexo-theme-matery.git themes/matery
            npm install hexo-renderer-pug hexo-renderer-stylus --save
            print_success "Matery 主题已安装到 themes/matery"
            THEME_NAME="matery"
            ;;
        6)
            print_info "安装 Cactus 主题..."
            git clone https://github.com/probberechts/hexo-theme-cactus.git themes/cactus
            print_success "Cactus 主题已安装到 themes/cactus"
            THEME_NAME="cactus"
            ;;
        7)
            print_info "安装 Apollo 主题..."
            git clone https://github.com/pinggod/hexo-theme-apollo.git themes/apollo
            print_success "Apollo 主题已安装到 themes/apollo"
            THEME_NAME="apollo"
            ;;
        8)
            print_info "安装 Minos 主题..."
            git clone https://github.com/ppoffice/hexo-theme-minos.git themes/minos
            print_success "Minos 主题已安装到 themes/minos"
            THEME_NAME="minos"
            ;;
        9)
            print_info "安装 Anzhiyu 主题..."
            git clone -b main https://github.com/anzhiyu-c/hexo-theme-anzhiyu.git themes/anzhiyu
            npm install hexo-renderer-pug hexo-renderer-stylus --save
            print_success "Anzhiyu 主题已安装到 themes/anzhiyu"
            THEME_NAME="anzhiyu"
            ;;
        10)
            print_info "安装 Redefine 主题..."
            npm install hexo-theme-redefine --save
            print_success "Redefine 主题已安装"
            THEME_NAME="redefine"
            ;;
        11)
            print_info "安装 Shoka 主题..."
            git clone https://github.com/amehime/hexo-theme-shoka.git themes/shoka
            npm install hexo-renderer-multi-markdown-it --save
            print_success "Shoka 主题已安装到 themes/shoka"
            THEME_NAME="shoka"
            ;;
        12)
            print_info "安装 Stellar 主题..."
            npm install hexo-theme-stellar --save
            print_success "Stellar 主题已安装"
            THEME_NAME="stellar"
            ;;
        13)
            print_info "安装 Volantis 主题..."
            git clone https://github.com/volantis-x/hexo-theme-volantis.git themes/volantis
            print_success "Volantis 主题已安装到 themes/volantis"
            THEME_NAME="volantis"
            ;;
        14)
            print_info "安装 Kratos 主题..."
            git clone https://github.com/Candinya/Kratos-Rebirth.git themes/kratos
            print_success "Kratos 主题已安装到 themes/kratos"
            THEME_NAME="kratos"
            ;;
        15)
            print_info "安装 Stun 主题..."
            git clone https://github.com/liuyib/hexo-theme-stun.git themes/stun
            print_success "Stun 主题已安装到 themes/stun"
            THEME_NAME="stun"
            ;;
        16)
            print_info "安装 Keep 主题..."
            git clone https://github.com/XPoet/hexo-theme-keep.git themes/keep
            print_success "Keep 主题已安装到 themes/keep"
            THEME_NAME="keep"
            ;;
        17)
            print_info "安装 Archer 主题..."
            git clone https://github.com/fi3ework/hexo-theme-archer.git themes/archer
            print_success "Archer 主题已安装到 themes/archer"
            THEME_NAME="archer"
            ;;
        18)
            print_info "安装 Inside 主题..."
            git clone https://github.com/ikeq/hexo-theme-inside.git themes/inside
            print_success "Inside 主题已安装到 themes/inside"
            THEME_NAME="inside"
            ;;
        19)
            print_info "安装 Hacker 主题..."
            git clone https://github.com/CodeDaraW/Hacker.git themes/hacker
            print_success "Hacker 主题已安装到 themes/hacker"
            THEME_NAME="hacker"
            ;;
        20)
            print_info "安装 Terminal 主题..."
            git clone https://github.com/gaearon/hexo-theme-terminal.git themes/terminal
            print_success "Terminal 主题已安装到 themes/terminal"
            THEME_NAME="terminal"
            ;;
        21)
            print_info "安装 Sakura 主题..."
            git clone https://github.com/honjun/hexo-theme-sakura.git themes/sakura
            npm install hexo-renderer-sass --save
            print_success "Sakura 主题已安装到 themes/sakura"
            THEME_NAME="sakura"
            ;;
        22)
            print_info "安装 Yun 主题..."
            git clone -b main https://github.com/YunYouJun/hexo-theme-yun.git themes/yun
            print_success "Yun 主题已安装到 themes/yun"
            THEME_NAME="yun"
            ;;
        23)
            print_info "安装 Chic 主题..."
            git clone https://github.com/Siricee/hexo-theme-Chic.git themes/chic
            print_success "Chic 主题已安装到 themes/chic"
            THEME_NAME="chic"
            ;;
        0) return ;;
        *)
            print_error "无效选项"
            return
            ;;
    esac
    
    if [ -n "$THEME_NAME" ]; then
        echo ""
        
        # 自动生成主题配置文件
        copy_theme_config "$THEME_NAME"
        
        # 询问是否切换主题
        read -p "是否立即切换到 $THEME_NAME 主题？(Y/n): " switch_now
        if [[ ! "$switch_now" =~ ^[Nn]$ ]]; then
            sed -i "s/^theme:.*/theme: $THEME_NAME/" _config.yml
            print_success "主题已切换为: $THEME_NAME"
            
            read -p "是否立即重新生成？(Y/n): " regen
            if [[ ! "$regen" =~ ^[Nn]$ ]]; then
                npx hexo clean
                npx hexo generate
                print_success "网站已重新生成"
            fi
        fi
    fi
    
    read -p "按 Enter 返回..."
}

# 查看已安装主题
show_installed_themes() {
    echo ""
    print_info "已安装的主题："
    echo ""
    
    if [ -d "themes" ]; then
        ls -1 themes/ | while read theme; do
            if [ -d "themes/$theme" ]; then
                echo "  • $theme"
            fi
        done
    fi
    
    echo ""
    print_info "当前使用的主题："
    CURRENT_THEME=$(grep '^theme:' _config.yml | awk '{print $2}')
    echo "  $CURRENT_THEME"
    
    echo ""
    read -p "按 Enter 返回..."
}

# 切换主题
switch_theme() {
    echo ""
    print_info "可用主题："
    echo ""
    
    # 收集所有主题（themes 目录 + npm 安装的）
    themes_list=()
    
    # themes 目录中的主题
    if [ -d "themes" ]; then
        for theme in themes/*; do
            if [ -d "$theme" ]; then
                themes_list+=($(basename "$theme"))
            fi
        done
    fi
    
    # npm 安装的主题（在 node_modules 中）
    if [ -d "node_modules" ]; then
        [ -d "node_modules/hexo-theme-fluid" ] && themes_list+=("fluid")
        [ -d "node_modules/hexo-theme-icarus" ] && themes_list+=("icarus")
        [ -d "node_modules/hexo-theme-matery" ] && themes_list+=("matery")
        [ -d "node_modules/hexo-theme-redefine" ] && themes_list+=("redefine")
        [ -d "node_modules/hexo-theme-stellar" ] && themes_list+=("stellar")
    fi
    
    if [ ${#themes_list[@]} -eq 0 ]; then
        print_error "未找到任何主题"
        print_info "请先安装主题（选项1）"
        read -p "按 Enter 返回..."
        return 1
    fi
    
    # 显示主题列表
    for i in "${!themes_list[@]}"; do
        echo "$((i+1))) ${themes_list[$i]}"
    done
    
    echo ""
    read -p "选择要切换的主题编号: " theme_num
    
    if [[ "$theme_num" =~ ^[0-9]+$ ]] && [ "$theme_num" -ge 1 ] && [ "$theme_num" -le "${#themes_list[@]}" ]; then
        selected_theme="${themes_list[$((theme_num-1))]}"
        sed -i "s/^theme:.*/theme: $selected_theme/" _config.yml
        print_success "主题已切换为: $selected_theme"
        
        read -p "是否立即重新生成？(Y/n): " regen
        if [[ ! "$regen" =~ ^[Nn]$ ]]; then
            npx hexo clean
            npx hexo generate
            print_success "网站已重新生成"
        fi
    else
        print_error "无效的编号"
    fi
    
    echo ""
    read -p "按 Enter 返回..."
}

# 主题配置说明
show_theme_config_guide() {
    echo ""
    print_info "主题配置通常在 themes/主题名/_config.yml"
    print_info "建议复制为 _config.主题名.yml 进行修改"
    echo ""
    read -p "按 Enter 返回..."
}

# 图床配置说明
show_image_hosting_guide() {
    print_info "=========================================="
    print_info "图床配置指南"
    print_info "=========================================="
    echo ""
    
    echo "Hexo 完全支持图床！直接在 Markdown 中引用："
    echo "![图片描述](https://图床URL/image.jpg)"
    echo ""
    
    print_info "推荐图床："
    echo "1. GitHub + jsDelivr（免费）"
    echo "   https://cdn.jsdelivr.net/gh/用户名/仓库名/图片.png"
    echo "2. 阿里云 OSS（付费，快速）"
    echo "3. SM.MS（免费，https://sm.ms/）"
    echo "4. 路过图床（免费，https://imgse.com/）"
    echo ""
    
    print_info "推荐工具："
    echo "• PicGo - https://molunerfinn.com/PicGo/"
    echo "• uPic (macOS) - https://github.com/gee1k/uPic"
    echo ""
    
    read -p "按 Enter 返回主菜单..."
}

# 配置管理
manage_config() {
    echo ""
    print_info "当前配置信息"
    print_info "=========================================="
    echo "博客目录: $BLOG_DIR"
    echo "备份目录: $BACKUP_DIR"
    echo "Hexo 端口: $HEXO_PORT"
    echo "配置文件: $CONFIG_FILE"
    echo ""
    
    echo "操作选项："
    echo "1) 修改博客目录"
    echo "2) 修改备份目录"
    echo "3) 修改 Hexo 端口"
    echo "4) 重置为默认配置"
    echo "5) 删除配置文件"
    echo "0) 返回"
    echo ""
    read -p "请选择 [0-5]: " config_option
    
    case $config_option in
        1)
            read -p "请输入新的博客目录（绝对路径）: " new_blog_dir
            if [ -n "$new_blog_dir" ]; then
                BLOG_DIR="$new_blog_dir"
                save_config
                print_success "博客目录已更新为: $BLOG_DIR"
                print_warning "注意：请确保该目录存在或重新部署博客"
            fi
            ;;
        2)
            read -p "请输入新的备份目录（绝对路径）: " new_backup_dir
            if [ -n "$new_backup_dir" ]; then
                BACKUP_DIR="$new_backup_dir"
                save_config
                print_success "备份目录已更新为: $BACKUP_DIR"
            fi
            ;;
        3)
            read -p "请输入新的 Hexo 端口（1024-65535）: " new_port
            if [ -n "$new_port" ] && [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1024 ] && [ "$new_port" -le 65535 ]; then
                HEXO_PORT="$new_port"
                save_config
                print_success "Hexo 端口已更新为: $HEXO_PORT"
                print_warning "注意：需要重新启动后台服务才能生效"
            else
                print_error "无效的端口号（需要 1024-65535 之间的数字）"
            fi
            ;;
        4)
            print_warning "将重置为默认配置"
            read -p "确认重置？(y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                BLOG_DIR="$DEFAULT_BLOG_DIR"
                BACKUP_DIR="$DEFAULT_BACKUP_DIR"
                HEXO_PORT="$DEFAULT_PORT"
                save_config
                print_success "配置已重置为默认值"
            fi
            ;;
        5)
            print_warning "将删除配置文件"
            read -p "确认删除？(y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                rm -f "$CONFIG_FILE"
                print_success "配置文件已删除"
                BLOG_DIR="$DEFAULT_BLOG_DIR"
                BACKUP_DIR="$DEFAULT_BACKUP_DIR"
                HEXO_PORT="$DEFAULT_PORT"
            fi
            ;;
        0)
            return
            ;;
        *)
            print_error "无效选项"
            ;;
    esac
}

# 主程序
main() {
    check_root
    load_config
    show_banner
    
    while true; do
        # 每次循环前重新检查配置
        if [ ! -f "$CONFIG_FILE" ]; then
            BLOG_DIR="$DEFAULT_BLOG_DIR"
            BACKUP_DIR="$DEFAULT_BACKUP_DIR"
            HEXO_PORT="$DEFAULT_PORT"
        fi
        
        show_menu
        read -p "请输入选项: " choice
        
        case $choice in
            1)
                deploy_hexo
                ;;
            2)
                uninstall_hexo
                ;;
            3)
                backup_hexo
                ;;
            4)
                restore_hexo
                ;;
            5)
                sync_hexo
                ;;
            6)
                upload_local_posts
                ;;
            7)
                manage_service
                ;;
            8)
                manage_webserver
                ;;
            9)
                start_hexo_server
                ;;
            10)
                generate_static
                ;;
            p|P)
                manage_plugins
                ;;
            t|T)
                manage_themes
                ;;
            i|I)
                show_image_hosting_guide
                ;;
            a|A)
                show_status
                ;;
            c|C)
                manage_config
                ;;
            0)
                print_info "感谢使用 Hexo 管理脚本！"
                exit 0
                ;;
            *)
                print_error "无效选项，请重新选择"
                ;;
        esac
        
        echo ""
        read -p "按 Enter 继续..."
    done
}

# 运行主程序
main
