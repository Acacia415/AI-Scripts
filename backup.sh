#!/bin/bash

##### 配置Begin #####
# 目标文件路径
TARGET_PATH_BITWARDEN=/root/bitwarden/bw-data
TARGET_PATH_HELLOHAO=/HellohaoData
# 备份保存路径
BACKUP_PATH=/root/backup
# 收件人邮箱
RECV_EMAIL=jingc595@gmail.com
##### 配置End #####

# 当前时间
CURRENT_TIME=$(date +%Y%m%d_%H%M%S)
# 备份文件后缀
BACKUP_FILE_SUFFIX=_backup_data.zip
# 备份后的文件名称
TAR_FILE_NAME_BITWARDEN=${CURRENT_TIME}_bitwarden${BACKUP_FILE_SUFFIX}
TAR_FILE_NAME_HELLOHAO=${CURRENT_TIME}_hellohao${BACKUP_FILE_SUFFIX}

if ! command -v zip &> /dev/null
then
    echo "zip 未安装，请先安装 zip。"
    exit
fi

[ ! -d "$BACKUP_PATH" ] && mkdir -p "$BACKUP_PATH"
FILE_GZ_BITWARDEN=${BACKUP_PATH}/${TAR_FILE_NAME_BITWARDEN}
FILE_GZ_HELLOHAO=${BACKUP_PATH}/${TAR_FILE_NAME_HELLOHAO}

# 压缩 Bitwarden 数据
zip -q -r $FILE_GZ_BITWARDEN $TARGET_PATH_BITWARDEN

# 压缩 HellohaoData 数据
zip -q -r $FILE_GZ_HELLOHAO $TARGET_PATH_HELLOHAO

EMAIL_TITLE="Bitwarden 和 HellohaoData 备份_$CURRENT_TIME"
# 发送邮件，附带两个压缩文件
echo "$EMAIL_TITLE" | mail -s "$EMAIL_TITLE" $RECV_EMAIL -A $FILE_GZ_BITWARDEN -A $FILE_GZ_HELLOHAO

# 删除 7 天以前的备份
cd $BACKUP_PATH
find $BACKUP_PATH -mtime +7 -name "*${BACKUP_FILE_SUFFIX}"  -exec rm -f {} \;

# 日志
echo -e "$EMAIL_TITLE 成功\n" >> $BACKUP_PATH/log 