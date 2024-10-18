#!/bin/bash

readp() { read -p "$1" $2; }

[[ $EUID -ne 0 ]] && echo "请输入 sudo -i 回车，进入 root 模式再运行脚本" && exit
lsattr /etc/passwd /etc/shadow >/dev/null 2>&1
chattr -i /etc/passwd /etc/shadow >/dev/null 2>&1
chattr -a /etc/passwd /etc/shadow >/dev/null 2>&1
lsattr /etc/passwd /etc/shadow >/dev/null 2>&1
readp "自定义 root 密码: " mima
if [[ -n $mima ]]; then
    echo root:$mima | sudo chpasswd root
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
    sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/g' /etc/ssh/sshd_config
    service sshd restart
    echo "VPS 当前用户名：root"
    echo "VPS 当前 root 密码：$mima"
    echo "请以 password 密码方式或者 keyboard 输入密码方式，进行 SSH 的 root 登录"
else
    echo "未输入相关字符，启用 root 账户或 root 密码更改失败"
fi
rm -rf root.sh

