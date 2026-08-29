#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/saveanybot-a19-test.XXXXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "${expected}" == "${actual}" ]] || fail "${label}: expected '${expected}', got '${actual}'"
}

assert_file_contains() {
  local file="$1" text="$2"
  grep -Fq -- "${text}" "${file}" || fail "${file} does not contain: ${text}"
}

assert_file_not_contains() {
  local file="$1" text="$2"
  if grep -Fq -- "${text}" "${file}"; then fail "${file} unexpectedly contains: ${text}"; fi
}

export SAVEANY_DIR="${TEST_ROOT}/telegram"
export SAVEANY_BIN="${SAVEANY_DIR}/saveany-bot"
export SAVEANY_CONFIG="${SAVEANY_DIR}/config.toml"
export SAVEANY_SERVICE="${TEST_ROOT}/systemd/saveany-bot.service"
export OPENLIST_DIR="${TEST_ROOT}/openlist"
export OPENLIST_COMPOSE="${OPENLIST_DIR}/docker-compose.yml"
export STATE_FILE="${TEST_ROOT}/etc/saveanybot-manager.conf"
export BACKUP_ROOT="${TEST_ROOT}/backups"
export BACKUP_KEEP=5
export SAVEANY_READY_TIMEOUT=4
export OPENLIST_READY_ATTEMPTS=2
export OPENLIST_READY_INTERVAL=0
export TMPDIR="${TEST_ROOT}/tmp"
export SAVEANYBOT_MANAGER_SOURCE_ONLY=1
mkdir -p "${SAVEANY_DIR}" "$(dirname -- "${SAVEANY_SERVICE}")" "${OPENLIST_DIR}/data" \
  "$(dirname -- "${STATE_FILE}")" "${BACKUP_ROOT}" "${TMPDIR}"

# shellcheck source=../saveanybot-manager.sh
source "${REPO_DIR}/saveanybot-manager.sh"

EVENT_LOG="${TEST_ROOT}/events.log"
SERVICE_ACTIVE_FILE="${TEST_ROOT}/service.active"
SERVICE_ENABLED_FILE="${TEST_ROOT}/service.enabled"
BOT_READY_FILE="${TEST_ROOT}/bot.ready"
printf 'true\n' > "${SERVICE_ACTIVE_FILE}"
printf 'true\n' > "${SERVICE_ENABLED_FILE}"
: > "${EVENT_LOG}"

clear() { :; }
pause() { :; }
confirm() { return 0; }
sleep() { :; }
install_base_packages() { printf 'dependencies\n' >> "${EVENT_LOG}"; }
install_docker() { :; }
systemd-analyze() { return 0; }

install() {
  local mode='' source_file target_file
  if [[ "${1:-}" == '-d' ]]; then
    shift
    if [[ "${1:-}" == '-m' ]]; then mode="$2"; shift 2; fi
    mkdir -p -- "$@"
    return
  fi
  if [[ "${1:-}" == '-m' ]]; then mode="$2"; shift 2; fi
  source_file="$1"
  target_file="$2"
  cp -f -- "${source_file}" "${target_file}"
  [[ -z "${mode}" ]] || chmod "${mode}" "${target_file}" 2>/dev/null || true
}

systemctl() {
  local action="${1:-}" unit="${2:-}"
  case "${action}" in
    is-active) [[ "$(< "${SERVICE_ACTIVE_FILE}")" == true ]] ;;
    is-enabled) [[ "$(< "${SERVICE_ENABLED_FILE}")" == true ]] ;;
    stop)
      printf 'stop %s\n' "${unit}" >> "${EVENT_LOG}"
      printf 'false\n' > "${SERVICE_ACTIVE_FILE}"
      ;;
    start)
      printf 'start %s\n' "${unit}" >> "${EVENT_LOG}"
      printf 'true\n' > "${SERVICE_ACTIVE_FILE}"
      ;;
    enable)
      printf 'enable %s\n' "${unit}" >> "${EVENT_LOG}"
      printf 'true\n' > "${SERVICE_ENABLED_FILE}"
      ;;
    disable) printf 'false\n' > "${SERVICE_ENABLED_FILE}" ;;
    daemon-reload|reset-failed) : ;;
    *) : ;;
  esac
}

journalctl() {
  [[ -f "${BOT_READY_FILE}" ]] && printf 'Bot initialization completed.\n'
  return 0
}

download_saveanybot() {
  local _arch="$1" output_file="$2"
  printf 'candidate-ready\n' >> "${EVENT_LOG}"
  printf '#!/usr/bin/env bash\nnew binary\n' > "${output_file}"
  chmod 755 "${output_file}"
}

# SaveAnyBot failure after replacement restores all files and the exact service state.
printf '#!/usr/bin/env bash\nold binary\n' > "${SAVEANY_BIN}"
chmod 755 "${SAVEANY_BIN}"
printf 'old config\n' > "${SAVEANY_CONFIG}"
printf 'old service\n' > "${SAVEANY_SERVICE}"
printf 'old state\n' > "${STATE_FILE}"
rm -f -- "${BOT_READY_FILE}"
SAVEANY_FAILURE_LOG="${TEST_ROOT}/saveany-failure.log"
if install_saveanybot > "${SAVEANY_FAILURE_LOG}" 2>&1; then
  fail 'SaveAnyBot initialization failure was accepted'
fi
assert_file_contains "${SAVEANY_BIN}" 'old binary'
assert_eq 'old config' "$(< "${SAVEANY_CONFIG}")" 'SaveAnyBot config rollback'
assert_eq 'old service' "$(< "${SAVEANY_SERVICE}")" 'SaveAnyBot service rollback'
assert_eq 'old state' "$(< "${STATE_FILE}")" 'SaveAnyBot manager state rollback'
assert_eq true "$(< "${SERVICE_ACTIVE_FILE}")" 'SaveAnyBot active state rollback'
assert_eq true "$(< "${SERVICE_ENABLED_FILE}")" 'SaveAnyBot enabled state rollback'
candidate_line="$(grep -n '^candidate-ready$' "${EVENT_LOG}" | tail -n 1 | cut -d: -f1 || true)"
first_stop_line="$(grep -n '^stop saveany-bot$' "${EVENT_LOG}" | head -n 1 | cut -d: -f1 || true)"
[[ -n "${candidate_line}" && -n "${first_stop_line}" && ${candidate_line} -lt ${first_stop_line} ]] \
  || { sed -n '1,120p' "${SAVEANY_FAILURE_LOG}" >&2; fail 'old SaveAnyBot stopped before candidate preparation'; }

# A healthy initialization commits the new version.
: > "${EVENT_LOG}"
: > "${BOT_READY_FILE}"
install_saveanybot >/dev/null || fail 'healthy SaveAnyBot update failed'
assert_file_contains "${SAVEANY_BIN}" 'new binary'
assert_file_contains "${SAVEANY_SERVICE}" "ExecStart=${SAVEANY_BIN}"
assert_eq true "$(< "${SERVICE_ACTIVE_FILE}")" 'SaveAnyBot successful active state'

# Docker mock persists state through command substitutions and subshells.
DOCKER_EXISTS_FILE="${TEST_ROOT}/docker.exists"
DOCKER_RUNNING_FILE="${TEST_ROOT}/docker.running"
DOCKER_IMAGE_FILE="${TEST_ROOT}/docker.image"
DOCKER_IMAGE_REF_FILE="${TEST_ROOT}/docker.image-ref"
DOCKER_TAG_IMAGE_FILE="${TEST_ROOT}/docker.tag-image"
DOCKER_BACKUP_TAG_FILE="${TEST_ROOT}/docker.backup-tag"
DOCKER_BACKUP_IMAGE_FILE="${TEST_ROOT}/docker.backup-image"
DOCKER_FAIL_UP_ONCE="${TEST_ROOT}/docker.fail-up-once"
printf 'true\n' > "${DOCKER_EXISTS_FILE}"
printf 'true\n' > "${DOCKER_RUNNING_FILE}"
printf 'sha256:old\n' > "${DOCKER_IMAGE_FILE}"
printf 'openlistteam/openlist:latest\n' > "${DOCKER_IMAGE_REF_FILE}"
printf 'sha256:old\n' > "${DOCKER_TAG_IMAGE_FILE}"

docker() {
  local command="${1:-}" source_ref target_ref template
  shift || true
  case "${command}" in
    inspect)
      if [[ "${1:-}" == '-f' ]]; then
        template="$2"
        case "${template}" in
          *State.Running*) cat "${DOCKER_RUNNING_FILE}" ;;
          *Config.Image*) cat "${DOCKER_IMAGE_REF_FILE}" ;;
          *Image*) cat "${DOCKER_IMAGE_FILE}" ;;
          *) return 1 ;;
        esac
      else
        [[ "$(< "${DOCKER_EXISTS_FILE}")" == true ]]
      fi
      ;;
    tag)
      source_ref="$1"
      target_ref="$2"
      if [[ "${source_ref}" == sha256:* ]]; then
        printf '%s\n' "${source_ref}" > "${DOCKER_BACKUP_IMAGE_FILE}"
        printf '%s\n' "${target_ref}" > "${DOCKER_BACKUP_TAG_FILE}"
      else
        assert_eq "$(< "${DOCKER_BACKUP_TAG_FILE}")" "${source_ref}" 'OpenList rollback backup tag'
        cat "${DOCKER_BACKUP_IMAGE_FILE}" > "${DOCKER_TAG_IMAGE_FILE}"
      fi
      ;;
    rm)
      printf 'false\n' > "${DOCKER_EXISTS_FILE}"
      printf 'false\n' > "${DOCKER_RUNNING_FILE}"
      ;;
    image) return 0 ;;
    compose)
      case "${1:-}" in
        version) return 0 ;;
        -f) return 0 ;;
        pull)
          printf 'sha256:new\n' > "${DOCKER_TAG_IMAGE_FILE}"
          return 0
          ;;
        up)
          if [[ -f "${DOCKER_FAIL_UP_ONCE}" ]]; then
            rm -f -- "${DOCKER_FAIL_UP_ONCE}"
            printf 'true\n' > "${DOCKER_EXISTS_FILE}"
            printf 'false\n' > "${DOCKER_RUNNING_FILE}"
            printf 'sha256:new\n' > "${DOCKER_IMAGE_FILE}"
            return 1
          fi
          printf 'true\n' > "${DOCKER_EXISTS_FILE}"
          printf 'true\n' > "${DOCKER_RUNNING_FILE}"
          cat "${DOCKER_TAG_IMAGE_FILE}" > "${DOCKER_IMAGE_FILE}"
          return 0
          ;;
        create)
          printf 'true\n' > "${DOCKER_EXISTS_FILE}"
          printf 'false\n' > "${DOCKER_RUNNING_FILE}"
          cat "${DOCKER_TAG_IMAGE_FILE}" > "${DOCKER_IMAGE_FILE}"
          return 0
          ;;
      esac
      ;;
    logs|exec|ps) return 0 ;;
    *) return 0 ;;
  esac
}

printf 'old compose\n' > "${OPENLIST_COMPOSE}"
printf 'old manager state\n' > "${STATE_FILE}"
openlist_stage="$(mktemp -d "${TMPDIR}/openlist-stage.XXXXXXXX")"
# shellcheck disable=SC2034
OPENLIST_PORT=5244
write_openlist_compose "${openlist_stage}/docker-compose.yml"
assert_file_contains "${openlist_stage}/docker-compose.yml" 'driver: "json-file"'
assert_file_contains "${openlist_stage}/docker-compose.yml" 'max-size: "10m"'
assert_file_contains "${openlist_stage}/docker-compose.yml" 'max-file: "3"'
openlist_backup="$(create_openlist_transaction_backup)" || fail 'OpenList transaction backup failed'
activate_update_transaction OpenList "${openlist_backup}" "${openlist_stage}"
: > "${DOCKER_FAIL_UP_ONCE}"
if commit_openlist_update "${openlist_stage}/docker-compose.yml" true; then
  fail 'failed OpenList container update was accepted'
fi
rollback_active_update_transaction 1 || true
assert_eq 'old compose' "$(< "${OPENLIST_COMPOSE}")" 'OpenList Compose rollback'
assert_eq 'old manager state' "$(< "${STATE_FILE}")" 'OpenList state rollback'
assert_eq true "$(< "${DOCKER_EXISTS_FILE}")" 'OpenList container existence rollback'
assert_eq true "$(< "${DOCKER_RUNNING_FILE}")" 'OpenList running state rollback'
assert_eq 'sha256:old' "$(< "${DOCKER_IMAGE_FILE}")" 'OpenList image rollback'

# WebDAV tests use a private curl config and private response files; credentials
# never appear in curl arguments and every temporary file is removed on return.
CURL_EVENT_LOG="${TEST_ROOT}/curl-events.log"
: > "${CURL_EVENT_LOG}"
curl() {
  local method='' output_file='' config_file='' argument previous=''
  for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${CURL_EVENT_LOG}"
    if [[ "${previous}" == '--config' ]]; then config_file="${argument}"; fi
    if [[ "${previous}" == '-o' ]]; then output_file="${argument}"; fi
    if [[ "${previous}" == '-X' ]]; then method="${argument}"; fi
    [[ "${argument}" == '-T' ]] && method='PUT'
    previous="${argument}"
  done
  [[ -f "${config_file}" ]] || fail 'curl credential config missing during WebDAV test'
  assert_eq 600 "$(stat -c '%a' "${config_file}")" 'curl credential config mode'
  [[ -z "${output_file}" ]] || : > "${output_file}"
  case "${method}" in
    PROPFIND) printf '207' ;;
    PUT) printf '201' ;;
    DELETE) : ;;
    *) return 1 ;;
  esac
}

test_webdav 'http://127.0.0.1:5244/dav/' 'webuser' 'top-secret' >/dev/null \
  || fail 'secure WebDAV test failed'
assert_file_not_contains "${CURL_EVENT_LOG}" 'top-secret'
assert_file_not_contains "${REPO_DIR}/saveanybot-manager.sh" '/tmp/saveanybot-propfind.xml'
assert_file_not_contains "${REPO_DIR}/saveanybot-manager.sh" '/tmp/saveanybot-put.txt'
assert_file_not_contains "${REPO_DIR}/saveanybot-manager.sh" '--user "${username}:${password}"'
if find "${TMPDIR}" -mindepth 1 -maxdepth 1 -type d -name 'saveanybot-webdav.*' | grep -q .; then
  fail 'WebDAV private temporary directory was not cleaned'
fi

printf 'PASS: saveanybot-manager.sh A19 regression tests\n'
