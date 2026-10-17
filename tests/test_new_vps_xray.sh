#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/EZxray.sh"
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
main
for target in "${NOOP_TARGETS[@]}"; do
    cmp -s "$target" "$target.expected" || fail "ordinary rerun changed $target"
done
unset -f systemctl

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

printf 'PASS: EZxray config, ports, rerun, service-state, and rollback checks\n'
