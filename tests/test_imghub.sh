#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/imghub-test.XXXXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export IMGHUB_INSTALLER_SOURCE_ONLY=1
export PYTHON_SCRIPT_PATH="$TEST_ROOT/opt/imghub/imghub_bot.py"
export PYTHON_SCRIPT_DIR="$TEST_ROOT/opt/imghub"
export CONFIG_FILE_PATH="$TEST_ROOT/root/imghub_config.ini"
export DATA_DIR="$TEST_ROOT/var/lib/imghub"
export CACHE_DIR="$TEST_ROOT/var/cache/imghub"
export SERVICE_NAME=imghub-test
export SERVICE_FILE="$TEST_ROOT/etc/systemd/system/imghub-test.service"
export BACKUP_ROOT="$TEST_ROOT/backups"
export BACKUP_KEEP=5
export STARTUP_ATTEMPTS=2
export STARTUP_INTERVAL=0
export HEALTH_PORT=18080

# shellcheck source=../install_imghub.sh disable=SC1091
. "$REPO_DIR/install_imghub.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" message="${3:-values differ}"
    [[ "$actual" == "$expected" ]] || fail "$message: expected [$expected], got [$actual]"
}

assert_file_contains() {
    grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

assert_file_not_contains() {
    if grep -Fq -- "$2" "$1"; then fail "$1 unexpectedly contains: $2"; fi
}

install() {
    local mode
    if [[ ${1:-} == -d ]]; then
        shift
        if [[ ${1:-} == -m ]]; then
            mode=$2
            shift 2
        fi
        mkdir -p -- "$@"
        [[ -z ${mode:-} ]] || chmod "$mode" "$@" 2>/dev/null || true
    elif [[ ${1:-} == -m ]]; then
        mode=$2
        cp -- "$3" "$4"
        chmod "$mode" "$4" 2>/dev/null || true
    else
        command install "$@"
    fi
}

check_root() { :; }
sleep() { :; }

SERVICE_ACTIVE=true
SERVICE_ENABLED=false
NRESTARTS=0
FAIL_STARTS=0
SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
EVENT_LOG="$TEST_ROOT/events.log"
systemctl() {
    local action="${1:-}"
    shift || true
    printf '%s %s\n' "$action" "$*" >> "$SYSTEMCTL_LOG"
    case "$action" in
        is-active) [[ "$SERVICE_ACTIVE" == true ]] ;;
        is-enabled) [[ "$SERVICE_ENABLED" == true ]] ;;
        enable) SERVICE_ENABLED=true ;;
        disable) SERVICE_ENABLED=false ;;
        stop) printf 'stop\n' >> "$EVENT_LOG"; SERVICE_ACTIVE=false ;;
        start|restart)
            if ((FAIL_STARTS > 0)); then
                FAIL_STARTS=$((FAIL_STARTS - 1))
                SERVICE_ACTIVE=false
                return 1
            fi
            SERVICE_ACTIVE=true
            ;;
        show) printf '%s\n' "$NRESTARTS" ;;
        daemon-reload|status) return 0 ;;
        *) return 0 ;;
    esac
}

CURL_OK=true
curl() {
    printf 'curl %s\n' "$*" >> "$EVENT_LOG"
    [[ "$CURL_OK" == true ]]
}

APT_FAIL_ONCE=0
apt-get() {
    printf 'apt %s\n' "$*" >> "$EVENT_LOG"
    if ((APT_FAIL_ONCE > 0)); then
        APT_FAIL_ONCE=$((APT_FAIL_ONCE - 1))
        return 1
    fi
}
pip3() { printf 'pip %s\n' "$*" >> "$EVENT_LOG"; }
systemd-analyze() { return 0; }
journalctl() { printf 'journal %s\n' "$*" >> "$EVENT_LOG"; }

TEST_PYTHON="${IMGHUB_TEST_PYTHON:-python3}"
STUB_ROOT="$TEST_ROOT/python-stubs"
mkdir -p "$STUB_ROOT/telegram/ext" "$STUB_ROOT/aiohttp"
cat > "$STUB_ROOT/telegram/__init__.py" <<'PY'
class Bot:
    pass

class Update:
    pass
PY
cat > "$STUB_ROOT/telegram/ext/__init__.py" <<'PY'
class Application:
    pass

class CommandHandler:
    def __init__(self, *args, **kwargs):
        pass

class ContextTypes:
    DEFAULT_TYPE = object

class MessageHandler:
    def __init__(self, *args, **kwargs):
        pass

class _Filter:
    def __or__(self, other):
        return self

class _Document:
    IMAGE = _Filter()

class _Filters:
    PHOTO = _Filter()
    Document = _Document()

filters = _Filters()
PY
cat > "$STUB_ROOT/aiohttp/__init__.py" <<'PY'
class _Application(dict):
    def __init__(self, *args, **kwargs):
        super().__init__()
    def add_routes(self, routes):
        self.routes = routes

class _HTTPException(Exception):
    pass

class _Web:
    Application = _Application
    HTTPException = _HTTPException
    class HTTPServiceUnavailable(_HTTPException):
        pass
    class HTTPRequestEntityTooLarge(_HTTPException):
        def __init__(self, *args, **kwargs):
            pass
    @staticmethod
    def get(*args, **kwargs):
        return (args, kwargs)
    @staticmethod
    def json_response(*args, **kwargs):
        return (args, kwargs)

web = _Web()
PY

STUB_NATIVE=$(cygpath -w "$STUB_ROOT" 2>/dev/null || printf '%s' "$STUB_ROOT")
python3() {
    local config_path="${IMGHUB_CONFIG_PATH:-}" data_path="${IMGHUB_DATA_DIR:-}" cache_path="${IMGHUB_CACHE_DIR:-}"
    if command -v cygpath >/dev/null 2>&1; then
        [[ "$config_path" != /* ]] || config_path=$(cygpath -w "$config_path")
        [[ "$data_path" != /* ]] || data_path=$(cygpath -w "$data_path")
        [[ "$cache_path" != /* ]] || cache_path=$(cygpath -w "$cache_path")
    fi
    PYTHONPATH="$STUB_NATIVE" IMGHUB_CONFIG_PATH="$config_path" \
        IMGHUB_DATA_DIR="$data_path" IMGHUB_CACHE_DIR="$cache_path" \
        IMGHUB_CHECK_CONFIG_ONLY="${IMGHUB_CHECK_CONFIG_ONLY:-}" "$TEST_PYTHON" "$@"
}

mkdir -p "$PYTHON_SCRIPT_DIR" "$(dirname -- "$CONFIG_FILE_PATH")" "$(dirname -- "$SERVICE_FILE")" "$DATA_DIR"
PYTHON_CANDIDATE="$TEST_ROOT/imghub_bot.py"
printf '%s\n' "$PYTHON_SCRIPT_CONTENT" > "$PYTHON_CANDIDATE"
python3 -m py_compile "$PYTHON_CANDIDATE" || fail 'embedded Python does not compile'

# Shell-side validation prevents INI injection and malformed Telegram/URL data.
is_valid_bot_token '123456:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi_1234' || fail 'valid bot token rejected'
for token in 'bad-token' $'12345:abc\n[server]'; do
    if is_valid_bot_token "$token"; then fail "invalid bot token accepted: $token"; fi
done
is_valid_channel_id -1001234567890 || fail 'valid channel ID rejected'
if is_valid_channel_id 123456; then fail 'positive channel ID accepted'; fi
is_valid_channel_username imghub_test || fail 'valid channel username rejected'
for username in 'bad-name' 'x' $'name\nkey'; do
    if is_valid_channel_username "$username"; then fail "invalid username accepted: $username"; fi
done
is_valid_allowed_users '12345,67890' || fail 'valid allowed users rejected'
for users in '' '123,123' '0' '1;id'; do
    if is_valid_allowed_users "$users"; then fail "invalid user list accepted: $users"; fi
done
for url in https://img.example.com http://192.0.2.10:8080; do
    is_valid_base_url "$url" || fail "valid base URL rejected: $url"
done
for url in 'https://example.com/path' 'https://example.com?x=1' 'https://bad_name.com' 'https://999.1.1.1' 'https://example.com:99999' $'https://ok.test\nkey=x'; do
    if is_valid_base_url "$url"; then fail "invalid base URL accepted: $url"; fi
done

VALID_CONFIG="$TEST_ROOT/valid.ini"
write_config_candidate "$VALID_CONFIG" '123456:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi_1234' \
    -1001234567890 imghub_test '12345,67890' https://img.example.com
IMGHUB_CONFIG_PATH="$VALID_CONFIG" IMGHUB_CHECK_CONFIG_ONLY=1 python3 "$PYTHON_CANDIDATE" >/dev/null \
    || fail 'valid runtime config rejected'
INVALID_CONFIG="$TEST_ROOT/invalid.ini"
cp -- "$VALID_CONFIG" "$INVALID_CONFIG"
sed -i 's#base_url = .*#base_url = https://example.com/path#' "$INVALID_CONFIG"
if IMGHUB_CONFIG_PATH="$INVALID_CONFIG" IMGHUB_CHECK_CONFIG_ONLY=1 python3 "$PYTHON_CANDIDATE" >/dev/null 2>&1; then
    fail 'invalid runtime config accepted'
fi
OVERSIZED_CONFIG="$TEST_ROOT/oversized.ini"
cp -- "$VALID_CONFIG" "$OVERSIZED_CONFIG"
sed -i 's/max_file_bytes = .*/max_file_bytes = 20971521/' "$OVERSIZED_CONFIG"
if IMGHUB_CONFIG_PATH="$OVERSIZED_CONFIG" IMGHUB_CHECK_CONFIG_ONLY=1 python3 "$PYTHON_CANDIDATE" >/dev/null 2>&1; then
    fail 'Telegram download limit above 20 MiB was accepted'
fi

# Exercise atomic records, last-good backup, legacy ID compatibility, and
# corruption refusal with the embedded Python implementation.
PYTHON_DATA_NATIVE=$(cygpath -w "$TEST_ROOT/python-data" 2>/dev/null || printf '%s' "$TEST_ROOT/python-data")
PYTHON_CACHE_NATIVE=$(cygpath -w "$TEST_ROOT/python-cache" 2>/dev/null || printf '%s' "$TEST_ROOT/python-cache")
PYTHON_MODULE_NATIVE=$(cygpath -w "$PYTHON_CANDIDATE" 2>/dev/null || printf '%s' "$PYTHON_CANDIDATE")
cat > "$TEST_ROOT/test_records.py" <<'PY'
import importlib.util
import json
import os
import pathlib

spec = importlib.util.spec_from_file_location("imghub_runtime", os.environ["PYTHON_MODULE"])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
config = {
    "max_concurrency": 2,
    "max_file_bytes": 1024 * 1024,
    "cache_max_bytes": 2 * 1024 * 1024,
    "cache_ttl_seconds": 3600,
    "listen_host": "127.0.0.1",
    "listen_port": 18080,
}
service = module.ImageHostingService(None, config)
service.add_record("abcdef12", ("123456", 1, "telegram-one", "image/png"))
service.add_record("abcdef123456", ("123456", 2, "telegram-two", "image/jpeg"))
primary = json.loads(module.DB_PATH.read_text(encoding="utf-8"))
backup = json.loads(module.DB_BACKUP_PATH.read_text(encoding="utf-8"))
assert set(primary) == {"abcdef12", "abcdef123456"}
assert set(backup) == {"abcdef12"}
assert not list(module.DB_PATH.parent.glob(".records.json.*"))
module.DB_PATH.write_text("{broken", encoding="utf-8")
broken_before = module.DB_PATH.read_bytes()
try:
    module.ImageHostingService(None, config)
except module.RecordsCorruptionError:
    pass
else:
    raise AssertionError("corrupt records were accepted")
assert module.DB_PATH.read_bytes() == broken_before
assert json.loads(module.DB_BACKUP_PATH.read_text(encoding="utf-8"))["abcdef12"]
PY
PYTHONPATH="$STUB_NATIVE" PYTHON_MODULE="$PYTHON_MODULE_NATIVE" \
    IMGHUB_DATA_DIR="$PYTHON_DATA_NATIVE" IMGHUB_CACHE_DIR="$PYTHON_CACHE_NATIVE" \
    "$TEST_PYTHON" "$TEST_ROOT/test_records.py" || fail 'atomic records tests failed'

# Complete transaction backup and restore includes program, config, service,
# primary records, last-good records, and exact service state.
printf 'old python\n' > "$PYTHON_SCRIPT_PATH"
printf 'old config\n' > "$CONFIG_FILE_PATH"
printf 'old service\n' > "$SERVICE_FILE"
printf '{"abcdef12":["1",1,"f","image/png"]}\n' > "$DATA_DIR/records.json"
printf '{"abcdef12":["1",1,"f","image/png"]}\n' > "$DATA_DIR/records.json.last-good"
SERVICE_ACTIVE=true
SERVICE_ENABLED=false
backup_dir=$(create_transaction_backup)
printf 'new python\n' > "$PYTHON_SCRIPT_PATH"
printf 'new config\n' > "$CONFIG_FILE_PATH"
printf 'new service\n' > "$SERVICE_FILE"
printf '{}\n' > "$DATA_DIR/records.json"
restore_transaction_backup "$backup_dir" || fail 'complete transaction restore failed'
assert_file_contains "$PYTHON_SCRIPT_PATH" 'old python'
assert_file_contains "$CONFIG_FILE_PATH" 'old config'
assert_file_contains "$SERVICE_FILE" 'old service'
assert_file_contains "$DATA_DIR/records.json" 'abcdef12'
assert_eq true "$SERVICE_ACTIVE" 'restore changed active state'
assert_eq false "$SERVICE_ENABLED" 'restore changed enabled state'

# Candidate files compile and config-check before commit.
STAGE_DIR="$TEST_ROOT/stage"
mkdir -p "$STAGE_DIR"
write_stage_files "$STAGE_DIR"
cp -- "$VALID_CONFIG" "$STAGE_DIR/imghub_config.ini"
validate_stage_files "$STAGE_DIR" || fail 'valid staged files rejected'

# A complete successful update keeps the old service running throughout input,
# dependency installation and staging, then commits and passes two health checks.
: > "$EVENT_LOG"
APT_FAIL_ONCE=1
SERVICE_ACTIVE=true
if main <<< $'y\n123456:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi_1234\n-1001234567890\nimghub_test\n12345,67890\nhttps://img.example.com\n' >/dev/null 2>&1; then
    fail 'dependency failure was ignored'
fi
if grep -Fxq stop "$EVENT_LOG"; then fail 'dependency failure stopped the old service'; fi
assert_file_contains "$PYTHON_SCRIPT_PATH" 'old python'
assert_eq true "$SERVICE_ACTIVE" 'dependency failure changed old service state'

: > "$EVENT_LOG"
CURL_OK=true
SERVICE_ACTIVE=true
SERVICE_ENABLED=false
main <<< $'y\n123456:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi_1234\n-1001234567890\nimghub_test\n12345,67890\nhttps://img.example.com\n' >/dev/null \
    || fail 'full installer transaction failed'
assert_file_contains "$PYTHON_SCRIPT_PATH" 'class ImageHostingService'
assert_file_contains "$CONFIG_FILE_PATH" 'listen_host = 127.0.0.1'
assert_file_contains "$SERVICE_FILE" 'Restart=on-failure'
assert_file_contains "$SERVICE_FILE" 'StandardOutput=journal'
first_stop=$(grep -n '^stop$' "$EVENT_LOG" | head -n 1 | cut -d: -f1)
last_dependency=$(grep -nE '^(apt|pip) ' "$EVENT_LOG" | tail -n 1 | cut -d: -f1)
[[ -n "$first_stop" && -n "$last_dependency" && $first_stop -gt $last_dependency ]] \
    || fail 'old service stopped before dependencies/staging completed'
successful_python=$(< "$PYTHON_SCRIPT_PATH")
successful_config=$(< "$CONFIG_FILE_PATH")
successful_service=$(< "$SERVICE_FILE")

# Health failure after commit triggers rollback to the complete pre-attempt state.
CURL_OK=false
SERVICE_ACTIVE=true
if main <<< $'y\n123456:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi_1234\n-1001234567890\nimghub_test\n12345,67890\nhttps://new.example.com\n' >/dev/null 2>&1; then
    fail 'failed HTTP health check was accepted'
fi
assert_eq "$successful_python" "$(< "$PYTHON_SCRIPT_PATH")" 'health failure did not restore Python program'
assert_eq "$successful_config" "$(< "$CONFIG_FILE_PATH")" 'health failure did not restore config'
assert_eq "$successful_service" "$(< "$SERVICE_FILE")" 'health failure did not restore service unit'
assert_eq true "$SERVICE_ACTIVE" 'health rollback did not restart old service'
CURL_OK=true

# Backup retention is bounded.
for _ in 1 2 3 4 5 6 7; do create_transaction_backup >/dev/null; done
backup_count=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'transaction.*' | wc -l | tr -d '[:space:]')
assert_eq 5 "$backup_count" 'ImgHub backup retention'

# Static A17/A18 safety boundaries.
assert_file_contains "$REPO_DIR/install_imghub.sh" 'os.replace(temp_name, path)'
assert_file_contains "$REPO_DIR/install_imghub.sh" 'os.fsync(temp_file.fileno())'
assert_file_contains "$REPO_DIR/install_imghub.sh" 'records.json.last-good'
assert_file_contains "$REPO_DIR/install_imghub.sh" 'asyncio.Semaphore'
assert_file_contains "$REPO_DIR/install_imghub.sh" 'web.StreamResponse'
assert_file_contains "$REPO_DIR/install_imghub.sh" 'listen_host = 127.0.0.1'
assert_file_contains "$REPO_DIR/install_imghub.sh" 'finally:'
assert_file_not_contains "$REPO_DIR/install_imghub.sh" 'download_as_bytearray'
assert_file_not_contains "$REPO_DIR/install_imghub.sh" 'ImageHostingService(None)'
assert_file_not_contains "$REPO_DIR/install_imghub.sh" '${LOG_FILE}'
assert_file_contains "$REPO_DIR/install_imghub.sh" 'journalctl -u "$SERVICE_NAME.service"'
assert_file_contains "$REPO_DIR/install_imghub.sh" 'IMGHUB_INSTALLER_SOURCE_ONLY'

printf 'PASS: install_imghub.sh A17/A18 regression tests\n'
