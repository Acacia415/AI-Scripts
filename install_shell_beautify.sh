#!/bin/bash

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

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

# 执行函数
install_shell_beautify
