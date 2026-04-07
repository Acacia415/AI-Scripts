#! /bin/bash
# shellcheck disable=SC2154

Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"

shell_version="2.3.2-fixed"
ct_new_ver="3.2.4"

gost_conf_path="/etc/gost/config.yml"
raw_conf_path="/etc/gost/rawconf"

# --- 核心修复点：YAML 生成 ---
function regenerate_yaml_config() {

    local chain_definitions=""
    local has_chains=false

    echo "services:" > "$gost_conf_path"

    while IFS= read -r trans_conf || [[ -n "$trans_conf" ]]; do

        d_server=${trans_conf#*#}
        d_port=${d_server#*#}
        d_ip=${d_server%#*}

        flag_s_port=${trans_conf%%#*}
        s_port=${flag_s_port#*/}
        is_encrypt=${flag_s_port%/*}

        service_name="service_$(echo "${trans_conf}" | md5sum | head -c 8)"

        case "$is_encrypt" in

        # -----------------------------
        # WS / WSS 解密（落地）
        # -----------------------------
        decryptws|decryptwss)

cat >> "$gost_conf_path" <<EOF
- name: "${service_name}"
  addr: ":${s_port}"
  handler:
    type: relay
  listener:
    type: "${is_encrypt//decrypt/}"
    metadata:
      path: "/ws"
  forwarder:
    nodes:
    - name: target
      addr: "${d_ip}:${d_port}"
EOF
        ;;

        # -----------------------------
        # TLS 解密（落地）
        # -----------------------------
        decrypttls)

cat >> "$gost_conf_path" <<EOF
- name: "${service_name}"
  addr: ":${s_port}"
  handler:
    type: relay
  listener:
    type: tls
  forwarder:
    nodes:
    - name: target
      addr: "${d_ip}:${d_port}"
EOF
        ;;

        # -----------------------------
        # 加密中转（关键修复点）
        # -----------------------------
        encryptws|encryptwss|encrypttls)

has_chains=true

cat >> "$gost_conf_path" <<EOF
- name: "${service_name}"
  addr: ":${s_port}"
  handler:
    type: relay
    chain: "chain_${service_name}"
  listener:
    type: tcp
EOF

        # --- 构建 chain ---
        if [[ "$is_encrypt" == "encrypttls" ]]; then

chain_definitions+=$(cat <<EOF
- name: "chain_${service_name}"
  hops:
  - nodes:
    - name: "node_${service_name}"
      addr: "${d_ip}:${d_port}"
      connector:
        type: relay
      dialer:
        type: tls
EOF
)

        else

chain_definitions+=$(cat <<EOF
- name: "chain_${service_name}"
  hops:
  - nodes:
    - name: "node_${service_name}"
      addr: "${d_ip}:${d_port}"
      connector:
        type: relay
      dialer:
        type: "${is_encrypt//encrypt/}"
        metadata:
          path: "/ws"
EOF
)

        fi
        ;;

        esac

    done < "$raw_conf_path"

    if [[ "$has_chains" == true ]]; then
        echo "chains:" >> "$gost_conf_path"
        echo "$chain_definitions" >> "$gost_conf_path"
    fi
}

# -----------------------------
# 服务控制
# -----------------------------
function restart_gost() {
    systemctl restart gost
    systemctl status gost --no-pager -l
}

# -----------------------------
# 测试入口
# -----------------------------
function debug_show_yaml() {
    echo "====== 当前配置 ======"
    cat /etc/gost/config.yml
}

# -----------------------------
# 主菜单（简化版）
# -----------------------------
function main_menu() {

    echo "1. 重新生成配置"
    echo "2. 重启 gost"
    echo "3. 查看配置"
    echo "0. 退出"

    read -p "选择: " num

    case "$num" in
        1) regenerate_yaml_config ;;
        2) restart_gost ;;
        3) debug_show_yaml ;;
        0) exit ;;
    esac
}

while true; do
    main_menu
done
