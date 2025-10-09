#! /bin/bash
Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
shell_version="2.3.0" # Upgraded version and added smart check
ct_new_ver="3.2.4" # GOST v3 版本 (Updated as per user request)
gost_conf_path="/etc/gost/config.json"
raw_conf_path="/etc/gost/rawconf"
backup_path="/root/gost_backups"

# --- 辅助函数 ---
version_gt() { test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"; }

function check_root() {
  [[ $EUID != 0 ]] && echo -e "${Error} 当前非ROOT账号(或没有ROOT权限)，无法继续操作，请更换ROOT账号或使用 ${Green_background_prefix}sudo su${Font_color_suffix} 命令获取临时ROOT权限（执行后可能会提示输入当前账号的密码）。" && exit 1
}

function check_sys() {
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
  bit=$(uname -m)
  if test "$bit" != "x86_64"; then
    echo "请输入你的芯片架构，/386/armv5/armv6/armv7/armv8"
    read bit
  else
    bit="amd64"
  fi
}

function Installation_dependency() {
  if ! command -v wget >/dev/null 2>&1 || ! command -v gzip >/dev/null 2>&1; then
    if [[ ${release} == "centos" ]]; then
      yum update && yum install -y gzip wget
    else
      apt-get update && apt-get install -y gzip wget
    fi
  fi
}

# --- GOST 服务管理 ---

function check_service_exists() {
  if [[ ! -f /usr/lib/systemd/system/gost.service ]]; then
    echo -e "${Error} gost 服务文件未找到 (gost.service not found)."
    echo -e "${Info} 请先使用主菜单中的选项 [1] 来安装gost。"
    return 1
  fi
  return 0
}

function restart_gost_safely() {
    if ! check_service_exists; then
        read -n 1 -s -r -p "按任意键返回..."
        return 1
    fi
    systemctl restart gost
    if [[ $? -eq 0 ]]; then
        echo -e "${Info} gost 服务已成功重启。"
    else
        echo -e "${Error} gost 服务重启失败。请使用 'systemctl status gost' 或 'journalctl -u gost' 查看日志。"
    fi
}

function backup_config() {
  if [[ -d /etc/gost ]]; then
    echo -e "${Info} 检测到现有配置，正在备份..."
    cp -r /etc/gost "/tmp/gost_backup_$(date +%Y%m%d_%H%M%S)"
  fi
}

function restore_config() {
  latest_backup=$(ls -t /tmp/gost_backup_* 2>/dev/null | head -1)
  if [[ -n "$latest_backup" ]]; then
    echo -e "${Info} 安装失败，正在恢复原有配置..."
    rm -rf /etc/gost
    cp -r "$latest_backup" /etc/gost
    echo -e "${Info} 配置已恢复"
  fi
}

function create_service_file() {
  cat >/usr/lib/systemd/system/gost.service <<EOF
[Unit]
Description=GOST Tunnel Service
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/bin/gost -C ${gost_conf_path}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 /usr/lib/systemd/system/gost.service
}

function Install_ct() {
  # --- 新增：智能检查 ---
  if command -v gost >/dev/null 2>&1; then
    echo -e "\033[0;33mWARNING: 检测到Gost已安装: $(command -v gost) ($(gost -V))\033[0m"
    read -p "是否继续并覆盖现有版本为 v${ct_new_ver}? (y/N): " choice
    if [[ ! "$choice" =~ ^[yY]$ ]]; then
      echo "安装已取消。"
      return 1
    fi
  fi

  check_root
  backup_config
  Installation_dependency
  check_sys
  
  local download_url="https://github.com/go-gost/gost/releases/download/v${ct_new_ver}/gost_${ct_new_ver}_linux_${bit}.tar.gz"

  echo "正在从GitHub下载Gost v${ct_new_ver}..."
  wget --no-check-certificate -O "gost.tar.gz" "${download_url}" || { echo -e "${Error} gost下载失败"; restore_config; return 1; }
  tar -zxvf gost.tar.gz || { echo -e "${Error} gost解压失败"; rm -f gost.tar.gz; restore_config; return 1; }
  
  if [[ ! -f "gost" ]]; then
    echo -e "${Error} 解压文件中未找到gost程序"
    restore_config
    rm -f gost*
    return 1
  fi

  mv gost /usr/bin/gost
  chmod +x /usr/bin/gost
  rm -f gost.tar.gz

  if [[ ! -d /etc/gost ]]; then
    mkdir /etc/gost
  fi
  
  create_service_file
  
  if [[ ! -f ${gost_conf_path} ]]; then
    echo '{
  "services": []
}' > ${gost_conf_path}
  fi
  
  chmod -R 755 /etc/gost

  systemctl daemon-reload
  systemctl enable gost
  restart_gost_safely
  
  echo "------------------------------"
  if command -v gost >/dev/null 2>&1; then
    echo "gost v${ct_new_ver} 安装成功"
    rm -rf /tmp/gost_backup_*
  else
    echo "gost没有安装成功"
    restore_config
  fi
}

function checknew() {
  if ! command -v gost >/dev/null 2>&1; then
    echo -e "${Error} gost未安装，无法检查更新。"
    return
  fi
  checknew=$(gost -V 2>&1 | awk '{print $2}')
  echo "你的gost版本为:""$checknew"""
  echo -n 是否更新\(y/n\)\:
  read checknewnum
  if [[ "$checknewnum" == "y" ]] || [[ "$checknewnum" == "Y" ]]; then
    Install_ct
  else
    echo "已取消更新"
  fi
}

function Uninstall_ct() {
  systemctl stop gost
  systemctl disable gost
  rm -rf /usr/bin/gost
  rm -rf /usr/lib/systemd/system/gost.service
  rm -rf /etc/gost
  systemctl daemon-reload
  echo "gost转发服务已成功删除"
}

function Start_ct() { check_service_exists && systemctl start gost && echo "已启动"; }
function Stop_ct() { check_service_exists && systemctl stop gost && echo "已停止"; }
function Restart_ct() { regenerate_json_config && restart_gost_safely; }

# --- 配置生成核心逻辑 ---

function eachconf_retrieve() {
  d_server=${trans_conf#*#}
  d_port=${d_server#*#}
  d_ip=${d_server%#*}
  flag_s_port=${trans_conf%%#*}
  s_port=${flag_s_port#*/}
  is_encrypt=${flag_s_port%/*}
}

function regenerate_json_config() {
    local services_json_parts=()
    local chains_json_parts=()
    local has_chains=false

    if [[ -s "$raw_conf_path" ]]; then
        while IFS= read -r trans_conf || [[ -n "$trans_conf" ]]; do
            eachconf_retrieve
            service_name="service_$(echo "${is_encrypt}_${s_port}_${d_ip}_${d_port}" | md5sum | head -c 8)"
            
            # --- Build Service JSON String ---
            case "$is_encrypt" in
                nonencrypt)
                    services_json_parts+=("{\"name\":\"${service_name}_tcp\",\"addr\":\":${s_port}\",\"handler\":{\"type\":\"tcp\"},\"listener\":{\"type\":\"tcp\"},\"forwarder\":{\"nodes\":[{\"name\":\"target\",\"addr\":\"${d_ip}:${d_port}\"}]}}")
                    services_json_parts+=("{\"name\":\"${service_name}_udp\",\"addr\":\":${s_port}\",\"handler\":{\"type\":\"udp\"},\"listener\":{\"type\":\"udp\"},\"forwarder\":{\"nodes\":[{\"name\":\"target\",\"addr\":\"${d_ip}:${d_port}\"}]}}")
                    ;;
                encrypt*|peertls|peerws|peerwss)
                    services_json_parts+=("{\"name\":\"${service_name}\",\"addr\":\":${s_port}\",\"handler\":{\"type\":\"relay\",\"chain\":\"chain_${service_name}\"},\"listener\":{\"type\":\"tcp\"}}")
                    has_chains=true
                    ;;
                decrypttls|decryptwss)
                    local tls_config=""
                    if [ -f "$HOME/gost_cert/cert.pem" ] && [ -f "$HOME/gost_cert/key.pem" ]; then
                        tls_config=",\"tls\":{\"certFile\":\"/root/gost_cert/cert.pem\",\"keyFile\":\"/root/gost_cert/key.pem\"}"
                    fi
                    local listener_type=${is_encrypt//decrypt/}
                    services_json_parts+=("{\"name\":\"${service_name}\",\"addr\":\":${s_port}\",\"handler\":{\"type\":\"relay\"},\"listener\":{\"type\":\"${listener_type}\"${tls_config}},\"forwarder\":{\"nodes\":[{\"name\":\"target\",\"addr\":\"${d_ip}:${d_port}\"}]}}")
                    ;;
                decryptws)
                    services_json_parts+=("{\"name\":\"${service_name}\",\"addr\":\":${s_port}\",\"handler\":{\"type\":\"relay\"},\"listener\":{\"type\":\"ws\"},\"forwarder\":{\"nodes\":[{\"name\":\"target\",\"addr\":\"${d_ip}:${d_port}\"}]}}")
                    ;;
                ss)
                    services_json_parts+=("{\"name\":\"${service_name}\",\"addr\":\":${d_port}\",\"handler\":{\"type\":\"ss\",\"auth\":{\"password\":\"${s_port}\"},\"metadata\":{\"method\":\"${d_ip}\"}},\"listener\":{\"type\":\"tcp\"}}")
                    ;;
                socks)
                    services_json_parts+=("{\"name\":\"${service_name}\",\"addr\":\":${d_port}\",\"handler\":{\"type\":\"socks5\",\"auth\":{\"username\":\"${d_ip}\",\"password\":\"${s_port}\"}},\"listener\":{\"type\":\"tcp\"}}")
                    ;;
                http)
                    services_json_parts+=("{\"name\":\"${service_name}\",\"addr\":\":${d_port}\",\"handler\":{\"type\":\"http\",\"auth\":{\"username\":\"${d_ip}\",\"password\":\"${s_port}\"}},\"listener\":{\"type\":\"tcp\"}}")
                    ;;
                peerno)
                    local nodes_json=$(awk '{printf "%s{\"name\":\"node_%s\",\"addr\":\"%s\"}", (NR==1?"":","), $0, $0}' "/root/$d_ip.txt" | tr -d '\n' | sed 's/:/_/g')
                    services_json_parts+=("{\"name\":\"${service_name}_tcp\",\"addr\":\":${s_port}\",\"handler\":{\"type\":\"tcp\"},\"listener\":{\"type\":\"tcp\"},\"forwarder\":{\"nodes\":[${nodes_json}],\"selector\":{\"strategy\":\"${d_port}\"}}}")
                    services_json_parts+=("{\"name\":\"${service_name}_udp\",\"addr\":\":${s_port}\",\"handler\":{\"type\":\"udp\"},\"listener\":{\"type\":\"udp\"},\"forwarder\":{\"nodes\":[${nodes_json}],\"selector\":{\"strategy\":\"${d_port}\"}}}")
                    ;;
            esac

            # --- Build Chain JSON String if needed ---
            case "$is_encrypt" in
                encrypttls|encryptwss)
                    local tls_dialer_opts=""
                    if [[ ${is_cert} == [Yy] ]]; then tls_dialer_opts=",\"tls\":{\"secure\":true,\"serverName\":\"${d_ip}\"}"; fi
                    local dialer_type=${is_encrypt//encrypt/}
                    chains_json_parts+=("{\"name\":\"chain_${service_name}\",\"hops\":[{\"name\":\"hop_${service_name}\",\"nodes\":[{\"name\":\"node_${service_name}\",\"addr\":\"${d_ip}:${d_port}\",\"connector\":{\"type\":\"relay\"},\"dialer\":{\"type\":\"${dialer_type}\"${tls_dialer_opts}}}]}]}")
                    ;;
                encryptws)
                    chains_json_parts+=("{\"name\":\"chain_${service_name}\",\"hops\":[{\"name\":\"hop_${service_name}\",\"nodes\":[{\"name\":\"node_${service_name}\",\"addr\":\"${d_ip}:${d_port}\",\"connector\":{\"type\":\"relay\"},\"dialer\":{\"type\":\"ws\"}}]}]}")
                    ;;
                peertls|peerws|peerwss)
                    local dialer_type=${is_encrypt//peer/}
                    local nodes_json=$(awk -v dt="$dialer_type" '{printf "%s{\"name\":\"node_%s\",\"addr\":\"%s\",\"connector\":{\"type\":\"relay\"},\"dialer\":{\"type\":\"%s\"}}", (NR==1?"":","), $0, $0, dt}' "/root/$d_ip.txt" | tr -d '\n' | sed 's/:/_/g')
                    chains_json_parts+=("{\"name\":\"chain_${service_name}\",\"hops\":[{\"name\":\"hop_${service_name}\",\"nodes\":[${nodes_json}],\"selector\":{\"strategy\":\"${d_port}\"}}]}")
                    ;;
            esac
        done < "$raw_conf_path"
    fi

    # --- Assemble the final JSON file ---
    {
        echo "{"
        echo "  \"services\": ["
        local num_services=${#services_json_parts[@]}
        for i in "${!services_json_parts[@]}"; do
            echo -n "    ${services_json_parts[$i]}"
            if [[ $i -lt $((num_services - 1)) ]]; then
                echo ","
            else
                echo ""
            fi
        done
        echo "  ]"
        if [ "$has_chains" = true ]; then
            echo ","
            echo "  \"chains\": ["
            local num_chains=${#chains_json_parts[@]}
            for i in "${!chains_json_parts[@]}"; do
                echo -n "    ${chains_json_parts[$i]}"
                if [[ $i -lt $((num_chains - 1)) ]]; then
                    echo ","
                else
                    echo ""
                fi
            done
            echo "  ]"
        fi
        echo "}"
    } > "$gost_conf_path"
}


# --- 规则管理与菜单 ---

function show_all_conf(){
    if [[ ! -f ${raw_conf_path} ]] || [[ ! -s ${raw_conf_path} ]]; then
        echo -e "当前没有配置规则。"
    else
        echo -e "当前gost规则:"
        echo -e "--------------------------------------------------------"
        cat -n "${raw_conf_path}"
        echo -e "--------------------------------------------------------"
    fi
}

function read_protocol() {
  while true; do
    echo -e "请问您要设置哪种功能: "
    echo -e "-----------------------------------"
    echo -e "[1] tcp+udp流量转发, 不加密"
    echo -e "[2] 加密隧道流量转发 (中转机)"
    echo -e "[3] 解密隧道流量并转发 (落地机)"
    echo -e "[4] 一键安装ss/socks5/http代理"
    echo -e "[5] 进阶：多落地均衡负载"
    echo -e "-----------------------------------"
    echo -e "[00] 返回主菜单"
    echo -e "-----------------------------------"
    read -p "请选择: " numprotocol

    case "$numprotocol" in
      1) flag_a="nonencrypt"; break ;;
      2) encrypt; break ;;
      3) decrypt; break ;;
      4) proxy; break ;;
      5) enpeer; break ;;
      "00") return ;;
      *) echo "输入错误，请重新选择" ;;
    esac
  done
}

function encrypt() {
  read -p "请选择转发传输类型: [1]tls [2]ws [3]wss: " numencrypt
  case "$numencrypt" in
    1) flag_a="encrypttls";;
    2) flag_a="encryptws";;
    3) flag_a="encryptwss";;
    *) echo "type error, please try again"; exit 1;;
  esac
  if [[ "$numencrypt" == "1" ]] || [[ "$numencrypt" == "3" ]]; then
    read -e -p "落地机是否开启了自定义tls证书？[y/n]:" is_cert
  fi
}

function decrypt() {
  read -p "请选择解密传输类型: [1]tls [2]ws [3]wss: " numdecrypt
  case "$numdecrypt" in
    1) flag_a="decrypttls";;
    2) flag_a="decryptws";;
    3) flag_a="decryptwss";;
    *) echo "type error, please try again"; exit 1;;
  esac
}

function proxy() {
  read -p "请选择代理类型: [1]shadowsocks [2]socks5 [3]http: " numproxy
  case "$numproxy" in
    1) flag_a="ss";;
    2) flag_a="socks";;
    3) flag_a="http";;
    *) echo "type error, please try again"; exit 1;;
  esac
}

function enpeer() {
  read -p "请选择均衡负载传输类型: [1]不加密 [2]tls [3]ws [4]wss: " numpeer
  case "$numpeer" in
    1) flag_a="peerno";;
    2) flag_a="peertls";;
    3) flag_a="peerws";;
    4) flag_a="peerwss";;
    *) echo "type error, please try again"; exit 1;;
  esac
}

function read_s_port() {
  case "$flag_a" in
    ss) read -p "请输入ss密码: " flag_b ;;
    socks) read -p "请输入socks密码: " flag_b ;;
    http) read -p "请输入http密码: " flag_b ;;
    *) read -p "请输入本机监听端口: " flag_b ;;
  esac
}

function read_d_ip() {
  case "$flag_a" in
    ss)
      read -p "请选择ss加密方式 [1]aes-256-gcm [2]chacha20-ietf-poly1305: " ssencrypt
      if [ "$ssencrypt" == "1" ]; then flag_c="aes-256-gcm"; else flag_c="chacha20-ietf-poly1305"; fi
      ;;
    socks) read -p "请输入socks用户名: " flag_c ;;
    http) read -p "请输入http用户名: " flag_c ;;
    peer*)
      read -e -p "请输入落地列表文件名(例如: ips1): " flag_c
      local ip_list_file="/root/${flag_c}.txt"
      echo -e "请依次输入你要均衡负载的落地ip与端口, 输入 'done' 结束"
      rm -f "$ip_list_file"
      while true; do
        read -p "请输入落地IP或域名 (输入 'done' 结束): " peer_ip
        if [[ "$peer_ip" == "done" ]]; then break; fi
        read -p "请输入 ${peer_ip} 的端口: " peer_port
        echo "${peer_ip}:${peer_port}" >> "$ip_list_file"
      done
      echo -e "已在 ${ip_list_file} 创建落地列表"
      ;;
    *)
      if [[ ${is_cert} == [Yy] ]]; then echo -e "注意: 落地机开启自定义tls证书，务必填写${Red_font_prefix}域名${Font_color_suffix}"; fi
      read -p "请输入目标IP或域名: " flag_c
      ;;
  esac
}

function read_d_port() {
  case "$flag_a" in
    ss|socks|http) read -p "请输入代理服务端口: " flag_d ;;
    peer*)
      read -p "请选择均衡负载策略 [1]round(轮询) [2]random(随机) [3]fifo(顺序): " numstra
      if [ "$numstra" == "1" ]; then flag_d="round"; elif [ "$numstra" == "2" ]; then flag_d="random"; else flag_d="fifo"; fi
      ;;
    *) read -p "请输入目标端口: " flag_d ;;
  esac
}

function writerawconf() {
  echo "${flag_a}/${flag_b}#${flag_c}#${flag_d}" >> $raw_conf_path
}

function rawconf() {
  read_protocol
  if [ "$numprotocol" == "00" ]; then return; fi
  read_s_port
  read_d_ip
  read_d_port
  writerawconf
}

function show_rule_menu() {
    clear
    show_all_conf
    echo -e "--------------------------------------------------------"
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

function add_rule_menu() {
  while true; do
    echo -e "配置已生效，当前配置如下"
    show_all_conf
    echo -e "--------------------------------------------------------"
    echo -e "[1] 继续添加新的转发规则"
    echo -e "[00] 返回主菜单"
    echo -e "--------------------------------------------------------"
    read -p "请选择: " add_choice
    if [ "$add_choice" == "1" ]; then
      rawconf
      if [ "$numprotocol" != "00" ]; then
        regenerate_json_config
        restart_gost_safely
      fi
    elif [ "$add_choice" == "00" ]; then
      break
    else
      echo "输入错误，请重新选择"
    fi
  done
}

function delete_rule_menu() {
  while true; do
    clear
    show_all_conf
    if [[ ! -f $raw_conf_path ]] || [[ ! -s $raw_conf_path ]]; then
      read -n 1 -s -r -p "按任意键返回主菜单..."
      break
    fi
    echo -e "--------------------------------------------------------"
    read -p "请输入你要删除的配置编号(输入00返回主菜单)：" numdelete
    if [ "$numdelete" == "00" ]; then
      break
    elif echo "$numdelete" | grep -q '^[0-9][0-9]*$'; then
      total_lines=$(sed -n '$=' $raw_conf_path)
      if [ "$numdelete" -gt 0 ] && [ "$numdelete" -le "$total_lines" ]; then
        sed -i "${numdelete}d" $raw_conf_path
        regenerate_json_config
        restart_gost_safely
        echo -e "${Info} 配置已删除。"
      else
        echo -e "${Error} 输入的编号不在有效范围内"
          sleep 1
      fi
    else
      echo -e "${Error} 请输入正确的数字"
      sleep 1
    fi
  done
}

function update_sh() {
  ol_version=$(curl -L -s --connect-timeout 5 https://raw.githubusercontent.com/KANIKIG/Multi-EasyGost/master/gost.sh | grep "shell_version=" | head -1 | awk -F '=|"' '{print $3}' | tr -d '\r')
  if [ -n "$ol_version" ]; then
    if version_gt "$ol_version" "$shell_version"; then
      echo -e "存在新版本 (${ol_version})，是否更新 [Y/N]?"
      read -r update_confirm
      if [[ "$update_confirm" == "y" ]] || [[ "$update_confirm" == "Y" ]]; then
        wget --no-check-certificate -O "$0.tmp" https://raw.githubusercontent.com/KANIKIG/Multi-EasyGost/master/gost.sh && mv "$0.tmp" "$0" && chmod +x "$0" && echo -e "更新完成，正在重新启动脚本..." && exec bash "$0" "$@" || echo -e "${Error} 下载新版本失败。"
      fi
    fi
  fi
}

function cron_restart() {
  sed -i "/gost/d" /etc/crontab
  echo -e "gost定时重启任务: [1]配置 [2]删除"
  read -p "请选择: " numcron
  if [ "$numcron" == "1" ]; then
    echo -e "任务类型: [1]每?小时重启 [2]每日?点重启"
    read -p "请选择: " numcrontype
    read -p "请输入小时数或整点数: " cronhr
    if [ "$numcrontype" == "1" ]; then
      echo "0 */$cronhr * * * root systemctl restart gost" >>/etc/crontab
    elif [ "$numcrontype" == "2" ]; then
      echo "0 $cronhr * * * root systemctl restart gost" >>/etc/crontab
    fi
    echo -e "定时重启设置成功！"
  else
    echo -e "定时重启任务删除完成！"
  fi
}

function backup_gost() {
    echo -e "${Info} 开始备份gost配置..."
    mkdir -p ${backup_path}
    local backup_file="${backup_path}/gost_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -zcvf ${backup_file} -C /etc gost
    if [ $? -eq 0 ]; then
        echo -e "${Info} 备份成功！文件位于: ${Green_font_prefix}${backup_file}${Font_color_suffix}"
    else
        echo -e "${Error} 备份失败。"
    fi
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

function restore_gost() {
    if [ ! -d "${backup_path}" ] || [ -z "$(ls -A ${backup_path}/*.tar.gz 2>/dev/null)" ]; then
        echo -e "${Error} 未找到任何备份文件。"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return
    fi
    echo -e "可用备份文件列表:"
    select backup_file in $(ls -r ${backup_path}/*.tar.gz); do
        [ -n "${backup_file}" ] && break || echo "无效选择"
    done
    read -p "这将覆盖当前所有配置，是否继续? [y/N]: " confirm
    if [[ ! ${confirm} =~ ^[yY]$ ]]; then
        echo -e "已取消恢复操作。"; return
    fi
    tar -zxvf ${backup_file} -C /
    if [ $? -eq 0 ]; then
        echo -e "${Info} 恢复成功！正在重启gost服务..."
        restart_gost_safely
    else
        echo -e "${Error} 恢复失败。"
    fi
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

function main_menu() {
  clear
  update_sh
  echo && echo -e "gost v3 一键安装配置脚本 ${Red_font_prefix}[v${shell_version}]${Font_color_suffix}"
  echo -e "
  ${Green_font_prefix}1.${Font_color_suffix} 安装 gost v3
  ${Green_font_prefix}2.${Font_color_suffix} 更新 gost v3
  ${Green_font_prefix}3.${Font_color_suffix} 卸载 gost v3
  ————————————
  ${Green_font_prefix}4.${Font_color_suffix} 启动 gost
  ${Green_font_prefix}5.${Font_color_suffix} 停止 gost
  ${Green_font_prefix}6.${Font_color_suffix} 重启 gost
  ————————————
  ${Green_font_prefix}7.${Font_color_suffix} 新增gost转发配置
  ${Green_font_prefix}8.${Font_color_suffix} 查看现有gost配置
  ${Green_font_prefix}9.${Font_color_suffix} 删除一则gost配置
  ————————————
  ${Green_font_prefix}10.${Font_color_suffix} gost定时重启配置
  ${Green_font_prefix}11.${Font_color_suffix} 备份gost配置
  ${Green_font_prefix}12.${Font_color_suffix} 恢复gost配置
  ————————————
  ${Green_font_prefix}00.${Font_color_suffix} 退出脚本
  ————————————" && echo
  read -e -p "请输入数字 [1-12,00]: " num
  case "$num" in
    1) Install_ct ;;
    2) checknew ;;
    3) Uninstall_ct ;;
    4) Start_ct ;;
    5) Stop_ct ;;
    6) Restart_ct ;;
    7)
      rawconf
      if [ "$numprotocol" != "00" ]; then
        regenerate_json_config
        restart_gost_safely
        add_rule_menu
      fi
      ;;
    8) show_rule_menu ;;
    9) delete_rule_menu ;;
    10) cron_restart ;;
    11) backup_gost ;;
    12) restore_gost ;;
    00) exit 0 ;;
    *) echo "请输入正确数字" ;;
  esac
}

while true; do
  main_menu
done