#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/iptables-forward-test.XXXXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export IPTABLES_FORWARD_SOURCE_ONLY=1
export IPTABLES_FORWARD_BACKUP_ROOT="$TEST_ROOT/backups"
export IPTABLES_FORWARD_BACKUP_KEEP=5

# shellcheck source=../iptables.sh disable=SC1091
. "$REPO_DIR/iptables.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" message="${3:-values differ}"
    [[ "$actual" == "$expected" ]] || fail "$message: expected [$expected], got [$actual]"
}

assert_contains_text() {
    [[ "$1" == *"$2"* ]] || fail "text does not contain: $2"
}

assert_file_contains() {
    grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

assert_file_not_contains() {
    if grep -Fq -- "$2" "$1"; then
        fail "$1 unexpectedly contains: $2"
    fi
}

declare -A FAKE_RULES=()
FAKE_IPTABLES_FAIL_MATCH=""
FAKE_RESTORE_TEST_FAIL=0
FAKE_RESTORE_APPLY_FAIL_ONCE=0
FAKE_PERSIST_FAIL_ONCE=0

fake_rule_key() {
    printf '%s|%s|%s' "$1" "$2" "$3"
}

iptables() {
    local table=filter action chain key rule
    if [[ "${1:-}" == -t ]]; then
        table="$2"
        shift 2
    fi
    action="${1:-}"
    shift || true
    case "$action" in
        -A|-C|-D)
            chain="${1:-}"
            shift || true
            rule="$*"
            key=$(fake_rule_key "$table" "$chain" "$rule")
            ;;
        -S)
            chain="${1:-}"
            while IFS= read -r key; do
                [[ -n "$key" ]] || continue
                IFS='|' read -r table_part chain_part rule_part <<< "$key"
                [[ "$table_part" == "$table" ]] || continue
                [[ -z "$chain" || "$chain_part" == "$chain" ]] || continue
                printf -- '-A %s %s\n' "$chain_part" "$rule_part"
            done < <(printf '%s\n' "${!FAKE_RULES[@]}" | sort)
            return 0
            ;;
        *)
            fail "unexpected iptables invocation: $action $*"
            ;;
    esac

    case "$action" in
        -C) [[ -v 'FAKE_RULES[$key]' ]] ;;
        -A)
            if [[ -n "$FAKE_IPTABLES_FAIL_MATCH" && "$key" == *"$FAKE_IPTABLES_FAIL_MATCH"* ]]; then
                FAKE_IPTABLES_FAIL_MATCH=""
                return 1
            fi
            FAKE_RULES["$key"]=1
            ;;
        -D)
            [[ -v 'FAKE_RULES[$key]' ]] || return 1
            unset 'FAKE_RULES[$key]'
            ;;
    esac
}

iptables-save() {
    local table key table_part chain_part rule_part
    for table in filter nat; do
        printf '*%s\n' "$table"
        if [[ "$table" == filter ]]; then
            printf ':FORWARD ACCEPT [0:0]\n'
        else
            printf ':PREROUTING ACCEPT [0:0]\n:POSTROUTING ACCEPT [0:0]\n'
        fi
        while IFS= read -r key; do
            [[ -n "$key" ]] || continue
            IFS='|' read -r table_part chain_part rule_part <<< "$key"
            [[ "$table_part" == "$table" ]] || continue
            printf -- '-A %s %s\n' "$chain_part" "$rule_part"
        done < <(printf '%s\n' "${!FAKE_RULES[@]}" | sort)
        printf 'COMMIT\n'
    done
}

iptables-restore() {
    local test_only=0 input line table="" action chain rule
    local -A restored_rules=()
    for action in "$@"; do
        [[ "$action" == --test ]] && test_only=1
    done
    input=$(command cat)
    if ((test_only)); then
        ((FAKE_RESTORE_TEST_FAIL == 0)) || return 1
        [[ "$input" == *'*filter'* && "$input" == *'*nat'* && "$input" == *'COMMIT'* ]]
        return
    fi
    if ((FAKE_RESTORE_APPLY_FAIL_ONCE)); then
        FAKE_RESTORE_APPLY_FAIL_ONCE=0
        FAKE_RULES=()
        FAKE_RULES["filter|FORWARD|-p tcp -j DROP"]=1
        return 1
    fi
    while IFS= read -r line; do
        case "$line" in
            \**) table="${line#\*}" ;;
            -A\ *)
                action="${line#-A }"
                chain="${action%% *}"
                rule="${action#* }"
                restored_rules["$(fake_rule_key "$table" "$chain" "$rule")"]=1
                ;;
        esac
    done <<< "$input"
    FAKE_RULES=()
    for action in "${!restored_rules[@]}"; do
        FAKE_RULES["$action"]=1
    done
}

netfilter-persistent() {
    [[ "${1:-}" == save ]] || fail "unexpected netfilter-persistent invocation: $*"
    if ((FAKE_PERSIST_FAIL_ONCE)); then
        FAKE_PERSIST_FAIL_ONCE=0
        return 1
    fi
}

reset_fake_rules() {
    FAKE_RULES=()
    FAKE_IPTABLES_FAIL_MATCH=""
    FAKE_RESTORE_TEST_FAIL=0
    FAKE_RESTORE_APPLY_FAIL_ONCE=0
    FAKE_PERSIST_FAIL_ONCE=0
}

remove_fake_rule_matching() {
    local pattern="$1" key
    for key in "${!FAKE_RULES[@]}"; do
        if [[ "$key" == *"$pattern"* ]]; then
            unset 'FAKE_RULES[$key]'
            return 0
        fi
    done
    return 1
}

# Strict address and port validation rejects values that could alter commands.
is_valid_ipv4 0.0.0.0
is_valid_ipv4 203.0.113.9
for invalid_ip in 256.1.1.1 1.2.3 '1.2.3.4;reboot' 1.2.3.-1 01.2.3.4; do
    if is_valid_ipv4 "$invalid_ip"; then fail "invalid IPv4 accepted: $invalid_ip"; fi
done
validate_port 1
validate_port 65535
for invalid_port in 0 65536 22.5 '80;reboot'; do
    if validate_port "$invalid_port"; then fail "invalid port accepted: $invalid_port"; fi
done

# The same logical forwarding tuple always receives the same ownership ID.
rule_id=$(forward_rule_id tcp 8080 203.0.113.8 443)
assert_eq 8c8d3c50d29ce79a "$rule_id" "forwarding group ID changed unexpectedly"

# A managed TCP forwarding group consists of DNAT, MASQUERADE, and two stateful
# FORWARD rules. It must never pin SNAT to a guessed interface address.
reset_fake_rules
add_forward_rule tcp 8080 203.0.113.8 443 >/dev/null
assert_eq 4 "${#FAKE_RULES[@]}" "managed TCP group size"
forward_group_complete tcp 8080 203.0.113.8 443 || fail "new TCP group is incomplete"
saved_rules=$(iptables-save)
assert_contains_text "$saved_rules" 'MASQUERADE'
comment_base="$RULE_COMMENT_PREFIX:$rule_id:tcp:8080:203.0.113.8:443"
assert_contains_text "$saved_rules" "$comment_base:dnat"
assert_contains_text "$saved_rules" "$comment_base:masquerade"
assert_contains_text "$saved_rules" "$comment_base:forward"
assert_contains_text "$saved_rules" "$comment_base:return"
if [[ "$saved_rules" == *'SNAT'* || "$saved_rules" == *'--to-source'* ]]; then
    fail "managed forwarding group still uses fixed-source SNAT"
fi

# Re-running the operation repairs an incomplete owned group instead of treating
# the DNAT rule alone as proof that the entire forwarding setup exists.
remove_fake_rule_matching ":return" || fail "could not remove return rule from fake state"
if forward_group_complete tcp 8080 203.0.113.8 443; then
    fail "incomplete group was reported as complete"
fi
add_forward_rule tcp 8080 203.0.113.8 443 >/dev/null
assert_eq 4 "${#FAKE_RULES[@]}" "repair did not recreate exactly one complete group"
forward_group_complete tcp 8080 203.0.113.8 443 || fail "repaired group is incomplete"

# Deletion removes every rule belonging to the logical group.
delete_forward_rule tcp 8080 203.0.113.8 443 >/dev/null
assert_eq 0 "${#FAKE_RULES[@]}" "group deletion left orphaned rules"

# A mid-add failure restores unrelated rules and leaves no partial group behind.
reset_fake_rules
FAKE_RULES["filter|FORWARD|-p icmp -j ACCEPT"]=1
before_failure=$(iptables-save)
FAKE_IPTABLES_FAIL_MATCH=":return"
if add_forward_rule tcp 8080 203.0.113.8 443 >/dev/null; then
    fail "injected rule-add failure was ignored"
fi
after_failure=$(iptables-save)
assert_eq "$before_failure" "$after_failure" "failed add did not restore original rules"

# TCP+UDP is one transaction: failure while creating UDP also removes the TCP
# group created earlier in the same operation.
reset_fake_rules
FAKE_RULES["filter|FORWARD|-p icmp -j ACCEPT"]=1
before_both_failure=$(iptables-save)
FAKE_IPTABLES_FAIL_MATCH='nat|PREROUTING|-p udp'
if add_forward_rule both 8443 203.0.113.9 443 >/dev/null; then
    fail "injected TCP+UDP transaction failure was ignored"
fi
assert_eq "$before_both_failure" "$(iptables-save)" "TCP+UDP failure left a partial protocol group"

# Every owned rule carries enough signed metadata to find an incomplete group,
# even when its DNAT entry is missing. Similar unowned and forged DNAT rules
# remain visible to iptables itself but outside this script's control.
reset_fake_rules
add_forward_rule udp 5353 198.51.100.7 53 >/dev/null
remove_fake_rule_matching ':dnat' || fail "could not remove DNAT rule from fake state"
iptables -t nat -A PREROUTING -p tcp --dport 9000 -j DNAT --to-destination 192.0.2.10:9001
iptables -t nat -A PREROUTING -p tcp --dport 9002 -m comment --comment "$RULE_COMMENT_PREFIX:0000000000000000:tcp:9002:192.0.2.11:9003:dnat" -j DNAT --to-destination 192.0.2.11:9003
mapfile -t managed_records < <(list_managed_forward_records)
assert_eq 1 "${#managed_records[@]}" "unowned or forged DNAT rule was claimed"
assert_contains_text "${managed_records[0]}" $'udp\t5353\t198.51.100.7\t53'
delete_forward_rule udp 5353 198.51.100.7 53 >/dev/null
mapfile -t managed_records < <(list_managed_forward_records)
assert_eq 0 "${#managed_records[@]}" "deletion left owned rules from incomplete group"

# A restore target must pass preflight before the current firewall is backed up
# or changed.
invalid_restore="$TEST_ROOT/invalid.rules"
printf 'not an iptables ruleset\n' > "$invalid_restore"
before_invalid_restore=$(iptables-save)
FAKE_RESTORE_TEST_FAIL=1
if restore_rules_from_file "$invalid_restore" >/dev/null; then
    fail "invalid restore target was accepted"
fi
FAKE_RESTORE_TEST_FAIL=0
assert_eq "$before_invalid_restore" "$(iptables-save)" "preflight failure changed current rules"

# A target that fails while being applied rolls back to the exact pre-restore
# rules, while retaining a private recovery snapshot.
target_restore="$TEST_ROOT/target.rules"
reset_fake_rules
FAKE_RULES["filter|FORWARD|-p tcp --dport 22 -j ACCEPT"]=1
before_apply_failure=$(iptables-save)
printf '%s\n' '*filter' ':FORWARD ACCEPT [0:0]' '-A FORWARD -p udp --dport 53 -j ACCEPT' 'COMMIT' '*nat' ':PREROUTING ACCEPT [0:0]' ':POSTROUTING ACCEPT [0:0]' 'COMMIT' > "$target_restore"
FAKE_RESTORE_APPLY_FAIL_ONCE=1
if restore_rules_from_file "$target_restore" >/dev/null; then
    fail "injected restore-apply failure was ignored"
fi
assert_eq "$before_apply_failure" "$(iptables-save)" "failed restore did not recover pre-restore rules"
backup_count=$(find "$IPTABLES_FORWARD_BACKUP_ROOT" -type f -name 'transaction.pre-restore.*.rules' | wc -l | tr -d '[:space:]')
((backup_count >= 1)) || fail "pre-restore recovery snapshot was not retained"

# A valid target is applied and persisted, and transaction retention is capped.
restore_rules_from_file "$target_restore" >/dev/null
restored_state=$(iptables-save)
assert_contains_text "$restored_state" '-p udp --dport 53 -j ACCEPT'
if [[ "$restored_state" == *'--dport 22'* ]]; then fail "valid restore did not replace old rules"; fi
for backup_index in 1 2 3 4 5 6 7; do
    create_runtime_backup "retention-$backup_index" >/dev/null
done
backup_count=$(find "$IPTABLES_FORWARD_BACKUP_ROOT" -type f -name 'transaction.*.rules' | wc -l | tr -d '[:space:]')
assert_eq 5 "$backup_count" "transaction backup retention"

# Static regression checks for the safety properties covered by A11.
assert_file_not_contains "$REPO_DIR/iptables.sh" '--to-source'
assert_file_contains "$REPO_DIR/iptables.sh" 'iptables-restore --test'
assert_file_contains "$REPO_DIR/iptables.sh" "restore_runtime_backup \"\$transaction_backup\""
assert_file_contains "$REPO_DIR/iptables.sh" 'IPTABLES_FORWARD_SOURCE_ONLY'

printf 'PASS: iptables forwarding group and restore safety tests\n'
