#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/new_vps_xray.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    [[ "$1" == "$2" ]] || fail "$3 (expected '$2', got '$1')"
}

assert_true() {
    "$@" || fail "$*"
}

mapfile -t AUTO_PORTS < <(auto_port_candidates)
assert_eq "${#AUTO_PORTS[@]}" "19" "automatic port candidate count"
for port in "${AUTO_PORTS[@]}"; do
    [[ "$port" != "443" ]] || fail "automatic port selection must skip 443"
done

EXPLICIT="443,8443,8080,2096,2053,2083,2087,2095,8444,8445,8446,8447"
assert_true parse_port_list "$EXPLICIT"
assert_eq "${SELECTED_PORTS[0]}" "443" "explicit 443 must be accepted"
assert_eq "${#SELECTED_PORTS[@]}" "12" "explicit port count"
if parse_port_list "443,443,8080,2096,2053,2083,2087,2095,8444,8445,8446,8447"; then
    fail "duplicate explicit ports must be rejected"
fi
if parse_port_list "443,0443,8080,2096,2053,2083,2087,2095,8444,8445,8446,8447"; then
    fail "ports with alternate decimal spelling must still be treated as duplicates"
fi
if parse_port_list "443,8443"; then
    fail "explicit lists shorter than 12 ports must be rejected"
fi

SELECTED_PORTS=(443 8443 8080 2096 2053 2083 2087 2095 8444 8445 8446 8447)
write_service_unit "$TMP_DIR/ezxray.service"
SERVICE_TEXT="$(< "$TMP_DIR/ezxray.service")"
[[ $SERVICE_TEXT == *'User=ezxray'* ]] || fail "service must run as the dedicated account"
[[ $SERVICE_TEXT == *'Group=ezxray'* ]] || fail "service must run with the dedicated group"
[[ $SERVICE_TEXT == *'Environment=GOMAXPROCS=1'* ]] || fail "service must use one Go scheduler thread on a one-CPU VPS"
[[ $SERVICE_TEXT == *'AmbientCapabilities=CAP_NET_BIND_SERVICE'* ]] || fail "low explicit ports need only the bind-service capability"
[[ $SERVICE_TEXT == *'NoNewPrivileges=true'* ]] || fail "service must prevent privilege escalation"
if command -v systemd-analyze >/dev/null 2>&1; then
    python3 - "$TMP_DIR/ezxray.service" <<'PY'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    lines = source.readlines()
with open(path, "w", encoding="utf-8") as output:
    for line in lines:
        if line.startswith("User=") or line.startswith("Group="):
            line = line.split("=", 1)[0] + "=root\n"
        elif line.startswith("ExecStart="):
            line = "ExecStart=/usr/bin/true\n"
        output.write(line)
PY
    systemd-analyze verify "$TMP_DIR/ezxray.service" || fail "systemd rejected the generated unit directives"
fi
SELECTED_PORTS=(8443 8080 2096 2053 2083 2087 2095 8444 8445 8446 8447 8448)
write_service_unit "$TMP_DIR/ezxray-high-ports.service"
SERVICE_TEXT="$(< "$TMP_DIR/ezxray-high-ports.service")"
[[ $SERVICE_TEXT != *'CAP_NET_BIND_SERVICE'* ]] || fail "high ports must not request extra capabilities"

SERVICE_STATE_LOG="$TMP_DIR/service-state.log"
systemctl() { printf '%s\n' "$*" >> "$SERVICE_STATE_LOG"; }
RECONFIGURE=true
SERVICE_WAS_ACTIVE=false
SERVICE_WAS_ENABLED=true
reload_service_for_current_mode
[[ "$(< "$SERVICE_STATE_LOG")" == "daemon-reload" ]] || fail "inactive enabled service must remain inactive and enabled during reconfigure"
: > "$SERVICE_STATE_LOG"
SERVICE_WAS_ACTIVE=true
SERVICE_WAS_ENABLED=false
reload_service_for_current_mode
[[ "$(< "$SERVICE_STATE_LOG")" == $'daemon-reload\nrestart ezxray.service' ]] || fail "active disabled service must restart without changing enablement"
: > "$SERVICE_STATE_LOG"
RECONFIGURE=false
reload_service_for_current_mode
[[ "$(< "$SERVICE_STATE_LOG")" == $'daemon-reload\nenable --now ezxray.service' ]] || fail "first install must enable and start the service"
unset -f systemctl

MARKER_PATH="$TMP_DIR/noop/managed"
STATE_PATH="$TMP_DIR/noop/state.json"
XRAY_CONFIG_PATH="$TMP_DIR/noop/config.json"
PROFILE_PATH="$TMP_DIR/noop/profiles.txt"
SERVICE_PATH="$TMP_DIR/noop/ezxray.service"
XRAY_BIN="$TMP_DIR/noop/xray"
TLS_CERT_MANAGED_PATH="$TMP_DIR/noop/fullchain.pem"
TLS_KEY_MANAGED_PATH="$TMP_DIR/noop/privkey.pem"
NOOP_TARGETS=("$MARKER_PATH" "$STATE_PATH" "$XRAY_CONFIG_PATH" "$PROFILE_PATH" "$SERVICE_PATH" "$XRAY_BIN" "$TLS_CERT_MANAGED_PATH" "$TLS_KEY_MANAGED_PATH")
for target in "${NOOP_TARGETS[@]}"; do
    mkdir -p "$(dirname "$target")"
    printf 'preserve:%s\n' "$target" > "$target"
    cp "$target" "$target.expected"
done
systemctl() { fail "ordinary rerun must not call systemctl"; }
ufw() { fail "ordinary rerun must not change UFW"; }
apt-get() { fail "ordinary rerun must not install or update packages"; }
NOOP_OUTPUT="$(main)"
[[ $NOOP_OUTPUT != *'Client configurations'* ]] || fail "ordinary rerun must not print client configs"
for target in "${NOOP_TARGETS[@]}"; do
    cmp -s "$target" "$target.expected" || fail "ordinary rerun changed $target"
done
unset -f systemctl ufw apt-get

# UFW is installed through the existing Debian/Ubuntu dependency path.
mkdir -p "$TMP_DIR/mock-bin"
cat > "$TMP_DIR/mock-bin/apt-get" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$APT_GET_LOG"
EOF
chmod +x "$TMP_DIR/mock-bin/apt-get"
APT_GET_LOG="$TMP_DIR/apt-get.log"
export APT_GET_LOG
ORIGINAL_PATH=$PATH
PATH="$TMP_DIR/mock-bin"
export PATH
ensure_dependencies > "$TMP_DIR/dependencies.log"
PATH=$ORIGINAL_PATH
export PATH
[[ "$(< "$APT_GET_LOG")" == *'install -y --no-install-recommends'*'ufw'* ]] || fail "missing UFW must be installed through apt-get"

UFW_LOG="$TMP_DIR/ufw.log"
TEST_UFW_STATUS=active
TEST_UFW_FAIL_RULE=
TEST_UFW_ENABLE_FAIL=false
TEST_OTHER_FIREWALL_ACTIVE=false
TEST_VIRT=none
TEST_SSHD_CONFIG=$'port 2200\nport 2222'
ufw() {
    printf '%s\n' "$*" >> "$UFW_LOG"
    if [[ $1 == status ]]; then
        printf 'Status: %s\n' "$TEST_UFW_STATUS"
        return 0
    fi
    if [[ $1 == --force && $2 == enable ]]; then
        [[ $TEST_UFW_ENABLE_FAIL != true ]]
        return
    fi
    [[ ${TEST_UFW_FAIL_RULE:-} != "${3:-}" ]]
}
systemd-detect-virt() { printf '%s\n' "$TEST_VIRT"; }
sshd() { [[ $1 == -T ]] && printf '%s\n' "$TEST_SSHD_CONFIG"; }
systemctl() {
    [[ $1 == is-active && ${3:-} == firewalld.service && $TEST_OTHER_FIREWALL_ACTIVE == true ]]
}
assert_ufw_log_has() {
    grep -Fqx -- "$1" "$UFW_LOG" || fail "expected UFW command '$1'"
}
assert_ufw_log_lacks() {
    if grep -Fqx -- "$1" "$UFW_LOG"; then
        fail "unexpected UFW command '$1'"
    fi
}
assert_firewall_setup_fails() {
    local output_file=$1 status
    if open_firewall_if_available > "$output_file" 2>&1; then
        fail "firewall setup should have returned a failure status"
    else
        status=$?
        [[ $status -eq 1 ]] || fail "firewall setup should return status 1 on incomplete setup"
    fi
}

SELECTED_PORTS=(443 8443 8080 2096 2053 2083 2087 2095 8444 8445 8446 8447)
SSH_CONNECTION='198.51.100.10 51000 203.0.113.4 2222'
: > "$UFW_LOG"
open_firewall_if_available > "$TMP_DIR/ufw-active.log"
for port in "${SELECTED_PORTS[@]}" 53; do
    assert_ufw_log_has "allow in $port/tcp"
    assert_ufw_log_has "allow in $port/udp"
done
assert_ufw_log_lacks 'allow in 2222/tcp'
assert_ufw_log_lacks '--force enable'
assert_ufw_log_lacks 'reset'
assert_ufw_log_lacks 'default deny incoming'
[[ $(grep -c '^allow in ' "$UFW_LOG") -eq 26 ]] || fail "active UFW should receive one TCP and UDP rule per unique requested port"

TEST_UFW_STATUS=inactive
: > "$UFW_LOG"
open_firewall_if_available > "$TMP_DIR/ufw-inactive.log" 2>&1
assert_ufw_log_has 'allow in 2222/tcp'
assert_ufw_log_has 'allow in 2200/tcp'
assert_ufw_log_has '--force enable'
[[ "$(< "$TMP_DIR/ufw-inactive.log")" == *'existing default policy to all inbound traffic'* ]] || fail "enabling inactive UFW must warn that existing defaults apply to all inbound traffic"
SSH_RULE_LINE=$(grep -n -F 'allow in 2222/tcp' "$UFW_LOG" | cut -d: -f1)
FIRST_XRAY_RULE_LINE=$(grep -n -F 'allow in 443/tcp' "$UFW_LOG" | cut -d: -f1)
ENABLE_RULE_LINE=$(grep -n -F -- '--force enable' "$UFW_LOG" | cut -d: -f1)
((SSH_RULE_LINE < FIRST_XRAY_RULE_LINE && FIRST_XRAY_RULE_LINE < ENABLE_RULE_LINE)) || fail "SSH must be allowed before Xray rules and UFW activation"

unset SSH_CONNECTION
TEST_SSHD_CONFIG=
: > "$UFW_LOG"
assert_firewall_setup_fails "$TMP_DIR/ufw-no-ssh.log"
assert_ufw_log_lacks '--force enable'
[[ "$(< "$TMP_DIR/ufw-no-ssh.log")" == *'UFW will remain inactive'* ]] || fail "unknown SSH port must prevent enabling UFW"
assert_ufw_log_has 'allow in 53/tcp'
assert_ufw_log_has 'allow in 53/udp'

SSH_CONNECTION='198.51.100.10 51000 203.0.113.4 2222'
TEST_UFW_FAIL_RULE=53/udp
: > "$UFW_LOG"
assert_firewall_setup_fails "$TMP_DIR/ufw-rule-fail.log"
assert_ufw_log_lacks '--force enable'
[[ "$(< "$TMP_DIR/ufw-rule-fail.log")" == *'some requested UFW rules could not be added'* ]] || fail "UFW must not enable when requested rules fail"

TEST_UFW_FAIL_RULE=
TEST_UFW_ENABLE_FAIL=true
TEST_VIRT=lxc
: > "$UFW_LOG"
assert_firewall_setup_fails "$TMP_DIR/ufw-lxc-fail.log"
assert_ufw_log_has '--force enable'
[[ "$(< "$TMP_DIR/ufw-lxc-fail.log")" == *'enabling UFW failed'* ]] || fail "failed UFW activation must be reported"
[[ "$(< "$TMP_DIR/ufw-lxc-fail.log")" == *'host/provider'* ]] || fail "container must report host/provider firewall requirements"

TEST_UFW_ENABLE_FAIL=false
TEST_VIRT=none
TEST_OTHER_FIREWALL_ACTIVE=true
: > "$UFW_LOG"
assert_firewall_setup_fails "$TMP_DIR/ufw-other-manager.log"
assert_ufw_log_lacks '--force enable'
[[ "$(< "$TMP_DIR/ufw-other-manager.log")" == *'avoid competing firewall managers'* ]] || fail "another active firewall manager must prevent enabling UFW"
unset -f ufw systemd-detect-virt sshd

DOMAIN="vpn.example.test"
TLS_CERT="/etc/ssl/example/fullchain.pem"
TLS_KEY="/etc/ssl/example/privkey.pem"
SELECTED_PORTS=(443 8443 8080 2096 2053 2083 2087 2095 8444 8445 8446 8447)
VLESS_UUIDS=(11111111-1111-4111-8111-111111111111 22222222-2222-4222-8222-222222222222 33333333-3333-4333-8333-333333333333)
VMESS_UUIDS=(44444444-4444-4444-8444-444444444444 55555555-5555-4555-8555-555555555555 66666666-6666-4666-8666-666666666666)
TROJAN_PASSWORDS=(trojan-one trojan-two trojan-three)
SS_PASSWORDS=(shadowsocks-one shadowsocks-two shadowsocks-three)

write_render_spec "$TMP_DIR/spec"
render_artifacts "$TMP_DIR/config.json" "$TMP_DIR/profiles.txt" "$TMP_DIR/state.json" "$TMP_DIR/spec"
PROFILE_PATH="$TMP_DIR/profiles.txt"
print_profiles > "$TMP_DIR/printed-profiles.txt"
python3 - "$TMP_DIR/profiles.txt" "$TMP_DIR/printed-profiles.txt" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    profiles = [line.rstrip("\n") for line in source]
with open(sys.argv[2], encoding="utf-8") as source:
    printed = source.read()

protocols = ("VLESS", "VMess", "Trojan", "Shadowsocks")
assert "Client configurations (12 total)" in printed
assert len(profiles) == 12
for protocol in protocols:
    assert f"\n{protocol}\n" in printed
for profile in profiles:
    label, link = profile.split(": ", 1)
    assert f"  {label}\n    {link}\n" in printed, label
links = re.findall(r"^    (?:vless|vmess|trojan|ss)://\S+$", printed, re.MULTILINE)
assert len(links) == 12, len(links)
PY

python3 - "$TMP_DIR/config.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    config = json.load(f)
inbounds = config["inbounds"]
assert len(inbounds) == 12, len(inbounds)
assert len({item["port"] for item in inbounds}) == 12
assert inbounds[0]["port"] == 443
counts = {name: 0 for name in ("vless", "vmess", "trojan", "shadowsocks")}
for item in inbounds:
    protocol = item["protocol"]
    counts[protocol] += 1
    if protocol in ("vless", "vmess", "trojan"):
        stream = item["streamSettings"]
        assert stream["network"] == "ws"
        assert stream["security"] == "tls"
        assert stream["wsSettings"]["path"] == "/ws"
        if protocol == "vless":
            assert "flow" not in item["settings"]["clients"][0]
assert counts == {"vless": 3, "vmess": 3, "trojan": 3, "shadowsocks": 3}, counts
PY

[[ "$(wc -l < "$TMP_DIR/profiles.txt")" -eq 12 ]] || fail "expected 12 profile links"
python3 - "$TMP_DIR/state.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    state = json.load(f)
assert state["ports"][0] == 443
assert len(state["ports"]) == 12
assert state["schema"] == 1
PY

point_config_to_managed_tls "$TMP_DIR/config.json"
python3 - "$TMP_DIR/config.json" "$TLS_CERT_MANAGED_PATH" "$TLS_KEY_MANAGED_PATH" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    config = json.load(f)
for inbound in config["inbounds"]:
    tls = inbound.get("streamSettings", {}).get("tlsSettings")
    if tls:
        certificate = tls["certificates"][0]
        assert certificate["certificateFile"] == sys.argv[2]
        assert certificate["keyFile"] == sys.argv[3]
PY

ROLLBACK_ROOT="$TMP_DIR/rollback"
XRAY_CONFIG_PATH="$ROLLBACK_ROOT/xray/config.json"
PROFILE_PATH="$ROLLBACK_ROOT/root/profiles.txt"
STATE_PATH="$ROLLBACK_ROOT/etc/state.json"
MARKER_PATH="$ROLLBACK_ROOT/etc/managed"
SERVICE_PATH="$ROLLBACK_ROOT/systemd/ezxray.service"
XRAY_BIN="$ROLLBACK_ROOT/lib/xray"
TLS_CERT_MANAGED_PATH="$ROLLBACK_ROOT/etc/fullchain.pem"
TLS_KEY_MANAGED_PATH="$ROLLBACK_ROOT/etc/privkey.pem"
BACKUP_DIR="$ROLLBACK_ROOT/backup"
mkdir -p "$BACKUP_DIR"
ROLLBACK_TARGETS=("$XRAY_CONFIG_PATH" "$PROFILE_PATH" "$STATE_PATH" "$MARKER_PATH" "$SERVICE_PATH" "$XRAY_BIN" "$TLS_CERT_MANAGED_PATH" "$TLS_KEY_MANAGED_PATH")
for target in "${ROLLBACK_TARGETS[@]}"; do
    mkdir -p "$(dirname "$target")"
    printf 'old:%s\n' "$target" > "$BACKUP_DIR/${target##*/}"
    printf 'new:%s\n' "$target" > "$target"
    printf 'partial:%s\n' "$target" > "$target.new.$$"
done
TEST_SYSTEMCTL_LOG="$TMP_DIR/systemctl.log"
systemctl() {
    printf '%s\n' "$*" >> "$TEST_SYSTEMCTL_LOG"
    [[ $1 != restart ]]
}
RECONFIGURE=true
SERVICE_WAS_ACTIVE=true
SERVICE_WAS_ENABLED=false
SERVICE_USER_CREATED=false
SERVICE_GROUP_CREATED=false
rollback_changes 2> "$TMP_DIR/rollback-errors.log"
for target in "${ROLLBACK_TARGETS[@]}"; do
    [[ "$(< "$target")" == "old:$target" ]] || fail "rollback did not restore $target"
    [[ ! -e $target.new.$$ ]] || fail "rollback left a partial replacement for $target"
done
SYSTEMCTL_CALLS="$(< "$TEST_SYSTEMCTL_LOG")"
[[ $SYSTEMCTL_CALLS == $'stop ezxray.service\ndaemon-reload\ndisable ezxray.service\nrestart ezxray.service' ]] || fail "rollback did not restore the prior service state"
[[ $ROLLBACK_FAILED == true ]] || fail "rollback failure should be recorded"
ROLLBACK_ERRORS="$(< "$TMP_DIR/rollback-errors.log")"
[[ $ROLLBACK_ERRORS == *'restarting restored ezxray.service failed'* ]] || fail "rollback failure should be reported"

CONTROL_ROOT="$TMP_DIR/control"
EZXRAY_DIR="$CONTROL_ROOT/etc/ezxray"
STATE_PATH="$EZXRAY_DIR/state.json"
MARKER_PATH="$EZXRAY_DIR/managed"
TLS_CERT_MANAGED_PATH="$EZXRAY_DIR/fullchain.pem"
TLS_KEY_MANAGED_PATH="$EZXRAY_DIR/privkey.pem"
BACKUP_ROOT="$EZXRAY_DIR/backups"
XRAY_CONFIG_PATH="$CONTROL_ROOT/usr/local/xray/config.json"
XRAY_RELEASE_DIR="$CONTROL_ROOT/usr/local/lib/ezxray/$EZXRAY_VERSION"
XRAY_BIN="$XRAY_RELEASE_DIR/xray"
PROFILE_PATH="$CONTROL_ROOT/root/xray-configs-12-protocols.txt"
SERVICE_PATH="$CONTROL_ROOT/systemd/ezxray.service"
CONTROL_SYSTEMCTL_LOG="$TMP_DIR/control-systemctl.log"
CONTROL_UFW_LOG="$TMP_DIR/control-ufw.log"
USER_GROUP_LOG="$TMP_DIR/user-group.log"
: > "$CONTROL_SYSTEMCTL_LOG"
: > "$CONTROL_UFW_LOG"
: > "$USER_GROUP_LOG"

systemctl() {
    printf '%s\n' "$*" >> "$CONTROL_SYSTEMCTL_LOG"
    case "$1 ${2:-}" in
        'is-active ezxray.service')
            printf '%s\n' "${TEST_SERVICE_ACTIVE:-active}"
            [[ ${TEST_SERVICE_ACTIVE:-active} == active ]]
            ;;
        'is-enabled ezxray.service')
            printf '%s\n' "${TEST_SERVICE_ENABLED:-enabled}"
            [[ ${TEST_SERVICE_ENABLED:-enabled} == enabled ]]
            ;;
        *) return 0 ;;
    esac
}
ufw() {
    printf '%s\n' "$*" >> "$CONTROL_UFW_LOG"
    [[ $1 == status ]] && printf 'Status: active\n'
}

mkdir -p "$EZXRAY_DIR"
printf 'EZxray managed %s\n' "$EZXRAY_VERSION" > "$MARKER_PATH"
python3 - "$STATE_PATH" <<'PY'
import json
import sys

state = {
    "schema": 1,
    "domain": "vpn.example.test",
    "tls_cert": "/managed/certificate.pem",
    "tls_key": "/managed/private-key.pem",
    "ports": [443, 8443, 8080, 2096, 2053, 2083, 2087, 2095, 8444, 8445, 8446, 8447],
    "credentials": {
        "vless": ["secret-vless-1", "secret-vless-2", "secret-vless-3"],
        "vmess": ["secret-vmess-1", "secret-vmess-2", "secret-vmess-3"],
        "trojan": ["secret-trojan-1", "secret-trojan-2", "secret-trojan-3"],
        "shadowsocks": ["secret-shadowsocks-1", "secret-shadowsocks-2", "secret-shadowsocks-3"],
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump(state, output)
    output.write("\n")
PY
cp "$STATE_PATH" "$TMP_DIR/state-before-status.json"
: > "$CONTROL_SYSTEMCTL_LOG"
: > "$CONTROL_UFW_LOG"
STATUS_OUTPUT=$(show_status)
[[ $STATUS_OUTPUT == *'Installation: installed'* ]] || fail "status should recognize the managed installation"
[[ $STATUS_OUTPUT == *"Version: $EZXRAY_VERSION"* ]] || fail "status should report the installed version"
[[ $STATUS_OUTPUT == *'Service active: active'* ]] || fail "status should report active service state"
[[ $STATUS_OUTPUT == *'Service enabled: enabled'* ]] || fail "status should report enabled service state"
[[ $STATUS_OUTPUT == *'Domain: vpn.example.test'* ]] || fail "status should report the configured domain"
[[ $STATUS_OUTPUT == *'Ports: 443,8443,8080,2096,2053,2083,2087,2095,8444,8445,8446,8447'* ]] || fail "status should report configured ports"
[[ $STATUS_OUTPUT == *'UFW: active'* ]] || fail "status should report UFW state"
for secret in secret-vless-1 secret-vmess-1 secret-trojan-1 secret-shadowsocks-1 /managed/private-key.pem; do
    [[ $STATUS_OUTPUT != *"$secret"* ]] || fail "status exposed a credential or private-key path"
done
cmp -s "$STATE_PATH" "$TMP_DIR/state-before-status.json" || fail "status modified the managed state file"
[[ "$(< "$CONTROL_SYSTEMCTL_LOG")" == $'is-active ezxray.service\nis-enabled ezxray.service' ]] || fail "status must only query service state"
[[ "$(< "$CONTROL_UFW_LOG")" == 'status' ]] || fail "status must only query UFW state"

printf '{invalid state\n' > "$STATE_PATH"
cp "$STATE_PATH" "$TMP_DIR/invalid-state-before-status.json"
STATUS_OUTPUT=$(show_status)
[[ $STATUS_OUTPUT == *'Installation: invalid'* ]] || fail "status should describe an invalid managed state"
[[ $STATUS_OUTPUT == *'Domain: unavailable'* && $STATUS_OUTPUT == *'Ports: unavailable'* ]] || fail "invalid state must not expose partial metadata"
cmp -s "$STATE_PATH" "$TMP_DIR/invalid-state-before-status.json" || fail "invalid status read changed the state file"

ABSENT_ROOT="$TMP_DIR/absent"
EZXRAY_DIR="$ABSENT_ROOT/etc/ezxray"
STATE_PATH="$EZXRAY_DIR/state.json"
MARKER_PATH="$EZXRAY_DIR/managed"
TLS_CERT_MANAGED_PATH="$EZXRAY_DIR/fullchain.pem"
TLS_KEY_MANAGED_PATH="$EZXRAY_DIR/privkey.pem"
BACKUP_ROOT="$EZXRAY_DIR/backups"
XRAY_CONFIG_PATH="$ABSENT_ROOT/usr/local/xray/config.json"
XRAY_RELEASE_DIR="$ABSENT_ROOT/usr/local/lib/ezxray/$EZXRAY_VERSION"
XRAY_BIN="$XRAY_RELEASE_DIR/xray"
PROFILE_PATH="$ABSENT_ROOT/root/xray-configs-12-protocols.txt"
SERVICE_PATH="$ABSENT_ROOT/systemd/ezxray.service"
STATUS_OUTPUT=$(show_status)
[[ $STATUS_OUTPUT == *'Installation: not installed'* ]] || fail "status should report an absent installation"

printf 'invalid\n6\n' > "$TMP_DIR/menu-input"
interactive_menu < "$TMP_DIR/menu-input" > "$TMP_DIR/menu-output"
[[ "$(< "$TMP_DIR/menu-output")" == *'Invalid choice'* ]] || fail "menu should reject invalid choices"
: > "$TMP_DIR/menu-eof"
interactive_menu < "$TMP_DIR/menu-eof" > "$TMP_DIR/menu-eof-output"
[[ "$(< "$TMP_DIR/menu-eof-output")" == *'No input received'* ]] || fail "menu EOF should exit without an action"

ORIGINAL_RUN_INSTALL=$(declare -f run_install)
ORIGINAL_SHOW_STATUS=$(declare -f show_status)
ORIGINAL_INTERACTIVE_MENU=$(declare -f interactive_menu)
ORIGINAL_IS_INTERACTIVE_TTY=$(declare -f is_interactive_tty)
ROUTING_LOG="$TMP_DIR/menu-routing.log"
: > "$ROUTING_LOG"
run_install() { printf 'install reconfigure=%s\n' "$RECONFIGURE" >> "$ROUTING_LOG"; }
show_status() { printf 'status\n' >> "$ROUTING_LOG"; }
interactive_menu() { printf 'menu\n' >> "$ROUTING_LOG"; }
is_interactive_tty() { [[ ${TEST_TTY:-false} == true ]]; }
TEST_TTY=true
main
main --reconfigure
TEST_TTY=false
main --status
main
[[ "$(< "$ROUTING_LOG")" == $'menu\ninstall reconfigure=true\nstatus\ninstall reconfigure=false' ]] || fail "CLI arguments and TTY menu routing changed"
eval "$ORIGINAL_RUN_INSTALL"
eval "$ORIGINAL_SHOW_STATUS"
eval "$ORIGINAL_INTERACTIVE_MENU"
eval "$ORIGINAL_IS_INTERACTIVE_TTY"
unset ORIGINAL_RUN_INSTALL ORIGINAL_SHOW_STATUS ORIGINAL_INTERACTIVE_MENU ORIGINAL_IS_INTERACTIVE_TTY TEST_TTY

DELETE_ROOT="$TMP_DIR/delete"
EZXRAY_DIR="$DELETE_ROOT/etc/ezxray"
STATE_PATH="$EZXRAY_DIR/state.json"
MARKER_PATH="$EZXRAY_DIR/managed"
TLS_CERT_MANAGED_PATH="$EZXRAY_DIR/fullchain.pem"
TLS_KEY_MANAGED_PATH="$EZXRAY_DIR/privkey.pem"
BACKUP_ROOT="$EZXRAY_DIR/backups"
XRAY_CONFIG_PATH="$DELETE_ROOT/usr/local/xray/config.json"
XRAY_RELEASE_DIR="$DELETE_ROOT/usr/local/lib/ezxray/$EZXRAY_VERSION"
XRAY_BIN="$XRAY_RELEASE_DIR/xray"
PROFILE_PATH="$DELETE_ROOT/root/xray-configs-12-protocols.txt"
SERVICE_PATH="$DELETE_ROOT/systemd/ezxray.service"
create_delete_fixture() {
    local target
    for target in "$STATE_PATH" "$MARKER_PATH" "$TLS_CERT_MANAGED_PATH" "$TLS_KEY_MANAGED_PATH" "$XRAY_CONFIG_PATH" "$XRAY_BIN" "$PROFILE_PATH" "$SERVICE_PATH"; do
        mkdir -p "$(dirname "$target")"
        if [[ $target == "$MARKER_PATH" ]]; then
            printf 'EZxray managed %s\n' "$EZXRAY_VERSION" > "$target"
        else
            printf 'managed:%s\n' "$target" > "$target"
        fi
    done
}

getent() {
    case "$1 ${2:-}" in
        'passwd ezxray') printf 'ezxray:x:998:998::/nonexistent:/usr/sbin/nologin\n' ;;
        'passwd ')
            printf 'root:x:0:0:root:/root:/bin/bash\n'
            printf 'ezxray:x:998:998::/nonexistent:/usr/sbin/nologin\n'
            if [[ ${TEST_PRIMARY_GROUP_USER:-false} == true ]]; then
                printf 'unrelated:x:1000:998::/home/unrelated:/usr/sbin/nologin\n'
            fi
            ;;
        'group ezxray') printf 'ezxray:x:998:%s\n' "${TEST_GROUP_MEMBERS:-}" ;;
        *) return 2 ;;
    esac
}
id() { [[ $1 == -G && $2 == ezxray ]] && printf '998\n'; }
pgrep() { [[ ${TEST_PROCESS_RUNNING:-false} == true ]]; }
userdel() { printf 'userdel %s\n' "$*" >> "$USER_GROUP_LOG"; }
groupdel() { printf 'groupdel %s\n' "$*" >> "$USER_GROUP_LOG"; }
require_systemd() { :; }

SYSTEMD_SCAN_DIR="$TMP_DIR/systemd-scan"
mkdir -p "$SYSTEMD_SCAN_DIR/consumer.socket.d" "$SYSTEMD_SCAN_DIR/consumer.service.d"
printf '[Socket]\nSocketUser=ezxray\n' > "$SYSTEMD_SCAN_DIR/consumer.socket"
if ! other_systemd_unit_uses_service_account 998 998 "$SYSTEMD_SCAN_DIR"; then
    fail "account cleanup safety should detect SocketUser references"
fi
printf '[Socket]\nSocketGroup=ezxray\n' > "$SYSTEMD_SCAN_DIR/consumer.socket"
if ! other_systemd_unit_uses_service_account 998 998 "$SYSTEMD_SCAN_DIR"; then
    fail "account cleanup safety should detect SocketGroup references"
fi
printf '[Socket]\nSocketUser=998\n' > "$SYSTEMD_SCAN_DIR/consumer.socket"
if ! other_systemd_unit_uses_service_account 998 998 "$SYSTEMD_SCAN_DIR"; then
    fail "account cleanup safety should detect numeric SocketUser references"
fi
printf '[Socket]\nSocketGroup=998\n' > "$SYSTEMD_SCAN_DIR/consumer.socket"
if ! other_systemd_unit_uses_service_account 998 998 "$SYSTEMD_SCAN_DIR"; then
    fail "account cleanup safety should detect numeric SocketGroup references"
fi
printf '[Service]\nUser=998\n' > "$SYSTEMD_SCAN_DIR/consumer.service"
if ! other_systemd_unit_uses_service_account 998 998 "$SYSTEMD_SCAN_DIR"; then
    fail "account cleanup safety should detect numeric User references"
fi
printf '[Service]\nUser=01746\n' > "$SYSTEMD_SCAN_DIR/consumer.service"
if ! other_systemd_unit_uses_service_account 998 998 "$SYSTEMD_SCAN_DIR"; then
    fail "account cleanup safety should detect zero-padded octal User references"
fi
printf '[Service]\nGroup=998\n' > "$SYSTEMD_SCAN_DIR/consumer.service"
if ! other_systemd_unit_uses_service_account 998 998 "$SYSTEMD_SCAN_DIR"; then
    fail "account cleanup safety should detect numeric Group references"
fi
printf '[Service]\nGroup=0x3e6\n' > "$SYSTEMD_SCAN_DIR/consumer.service"
if ! other_systemd_unit_uses_service_account 998 998 "$SYSTEMD_SCAN_DIR"; then
    fail "account cleanup safety should detect hexadecimal Group references"
fi
printf '[Service]\nGroup=0X3E6\n' > "$SYSTEMD_SCAN_DIR/consumer.service"
if ! other_systemd_unit_uses_service_account 998 998 "$SYSTEMD_SCAN_DIR"; then
    fail "account cleanup safety should detect uppercase hexadecimal Group references"
fi
printf '[Service]\nGroup=unrelated\n' > "$SYSTEMD_SCAN_DIR/consumer.service"
printf '[Service]\nSupplementaryGroups=998\n' > "$SYSTEMD_SCAN_DIR/consumer.service.d/override.conf"
if ! other_systemd_unit_uses_service_account 998 998 "$SYSTEMD_SCAN_DIR"; then
    fail "account cleanup safety should detect numeric SupplementaryGroups references"
fi
printf '[Service]\nSupplementaryGroups=+0X3E6\n' > "$SYSTEMD_SCAN_DIR/consumer.service.d/override.conf"
if ! other_systemd_unit_uses_service_account 998 998 "$SYSTEMD_SCAN_DIR"; then
    fail "account cleanup safety should detect signed hexadecimal SupplementaryGroups references"
fi
rm -f -- "$SYSTEMD_SCAN_DIR/consumer.service.d/override.conf"
printf '[Service]\nUser=ezxray-helper\nGroup=1998\n' > "$SYSTEMD_SCAN_DIR/consumer.service"
printf '[Socket]\nSocketUser=ezxray-helper\nSocketGroup=1998\n' > "$SYSTEMD_SCAN_DIR/consumer.socket"
if other_systemd_unit_uses_service_account 998 998 "$SYSTEMD_SCAN_DIR"; then
    fail "account cleanup safety should ignore unrelated name and numeric prefixes"
fi

SYSTEMD_TRANSIENT_SCAN_DIR="$SYSTEMD_SCAN_DIR/transient"
mkdir -p "$SYSTEMD_TRANSIENT_SCAN_DIR"
[[ " ${SYSTEMD_UNIT_DIRS[*]} " == *" /run/systemd/transient "* ]] || fail "default systemd scan directories should include transient units"
SYSTEMD_UNIT_DIRS=("$SYSTEMD_TRANSIENT_SCAN_DIR")
printf '[Service]\nUser=ezxray\n' > "$SYSTEMD_TRANSIENT_SCAN_DIR/pending.service"
if ! other_systemd_unit_uses_service_account 998 998; then
    fail "account cleanup safety should scan the default transient unit directory"
fi
printf '%s\n' '[Service]' 'User=ez\' 'xray' > "$SYSTEMD_TRANSIENT_SCAN_DIR/continued.service"
if ! other_systemd_unit_uses_service_account 998 998; then
    fail "account cleanup safety should fail closed on continued identity directives"
fi

other_systemd_unit_uses_service_account() { return 1; }

create_delete_fixture
cp "$MARKER_PATH" "$TMP_DIR/marker-before-cancel"
: > "$CONTROL_SYSTEMCTL_LOG"
printf 'no\n' > "$TMP_DIR/delete-cancel-input"
delete_installation < "$TMP_DIR/delete-cancel-input" > "$TMP_DIR/delete-cancel-output"
cmp -s "$MARKER_PATH" "$TMP_DIR/marker-before-cancel" || fail "cancelled deletion changed the installation"
[[ ! -s $CONTROL_SYSTEMCTL_LOG ]] || fail "cancelled deletion must not change service state"

printf 'unrecognized marker\n' > "$MARKER_PATH"
cp "$MARKER_PATH" "$TMP_DIR/marker-before-unrecognized-delete"
: > "$CONTROL_SYSTEMCTL_LOG"
printf 'DELETE\n' > "$TMP_DIR/delete-unrecognized-input"
if delete_installation < "$TMP_DIR/delete-unrecognized-input" > "$TMP_DIR/delete-unrecognized-output" 2>&1; then
    fail "deletion should refuse an unrecognized managed marker"
fi
cmp -s "$MARKER_PATH" "$TMP_DIR/marker-before-unrecognized-delete" || fail "unrecognized deletion changed the marker"
[[ ! -s $CONTROL_SYSTEMCTL_LOG ]] || fail "unrecognized deletion must not change service state"
printf 'EZxray managed %s\n' "$EZXRAY_VERSION" > "$MARKER_PATH"

mkdir -p "$BACKUP_ROOT/20261018T010203-1234" "$BACKUP_ROOT/manual"
printf 'old config\n' > "$BACKUP_ROOT/20261018T010203-1234/config.json"
printf 'keep backup extra\n' > "$BACKUP_ROOT/20261018T010203-1234/keep.me"
printf 'keep manual backup\n' > "$BACKUP_ROOT/manual/keep.me"
printf 'unrelated\n' > "$DELETE_ROOT/usr/local/xray/unrelated.txt"
: > "$CONTROL_SYSTEMCTL_LOG"
: > "$CONTROL_UFW_LOG"
: > "$USER_GROUP_LOG"
printf 'DELETE\n' > "$TMP_DIR/delete-confirm-input"
delete_installation < "$TMP_DIR/delete-confirm-input" > "$TMP_DIR/delete-confirm-output"
for target in "$STATE_PATH" "$MARKER_PATH" "$TLS_CERT_MANAGED_PATH" "$TLS_KEY_MANAGED_PATH" "$XRAY_CONFIG_PATH" "$XRAY_BIN" "$PROFILE_PATH" "$SERVICE_PATH"; do
    [[ ! -e $target && ! -L $target ]] || fail "confirmed deletion left managed artifact $target"
done
[[ ! -e "$BACKUP_ROOT/20261018T010203-1234/config.json" ]] || fail "confirmed deletion left a managed backup file"
[[ -f "$BACKUP_ROOT/20261018T010203-1234/keep.me" ]] || fail "deletion removed unrelated backup content"
[[ -f "$BACKUP_ROOT/manual/keep.me" ]] || fail "deletion removed a non-managed backup directory"
[[ -f "$DELETE_ROOT/usr/local/xray/unrelated.txt" ]] || fail "deletion removed an unrelated file"
[[ "$(< "$CONTROL_SYSTEMCTL_LOG")" == $'is-active ezxray.service\nstop ezxray.service\nis-enabled ezxray.service\ndisable ezxray.service\ndaemon-reload' ]] || fail "confirmed deletion service calls were: $(< "$CONTROL_SYSTEMCTL_LOG")"
[[ "$(< "$USER_GROUP_LOG")" == $'userdel ezxray\ngroupdel ezxray' ]] || fail "confirmed deletion did not remove the unused service account and group"
[[ ! -s $CONTROL_UFW_LOG ]] || fail "deletion must preserve UFW rules"

TEST_PROCESS_RUNNING=true
create_delete_fixture
: > "$USER_GROUP_LOG"
printf 'DELETE\n' > "$TMP_DIR/delete-running-process-input"
if delete_installation < "$TMP_DIR/delete-running-process-input" > "$TMP_DIR/delete-running-process-output" 2>&1; then
    fail "deletion should stop when a service-account process remains"
fi
[[ -f $STATE_PATH && -f $MARKER_PATH ]] || fail "a remaining service-account process should prevent artifact deletion"
[[ -z "$(< "$USER_GROUP_LOG")" ]] || fail "a remaining service-account process must prevent account removal"

TEST_PROCESS_RUNNING=false
TEST_GROUP_MEMBERS=unrelated-user
create_delete_fixture
: > "$USER_GROUP_LOG"
printf 'DELETE\n' > "$TMP_DIR/delete-unsafe-account-input"
delete_installation < "$TMP_DIR/delete-unsafe-account-input" > "$TMP_DIR/delete-unsafe-account-output"
[[ -z "$(< "$USER_GROUP_LOG")" ]] || fail "deletion removed a group with unrelated members"
[[ ! -e $STATE_PATH && ! -e $MARKER_PATH ]] || fail "unsafe account state should preserve managed artifact cleanup"

TEST_GROUP_MEMBERS=
TEST_PRIMARY_GROUP_USER=true
create_delete_fixture
: > "$USER_GROUP_LOG"
printf 'DELETE\n' > "$TMP_DIR/delete-primary-group-input"
delete_installation < "$TMP_DIR/delete-primary-group-input" > "$TMP_DIR/delete-primary-group-output"
[[ -z "$(< "$USER_GROUP_LOG")" ]] || fail "deletion removed an account or group used by another primary-group user"

REAL_EZXRAY_DIR="$TMP_DIR/redirected/etc/ezxray"
rm -rf -- "$EZXRAY_DIR"
mkdir -p "$(dirname "$REAL_EZXRAY_DIR")"
ln -s "$REAL_EZXRAY_DIR" "$EZXRAY_DIR"
mkdir -p "$REAL_EZXRAY_DIR"
printf 'EZxray managed %s\n' "$EZXRAY_VERSION" > "$MARKER_PATH"
printf 'preserve redirected state\n' > "$STATE_PATH"
: > "$CONTROL_SYSTEMCTL_LOG"
printf 'DELETE\n' > "$TMP_DIR/delete-symlink-parent-input"
if delete_installation < "$TMP_DIR/delete-symlink-parent-input" > "$TMP_DIR/delete-symlink-parent-output" 2>&1; then
    fail "deletion should refuse artifacts below a symlinked managed directory"
fi
[[ -f $MARKER_PATH && "$(< "$STATE_PATH")" == 'preserve redirected state' ]] || fail "symlinked managed directory contents were changed"
[[ ! -s $CONTROL_SYSTEMCTL_LOG ]] || fail "symlinked managed directory must be refused before changing service state"

test_install_profile_output() (
    local root="$TMP_DIR/profile-output"
    EZXRAY_DIR="$root/etc/ezxray"
    STATE_PATH="$EZXRAY_DIR/state.json"
    MARKER_PATH="$EZXRAY_DIR/managed"
    TLS_CERT_MANAGED_PATH="$EZXRAY_DIR/fullchain.pem"
    TLS_KEY_MANAGED_PATH="$EZXRAY_DIR/privkey.pem"
    BACKUP_ROOT="$EZXRAY_DIR/backups"
    XRAY_CONFIG_PATH="$root/usr/local/xray/config.json"
    XRAY_RELEASE_DIR="$root/usr/local/lib/ezxray/$EZXRAY_VERSION"
    XRAY_BIN="$XRAY_RELEASE_DIR/xray"
    PROFILE_PATH="$root/root/xray-configs-12-protocols.txt"
    SERVICE_PATH="$root/systemd/ezxray.service"
    CLI_DOMAIN="vpn.example.test"
    CLI_TLS_CERT="$root/source/fullchain.pem"
    CLI_TLS_KEY="$root/source/privkey.pem"
    CLI_PORTS_SET=false
    RECONFIGURE=false
    SERVICE_WAS_ACTIVE=false
    SELECTED_PORTS=(443 8443 8080 2096 2053 2083 2087 2095 8444 8445 8446 8447)
    VLESS_UUIDS=(11111111-1111-4111-8111-111111111111 22222222-2222-4222-8222-222222222222 33333333-3333-4333-8333-333333333333)
    VMESS_UUIDS=(44444444-4444-4444-8444-444444444444 55555555-5555-4555-8555-555555555555 66666666-6666-4666-8666-666666666666)
    TROJAN_PASSWORDS=(trojan-one trojan-two trojan-three)
    SS_PASSWORDS=(shadowsocks-one shadowsocks-two shadowsocks-three)
    mkdir -p "$root/source" "$XRAY_RELEASE_DIR"
    printf 'test certificate\n' > "$CLI_TLS_CERT"
    printf 'test private key\n' > "$CLI_TLS_KEY"
    printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"
    chmod 0755 "$XRAY_BIN"

    require_systemd() { :; }
    has_unmanaged_collision() { return 1; }
    ensure_dependencies() { :; }
    validate_tls_files() { :; }
    validate_service_account() { :; }
    port_is_available() { return 0; }
    select_automatic_ports() { :; }
    generate_credentials() { :; }
    ensure_service_account() { :; }
    service_is_active() { return 1; }
    service_is_enabled() { return 1; }
    save_backup() { :; }
    reload_service_for_current_mode() { :; }
    open_firewall_if_available() { :; }
    install() {
        local -a args=()
        while (($#)); do
            case "$1" in
                -o|-g) shift 2 ;;
                *) args+=("$1"); shift ;;
            esac
        done
        command install "${args[@]}"
    }

    assert_profiles_printed() {
        local output_path=$1
        python3 - "$PROFILE_PATH" "$output_path" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    profiles = [line.rstrip("\n") for line in source]
with open(sys.argv[2], encoding="utf-8") as source:
    printed = source.read()

assert len(profiles) == 12
assert "No bandwidth shaping is configured" in printed
assert printed.index("No bandwidth shaping is configured") < printed.index("Client configurations (12 total)")
for profile in profiles:
    label, link = profile.split(": ", 1)
    assert printed.count(link) == 1, label
    assert f"  {label}\n    {link}\n" in printed, label
assert printed.rstrip().endswith(profiles[-1].split(": ", 1)[1])
PY
    }

    FIRST_OUTPUT="$(run_install)"
    [[ $FIRST_OUTPUT == *'EZxray is active. Generated 12 profiles:'* ]] || fail "first install should report its active service"
    [[ $FIRST_OUTPUT == *'Client configurations (12 total)'* ]] || fail "first install should print all client profiles"
    printf '%s\n' "$FIRST_OUTPUT" > "$root/first-output.txt"
    assert_profiles_printed "$root/first-output.txt"

    RECONFIGURE=true
    RECONFIGURE_OUTPUT="$(run_install)"
    [[ $RECONFIGURE_OUTPUT == *'previously inactive service remains stopped'* ]] || fail "reconfigure should preserve an inactive service"
    [[ $RECONFIGURE_OUTPUT == *'Client configurations (12 total)'* ]] || fail "reconfigure should print all client profiles"
    printf '%s\n' "$RECONFIGURE_OUTPUT" > "$root/reconfigure-output.txt"
    assert_profiles_printed "$root/reconfigure-output.txt"
)
test_install_profile_output

printf 'PASS: EZxray config, ports, rerun, service-state, and rollback checks\n'
