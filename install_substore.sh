#!/bin/bash

set -Eeuo pipefail

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; NC='\033[0m'
INSTALL_DIR=/opt/sub-store
DEFAULT_DATA_DIR=/var/lib/sub-store
DEFAULT_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
LEGACY_COMPOSE_FILE=/root/docker-compose.yml
BACKUP_DIR=/var/backups/ai-scripts/sub-store
ROLLBACK_IMAGE_KEEP=3
DEFAULT_CORS_ALLOWED_ORIGINS='https://sub-store.vercel.app,http://substore.stash,https://substore.stash'
COMPOSE_FILE="$DEFAULT_COMPOSE_FILE"
DATA_DIR="$DEFAULT_DATA_DIR"

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose -p sub-store -f "$COMPOSE_FILE" "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose -p sub-store -f "$COMPOSE_FILE" "$@"
    else
        return 127
    fi
}

install_docker() {
    command -v docker >/dev/null 2>&1 && return 0

    if [[ -f /etc/debian_version ]]; then
        local temp
        temp=$(mktemp /tmp/ai-docker-install.XXXXXX)
        if ! curl -fsSL --connect-timeout 10 --max-time 120 https://get.docker.com -o "$temp"; then
            rm -f -- "$temp"
            return 1
        fi
        if ! sh -n "$temp"; then
            rm -f -- "$temp"
            echo -e "${RED}Docker 最新安装脚本语法检查失败。${NC}"
            return 1
        fi
        sh "$temp"
        rm -f -- "$temp"
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y yum-utils
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        echo -e "${RED}无法识别系统，请手动安装 Docker。${NC}"
        return 1
    fi

    systemctl enable --now docker
}

compose_config() {
    local file=$1
    if docker compose version >/dev/null 2>&1; then
        docker compose -p sub-store -f "$file" config
    else
        docker-compose -p sub-store -f "$file" config
    fi
}

compose_environment_value() {
    local file=$1 key=$2 config value
    [[ -f $file ]] || return 1
    # 由 Compose 处理列表/映射、引号、env_file 和变量插值，再读取规范化的单个服务。
    config=$(compose_config "$file") || return 1
    value=$(awk -v key="$key" '
        /^  sub-store:$/ { service=1; next }
        /^  [^ ]/ { service=0 }
        service && /^    environment:$/ { env=1; next }
        /^    [^ ]/ { env=0 }
        service && env && $1 == key ":" {
            sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")
            print; found=1; exit
        }
        END { if (!found) exit 1 }
    ' <<< "$config") || return 1
    case "$value" in
        \"*\") value=${value:1:${#value}-2} ;;
        \'*\') value=${value:1:${#value}-2} ;;
    esac
    printf '%s\n' "$value"
}

compose_backend_path() {
    compose_environment_value "$1" SUB_STORE_FRONTEND_BACKEND_PATH
}

compose_cors_origins() {
    compose_environment_value "$1" SUB_STORE_CORS_ALLOWED_ORIGINS
}

preferred_cors_origins() {
    local file=$1 runtime_value=$2 configured_value
    if [[ -n $file ]] && configured_value=$(compose_cors_origins "$file"); then
        # Compose 中显式设置为空也应被保留，以便重新询问，而不是还原旧容器的值。
        printf '%s\n' "$configured_value"
    else
        printf '%s\n' "$runtime_value"
    fi
}

compose_data_dir() {
    local file=$1
    [[ -f $file ]] || return 1
    sed -n -E 's|^[[:space:]]*-[[:space:]]*"?([^"[:space:]]+):/opt/app/data"?[[:space:]]*$|\1|p' "$file" | head -n1
}

compose_port_value() {
    local file=$1 line
    [[ -f $file ]] || return 1
    line=$(grep -E ':[[:space:]]*3001|:3001' "$file" | head -n1 || true)
    [[ -n $line ]] || return 1
    printf '%s\n' "$line" | sed -E 's|^[[:space:]]*-[[:space:]]*"?||; s|"?[[:space:]]*(#.*)?$||'
}

compose_bind_address() {
    local file=$1 value
    value=$(compose_port_value "$file" 2>/dev/null || true)
    [[ -n $value ]] || return 1
    case "$value" in
        127.0.0.1:*) printf '%s\n' '127.0.0.1' ;;
        0.0.0.0:*) printf '%s\n' '0.0.0.0' ;;
        *) printf '%s\n' '0.0.0.0' ;;
    esac
}

compose_host_port() {
    local file=$1 value host_port
    value=$(compose_port_value "$file" 2>/dev/null || true)
    [[ -n $value ]] || return 1

    case "$value" in
        127.0.0.1:*:3001)
            host_port=${value#127.0.0.1:}
            host_port=${host_port%:3001}
            ;;
        0.0.0.0:*:3001)
            host_port=${value#0.0.0.0:}
            host_port=${host_port%:3001}
            ;;
        *:3001)
            host_port=${value%:3001}
            ;;
        *) return 1 ;;
    esac

    [[ $host_port =~ ^[0-9]{1,5}$ ]] || return 1
    printf '%s\n' "$host_port"
}

compose_matches_runtime() {
    local file=$1 expected_path=$2 expected_data=$3
    local file_path='' file_data=''
    [[ -f $file ]] || return 1
    file_path=$(compose_backend_path "$file" 2>/dev/null || true)
    file_data=$(compose_data_dir "$file" 2>/dev/null || true)
    [[ -n $file_path && -n $file_data && $file_path == "$expected_path" && $file_data == "$expected_data" ]]
}

safe_data_dir() {
    local dir=$1
    [[ -n $dir && $dir == /* && $dir != / && $dir != /root && $dir != /var && $dir != /opt ]]
}

valid_backend_path() {
    [[ $1 =~ ^/[A-Za-z0-9._~%/-]*$ && $1 != *'//'* ]]
}

normalize_origin() {
    local origin=${1%/} scheme host port label address compressed=false
    local -a labels=()
    local pattern='^(https?)://(\[[0-9a-fA-F:]+\]|[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?)(:([0-9]{1,5}))?$'
    [[ $origin =~ $pattern ]] || return 1
    scheme=${BASH_REMATCH[1]}
    host=${BASH_REMATCH[2],,}
    port=${BASH_REMATCH[5]}
    if [[ $host == \[* ]]; then
        address=${host:1:${#host}-2}
        [[ $address == *:* && $address != *:::* ]] || return 1
        if [[ $address == *::* ]]; then
            compressed=true
            [[ ${address#*::} != *::* ]] || return 1
            address=${address/::/:}
            address=${address#:}
            address=${address%:}
        else
            [[ $address != :* && $address != *: ]] || return 1
        fi
        IFS=':' read -r -a labels <<< "$address"
        if $compressed; then
            ((${#labels[@]} < 8)) || return 1
        else
            ((${#labels[@]} == 8)) || return 1
        fi
        for label in "${labels[@]}"; do
            [[ $label =~ ^[0-9a-f]{1,4}$ ]] || return 1
        done
    else
        [[ $host != *'..'* && ${#host} -le 253 ]] || return 1
        IFS='.' read -r -a labels <<< "$host"
        for label in "${labels[@]}"; do
            [[ ${#label} -le 63 && $label != -* && $label != *- ]] || return 1
        done
        if [[ $host =~ ^[0-9.]+$ ]]; then
            ((${#labels[@]} == 4)) || return 1
            for label in "${labels[@]}"; do
                [[ $label == 0 || $label =~ ^[1-9][0-9]{0,2}$ ]] || return 1
                ((10#$label <= 255)) || return 1
            done
        fi
    fi
    if [[ -n $port ]]; then
        ((10#$port >= 1 && 10#$port <= 65535)) || return 1
        port=$((10#$port))
        if [[ $scheme == http && $port == 80 || $scheme == https && $port == 443 ]]; then
            port=''
        fi
    fi
    printf '%s://%s%s\n' "$scheme" "$host" "${port:+:$port}"
}

normalize_cors_origins() {
    local value=$1 origin normalized result='' wildcard=false
    local -a origins=()
    value=${value//，/,}
    value=${value//[[:space:]]/,}
    IFS=',' read -r -a origins <<< "$value"
    for origin in "${origins[@]}"; do
        origin=${origin#"${origin%%[![:space:]]*}"}
        origin=${origin%"${origin##*[![:space:]]}"}
        [[ -n $origin ]] || continue
        if [[ $origin == '*' ]]; then
            wildcard=true
            continue
        fi
        normalized=$(normalize_origin "$origin") || return 1
        result=$(append_origin "$result" "$normalized")
    done
    if $wildcard; then
        printf '*\n'
    elif [[ -n $result ]]; then
        printf '%s\n' "$result"
    else
        return 1
    fi
}

append_origin() {
    local list=$1 origin=$2
    if [[ ,$list, == *,$origin,* ]]; then
        printf '%s\n' "$list"
    elif [[ -n $list ]]; then
        printf '%s,%s\n' "$list" "$origin"
    else
        printf '%s\n' "$origin"
    fi
}

prompt_custom_origin() {
    local current=$1 origin='' normalized
    echo 'CORS 填写浏览器打开前端的协议 + 域名/IP + 可选端口，不带 API 路径、查询参数。' >&2
    echo '例如 https://sub.example.com 或 http://192.0.2.10:3001；多个来源用逗号分隔。' >&2
    echo "当前允许来源：${current:-尚未配置}" >&2
    echo '输入完整列表会替换当前值；已有配置可回车保留；仅使用官方前端可输入 official。' >&2
    while true; do
        read -r -p '允许的前端 Origin: ' origin || return 1
        [[ $origin != official ]] || origin=$DEFAULT_CORS_ALLOWED_ORIGINS
        origin=${origin:-$current}
        if ! normalized=$(normalize_cors_origins "$origin"); then
            echo -e "${RED}请填写有效的前端来源。首次配置不能留空；端口范围为 1–65535。${NC}" >&2
            continue
        fi
        if [[ $normalized == '*' ]]; then
            echo -e "${YELLOW}警告: * 会允许任意网站通过浏览器读取后端响应。${NC}" >&2
        fi
        printf '%s\n' "$normalized"
        return 0
    done
}

cleanup_old_rollback_images() {
    local keep=${1:-$ROLLBACK_IMAGE_KEEP}
    local -a rollback_tags=()
    local tag i

    [[ $keep =~ ^[0-9]+$ ]] || keep=3

    mapfile -t rollback_tags < <(
        docker images xream/sub-store --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
            | grep -E '^xream/sub-store:rollback-[0-9]{8}-[0-9]{6}$' \
            | sort -r || true
    )

    if (( ${#rollback_tags[@]} <= keep )); then
        return 0
    fi

    echo -e "${YELLOW}清理旧的 Sub-Store 回滚镜像，仅保留最近 ${keep} 个。${NC}"
    for ((i=keep; i<${#rollback_tags[@]}; i++)); do
        tag=${rollback_tags[$i]}
        if docker image rm "$tag" >/dev/null 2>&1; then
            echo -e "已删除旧回滚镜像：${CYAN}${tag}${NC}"
        else
            echo -e "${YELLOW}无法删除 ${tag}，可能仍被容器引用，已跳过。${NC}"
        fi
    done
}

health_request() {
    local method=$1 url=$2 headers=$3 body=$4 origin=${5:-}
    local -a args=()
    [[ -z $origin ]] || args+=(-H "Origin: $origin")
    if [[ $method == OPTIONS ]]; then
        args+=(-H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: content-type')
    fi
    curl --silent --show-error --noproxy '*' --connect-timeout 2 --max-time 5 \
        -X "$method" -D "$headers" -o "$body" -w '%{http_code}' "${args[@]}" "$url"
}

health_header() {
    local file=$1 name=$2
    awk -v name="$name" '
        { sub(/\r$/, "") }
        tolower($0) ~ "^" tolower(name) ":[[:space:]]*" {
            sub(/^[^:]*:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print
        }
    ' "$file"
}

health_api_json() {
    local headers=$1 body=$2 content_type
    content_type=$(health_header "$headers" Content-Type)
    [[ ${content_type,,} == application/json* ]] || return 1
    # 使用镜像内已有的 Node.js 解析 JSON，不要求宿主机另装 jq/Node.js。
    docker exec -i sub-store node -e '
        try {
            const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
            if (r.status !== "success" || r.data?.backend !== "Node" ||
                typeof r.data?.version !== "string" || !r.data.version) process.exit(1);
        } catch { process.exit(1); }
    ' < "$body"
}

backend_health_check() (
    local host_port=$1 backend_path=$2 cors_origins=$3
    local base="http://127.0.0.1:${host_port}" url origin expected status attempt ready=false
    local headers body health_dir methods allowed_headers blocked_origin
    local -a origins=()
    url="${base}${backend_path}/api/utils/env"
    [[ $backend_path != / ]] || url="${base}/api/utils/env"
    health_dir=$(mktemp -d /tmp/substore-health.XXXXXX) || return 1
    trap 'rm -f -- "$health_dir/headers" "$health_dir/body"; rmdir -- "$health_dir"' EXIT
    headers="$health_dir/headers"
    body="$health_dir/body"

    echo '正在等待 Sub-Store 前后端就绪，并验证 API/CORS...'
    for ((attempt=1; attempt<=12; attempt++)); do
        if [[ $(docker inspect -f '{{.State.Running}}' sub-store 2>/dev/null || true) == true ]] \
            && status=$(health_request GET "$base/" "$headers" "$body" 2>/dev/null) && [[ $status == 200 ]] \
            && status=$(health_request GET "$url" "$headers" "$body" 2>/dev/null) && [[ $status == 200 ]] \
            && health_api_json "$headers" "$body"; then
            ready=true
            break
        fi
        echo "等待服务启动 (${attempt}/12)..."
        sleep 2
    done
    if ! $ready; then
        echo -e "${RED}前端或后端 API 未就绪，或 API 未返回有效的 Sub-Store JSON。${NC}" >&2
        return 1
    fi

    IFS=',' read -r -a origins <<< "$cors_origins"
    [[ $cors_origins != '*' ]] || origins=('https://sub-store-health.invalid')
    for origin in "${origins[@]}"; do
        expected=$origin
        if [[ $cors_origins == '*' ]]; then
            expected='*'
        else
            # 与上游 new URL(origin).origin 的标准化一致（尤其是 IPv6 压缩）。
            expected=$(docker exec sub-store node -p 'new URL(process.argv[1]).origin' "$origin") || return 1
            expected=${expected%$'\r'}
        fi
        if ! status=$(health_request GET "$url" "$headers" "$body" "$origin") \
            || [[ $status != 200 ]] || ! health_api_json "$headers" "$body" \
            || [[ $(health_header "$headers" Access-Control-Allow-Origin) != "$expected" ]]; then
            echo -e "${RED}CORS API 响应验证失败，前端来源: ${origin}${NC}" >&2
            return 1
        fi
        if ! status=$(health_request OPTIONS "$url" "$headers" "$body" "$origin") \
            || [[ ! $status =~ ^2[0-9][0-9]$ ]] \
            || [[ $(health_header "$headers" Access-Control-Allow-Origin) != "$expected" ]]; then
            echo -e "${RED}CORS OPTIONS 预检失败，前端来源: ${origin}${NC}" >&2
            return 1
        fi
        methods=$(health_header "$headers" Access-Control-Allow-Methods)
        allowed_headers=$(health_header "$headers" Access-Control-Allow-Headers)
        methods=${methods//[[:space:]]/}
        allowed_headers=${allowed_headers//[[:space:]]/}
        if [[ ,${methods^^}, != *,POST,* || ,${allowed_headers,,}, != *,content-type,* ]]; then
            echo -e "${RED}CORS 预检未允许 POST / Content-Type，前端来源: ${origin}${NC}" >&2
            return 1
        fi
    done

    if [[ $cors_origins != '*' ]]; then
        # 验证白名单确实生效，防止代理/旧后端仍允许任意来源。
        blocked_origin="https://sub-store-denied-${RANDOM}-${RANDOM}.invalid"
        while [[ ,$cors_origins, == *,$blocked_origin,* ]]; do
            blocked_origin="https://sub-store-denied-${RANDOM}-${RANDOM}.invalid"
        done
        if ! status=$(health_request OPTIONS "$url" "$headers" "$body" "$blocked_origin") \
            || [[ $status != 403 ]] || [[ -n $(health_header "$headers" Access-Control-Allow-Origin) ]]; then
            echo -e "${RED}CORS 白名单验证失败：未阻止名单外的来源。${NC}" >&2
            return 1
        fi
    fi
    echo -e "${GREEN}前后端及 CORS 检查通过（API JSON、来源响应头、POST 预检）。${NC}"
)

restore_previous() {
    local compose_backup=${1:-}
    local data_backup=${2:-}
    local rollback_tag=${3:-}

    echo -e "${YELLOW}正在恢复更新前的 Sub-Store。${NC}"
    compose down >/dev/null 2>&1 || docker rm -f sub-store >/dev/null 2>&1 || true

    if [[ -n $data_backup && -f $data_backup ]]; then
        if safe_data_dir "$DATA_DIR"; then
            rm -rf -- "$DATA_DIR"
            mkdir -p -- "$(dirname "$DATA_DIR")"
            tar -C "$(dirname "$DATA_DIR")" -xzf "$data_backup"
        else
            echo -e "${RED}数据目录安全检查失败，未自动恢复数据：${DATA_DIR}${NC}"
        fi
    fi

    if [[ -n $compose_backup && -f $compose_backup ]]; then
        cp -a "$compose_backup" "$COMPOSE_FILE"
        if [[ -n $rollback_tag ]] && docker image inspect "$rollback_tag" >/dev/null 2>&1; then
            sed -i -E "s|^([[:space:]]*)image:[[:space:]].*|\\1image: $rollback_tag|" "$COMPOSE_FILE"
        fi
        compose up -d >/dev/null 2>&1 || true
    else
        rm -f -- "$COMPOSE_FILE"
    fi
}

require_substore_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo -e "${RED}请使用 root 权限运行。${NC}"; return 1; }
}

install_substore() {
    require_substore_root || return 1

    install_docker
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        [[ -f /etc/debian_version ]] && apt-get update && apt-get install -y docker-compose-plugin || true
    fi
    docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1 || {
        echo -e "${RED}Docker Compose 不可用。${NC}"
        return 1
    }

    local timestamp backend_path='' cors_allowed_origins='' bind_address='' host_port='3001' public_ip display_host
    local existing_install=false container_exists=false source_compose='' compose_label=''
    local previous_image_id='' rollback_tag='' compose_backup='' data_backup=''

    timestamp=$(date +%Y%m%d-%H%M%S)
    install -d -m 700 "$INSTALL_DIR" "$BACKUP_DIR"

    if docker inspect sub-store >/dev/null 2>&1; then
        container_exists=true
        existing_install=true

        local current_image_name
        current_image_name=$(docker inspect -f '{{.Config.Image}}' sub-store 2>/dev/null || true)
        if [[ $current_image_name != xream/sub-store* ]]; then
            echo -e "${RED}发现名为 sub-store 的容器，但镜像不是 xream/sub-store，已停止操作以避免覆盖其他服务。${NC}"
            return 1
        fi

        backend_path=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' sub-store 2>/dev/null \
            | sed -n 's|^SUB_STORE_FRONTEND_BACKEND_PATH=\(.*\)$|\1|p' | head -n1 || true)
        cors_allowed_origins=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' sub-store 2>/dev/null \
            | sed -n 's|^SUB_STORE_CORS_ALLOWED_ORIGINS=\(.*\)$|\1|p' | head -n1 || true)
        DATA_DIR=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/opt/app/data"}}{{println .Source}}{{end}}{{end}}' sub-store 2>/dev/null | head -n1 || true)
        bind_address=$(docker inspect -f '{{with (index .HostConfig.PortBindings "3001/tcp")}}{{(index . 0).HostIp}}{{end}}' sub-store 2>/dev/null || true)
        host_port=$(docker inspect -f '{{with (index .HostConfig.PortBindings "3001/tcp")}}{{(index . 0).HostPort}}{{end}}' sub-store 2>/dev/null || true)
        previous_image_id=$(docker inspect -f '{{.Image}}' sub-store 2>/dev/null || true)
        compose_label=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' sub-store 2>/dev/null || true)

        bind_address=${bind_address:-0.0.0.0}
        host_port=${host_port:-3001}

        if compose_matches_runtime "$DEFAULT_COMPOSE_FILE" "$backend_path" "$DATA_DIR"; then
            source_compose="$DEFAULT_COMPOSE_FILE"
        elif compose_matches_runtime "$LEGACY_COMPOSE_FILE" "$backend_path" "$DATA_DIR"; then
            source_compose="$LEGACY_COMPOSE_FILE"
        elif [[ -n $compose_label && -f $compose_label ]] && compose_matches_runtime "$compose_label" "$backend_path" "$DATA_DIR"; then
            source_compose="$compose_label"
        fi
    fi

    if ! $container_exists; then
        local default_exists=false legacy_exists=false
        local default_secret='' default_data='' legacy_secret='' legacy_data=''

        if [[ -f $DEFAULT_COMPOSE_FILE ]] && grep -q 'xream/sub-store' "$DEFAULT_COMPOSE_FILE"; then
            default_exists=true
            default_secret=$(compose_backend_path "$DEFAULT_COMPOSE_FILE" 2>/dev/null || true)
            default_data=$(compose_data_dir "$DEFAULT_COMPOSE_FILE" 2>/dev/null || true)
        fi
        if [[ -f $LEGACY_COMPOSE_FILE ]] && grep -q 'xream/sub-store' "$LEGACY_COMPOSE_FILE"; then
            legacy_exists=true
            legacy_secret=$(compose_backend_path "$LEGACY_COMPOSE_FILE" 2>/dev/null || true)
            legacy_data=$(compose_data_dir "$LEGACY_COMPOSE_FILE" 2>/dev/null || true)
        fi

        if $default_exists && $legacy_exists && [[ $default_secret != "$legacy_secret" || $default_data != "$legacy_data" ]]; then
            echo -e "${RED}同时发现新旧两套 Sub-Store 配置且 API/数据目录不同，但当前没有容器可判断哪套正在使用。${NC}"
            echo -e "${YELLOW}为避免切错 API 或数据，脚本不会自动选择，请先恢复/启动正确的现有容器后再更新。${NC}"
            return 1
        elif $default_exists; then
            existing_install=true
            source_compose="$DEFAULT_COMPOSE_FILE"
        elif $legacy_exists; then
            existing_install=true
            source_compose="$LEGACY_COMPOSE_FILE"
        fi

        if $existing_install; then
            backend_path=$(compose_backend_path "$source_compose" 2>/dev/null || true)
            cors_allowed_origins=$(compose_cors_origins "$source_compose" 2>/dev/null || true)
            DATA_DIR=$(compose_data_dir "$source_compose" 2>/dev/null || true)
            bind_address=$(compose_bind_address "$source_compose" 2>/dev/null || true)
            host_port=$(compose_host_port "$source_compose" 2>/dev/null || true)
            previous_image_id=$(docker image inspect -f '{{.Id}}' xream/sub-store:latest 2>/dev/null || true)
            bind_address=${bind_address:-0.0.0.0}
            host_port=${host_port:-3001}
        fi
    fi

    if $existing_install; then
        [[ -n $backend_path ]] || {
            echo -e "${RED}检测到已有 Sub-Store，但无法读取现有 API 路径。为避免修改现有 API，已停止更新。${NC}"
            return 1
        }
        [[ -n $DATA_DIR ]] || {
            echo -e "${RED}检测到已有 Sub-Store，但无法读取现有数据目录。为避免切换数据目录，已停止更新。${NC}"
            return 1
        }
        safe_data_dir "$DATA_DIR" || {
            echo -e "${RED}检测到的数据目录不安全：${DATA_DIR}${NC}"
            return 1
        }

        if [[ -n $source_compose ]]; then
            COMPOSE_FILE="$source_compose"
        else
            COMPOSE_FILE="$DEFAULT_COMPOSE_FILE"
        fi

        cors_allowed_origins=$(preferred_cors_origins "$source_compose" "$cors_allowed_origins") || return 1

        echo -e "${GREEN}检测到已有 Sub-Store，将保持现有 API、数据目录和监听方式，并确认 CORS 设置。${NC}"
        echo -e "API 路径：${CYAN}${backend_path}${NC}"
        echo -e "数据目录：${CYAN}${DATA_DIR}${NC}"
        echo -e "CORS：${CYAN}${cors_allowed_origins}${NC}"
        echo -e "配置文件：${CYAN}${COMPOSE_FILE}${NC}"
    else
        COMPOSE_FILE="$DEFAULT_COMPOSE_FILE"
        DATA_DIR="$DEFAULT_DATA_DIR"
        backend_path="/$(openssl rand -hex 16)"

        read -r -p '监听地址 [127.0.0.1，输入 0.0.0.0 可公网访问]: ' bind_address
        bind_address=${bind_address:-127.0.0.1}
        [[ $bind_address == 127.0.0.1 || $bind_address == 0.0.0.0 ]] || {
            echo -e "${RED}只允许 127.0.0.1 或 0.0.0.0。${NC}"
            return 1
        }
    fi

    if ! valid_backend_path "$backend_path"; then
        echo -e "${RED}现有 API 路径格式不受支持，已停止更新，请检查路径配置。${NC}"
        return 1
    fi
    [[ $backend_path != / ]] || echo -e "${YELLOW}保留现有根路径 /：后端没有随机路径保护。${NC}"
    cors_allowed_origins=$(prompt_custom_origin "$cors_allowed_origins") || return 1
    [[ $existing_install == true ]] || install -d -m 700 "$DATA_DIR"
    mkdir -p -- "$(dirname "$COMPOSE_FILE")" "$DATA_DIR"

    if [[ -f $COMPOSE_FILE ]]; then
        compose_backup="$BACKUP_DIR/docker-compose.${timestamp}.yml"
        cp -a "$COMPOSE_FILE" "$compose_backup"
    fi

    if $existing_install && [[ -d $DATA_DIR ]]; then
        data_backup="$BACKUP_DIR/data.${timestamp}.tar.gz"
        tar -C "$(dirname "$DATA_DIR")" -czf "$data_backup" "$(basename "$DATA_DIR")"
    fi

    if [[ -n $previous_image_id ]] && docker image inspect "$previous_image_id" >/dev/null 2>&1; then
        rollback_tag="xream/sub-store:rollback-${timestamp}"
        docker tag "$previous_image_id" "$rollback_tag"
    fi

    cat > "$COMPOSE_FILE" <<EOF
services:
  sub-store:
    image: xream/sub-store:latest
    container_name: sub-store
    restart: unless-stopped
    environment:
      SUB_STORE_FRONTEND_BACKEND_PATH: "$backend_path"
      SUB_STORE_CORS_ALLOWED_ORIGINS: "$cors_allowed_origins"
    ports:
      - "$bind_address:$host_port:3001"
    volumes:
      - "$DATA_DIR:/opt/app/data"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
    chmod 600 "$COMPOSE_FILE"

    if ! compose config >/dev/null; then
        echo -e "${RED}生成的 Compose 配置校验失败，正在恢复。${NC}"
        restore_previous "$compose_backup" "$data_backup" "$rollback_tag"
        return 1
    fi

    if ! compose pull sub-store || ! compose up -d; then
        echo -e "${RED}更新失败，正在恢复更新前配置、数据和镜像。${NC}"
        restore_previous "$compose_backup" "$data_backup" "$rollback_tag"
        return 1
    fi

    if ! backend_health_check "$host_port" "$backend_path" "$cors_allowed_origins"; then
        echo -e "${RED}容器未通过前端、后端 API 或 CORS 健康检查，正在回滚。${NC}"
        restore_previous "$compose_backup" "$data_backup" "$rollback_tag"
        return 1
    fi

    cleanup_old_rollback_images "$ROLLBACK_IMAGE_KEEP"

    public_ip=$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || echo YOUR_SERVER_IP)
    display_host=$public_ip
    [[ $bind_address == 127.0.0.1 ]] && display_host=127.0.0.1

    echo -e "${GREEN}Sub-Store 已启动。${NC}"
    echo -e "面板：${CYAN}http://${display_host}:${host_port}${NC}"
    echo -e "API：${CYAN}http://${display_host}:${host_port}${backend_path}${NC}"
    echo -e "配置：${COMPOSE_FILE}；数据：${DATA_DIR}；日志限制：10MB × 3。"
    echo -e "CORS：${cors_allowed_origins}"
    echo -e "自动回滚镜像：最多保留最近 ${ROLLBACK_IMAGE_KEEP} 个。"
    [[ -n $compose_backup ]] && echo -e "更新前配置备份：${compose_backup}"
    [[ -n $data_backup ]] && echo -e "更新前数据备份：${data_backup}"
    [[ -n $rollback_tag ]] && echo -e "本次更新前镜像：${rollback_tag}"

    return 0
}

if [[ ${SUBSTORE_SOURCE_ONLY:-0} != 1 ]]; then
    install_substore
fi
