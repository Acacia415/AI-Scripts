#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#=================================================
#	System Required: CentOS/Debian/Ubuntu
#	Description: AnyTLS 一键管理脚本
#	Author: Acacia415
#=================================================

# 当前脚本版本号
sh_ver="1.1.0"

# AnyTLS 相关路径
ANYTLS_Folder="${ANYTLS_FOLDER:-/etc/anytls}"
ANYTLS_File="${ANYTLS_FILE:-/usr/local/bin/anytls-server}"
ANYTLS_Conf="${ANYTLS_CONF:-${ANYTLS_Folder}/config.json}"
ANYTLS_Env="${ANYTLS_ENV:-${ANYTLS_Folder}/env}"
ANYTLS_Now_ver_File="${ANYTLS_VERSION_FILE:-${ANYTLS_Folder}/ver.txt}"
ANYTLS_Service_File="${ANYTLS_SERVICE_FILE:-/etc/systemd/system/anytls.service}"
ANYTLS_Backup_Root="${ANYTLS_BACKUP_ROOT:-/var/backups/ai-scripts/anytls}"
ANYTLS_Service_Name="${ANYTLS_SERVICE_NAME:-anytls}"
ANYTLS_LAST_BACKUP=""

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
    local machine
    machine="$(uname -m)"
    case "${machine}" in
        x86_64|amd64)
            arch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        *)
            echo -e "${Error} 当前架构 ${machine} 不受 AnyTLS 官方 Linux 发布物支持。"
            echo -e "${Tip} 目前仅支持 amd64(x86_64) 和 arm64(aarch64)。"
            return 1
            ;;
    esac
}

check_installed_status(){
	[[ ! -e ${ANYTLS_File} ]] && echo -e "${Error} AnyTLS 没有安装，请检查！" && exit 1
}

check_status(){
	if systemctl is-active --quiet "${ANYTLS_Service_Name}" 2>/dev/null; then
		status="running"
	else
		status="stopped"
	fi
}

check_new_ver(){
	local release_json
	if ! release_json="$(curl -fL --silent --show-error --retry 3 --connect-timeout 10 --max-time 60 \
		-H 'Accept: application/vnd.github+json' \
		'https://api.github.com/repos/anytls/anytls-go/releases/latest')"; then
		echo -e "${Error} AnyTLS 最新版本获取失败！"
		return 1
	fi
	new_ver="$(jq -r '.tag_name // empty' <<< "${release_json}")"
	if [[ ! "${new_ver}" =~ ^v[0-9]+([.][0-9]+){2}([.-][0-9A-Za-z.-]+)?$ ]]; then
		echo -e "${Error} AnyTLS 最新版本号无效：${new_ver:-空}"
		return 1
	fi
	echo -e "${Info} 检测到 AnyTLS 最新版本为 [ ${new_ver} ]"
}

atomic_install_file() {
	local source_file="$1" target_file="$2" mode="$3"
	local target_dir temp_file
	target_dir="$(dirname "${target_file}")"
	mkdir -p "${target_dir}" || return 1
	temp_file="$(mktemp "${target_dir}/.$(basename "${target_file}").XXXXXX")" || return 1
	if ! command install -m "${mode}" "${source_file}" "${temp_file}" || ! mv -f "${temp_file}" "${target_file}"; then
		rm -f "${temp_file}"
		return 1
	fi
}

backup_file() {
	local source_file="$1" backup_dir="$2" backup_name="$3"
	if [[ -e "${source_file}" ]]; then
		cp -a "${source_file}" "${backup_dir}/${backup_name}" || return 1
	else
		: > "${backup_dir}/${backup_name}.missing" || return 1
	fi
}

create_backup() {
	local backup_dir
	mkdir -p "${ANYTLS_Backup_Root}" || return 1
	chmod 700 "${ANYTLS_Backup_Root}" || return 1
	backup_dir="$(mktemp -d "${ANYTLS_Backup_Root}/$(date +%Y%m%d-%H%M%S).XXXXXX")" || return 1
	chmod 700 "${backup_dir}" || return 1

	if ! backup_file "${ANYTLS_File}" "${backup_dir}" binary \
		|| ! backup_file "${ANYTLS_Conf}" "${backup_dir}" config.json \
		|| ! backup_file "${ANYTLS_Env}" "${backup_dir}" env \
		|| ! backup_file "${ANYTLS_Now_ver_File}" "${backup_dir}" ver.txt \
		|| ! backup_file "${ANYTLS_Service_File}" "${backup_dir}" anytls.service; then
		rm -rf "${backup_dir}"
		return 1
	fi
	[[ -d "${ANYTLS_Folder}" ]] && : > "${backup_dir}/folder-existing"
	systemctl is-active --quiet "${ANYTLS_Service_Name}" 2>/dev/null && : > "${backup_dir}/service-active"
	systemctl is-enabled --quiet "${ANYTLS_Service_Name}" 2>/dev/null && : > "${backup_dir}/service-enabled"
	ANYTLS_LAST_BACKUP="${backup_dir}"
}

restore_file() {
	local backup_dir="$1" backup_name="$2" target_file="$3" default_mode="$4"
	if [[ -e "${backup_dir}/${backup_name}" ]]; then
		local mode
		mode="$(stat -c '%a' "${backup_dir}/${backup_name}" 2>/dev/null || printf '%s' "${default_mode}")"
		atomic_install_file "${backup_dir}/${backup_name}" "${target_file}" "${mode}"
	elif [[ -e "${backup_dir}/${backup_name}.missing" ]]; then
		rm -f "${target_file}"
	else
		echo -e "${Error} 备份 ${backup_dir} 缺少 ${backup_name} 状态记录。"
		return 1
	fi
}

restore_backup() {
	local backup_dir="$1"
	echo -e "${Tip} 正在恢复修改前的 AnyTLS 文件和服务状态……"
	systemctl stop "${ANYTLS_Service_Name}" 2>/dev/null || true
	restore_file "${backup_dir}" binary "${ANYTLS_File}" 755 || return 1
	restore_file "${backup_dir}" config.json "${ANYTLS_Conf}" 600 || return 1
	restore_file "${backup_dir}" env "${ANYTLS_Env}" 600 || return 1
	restore_file "${backup_dir}" ver.txt "${ANYTLS_Now_ver_File}" 600 || return 1
	restore_file "${backup_dir}" anytls.service "${ANYTLS_Service_File}" 644 || return 1
	systemctl daemon-reload || return 1
	if [[ -f "${backup_dir}/service-enabled" ]]; then
		systemctl enable "${ANYTLS_Service_Name}" >/dev/null 2>&1 || return 1
	else
		systemctl disable "${ANYTLS_Service_Name}" >/dev/null 2>&1 || true
	fi
	if [[ -f "${backup_dir}/service-active" ]]; then
		systemctl start "${ANYTLS_Service_Name}" || return 1
		sleep 1
		systemctl is-active --quiet "${ANYTLS_Service_Name}" || return 1
	else
		systemctl stop "${ANYTLS_Service_Name}" 2>/dev/null || true
	fi
	if [[ ! -f "${backup_dir}/folder-existing" ]]; then
		rmdir "${ANYTLS_Folder}" 2>/dev/null || true
	fi
}

stage_release() {
	local stage_dir="$1"
	local ver_num filename archive_file extract_dir staged_binary
	ver_num="${new_ver#v}"
	filename="anytls_${ver_num}_linux_${arch}.zip"
	archive_file="${stage_dir}/${filename}"
	extract_dir="${stage_dir}/extract"
	mkdir -p "${extract_dir}" || return 1

	echo -e "${Info} 开始下载 AnyTLS ${new_ver} ……"
	if ! curl -fL --silent --show-error --retry 3 --retry-delay 1 \
		--connect-timeout 10 --max-time 300 \
		-o "${archive_file}" \
		"https://github.com/anytls/anytls-go/releases/download/${new_ver}/${filename}"; then
		echo -e "${Error} AnyTLS 下载失败！"
		return 1
	fi
	if [[ ! -s "${archive_file}" ]] || ! unzip -tq "${archive_file}" >/dev/null; then
		echo -e "${Error} AnyTLS 下载包为空或 ZIP 校验失败！"
		return 1
	fi
	if ! unzip -q "${archive_file}" -d "${extract_dir}"; then
		echo -e "${Error} AnyTLS 解压失败！"
		return 1
	fi
	staged_binary="$(find "${extract_dir}" -type f -name anytls-server -print -quit)"
	if [[ -z "${staged_binary}" || ! -s "${staged_binary}" ]]; then
		echo -e "${Error} 下载包中没有有效的 anytls-server！"
		return 1
	fi
	command install -m 755 "${staged_binary}" "${stage_dir}/anytls-server" || return 1
	if [[ "$(uname -s)" == "Linux" ]] && ! "${stage_dir}/anytls-server" -h >/dev/null 2>&1; then
		echo -e "${Error} anytls-server 无法在当前系统执行，拒绝安装。"
		return 1
	fi
	printf '%s\n' "${new_ver}" > "${stage_dir}/ver.txt" || return 1
}

installation_dependency(){
	if [[ ${release} == "centos" ]]; then
		yum install jq gzip wget curl unzip -y || return 1
	else
		apt-get update || return 1
		apt-get install jq gzip wget curl unzip -y || return 1
	fi
	if [[ -e /usr/share/zoneinfo/Asia/Shanghai ]]; then
		\cp -f /usr/share/zoneinfo/Asia/Shanghai /etc/localtime || return 1
	fi
}

# ================ 配置相关函数 ================

set_port(){
	while true
		do
		echo -e "${Tip} 本步骤不涉及系统防火墙端口操作，请手动放行相应端口！"
		echo -e "请输入 AnyTLS 端口 [1-65535]"
		read -r -e -p "(默认：8443)：" port
		[[ -z "${port}" ]] && port="8443"
		if [[ "${port}" =~ ^[0-9]+$ ]] && (( ${#port} <= 5 )) && (( 10#${port} >= 1 && 10#${port} <= 65535 )); then
			port="$((10#${port}))"
			echo && echo "========================================"
			echo -e "端口：${Red_background_prefix} ${port} ${Font_color_suffix}"
			echo "========================================" && echo
			break
		else
			echo "输入错误, 请输入正确的端口。"
		fi
		done
}

set_password(){
	while true; do
		echo "请输入 AnyTLS 密码（1-128 位，仅允许数字和英文字母）"
		read -r -e -p "(默认：随机生成)：" password
		[[ -z "${password}" ]] && password="$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)"
		if [[ "${password}" =~ ^[A-Za-z0-9]{1,128}$ ]]; then
			echo && echo "========================================"
			echo -e "密码：${Red_background_prefix} ${password} ${Font_color_suffix}"
			echo "========================================" && echo
			break
		fi
		echo -e "${Error} 密码格式不正确，请勿输入空格、引号、反斜杠或换行。"
	done
}

validate_sni() {
	local value="$1" label
	local -a labels
	[[ -z "${value}" ]] && return 0
	(( ${#value} <= 253 )) || return 1
	[[ "${value}" != .* && "${value}" != *..* ]] || return 1
	value="${value%.}"
	IFS='.' read -r -a labels <<< "${value}"
	for label in "${labels[@]}"; do
		(( ${#label} >= 1 && ${#label} <= 63 )) || return 1
		[[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
	done
}

set_sni(){
	while true; do
		echo "请输入 AnyTLS SNI 域名（客户端 TLS 握手时使用的域名）"
		echo -e "${Tip} 留空则客户端默认使用服务器 IP 作为 SNI"
		read -r -e -p "(默认：留空不设置)：" sni
		sni="${sni%.}"
		if validate_sni "${sni}"; then
			if [[ -n "${sni}" ]]; then
				echo && echo "========================================"
				echo -e "SNI：${Red_background_prefix} ${sni} ${Font_color_suffix}"
				echo "========================================" && echo
			else
				echo && echo "========================================"
				echo -e "SNI：${Red_background_prefix} 未设置（使用服务器IP） ${Font_color_suffix}"
				echo "========================================" && echo
			fi
			break
		fi
		echo -e "${Error} SNI 格式不正确，请输入合法域名或留空。"
	done
}

set_skip_cert_verify(){
	echo -e "是否跳过证书验证（skip-cert-verify）？
========================================
${Green_font_prefix} 1.${Font_color_suffix} 是（跳过，默认）  ${Green_font_prefix} 2.${Font_color_suffix} 否（严格验证）
========================================"
	while true; do
		read -r -e -p "(默认：1.跳过)：" skip_cert_choice
		[[ -z "${skip_cert_choice}" ]] && skip_cert_choice="1"
		case "${skip_cert_choice}" in
			1) skip_cert_verify="true"; break ;;
			2) skip_cert_verify="false"; break ;;
			*) echo -e "${Error} 请输入 1 或 2。" ;;
		esac
	done
	echo && echo "========================================"
	echo -e "跳过证书验证：${Red_background_prefix} ${skip_cert_verify} ${Font_color_suffix}"
	echo "========================================" && echo
}

# ================ 配置文件读写 ================

validate_config_values() {
	[[ "${port}" =~ ^[0-9]+$ ]] && (( ${#port} <= 5 )) && (( 10#${port} >= 1 && 10#${port} <= 65535 )) || return 1
	[[ "${password}" =~ ^[A-Za-z0-9]{1,128}$ ]] || return 1
	validate_sni "${sni}" || return 1
	[[ "${skip_cert_verify}" == "true" || "${skip_cert_verify}" == "false" ]]
}

generate_config_file(){
	local output_file="$1"
	if ! validate_config_values; then
		echo -e "${Error} AnyTLS 配置值校验失败，拒绝写入。"
		return 1
	fi
	jq -n \
		--argjson port "$((10#${port}))" \
		--arg password "${password}" \
		--arg sni "${sni}" \
		--argjson skip_cert_verify "${skip_cert_verify}" \
		'{port: $port, password: $password, sni: $sni, skip_cert_verify: $skip_cert_verify}' \
		> "${output_file}" || return 1
	jq empty "${output_file}" >/dev/null 2>&1 || return 1
	chmod 600 "${output_file}"
}

generate_env_file(){
	local output_file="$1"
	if ! validate_config_values; then
		echo -e "${Error} AnyTLS 环境变量值校验失败，拒绝写入。"
		return 1
	fi
	printf "PORT='%s'\nPASSWORD='%s'\n" "${port}" "${password}" > "${output_file}" || return 1
	chmod 600 "${output_file}"
}

read_config(){
	if [[ ! -e "${ANYTLS_Conf}" ]] || ! jq empty "${ANYTLS_Conf}" >/dev/null 2>&1; then
		echo -e "${Error} AnyTLS 配置文件不存在或 JSON 已损坏！"
		return 1
	fi
	port="$(jq -r '.port // empty' "${ANYTLS_Conf}")"
	password="$(jq -r '.password // empty' "${ANYTLS_Conf}")"
	sni="$(jq -r '.sni // ""' "${ANYTLS_Conf}")"
	skip_cert_verify="$(jq -r '.skip_cert_verify // true' "${ANYTLS_Conf}")"
	if ! validate_config_values; then
		echo -e "${Error} AnyTLS 配置文件包含无效值，请先恢复或修正配置。"
		return 1
	fi
}

# ================ systemd 服务 ================

generate_service_file(){
	local output_file="$1"
	cat > "${output_file}"<<-EOF
[Unit]
Description=AnyTLS Server Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
LimitNOFILE=51200
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=${ANYTLS_File} -l 0.0.0.0:\${PORT} -p \${PASSWORD}
EnvironmentFile=${ANYTLS_Env}

[Install]
WantedBy=multi-user.target
EOF
	chmod 644 "${output_file}"
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

rollback_transaction() {
	local backup_dir="$1"
	if restore_backup "${backup_dir}"; then
		echo -e "${Tip} 已恢复修改前状态，备份保留在：${backup_dir}"
	else
		echo -e "${Error} 自动回滚未完全成功，请使用备份手动恢复：${backup_dir}"
	fi
}

install_staged_release() {
	local stage_dir="$1"
	mkdir -p "${ANYTLS_Folder}" || return 1
	chmod 700 "${ANYTLS_Folder}" || return 1
	atomic_install_file "${stage_dir}/anytls-server" "${ANYTLS_File}" 755 || return 1
	atomic_install_file "${stage_dir}/config.json" "${ANYTLS_Conf}" 600 || return 1
	atomic_install_file "${stage_dir}/env" "${ANYTLS_Env}" 600 || return 1
	atomic_install_file "${stage_dir}/ver.txt" "${ANYTLS_Now_ver_File}" 600 || return 1
	atomic_install_file "${stage_dir}/anytls.service" "${ANYTLS_Service_File}" 644 || return 1
	systemctl daemon-reload || return 1
	systemctl enable "${ANYTLS_Service_Name}" >/dev/null || return 1
	systemctl restart "${ANYTLS_Service_Name}" || return 1
	sleep 1
	systemctl is-active --quiet "${ANYTLS_Service_Name}"
}

install_release_transaction() {
	local stage_dir="$1" backup_dir
	if ! create_backup; then
		echo -e "${Error} 创建安装前备份失败，系统未被修改。"
		return 1
	fi
	backup_dir="${ANYTLS_LAST_BACKUP}"
	if ! install_staged_release "${stage_dir}"; then
		echo -e "${Error} AnyTLS 安装或启动失败。"
		rollback_transaction "${backup_dir}"
		return 1
	fi
	echo -e "${Info} 安装前备份：${backup_dir}"
}

apply_config_transaction() {
	local include_env="$1"
	local stage_dir backup_dir apply_ok="yes"
	stage_dir="$(mktemp -d /tmp/anytls-config.XXXXXX)" || return 1
	if ! generate_config_file "${stage_dir}/config.json"; then
		rm -rf "${stage_dir}"
		return 1
	fi
	if [[ "${include_env}" == "yes" ]] && ! generate_env_file "${stage_dir}/env"; then
		rm -rf "${stage_dir}"
		return 1
	fi
	if ! create_backup; then
		echo -e "${Error} 创建修改前备份失败，配置未更改。"
		rm -rf "${stage_dir}"
		return 1
	fi
	backup_dir="${ANYTLS_LAST_BACKUP}"

	atomic_install_file "${stage_dir}/config.json" "${ANYTLS_Conf}" 600 || apply_ok="no"
	if [[ "${apply_ok}" == "yes" && "${include_env}" == "yes" ]]; then
		atomic_install_file "${stage_dir}/env" "${ANYTLS_Env}" 600 || apply_ok="no"
	fi
	if [[ "${apply_ok}" == "yes" ]]; then
		systemctl restart "${ANYTLS_Service_Name}" || apply_ok="no"
	fi
	if [[ "${apply_ok}" == "yes" ]]; then
		sleep 1
		systemctl is-active --quiet "${ANYTLS_Service_Name}" || apply_ok="no"
	fi
	if [[ "${apply_ok}" != "yes" ]]; then
		echo -e "${Error} 新配置应用失败。"
		rollback_transaction "${backup_dir}"
		rm -rf "${stage_dir}"
		return 1
	fi
	rm -rf "${stage_dir}"
	echo -e "${Info} 配置已生效，修改前备份：${backup_dir}"
}

update_release_transaction() {
	local stage_dir
	stage_dir="$(mktemp -d /tmp/anytls-update.XXXXXX)" || return 1
	if ! stage_release "${stage_dir}"; then
		rm -rf "${stage_dir}"
		return 1
	fi
	if ! create_backup; then
		echo -e "${Error} 创建更新前备份失败，当前版本未更改。"
		rm -rf "${stage_dir}"
		return 1
	fi
	backup_dir="${ANYTLS_LAST_BACKUP}"

	if ! atomic_install_file "${stage_dir}/anytls-server" "${ANYTLS_File}" 755 \
		|| ! atomic_install_file "${stage_dir}/ver.txt" "${ANYTLS_Now_ver_File}" 600 \
		|| ! systemctl restart "${ANYTLS_Service_Name}" \
		|| { sleep 1; ! systemctl is-active --quiet "${ANYTLS_Service_Name}"; }; then
		echo -e "${Error} AnyTLS 更新或启动失败。"
		rollback_transaction "${backup_dir}"
		rm -rf "${stage_dir}"
		return 1
	fi
	rm -rf "${stage_dir}"
	echo -e "${Info} AnyTLS 已更新到 ${new_ver}，更新前备份：${backup_dir}"
}

install(){
	[[ -e ${ANYTLS_File} ]] && echo -e "${Error} 检测到 AnyTLS 已安装！" && exit 1
	echo -e "${Info} 开始设置 配置..."
	set_port
	set_password
	set_sni
	set_skip_cert_verify
	echo -e "${Info} 开始安装/配置 依赖..."
	installation_dependency || { echo -e "${Error} 依赖安装失败，已停止安装。"; return 1; }
	sys_arch || return 1
	check_new_ver || return 1

	local stage_dir backup_dir
	stage_dir="$(mktemp -d /tmp/anytls-install.XXXXXX)" || return 1
	if ! stage_release "${stage_dir}" \
		|| ! generate_config_file "${stage_dir}/config.json" \
		|| ! generate_env_file "${stage_dir}/env" \
		|| ! generate_service_file "${stage_dir}/anytls.service"; then
		echo -e "${Error} 安装文件准备或校验失败，系统未被修改。"
		rm -rf "${stage_dir}"
		return 1
	fi
	if ! install_release_transaction "${stage_dir}"; then
		rm -rf "${stage_dir}"
		return 1
	fi
	rm -rf "${stage_dir}"
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
		[[ "$status" == "running" ]] && systemctl stop "${ANYTLS_Service_Name}"
		systemctl disable "${ANYTLS_Service_Name}"
		rm -rf "${ANYTLS_Folder}"
		rm -rf "${ANYTLS_File}"
		rm -f "${ANYTLS_Service_File}"
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
		systemctl start "${ANYTLS_Service_Name}"
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
	[[ "$status" != "running" ]] && echo -e "${Error} AnyTLS 没有运行，请检查！" && return 1
	if ! systemctl stop "${ANYTLS_Service_Name}"; then
		echo -e "${Error} AnyTLS 停止失败！"
		return 1
	fi
	sleep 3s
	start_menu
}

restart(){
	check_installed_status
	if ! systemctl restart "${ANYTLS_Service_Name}"; then
		echo -e "${Error} AnyTLS 重启失败！"
		return 1
	fi
	sleep 1
	if ! systemctl is-active --quiet "${ANYTLS_Service_Name}"; then
		echo -e "${Error} AnyTLS 重启后未处于运行状态！"
		return 1
	fi
	echo -e "${Info} AnyTLS 重启完毕！"
	sleep 3s
	start_menu
}

update(){
	check_installed_status
	sys_arch || return 1
	check_new_ver || return 1
	local now_ver="未知" yn
	[[ -s "${ANYTLS_Now_ver_File}" ]] && now_ver="$(<"${ANYTLS_Now_ver_File}")"
	if [[ "${now_ver}" == "${new_ver}" ]]; then
		echo -e "${Info} 当前 AnyTLS 已是最新版本 [ ${new_ver} ]！"
		return 0
	fi
	echo -e "${Info} 发现 AnyTLS 新版本 [ ${new_ver} ]，当前版本 [ ${now_ver} ]"
	read -r -e -p "是否更新？[Y/n]：" yn
	[[ -z "${yn}" ]] && yn="y"
	if [[ ! "${yn}" =~ ^[Yy]$ ]]; then
		echo -e "${Tip} 已取消更新。"
		return 0
	fi
	update_release_transaction || return 1
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
		read_config || return 1
		set_port
		apply_config_transaction yes || return 1
	elif [[ "${modify}" == "2" ]]; then
		read_config || return 1
		set_password
		apply_config_transaction yes || return 1
	elif [[ "${modify}" == "3" ]]; then
		read_config || return 1
		set_sni
		apply_config_transaction no || return 1
	elif [[ "${modify}" == "4" ]]; then
		read_config || return 1
		set_skip_cert_verify
		apply_config_transaction no || return 1
	elif [[ "${modify}" == "5" ]]; then
		read_config || return 1
		set_port
		set_password
		set_sni
		set_skip_cert_verify
		apply_config_transaction yes || return 1
	else
		echo -e "${Error} 请输入正确的数字(1-5)" && exit 1
	fi
	sleep 3s
	start_menu
}

# ================ 查看配置 ================

view(){
	check_installed_status
	read_config || return 1
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
	
	local surge_line
	surge_line="$(uname -n) = anytls, ${surge_ip}, ${port}, password=${password}"
	if [[ -n "${sni}" && "${sni}" != "null" && "${sni}" != "" ]]; then
		surge_line="${surge_line}, sni=${sni}"
	fi
	if [[ "${skip_cert_verify}" == "true" ]]; then
		surge_line="${surge_line}, skip-cert-verify=true"
	fi
	echo -e "${surge_line}"
	
	# 如果有 IPv6 且 IPv4 也有效，额外输出 IPv6 版本
	if [[ "${ipv4}" != "IPv4_Error" && "${ipv6}" != "IPv6_Error" ]]; then
		local surge_line_v6
		surge_line_v6="$(uname -n)-v6 = anytls, ${ipv6}, ${port}, password=${password}"
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
	
	systemctl status "${ANYTLS_Service_Name}"
	
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
	if [[ "${sh_new_ver}" != "${sh_ver}" ]]; then
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
	sys_arch || exit 1
	
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
			exit 0
			;;
		*)
			echo -e "${Error} 请输入正确数字 [0-9] (退出输入00)"
			sleep 5s
			start_menu
			;;
	esac
}

# 脚本执行入口
if [[ "${ANYTLS_SOURCE_ONLY:-0}" != "1" ]]; then
	start_menu
fi
