#!/bin/bash

# ======================= 系统工具模块 =======================
# 从 tool.sh 拆分出来的独立模块

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# ======================= 开启root登录 =======================
enable_root_login() {
  # 移除文件保护属性
  lsattr /etc/passwd /etc/shadow >/dev/null 2>&1
  chattr -i /etc/passwd /etc/shadow >/dev/null 2>&1
  chattr -a /etc/passwd /etc/shadow >/dev/null 2>&1

  # 交互设置密码
  read -p "请输入自定义 root 密码: " mima
  if [[ -n $mima ]]; then
    # 修改密码和SSH配置
    echo root:$mima | chpasswd root
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
    sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/g' /etc/ssh/sshd_config
    
    # 重启SSH服务
    systemctl restart sshd
    
    echo -e "\n${GREEN}配置完成！请手动重启服务器使部分设置生效！${NC}"
    echo -e "------------------------------------------"
    echo -e "VPS 当前用户名：root"
    echo -e "VPS 当前 root 密码：$mima"
    echo -e "------------------------------------------"
    echo -e "${YELLOW}请使用以下方式登录："
    echo -e "1. 密码方式登录"
    echo -e "2. keyboard-interactive 验证方式${NC}\n"
  else
    echo -e "${RED}密码不能为空，设置失败！${NC}"
  fi
}

# ======================= 开放所有端口 =======================
open_all_ports() {
    clear
    echo -e "${RED}════════════ 安全警告 ════════════${NC}"
    echo -e "${YELLOW}此操作将：${NC}"
    echo -e "1. 清空所有防火墙规则"
    echo -e "2. 设置默认策略为全部允许"
    echo -e "3. 完全开放所有网络端口"
    echo -e "${RED}═════════════════════════════════${NC}"
    read -p "确认继续操作？[y/N] " confirm
    
    if [[ $confirm =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}正在重置防火墙规则...${NC}"
        
        # 设置默认策略
        sudo iptables -P INPUT ACCEPT
        sudo iptables -P FORWARD ACCEPT
        sudo iptables -P OUTPUT ACCEPT
        
        # 清空所有规则
        sudo iptables -F
        sudo iptables -X
        sudo iptables -Z
        
        echo -e "${GREEN}所有端口已开放！${NC}"
        echo -e "${YELLOW}当前防火墙规则：${NC}"
        sudo iptables -L -n --line-numbers
    else
        echo -e "${BLUE}已取消操作${NC}"
    fi
}

# ======================= 命令行美化 =======================
install_shell_beautify() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}正在安装命令行美化组件...${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"

    echo -e "${CYAN}[1/6] 更新软件源...${NC}"
    apt-get update > /dev/null 2>&1

    echo -e "${CYAN}[2/6] 安装依赖组件...${NC}"
    if ! command -v git &> /dev/null; then
        apt-get install -y git > /dev/null
    else
        echo -e "${GREEN} ✓ Git 已安装${NC}"
    fi

    echo -e "${CYAN}[3/6] 检查zsh...${NC}"
    if ! command -v zsh &> /dev/null; then
        echo -e "${YELLOW}未检测到zsh，正在安装...${NC}"
        apt-get install -y zsh > /dev/null
    else
        echo -e "${GREEN} ✓ Zsh 已安装${NC}"
    fi

    echo -e "${CYAN}[4/6] 配置oh-my-zsh...${NC}"
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        echo -e "首次安装oh-my-zsh..."
        sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        if [ $? -ne 0 ]; then
            echo -e "${RED}oh-my-zsh安装失败！请检查网络连接${NC}"
            return 1
        fi
    else
        echo -e "${GREEN} ✓ oh-my-zsh 已安装${NC}"
    fi

    echo -e "${CYAN}[5/6] 设置Spaceship主题并自定义...${NC}"
    ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"
    SPACESHIP_REPO="https://github.com/spaceship-prompt/spaceship-prompt.git"
    SPACESHIP_DIR="$ZSH_CUSTOM/themes/spaceship-prompt"
    SPACESHIP_SYMLINK="$ZSH_CUSTOM/themes/spaceship.zsh-theme"

    rm -rf "$SPACESHIP_DIR"
    rm -f "$SPACESHIP_SYMLINK"

    git clone --depth=1 "$SPACESHIP_REPO" "$SPACESHIP_DIR" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 主题克隆失败！请检查网络或Git配置。${NC}"
        return 1
    fi

    ln -s "$SPACESHIP_DIR/spaceship.zsh-theme" "$SPACESHIP_SYMLINK"
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 创建符号链接失败！${NC}"
        return 1
    fi
    echo -e "${GREEN} ✓ 主题文件安装完成${NC}"

    # 配置 .zshrc 文件
    sed -i 's/^ZSH_THEME=.*/ZSH_THEME="spaceship"/' ~/.zshrc

    # 自定义Docker图标
    if grep -q "^SPACESHIP_DOCKER_SYMBOL=" ~/.zshrc; then
        sed -i 's/^SPACESHIP_DOCKER_SYMBOL=.*/SPACESHIP_DOCKER_SYMBOL="D "/' ~/.zshrc
    else
        sed -i '/^ZSH_THEME="spaceship"/i SPACESHIP_DOCKER_SYMBOL="D "' ~/.zshrc
    fi

    # 自定义箭头符号
    if grep -q "^SPACESHIP_CHAR_SYMBOL=" ~/.zshrc; then
        sed -i 's/^SPACESHIP_CHAR_SYMBOL=.*/SPACESHIP_CHAR_SYMBOL="❯ "/' ~/.zshrc
    else
        sed -i '/^ZSH_THEME="spaceship"/i SPACESHIP_CHAR_SYMBOL="❯ "' ~/.zshrc
    fi
    echo -e "${GREEN} ✓ .zshrc 配置完成 (图标已自定义)${NC}"

    echo -e "${CYAN}[6/6] 设置默认shell...${NC}"
    if [ "$SHELL" != "$(which zsh)" ]; then
        chsh -s $(which zsh) >/dev/null
    fi

    echo -e "\n${GREEN}✅ 美化完成！重启终端后生效${NC}"
    read -p "$(echo -e "${YELLOW}是否立即生效主题？[${GREEN}Y${YELLOW}/n] ${NC}")" confirm
    confirm=${confirm:-Y}
    if [[ "${confirm^^}" == "Y" ]]; then
        echo -e "${GREEN}正在应用新配置...${NC}"
        exec zsh
    else
        echo -e "\n${YELLOW}可稍后手动执行：${CYAN}exec zsh ${YELLOW}生效配置${NC}"
    fi
}

# ======================= 安装Sub-Store =======================
install_substore() {
    local secret_key
    local compose_file="docker-compose.yml" # 定义 docker-compose 文件名

    # 检查 docker-compose.yml 是否存在，并尝试从中提取 secret_key
    if [ -f "$compose_file" ]; then
        extracted_key=$(sed -n 's|.*SUB_STORE_FRONTEND_BACKEND_PATH=/\([0-9a-fA-F]\{32\}\).*|\1|p' "$compose_file" | head -n 1)
        if [[ -n "$extracted_key" && ${#extracted_key} -eq 32 ]]; then
            secret_key="$extracted_key"
            echo -e "${GREEN}检测到已存在的密钥，将继续使用: ${secret_key}${NC}"
        else
            echo -e "${YELLOW}未能从现有的 ${compose_file} 中提取有效密钥，或文件格式不符。${NC}"
        fi
    fi

    # 如果 secret_key 仍然为空 (文件不存在或提取失败)，则生成一个新的密钥
    if [ -z "$secret_key" ]; then
        secret_key=$(openssl rand -hex 16)
        echo -e "${YELLOW}生成新的密钥: ${secret_key}${NC}"
    fi

    mkdir -p /root/sub-store-data

    echo -e "${YELLOW}清理旧容器和相关配置...${NC}"
    docker rm -f sub-store >/dev/null 2>&1 || true
    # 优先使用 docker compose (v2)，如果失败则尝试 docker-compose (v1)
    if docker compose -p sub-store down >/dev/null 2>&1; then
        echo -e "${CYAN}使用 'docker compose down' 清理项目。${NC}"
    elif command -v docker-compose &>/dev/null && docker-compose -p sub-store -f "$compose_file" down >/dev/null 2>&1; then
        echo -e "${CYAN}使用 'docker-compose down' 清理项目。${NC}"
    else
        echo -e "${YELLOW}未找到 docker-compose.yml 或无法执行 down 命令，可能没有旧项目需要清理。${NC}"
    fi

    echo -e "${YELLOW}创建/更新 ${compose_file} 配置文件...${NC}"
    cat <<EOF > "$compose_file"
version: '3.8' # 建议使用较新的compose版本，例如3.8
services:
  sub-store:
    image: xream/sub-store:latest
    container_name: sub-store
    restart: unless-stopped
    environment:
      - SUB_STORE_FRONTEND_BACKEND_PATH=/$secret_key
    ports:
      - "3001:3001"
    volumes:
      - /root/sub-store-data:/opt/app/data
EOF

    echo -e "${YELLOW}拉取最新镜像 (xream/sub-store:latest)...${NC}"
    # 优先使用 docker compose (v2)，如果失败则尝试 docker-compose (v1)
    local pull_cmd_success=false
    if docker compose -p sub-store pull sub-store; then
        pull_cmd_success=true
    elif command -v docker-compose &>/dev/null && docker-compose -p sub-store -f "$compose_file" pull sub-store; then
        pull_cmd_success=true
    fi

    if ! $pull_cmd_success; then
        echo -e "${RED}拉取镜像失败，请检查网络连接或镜像名称 (xream/sub-store:latest)。${NC}"
    fi

    echo -e "${YELLOW}启动容器 (项目名: sub-store)...${NC}"
    # 优先使用 docker compose (v2)，如果失败则尝试 docker-compose (v1)
    local up_cmd_success=false
    if docker compose -p sub-store up -d; then
        up_cmd_success=true
    elif command -v docker-compose &>/dev/null && docker-compose -p sub-store -f "$compose_file" up -d; then
        up_cmd_success=true
    fi

    if ! $up_cmd_success; then
        echo -e "${RED}启动容器失败。请检查 Docker 服务状态及 ${compose_file} 文件配置。${NC}"
        echo -e "${RED}可以使用 'docker logs sub-store' 查看容器日志。${NC}"
    else
        # 可以增加一个短暂的延时，给容器一些启动时间
        echo -e "${YELLOW}等待容器启动 (约5-10秒)...${NC}"
        sleep 10

        # 检查容器是否仍在运行
        if docker ps -q -f name=sub-store | grep -q .; then
            # 获取公网IP
            local public_ip=$(curl -s4 ifconfig.me 2>/dev/null || echo "YOUR_SERVER_IP")
            echo -e "\n${GREEN}Sub-Store 已启动！${NC}"
            echo -e "Sub-Store 面板访问地址: ${CYAN}http://${public_ip}:3001${NC}"
            echo -e "Sub-Store 后端API地址: ${CYAN}http://${public_ip}:3001/${secret_key}${NC}"
            echo -e "\n${YELLOW}如果服务无法访问，请检查容器日志: ${CYAN}docker logs sub-store${NC}"
            echo -e "${YELLOW}或通过本地验证服务是否监听端口: ${CYAN}curl -I http://127.0.0.1:3001${NC}"

            # 清理旧的悬空镜像
            echo -e "\n${YELLOW}清理旧的悬空镜像...${NC}"
            docker image prune -f

        else
            echo -e "\n${RED}Sub-Store 容器未能保持运行状态。${NC}"
            echo -e "${RED}请手动检查容器日志: ${CYAN}docker logs sub-store${NC}"
        fi
    fi

    local compose_cmd_v2="docker compose -p sub-store -f \"$(pwd)/${compose_file}\""
    local compose_cmd_v1="docker-compose -p sub-store -f \"$(pwd)/${compose_file}\""
    local compose_cmd_prefix=""

    # 检测使用哪个compose命令
    if docker compose version &>/dev/null; then
        compose_cmd_prefix="$compose_cmd_v2"
        echo -e "${CYAN}将使用 'docker compose' (v2) 命令进行管理。${NC}"
    elif command -v docker-compose &>/dev/null; then
        compose_cmd_prefix="$compose_cmd_v1"
        echo -e "${CYAN}将使用 'docker-compose' (v1) 命令进行管理。${NC}"
    else
        echo -e "${RED}未找到 'docker compose' 或 'docker-compose' 命令，管理命令可能无法直接使用。${NC}"
    fi

    echo -e "\n${YELLOW}常用管理命令 (如果 ${compose_file} 不在当前目录，请先 cd 到对应目录):${NC}"
    if [[ -n "$compose_cmd_prefix" ]]; then
        echo -e "启动 Sub-Store: ${CYAN}${compose_cmd_prefix} start sub-store${NC}"
        echo -e "或者: ${CYAN}${compose_cmd_prefix} up -d sub-store${NC}"
        echo -e "停止 Sub-Store: ${CYAN}${compose_cmd_prefix} stop sub-store${NC}"
        echo -e "重启 Sub-Store: ${CYAN}${compose_cmd_prefix} restart sub-store${NC}"
        echo -e "查看 Sub-Store 状态: ${CYAN}${compose_cmd_prefix} ps${NC}"
    fi
    echo -e "查看 Sub-Store 日志: ${CYAN}docker logs --tail 100 sub-store${NC}"
    echo -e "删除数据目录: ${CYAN}rm -rf /root/sub-store-data${NC}"
    echo -e "删除配置文件: ${CYAN}rm -f \"$(pwd)/${compose_file}\"${NC}"
}

# 如果直接执行此脚本
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "用法："
    echo "  开启root登录: source $0 && enable_root_login"
    echo "  开放所有端口: source $0 && open_all_ports"
    echo "  命令行美化: source $0 && install_shell_beautify"
    echo "  安装Sub-Store: source $0 && install_substore"
fi
