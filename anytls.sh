#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#=================================================
#	System Required: CentOS/Debian/Ubuntu
#	Description: AnyTLS 一键管理脚本
#	Author: 翠花
#	WebSite: https://aapls.com
#=================================================

# 当前脚本版本号
sh_ver="1.0.0"

# AnyTLS 相关路径
ANYTLS_Folder="/etc/anytls"
ANYTLS_File="/usr/local/bin/anytls-server"
ANYTLS_Conf="/etc/anytls/config.json"
ANYTLS_Now_ver_File="/etc/anytls/ver.txt"

# BBR 配置文件
BBR_Local="/etc/sysctl.d/local.conf"

Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Red_background_prefix="\033[41;37m" && Font_color_suffix="\033[0m" && Yellow_font_prefix="\033[0;33m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Yellow_font_prefix}[注意]${Font_color_suffix}"

check_root(){
	if [[ $EUID != 0 ]]; then
		echo -e "${Error} 当前非ROOT账号(或没有ROOT权限)，无法继续操作，请更换ROOT账号或使用 ${Green_background_prefix}sudo su${Font_color_suffix} 命令获取临时ROOT权限（执行后可能会提示输入当前账号的密码）。"
		exit 1
	fi
}

check_sys(){
	if [[ -f /etc/redhat-release ]]; then
		release="centos"
	elif cat /etc/issue | grep -q -E -i "debian"; then
		release="debian"
	elif cat /etc/issue | grep -q -E -i "ubuntu"; then
		release="ubuntu"
	elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
		release="centos"
	elif cat /proc/version | grep -q -E -i "debian"; then
		release="debian"
	elif cat /proc/version | grep -q -E -i "ubuntu"; then
		release="ubuntu"
	elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
		release="centos"
    fi
}

sys_arch() {
    uname=$(uname -m)
    if [[ "$uname" == "i686" ]] || [[ "$uname" == "i386" ]]; then
        arch="amd64"
    elif [[ "$uname" == *"armv7"* ]] || [[ "$uname" == "armv6l" ]]; then
        arch="arm64"
    elif [[ "$uname" == *"armv8"* ]] || [[ "$uname" == "aarch64" ]]; then
        arch="arm64"
    else
        arch="amd64"
    fi    
}

check_installed_status(){
	[[ ! -e ${ANYTLS_File} ]] && echo -e "${Error} AnyTLS 没有安装，请检查！" && exit 1
}

check_status(){
	status=$(systemctl status anytls 2>/dev/null | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
}

check_new_ver(){
	new_ver=$(wget -qO- https://api.github.com/repos/anytls/anytls-go/releases/latest | jq -r '.tag_name')
	[[ -z ${new_ver} ]] && echo -e "${Error} AnyTLS 最新版本获取失败！" && exit 1
	echo -e "${Info} 检测到 AnyTLS 最新版本为 [ ${new_ver} ]"
}

check_ver_comparison(){
	now_ver=$(cat ${ANYTLS_Now_ver_File})
	if [[ "${now_ver}" != "${new_ver}" ]]; then
		echo -e "${Info} 发现 AnyTLS 已有新版本 [ ${new_ver} ]，旧版本 [ ${now_ver} ]"
		read -e -p "是否更新 ？ [Y/n]：" yn
		[[ -z "${yn}" ]] && yn="y"
		if [[ $yn == [Yy] ]]; then
			check_status
			[[ "$status" == "running" ]] && systemctl stop anytls
			\cp "${ANYTLS_Conf}" "/tmp/anytls_config.json"
			download
			mv -f "/tmp/anytls_config.json" "${ANYTLS_Conf}"
			restart
		fi
	else
		echo -e "${Info} 当前 AnyTLS 已是最新版本 [ ${new_ver} ] ！" && exit 1
	fi
}

download() {
	if [[ ! -e "${ANYTLS_Folder}" ]]; then
		mkdir "${ANYTLS_Folder}"
	fi
	# 去掉版本号前面的 v
	local ver_num="${new_ver#v}"
	local filename="anytls_${ver_num}_linux_${arch}.zip"
	
	echo -e "${Info} 开始下载 AnyTLS ${new_ver} ……"
	wget --no-check-certificate -N "https://github.com/anytls/anytls-go/releases/download/${new_ver}/${filename}"
	if [[ ! -e "${filename}" ]]; then
		echo -e "${Error} AnyTLS 下载失败！"
		exit 1
	fi
	
	unzip -o "${filename}"
	if [[ ! -e "anytls-server" ]]; then
		echo -e "${Error} AnyTLS 解压失败！"
		rm -f "${filename}"
		exit 1
	fi
	
	chmod +x anytls-server
	mv -f anytls-server "${ANYTLS_File}"
	rm -f anytls-client 2>/dev/null
	rm -f "${filename}"
	echo "${new_ver}" > ${ANYTLS_Now_ver_File}
	echo -e "${Info} AnyTLS 主程序下载安装完毕！"
}

installation_dependency(){
	if [[ ${release} == "centos" ]]; then
		yum update
		yum install jq gzip wget curl unzip -y
	else
		apt-get update
		apt-get install jq gzip wget curl unzip -y
	fi
	\cp -f /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
}

# ================ 配置相关函数 ================

set_port(){
	while true
		do
		echo -e "${Tip} 本步骤不涉及系统防火墙端口操作，请手动放行相应端口！"
		echo -e "请输入 AnyTLS 端口 [1-65535]"
		read -e -p "(默认：8443)：" port
		[[ -z "${port}" ]] && port="8443"
		echo $((${port}+0)) &>/dev/null
		if [[ $? -eq 0 ]]; then
			if [[ ${port} -ge 1 ]] && [[ ${port} -le 65535 ]]; then
				echo && echo "========================================"
				echo -e "端口：${Red_background_prefix} ${port} ${Font_color_suffix}"
				echo "========================================" && echo
				break
			else
				echo "输入错误, 请输入正确的端口。"
			fi
		else
			echo "输入错误, 请输入正确的端口。"
		fi
		done
}

set_password(){
	echo "请输入 AnyTLS 密码 [0-9][a-z][A-Z]"
	read -e -p "(默认：随机生成)：" password
	[[ -z "${password}" ]] && password=$(< /dev/urandom tr -dc 'a-zA-Z0-9' | head -c 16)
	echo && echo "========================================"
	echo -e "密码：${Red_background_prefix} ${password} ${Font_color_suffix}"
	echo "========================================" && echo
}

set_sni(){
	echo "请输入 AnyTLS SNI 域名（客户端 TLS 握手时使用的域名）"
	echo -e "${Tip} 留空则客户端默认使用服务器 IP 作为 SNI"
	read -e -p "(默认：留空不设置)：" sni
	[[ -z "${sni}" ]] && sni=""
	if [[ -n "${sni}" ]]; then
		echo && echo "========================================"
		echo -e "SNI：${Red_background_prefix} ${sni} ${Font_color_suffix}"
		echo "========================================" && echo
	else
		echo && echo "========================================"
		echo -e "SNI：${Red_background_prefix} 未设置（使用服务器IP） ${Font_color_suffix}"
		echo "========================================" && echo
	fi
}

set_skip_cert_verify(){
	echo -e "是否跳过证书验证（skip-cert-verify）？
========================================
${Green_font_prefix} 1.${Font_color_suffix} 是（跳过，默认）  ${Green_font_prefix} 2.${Font_color_suffix} 否（严格验证）
========================================"
	read -e -p "(默认：1.跳过)：" skip_cert_choice
	[[ -z "${skip_cert_choice}" ]] && skip_cert_choice="1"
	if [[ ${skip_cert_choice} == "1" ]]; then
		skip_cert_verify="true"
	else
		skip_cert_verify="false"
	fi
	echo && echo "========================================"
	echo -e "跳过证书验证：${Red_background_prefix} ${skip_cert_verify} ${Font_color_suffix}"
	echo "========================================" && echo
}

# ================ 配置文件读写 ================

write_config(){
	cat > ${ANYTLS_Conf}<<-EOF
{
    "port": ${port},
    "password": "${password}",
    "sni": "${sni}",
    "skip_cert_verify": ${skip_cert_verify}
}
EOF
}

read_config(){
	[[ ! -e ${ANYTLS_Conf} ]] && echo -e "${Error} AnyTLS 配置文件不存在！" && exit 1
	port=$(cat ${ANYTLS_Conf} | jq -r '.port')
	password=$(cat ${ANYTLS_Conf} | jq -r '.password')
	sni=$(cat ${ANYTLS_Conf} | jq -r '.sni // ""')
	skip_cert_verify=$(cat ${ANYTLS_Conf} | jq -r '.skip_cert_verify // "true"')
}

# ================ systemd 服务 ================

service(){
	cat > /etc/systemd/system/anytls.service<<-EOF
[Unit]
Description=AnyTLS Server Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
LimitNOFILE=32767
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStartPre=/bin/sh -c 'ulimit -n 51200'
ExecStart=${ANYTLS_File} -l 0.0.0.0:\${PORT} -p \${PASSWORD}
EnvironmentFile=${ANYTLS_Folder}/env

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable anytls
	echo -e "${Info} AnyTLS 服务配置完成！"
}

write_env(){
	cat > ${ANYTLS_Folder}/env<<-EOF
PORT=${port}
PASSWORD=${password}
EOF
}

# ================ IP 获取 ================

getipv4(){
	ipv4=$(wget -qO- -4 -t1 -T2 ipinfo.io/ip)
	if [[ -z "${ipv4}" ]]; then
		ipv4=$(wget -qO- -4 -t1 -T2 api.ip.sb/ip)
		if [[ -z "${ipv4}" ]]; then
			ipv4=$(wget -qO- -4 -t1 -T2 members.3322.org/dyndns/getip)
			if [[ -z "${ipv4}" ]]; then
				ipv4="IPv4_Error"
			fi
		fi
	fi
}

getipv6(){
	ipv6=$(wget -qO- -6 -t1 -T2 ifconfig.co)
	if [[ -z "${ipv6}" ]]; then
		ipv6="IPv6_Error"
	fi
}

# ================ 安装/卸载/启停 ================

install(){
	[[ -e ${ANYTLS_File} ]] && echo -e "${Error} 检测到 AnyTLS 已安装！" && exit 1
	echo -e "${Info} 开始设置 配置..."
	set_port
	set_password
	set_sni
	set_skip_cert_verify
	echo -e "${Info} 开始安装/配置 依赖..."
	installation_dependency
	echo -e "${Info} 开始下载/安装..."
	check_new_ver
	download
	echo -e "${Info} 开始写入 配置文件..."
	write_config
	write_env
	echo -e "${Info} 开始安装系统服务脚本..."
	service
	echo -e "${Info} 所有步骤 安装完毕，开始启动..."
	start
	echo -e "${Info} AnyTLS 安装完成！"
	view
}

uninstall(){
	check_installed_status
	echo "确定要卸载 AnyTLS ? (y/N)"
	echo
	read -e -p "(默认：n)：" unyn
	[[ -z ${unyn} ]] && unyn="n"
	if [[ ${unyn} == [Yy] ]]; then
		check_status
		[[ "$status" == "running" ]] && systemctl stop anytls
		systemctl disable anytls
		rm -rf "${ANYTLS_Folder}"
		rm -rf "${ANYTLS_File}"
		rm -f "/etc/systemd/system/anytls.service"
		systemctl daemon-reload
		echo && echo "AnyTLS 卸载完成！" && echo
	else
		echo && echo "卸载已取消..." && echo
	fi
	sleep 3s
	start_menu
}

start(){
	check_installed_status
	check_status
	if [[ "$status" == "running" ]]; then
		echo -e "${Info} AnyTLS 已在运行！"
	else
		systemctl start anytls
		check_status
		if [[ "$status" == "running" ]]; then
			echo -e "${Info} AnyTLS 启动成功！"
		else
			echo -e "${Error} AnyTLS 启动失败！"
			exit 1
		fi
	fi
	sleep 3s
}

stop(){
	check_installed_status
	check_status
	[[ !"$status" == "running" ]] && echo -e "${Error} AnyTLS 没有运行，请检查！" && exit 1
	systemctl stop anytls
	sleep 3s
	start_menu
}

restart(){
	check_installed_status
	systemctl restart anytls
	echo -e "${Info} AnyTLS 重启完毕！"
	sleep 3s
	start_menu
}

update(){
	check_installed_status
	check_new_ver
	check_ver_comparison
	echo -e "${Info} AnyTLS 更新完毕！"
	sleep 3s
	start_menu
}

# ================ 配置修改 ================

set_config(){
	check_installed_status
	echo && echo -e "你要做什么？
========================================
 ${Green_font_prefix}1.${Font_color_suffix}  修改 端口配置
 ${Green_font_prefix}2.${Font_color_suffix}  修改 密码配置
 ${Green_font_prefix}3.${Font_color_suffix}  修改 SNI 配置
 ${Green_font_prefix}4.${Font_color_suffix}  修改 证书验证配置
========================================
 ${Green_font_prefix}5.${Font_color_suffix}  修改 全部配置" && echo
	read -e -p "(默认：取消)：" modify
	[[ -z "${modify}" ]] && echo "已取消..." && exit 1
	if [[ "${modify}" == "1" ]]; then
		read_config
		set_port
		write_config
		write_env
		restart
	elif [[ "${modify}" == "2" ]]; then
		read_config
		set_password
		write_config
		write_env
		restart
	elif [[ "${modify}" == "3" ]]; then
		read_config
		set_sni
		write_config
		restart
	elif [[ "${modify}" == "4" ]]; then
		read_config
		set_skip_cert_verify
		write_config
		restart
	elif [[ "${modify}" == "5" ]]; then
		read_config
		set_port
		set_password
		set_sni
		set_skip_cert_verify
		write_config
		write_env
		restart
	else
		echo -e "${Error} 请输入正确的数字(1-5)" && exit 1
	fi
}

# ================ 查看配置 ================

view(){
	check_installed_status
	read_config
	getipv4
	getipv6
	clear && echo
	echo -e "AnyTLS 配置信息："
	echo -e "————————————————————————————————————————"
	[[ "${ipv4}" != "IPv4_Error" ]] && echo -e " 地址：${Green_font_prefix}${ipv4}${Font_color_suffix}"
	[[ "${ipv6}" != "IPv6_Error" ]] && echo -e " 地址：${Green_font_prefix}[${ipv6}]${Font_color_suffix}"
	echo -e " 端口：${Green_font_prefix}${port}${Font_color_suffix}"
	echo -e " 密码：${Green_font_prefix}${password}${Font_color_suffix}"
	if [[ -n "${sni}" && "${sni}" != "null" && "${sni}" != "" ]]; then
		echo -e " SNI ：${Green_font_prefix}${sni}${Font_color_suffix}"
	else
		echo -e " SNI ：${Yellow_font_prefix}未设置${Font_color_suffix}"
	fi
	echo -e " 跳过证书验证：${Green_font_prefix}${skip_cert_verify}${Font_color_suffix}"
	echo -e "————————————————————————————————————————"
	
	# 构建 Surge 配置
	echo -e ""
	echo -e "${Info} Surge 配置："
	echo -e "—————————————————————————"
	local surge_ip=""
	if [[ "${ipv4}" != "IPv4_Error" ]]; then
		surge_ip="${ipv4}"
	else
		surge_ip="${ipv6}"
	fi
	
	local surge_line="$(uname -n) = anytls, ${surge_ip}, ${port}, password=${password}"
	if [[ -n "${sni}" && "${sni}" != "null" && "${sni}" != "" ]]; then
		surge_line="${surge_line}, sni=${sni}"
	fi
	if [[ "${skip_cert_verify}" == "true" ]]; then
		surge_line="${surge_line}, skip-cert-verify=true"
	fi
	echo -e "${surge_line}"
	
	# 如果有 IPv6 且 IPv4 也有效，额外输出 IPv6 版本
	if [[ "${ipv4}" != "IPv4_Error" && "${ipv6}" != "IPv6_Error" ]]; then
		local surge_line_v6="$(uname -n)-v6 = anytls, ${ipv6}, ${port}, password=${password}"
		if [[ -n "${sni}" && "${sni}" != "null" && "${sni}" != "" ]]; then
			surge_line_v6="${surge_line_v6}, sni=${sni}"
		fi
		if [[ "${skip_cert_verify}" == "true" ]]; then
			surge_line_v6="${surge_line_v6}, skip-cert-verify=true"
		fi
		echo -e "${surge_line_v6}"
	fi
	
	# 构建 mihomo 单行 JSON 配置
	echo -e ""
	echo -e "${Info} mihomo (Clash Meta) JSON 配置："
	echo -e "—————————————————————————"
	
	local mihomo_sni_field=""
	if [[ -n "${sni}" && "${sni}" != "null" && "${sni}" != "" ]]; then
		mihomo_sni_field=", \"sni\": \"${sni}\""
	fi
	
	local mihomo_skip=""
	if [[ "${skip_cert_verify}" == "true" ]]; then
		mihomo_skip=", \"skip-cert-verify\": true"
	fi
	
	if [[ "${ipv4}" != "IPv4_Error" ]]; then
		echo -e "{\"name\": \"$(uname -n)\", \"type\": \"anytls\", \"server\": \"${ipv4}\", \"port\": ${port}, \"password\": \"${password}\", \"udp\": true, \"client-fingerprint\": \"chrome\"${mihomo_sni_field}${mihomo_skip}}"
	fi
	if [[ "${ipv6}" != "IPv6_Error" ]]; then
		echo -e "{\"name\": \"$(uname -n)-v6\", \"type\": \"anytls\", \"server\": \"${ipv6}\", \"port\": ${port}, \"password\": \"${password}\", \"udp\": true, \"client-fingerprint\": \"chrome\"${mihomo_sni_field}${mihomo_skip}}"
	fi
	
	echo -e ""
	echo -e "========================================"
	echo && echo -n " 按回车键返回主菜单..." && read
	start_menu
}

# ================ 查看状态 ================

view_status(){
	check_installed_status
	
	echo -e "${Info} 正在获取 AnyTLS 状态信息..."
	echo
	echo "=================================="
	echo -e " AnyTLS 服务状态"
	echo "=================================="
	
	systemctl status anytls
	
	echo "=================================="
	echo
	read -e -p "按回车键返回主菜单..." 
	start_menu
}

# ================ 脚本更新 ================

update_sh(){
	echo -e "当前版本为 [ ${sh_ver} ]，开始检测最新版本..."
	sh_new_ver=$(wget --no-check-certificate -qO- "https://raw.githubusercontent.com/xOS/Scripts/master/anytls.sh" | grep 'sh_ver="' | awk -F "=" '{print $NF}' | sed 's/\"//g' | head -1)
	[[ -z ${sh_new_ver} ]] && echo -e "${Error} 检测最新版本失败 !" && start_menu
	if [[ ${sh_new_ver} != ${sh_ver} ]]; then
		echo -e "发现新版本[ ${sh_new_ver} ]，是否更新？[Y/n]"
		read -p "(默认：y)：" yn
		[[ -z "${yn}" ]] && yn="y"
		if [[ ${yn} == [Yy] ]]; then
			wget -O anytls.sh --no-check-certificate https://raw.githubusercontent.com/xOS/Scripts/master/anytls.sh && chmod +x anytls.sh
			echo -e "脚本已更新为最新版本[ ${sh_new_ver} ]！"
			echo -e "3s后执行新脚本"
			sleep 3s
			bash anytls.sh
		else
			echo && echo "	已取消..." && echo
			sleep 3s
			start_menu
		fi
	else
		echo -e "当前已是最新版本[ ${sh_new_ver} ] ！"
		sleep 3s
		start_menu
	fi
	sleep 3s
	bash anytls.sh
}

# ================ 主菜单 ================

start_menu(){
	check_root
	check_sys
	sys_arch
	
	# 检查安装状态
	if [[ -e ${ANYTLS_File} ]]; then
		check_status
		if [[ "$status" == "running" ]]; then
			anytls_status_show="${Green_font_prefix}已安装${Font_color_suffix} 且 ${Green_font_prefix}运行中${Font_color_suffix}"
		else
			anytls_status_show="${Green_font_prefix}已安装${Font_color_suffix} 但 ${Yellow_font_prefix}未运行${Font_color_suffix}"
		fi
	else
		anytls_status_show="${Red_font_prefix}未安装${Font_color_suffix}"
	fi
	
	clear
	echo -e "AnyTLS 一键管理脚本 ${Red_font_prefix}[v${sh_ver}]${Font_color_suffix}
  
==================状态==================
 AnyTLS  : [${anytls_status_show}]
========================================
 ${Green_font_prefix}0.${Font_color_suffix}  更新脚本
==================菜单==================
 ${Green_font_prefix}1.${Font_color_suffix}  安装 AnyTLS
 ${Green_font_prefix}2.${Font_color_suffix}  更新 AnyTLS
 ${Green_font_prefix}3.${Font_color_suffix}  卸载 AnyTLS
————————————————————————————————————————
 ${Green_font_prefix}4.${Font_color_suffix}  启动 AnyTLS
 ${Green_font_prefix}5.${Font_color_suffix}  停止 AnyTLS
 ${Green_font_prefix}6.${Font_color_suffix}  重启 AnyTLS
————————————————————————————————————————
 ${Green_font_prefix}7.${Font_color_suffix}  修改 AnyTLS 配置
 ${Green_font_prefix}8.${Font_color_suffix}  查看 AnyTLS 配置
 ${Green_font_prefix}9.${Font_color_suffix}  查看 AnyTLS 状态
————————————————————————————————————————
 ${Green_font_prefix}00.${Font_color_suffix} 退出脚本
========================================" && echo
	read -e -p " 请输入数字 [0-9]：" num
	case "$num" in
		1)
			install
			;;
		2)
			update
			;;
		3)
			uninstall
			;;
		4)
			start
			start_menu
			;;
		5)
			stop
			;;
		6)
			restart
			;;
		7)
			set_config
			;;
		8)
			view
			;;
		9)
			view_status
			;;
		0)
			update_sh
			;;
		00)
			exit 1
			;;
		*)
			echo -e "${Error} 请输入正确数字 [0-9] (退出输入00)"
			sleep 5s
			start_menu
			;;
	esac
}

# 脚本执行入口
start_menu
