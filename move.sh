#!/bin/bash

# 定义源目录和目标目录
SOURCE_DIR="/root/backup"
TARGET_DIR="/mnt/alist/onedrive"

# 找到以 hellohao 开头的最新日期的 .sql 文件
LATEST_FILE=$(ls -t ${SOURCE_DIR}/hellohao_*.sql | head -n 1)

# 检查是否找到了文件
if [ -z "$LATEST_FILE" ]; then
    echo "没有找到以 hellohao 开头的 .sql 文件"
    exit 1
fi

# 复制最新文件到目标目录
cp "$LATEST_FILE" "$TARGET_DIR"

# 日志记录
echo "文件 $(basename $LATEST_FILE) 已复制到 $TARGET_DIR"
