#!/bin/bash

set -Eeuo pipefail

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; NC='\033[0m'

install_shell_beautify() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo -e "${RED}请使用 root 权限运行。${NC}"; return 1; }
    command -v apt-get >/dev/null 2>&1 || { echo -e "${RED}当前脚本仅支持 apt 系统。${NC}"; return 1; }
    apt-get update && apt-get install -y git zsh curl

    local timestamp backup_dir temp_installer zsh_custom spaceship_dir new_theme
    timestamp=$(date +%Y%m%d-%H%M%S)
    backup_dir="/var/backups/ai-scripts/shell-beautify/${timestamp}"
    install -d -m 700 "$backup_dir"
    [[ -f $HOME/.zshrc ]] && cp -a "$HOME/.zshrc" "$backup_dir/zshrc"
    [[ -d $HOME/.oh-my-zsh ]] && cp -a "$HOME/.oh-my-zsh" "$backup_dir/oh-my-zsh"

    if [[ ! -d $HOME/.oh-my-zsh ]]; then
        temp_installer=$(mktemp /tmp/ai-ohmyzsh.XXXXXX)
        if ! curl -fsSL --connect-timeout 10 --max-time 60 https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o "$temp_installer" \
            || ! sh -n "$temp_installer" \
            || ! sh "$temp_installer" --unattended; then
            rm -f "$temp_installer"
            echo -e "${RED}Oh My Zsh 最新安装脚本下载、校验或执行失败。${NC}"
            return 1
        fi
        rm -f "$temp_installer"
    fi

    zsh_custom=${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}
    spaceship_dir="$zsh_custom/themes/spaceship-prompt"
    new_theme=$(mktemp -d "$zsh_custom/themes/.spaceship.XXXXXX")
    if ! git clone --depth=1 https://github.com/spaceship-prompt/spaceship-prompt.git "$new_theme/repo"; then
        rm -rf -- "$new_theme"
        echo -e "${RED}主题下载失败；原主题和 .zshrc 未改动。${NC}"
        return 1
    fi
    [[ -d $spaceship_dir ]] && mv "$spaceship_dir" "$backup_dir/spaceship-prompt"
    mv "$new_theme/repo" "$spaceship_dir"
    rm -rf -- "$new_theme"
    ln -sfn "$spaceship_dir/spaceship.zsh-theme" "$zsh_custom/themes/spaceship.zsh-theme"

    [[ -f $HOME/.zshrc ]] || touch "$HOME/.zshrc"
    if grep -q '^ZSH_THEME=' "$HOME/.zshrc"; then
        sed -i 's/^ZSH_THEME=.*/ZSH_THEME="spaceship"/' "$HOME/.zshrc"
    else
        printf '\nZSH_THEME="spaceship"\n' >> "$HOME/.zshrc"
    fi
    if grep -q '^SPACESHIP_DOCKER_SYMBOL=' "$HOME/.zshrc"; then
        sed -i 's/^SPACESHIP_DOCKER_SYMBOL=.*/SPACESHIP_DOCKER_SYMBOL="D "/' "$HOME/.zshrc"
    else
        printf 'SPACESHIP_DOCKER_SYMBOL="D "\n' >> "$HOME/.zshrc"
    fi

    chsh -s "$(command -v zsh)" "$(id -un)"
    echo -e "${GREEN}安装完成。修改前备份：${backup_dir}${NC}"
    echo -e "${YELLOW}重新登录后生效。${NC}"
}

install_shell_beautify
