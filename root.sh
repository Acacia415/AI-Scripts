#!/bin/bash

# 检查是否为root用户执行脚本
if [ "$EUID" -ne 0 ]; then
  echo "请使用root权限运行此脚本！"
  exit 1
fi

# 获取用户输入的root密码
read -p "请输入root用户的新密码: " root_password
read -p "请再次输入以确认root用户密码: " root_password_confirm

# 检查两次密码是否匹配
if [ "$root_password" != "$root_password_confirm" ]; then
  echo "两次输入的密码不匹配，请重新运行脚本。"
  exit 1
fi

# 设置root用户密码
echo "root:$root_password" | chpasswd

# 修改sshd_config文件以允许root登录
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

# 确保PasswordAuthentication是yes
sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# 重启SSH服务
systemctl restart ssh

echo "root用户登录已启用，并且密码已设置。"
