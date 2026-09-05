#!/usr/bin/env bash
# Runs without a Docker daemon. Requires Node.js; a real Compose CLI validates YAML fixtures.
set -Eeuo pipefail
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/substore-cors-test.XXXXXX)
cleanup() {
    [[ $TEST_ROOT == /tmp/substore-cors-test.* && -d $TEST_ROOT ]] || return
    [[ $(cd -- "$TEST_ROOT" && pwd -P) == "$TEST_ROOT" ]] || return
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT
export SUBSTORE_SOURCE_ONLY=1
# shellcheck source=../install_substore.sh
source "$REPO_ROOT/install_substore.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ $1 == "$2" ]] || fail "expected [$2], got [$1]"; }
reject() { if "$@" > /dev/null 2>&1; then fail "unexpected success: $*"; fi; }

assert_eq "$(normalize_cors_origins ' https://EXAMPLE.com:443/, http://127.0.0.1:3001,https://example.com ')" \
    'https://example.com,http://127.0.0.1:3001'
assert_eq "$(normalize_cors_origins 'http://[::1]:3001')" 'http://[::1]:3001'
assert_eq "$(normalize_cors_origins 'https://[2001:0db8:0:0:0:0:0:1]')" 'https://[2001:0db8:0:0:0:0:0:1]'
assert_eq "$(normalize_cors_origins '*,https://example.com')" '*'
for bad in '' 'https://bad host' 'https://example.com?api=x' 'https://example.com#x' \
    'https://example.com/path' 'https://user@example.com' 'https://example.com"' \
    'https://example.com:0' 'https://example.com:65536' 'https://bad..host' \
    'http://[::::]:3001' 'http://[1:2:3]' 'http://[1:2:3:4:5:6:7:8:9]' \
    'http://999.1.1.1' 'http://01.2.3.4'; do
    reject normalize_cors_origins "$bad"
done
assert_eq "$(prompt_custom_origin 'https://old.example.com' <<< '' 2>/dev/null)" 'https://old.example.com'
assert_eq "$(prompt_custom_origin 'https://old.example.com' <<< 'https://new.example.com' 2>/dev/null)" 'https://new.example.com'
assert_eq "$(prompt_custom_origin '' <<< 'official' 2>/dev/null)" "$DEFAULT_CORS_ALLOWED_ORIGINS"
reject prompt_custom_origin '' < /dev/null
assert_eq "$(prompt_custom_origin '' <<< $'\nhttps://new.example.com' 2>/dev/null)" 'https://new.example.com'
valid_backend_path / || fail 'root backend path rejected'
valid_backend_path /existing-random-path || fail 'existing backend path rejected'
reject valid_backend_path ''
reject valid_backend_path '/bad"path'
reject valid_backend_path '/bad//path'

# The only Docker operations below are faked; JSON is parsed with the actual local Node runtime.
INTEGRATION=false
docker() {
    if [[ $1 == compose ]]; then return 1; fi
    if [[ $1 == inspect ]]; then
        if $INTEGRATION; then
            case ${3:-} in
                *Config.Image*) printf 'xream/sub-store:latest\n' ;;
                *Config.Env*) printf 'SUB_STORE_FRONTEND_BACKEND_PATH=/keep-this-path\nSUB_STORE_CORS_ALLOWED_ORIGINS=https://runtime.example.com\n' ;;
                *Mounts*) printf '%s\n' "$TEST_ROOT/data" ;;
                *HostIp*) printf '127.0.0.1\n' ;;
                *HostPort*) printf '3001\n' ;;
                *Config.Labels*) printf '%s\n' "$DEFAULT_COMPOSE_FILE" ;;
                '{{.Image}}') printf 'sha256:test-old-image\n' ;;
                *) printf 'true\n' ;;
            esac
        else
            printf 'true\n'
        fi
        return 0
    fi
    if [[ $1 == image || $1 == images || $1 == tag || $1 == rm ]]; then return 0; fi
    if [[ $1 == exec ]]; then
        shift
        [[ $1 != -i ]] || shift
        [[ $1 == sub-store && $2 == node ]] || return 99
        shift 2
        command node "$@"
        return $?
    fi
    return 99
}
docker-compose() { "$SUBSTORE_TEST_COMPOSE" "$@" | tr -d '\r'; }

if [[ -n ${SUBSTORE_TEST_COMPOSE:-} ]]; then
    cat > "$TEST_ROOT/list.yml" <<'EOF'
services:
  another-service:
    image: example:latest
    environment:
      SUB_STORE_CORS_ALLOWED_ORIGINS: https://wrong.example.com
  sub-store:
    image: xream/sub-store:latest
    environment:
      - "SUB_STORE_FRONTEND_BACKEND_PATH=/"
      - "SUB_STORE_CORS_ALLOWED_ORIGINS=https://manual.example.com,http://127.0.0.1:3001"
    volumes:
      - "/var/lib/sub-store:/opt/app/data"
EOF
    assert_eq "$(compose_backend_path "$TEST_ROOT/list.yml")" '/'
    assert_eq "$(compose_cors_origins "$TEST_ROOT/list.yml")" 'https://manual.example.com,http://127.0.0.1:3001'
    assert_eq "$(preferred_cors_origins "$TEST_ROOT/list.yml" 'https://runtime.example.com')" \
        'https://manual.example.com,http://127.0.0.1:3001'
    compose_matches_runtime "$TEST_ROOT/list.yml" / /var/lib/sub-store || fail 'root path did not match runtime'

    cat > "$TEST_ROOT/mapping.yml" <<'EOF'
services:
  sub-store:
    image: xream/sub-store:latest
    environment:
      SUB_STORE_FRONTEND_BACKEND_PATH: '/keep-this-path'
      SUB_STORE_CORS_ALLOWED_ORIGINS: '${SUBSTORE_TEST_ORIGIN}' # Compose interpolation
EOF
    export SUBSTORE_TEST_ORIGIN='https://edited.example.com'
    assert_eq "$(compose_backend_path "$TEST_ROOT/mapping.yml")" /keep-this-path
    assert_eq "$(compose_cors_origins "$TEST_ROOT/mapping.yml")" https://edited.example.com
    cat > "$TEST_ROOT/empty.yml" <<'EOF'
services:
  sub-store:
    image: xream/sub-store:latest
    environment:
      SUB_STORE_CORS_ALLOWED_ORIGINS: ""
EOF
    assert_eq "$(preferred_cors_origins "$TEST_ROOT/empty.yml" 'https://runtime.example.com')" ''
    cat > "$TEST_ROOT/missing.yml" <<'EOF'
services:
  sub-store:
    image: xream/sub-store:latest
EOF
    assert_eq "$(preferred_cors_origins "$TEST_ROOT/missing.yml" 'https://runtime.example.com')" 'https://runtime.example.com'
else
    printf 'SKIP: set SUBSTORE_TEST_COMPOSE to run real Compose YAML parsing checks\n'
fi

# HTTP fixtures reproduce the upstream CORS responses; calls still use the production curl argument builder.
HEALTH_MODE=ok
curl() {
    local method=GET headers='' body='' origin='' url='' status=200 allow='' preflight_method='' preflight_headers=''
    if [[ $* == *https://api.ipify.org* ]]; then printf '192.0.2.55\n'; return 0; fi
    while (($#)); do
        case $1 in
            -X) method=$2; shift 2 ;;
            -D) headers=$2; shift 2 ;;
            -o) body=$2; shift 2 ;;
            -w|--connect-timeout|--max-time|--noproxy) shift 2 ;;
            -H)
                case $2 in
                    'Origin: '*) origin=${2#Origin: } ;;
                    'Access-Control-Request-Method: '*) preflight_method=${2#*: } ;;
                    'Access-Control-Request-Headers: '*) preflight_headers=${2#*: } ;;
                esac
                shift 2 ;;
            http://*) url=$1; shift ;;
            *) shift ;;
        esac
    done
    [[ $url != *'//api/'* ]] || return 90
    printf '%s %s %s\n' "$method" "$url" "$origin" >> "$TEST_ROOT/http.log"
    if [[ $method == OPTIONS ]]; then
        [[ $preflight_method == POST && $preflight_headers == content-type ]] || return 91
    fi
    : > "$headers"
    printf '{"status":"success","data":{"backend":"Node","version":"2.38.0"}}' > "$body"
    printf 'Content-Type: application/json; charset=utf-8\r\n' >> "$headers"
    if [[ $HEALTH_MODE == html ]]; then
        printf '<html>fallback frontend</html>' > "$body"
        printf 'Content-Type: text/html\r\n' > "$headers"
    elif [[ $HEALTH_MODE == broken_json ]]; then
        printf '{"status":"success","data":' > "$body"
    elif [[ $HEALTH_MODE == fake_json ]]; then
        printf '{"message":"frontend fallback"}' > "$body"
    fi
    if [[ $origin == https://sub-store-denied-* ]]; then
        status=403
        [[ $HEALTH_MODE != accepts_denied ]] || status=200
    elif [[ -n $origin ]]; then
        allow=$(command node -p 'new URL(process.argv[1]).origin' "$origin")
        allow=${allow%$'\r'}
        [[ $HEALTH_MODE != wildcard ]] || allow='*'
        [[ $HEALTH_MODE != wrong_origin ]] || allow='https://wrong.example.com'
        if [[ $HEALTH_MODE != missing_header ]]; then
            printf 'Access-Control-Allow-Origin: %s\r\n' "$allow" >> "$headers"
        fi
        printf 'Access-Control-Allow-Methods: POST,GET,OPTIONS,PATCH,PUT,DELETE\r\n' >> "$headers"
        if [[ $HEALTH_MODE != bad_headers ]]; then
            printf 'Access-Control-Allow-Headers: Origin,Content-Type,Accept\r\n' >> "$headers"
        fi
        if [[ $HEALTH_MODE == bad_preflight && $method == OPTIONS ]]; then status=405; fi
    fi
    printf '%s' "$status"
}
sleep() { :; }

backend_health_check 3001 /secret https://panel.example.com > /dev/null
grep -q 'OPTIONS http://127.0.0.1:3001/secret/api/utils/env https://panel.example.com' "$TEST_ROOT/http.log" || fail 'preflight missing'
backend_health_check 3001 / https://panel.example.com > /dev/null
grep -q 'GET http://127.0.0.1:3001/api/utils/env' "$TEST_ROOT/http.log" || fail 'root path incorrect'
backend_health_check 3001 /secret https://[2001:0db8:0:0:0:0:0:1] > /dev/null
HEALTH_MODE=wildcard backend_health_check 3001 /secret '*' > /dev/null
for mode in html broken_json fake_json missing_header wrong_origin bad_preflight bad_headers accepts_denied; do
    HEALTH_MODE=$mode reject backend_health_check 3001 /secret https://panel.example.com
done

if [[ -n ${SUBSTORE_TEST_COMPOSE:-} ]]; then
    INTEGRATION=true
    INSTALL_DIR="$TEST_ROOT/install"
    DEFAULT_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
    COMPOSE_FILE="$DEFAULT_COMPOSE_FILE"
    # Read by the sourced install_substore function.
    # shellcheck disable=SC2034
    LEGACY_COMPOSE_FILE="$TEST_ROOT/legacy.yml"
    BACKUP_DIR="$TEST_ROOT/backups"
    mkdir -p "$INSTALL_DIR" "$TEST_ROOT/data"
    printf 'existing subscriptions\n' > "$TEST_ROOT/data/store.json"
    cat > "$DEFAULT_COMPOSE_FILE" <<EOF
services:
  sub-store:
    image: xream/sub-store:latest
    container_name: sub-store
    environment:
      SUB_STORE_FRONTEND_BACKEND_PATH: /keep-this-path
      SUB_STORE_CORS_ALLOWED_ORIGINS: https://manual.example.com
    ports:
      - "127.0.0.1:3001:3001"
    volumes:
      - "$TEST_ROOT/data:/opt/app/data"
EOF
    install_docker() { :; }
    require_substore_root() { :; }
    # Directory mode changes are not supported on every Git Bash/NTFS setup.
    install() {
        [[ $1 == -d && $2 == -m && $3 == 700 ]] || return 99
        shift 3
        local directory
        for directory in "$@"; do
            [[ $directory == "$TEST_ROOT"/* ]] || return 99
        done
        mkdir -p -- "$@"
    }
    UP_COUNT=0
    compose() {
        case $1 in
            config) compose_config "$COMPOSE_FILE" ;;
            up)
                UP_COUNT=$((UP_COUNT + 1))
                if [[ $HEALTH_MODE == wrong_origin && $UP_COUNT == 1 ]]; then
                    printf 'simulated failed migration\n' > "$TEST_ROOT/data/store.json"
                fi
                ;;
            pull|down) return 0 ;;
            *) return 99 ;;
        esac
    }
    # Preserve production errexit semantics inside the child while retaining its failure log.
    set +e
    (set -e; install_substore <<< '') > "$TEST_ROOT/install.log" 2>&1
    install_status=$?
    set -e
    if ((install_status != 0)); then
        cat "$TEST_ROOT/install.log" >&2
        fail 'simulated update failed'
    fi
    assert_eq "$(compose_backend_path "$COMPOSE_FILE")" /keep-this-path
    assert_eq "$(compose_cors_origins "$COMPOSE_FILE")" https://manual.example.com
    assert_eq "$(cat "$TEST_ROOT/data/store.json")" 'existing subscriptions'
    [[ -n $(find "$BACKUP_DIR" -name 'docker-compose.*.yml' -print -quit) ]] || fail 'config backup missing'
    [[ -n $(find "$BACKUP_DIR" -name 'data.*.tar.gz' -print -quit) ]] || fail 'data backup missing'
    UP_COUNT=0
    HEALTH_MODE=wrong_origin reject install_substore <<< 'https://new.example.com'
    assert_eq "$(compose_backend_path "$COMPOSE_FILE")" /keep-this-path
    assert_eq "$(compose_cors_origins "$COMPOSE_FILE")" https://manual.example.com
    assert_eq "$(cat "$TEST_ROOT/data/store.json")" 'existing subscriptions'
    grep -q 'image: xream/sub-store:rollback-' "$COMPOSE_FILE" || fail 'old image not restored'
fi
printf 'PASS: Sub-Store CORS configuration and API health checks\n'
