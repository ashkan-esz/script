#!/usr/bin/env bash

# EZxray: install a small Xray service with 12 client profiles.
# Ordinary reruns are deliberately read-only. Use --reconfigure to update files
# created and tracked by this script.

EZXRAY_VERSION="v26.3.27"
AUTO_PORTS=(8443 8080 2096 2053 2083 2087 2095 8444 8445 8446 8447 8448 8449 8450 8081 8082 8083 8084 8085)

XRAY_CONFIG_PATH="/usr/local/xray/config.json"
XRAY_RELEASE_DIR="/usr/local/lib/ezxray/${EZXRAY_VERSION}"
XRAY_BIN="${XRAY_RELEASE_DIR}/xray"
PROFILE_PATH="/root/xray-configs-12-protocols.txt"
EZXRAY_DIR="/etc/ezxray"
STATE_PATH="${EZXRAY_DIR}/state.json"
MARKER_PATH="${EZXRAY_DIR}/managed"
TLS_CERT_MANAGED_PATH="${EZXRAY_DIR}/fullchain.pem"
TLS_KEY_MANAGED_PATH="${EZXRAY_DIR}/privkey.pem"
SERVICE_PATH="/etc/systemd/system/ezxray.service"
SERVICE_NAME="ezxray.service"
SERVICE_USER="ezxray"
SERVICE_GROUP="ezxray"
BACKUP_ROOT="${EZXRAY_DIR}/backups"

SELECTED_PORTS=()
OLD_PORTS=()
VLESS_UUIDS=()
VMESS_UUIDS=()
TROJAN_PASSWORDS=()
SS_PASSWORDS=()

die() {
    printf 'EZxray: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: EZxray.sh [--domain DOMAIN] [--tls-cert FILE] [--tls-key FILE]
                 [--ports P1,P2,...,P12] [--reconfigure]

On first install, omitted domain and TLS paths are requested interactively.
Automatic port selection skips 443. An explicitly supplied 443 is accepted
when it is available. Normal reruns do not change existing files. TLS files are
copied into EZxray's managed directory; run --reconfigure after certificate renewal.
UFW rules are added for selected ports plus 443 and 53; existing firewall
defaults and rules are preserved.

Options:
  --domain DOMAIN       Public DNS name covered by the TLS certificate
  --tls-cert FILE       PEM certificate or full-chain file
  --tls-key FILE        Matching PEM private key
  --ports LIST          Exactly 12 unique ports, comma-separated
  --reconfigure         Update this script's managed installation (with backup)
  -h, --help            Show this help
EOF
}

auto_port_candidates() {
    printf '%s\n' "${AUTO_PORTS[@]}"
}

parse_port_list() {
    local input_port canonical
    local -a parsed=()
    local -A seen=()

    IFS=, read -r -a parsed <<< "$1"
    [[ ${#parsed[@]} -eq 12 ]] || return 1

    SELECTED_PORTS=()
    for input_port in "${parsed[@]}"; do
        [[ $input_port =~ ^[0-9]{1,5}$ ]] || return 1
        canonical=$((10#$input_port))
        (( canonical >= 1 && canonical <= 65535 )) || return 1
        [[ -z ${seen[$canonical]+x} ]] || return 1
        seen[$canonical]=1
        SELECTED_PORTS+=("$canonical")
    done
}

port_is_bound() {
    local port_hex table local_address state
    port_hex=$(printf '%04X' "$1")

    for table in /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6; do
        [[ -r $table ]] || continue
        while read -r _ local_address _ state _; do
            [[ ${local_address##*:} == "$port_hex" ]] || continue
            if [[ $table == */tcp || $table == */tcp6 ]]; then
                [[ $state == 0A ]] || continue
            fi
            return 0
        done < "$table"
    done
    return 1
}

port_is_available() {
    local port old_port
    port=$1

    if [[ ${RECONFIGURE:-false} == true && ${SERVICE_WAS_ACTIVE:-false} == true ]]; then
        for old_port in "${OLD_PORTS[@]}"; do
            [[ $port == "$old_port" ]] && return 0
        done
    fi
    ! port_is_bound "$port"
}

select_automatic_ports() {
    local port
    SELECTED_PORTS=()
    for port in "${AUTO_PORTS[@]}"; do
        if port_is_available "$port"; then
            SELECTED_PORTS+=("$port")
            (( ${#SELECTED_PORTS[@]} == 12 )) && break
        fi
    done
    [[ ${#SELECTED_PORTS[@]} -eq 12 ]] || die "fewer than 12 automatic ports are free; pass --ports with 12 free ports"
}

validate_domain() {
    DOMAIN=${DOMAIN,,}
    [[ ${#DOMAIN} -le 253 ]] || die "domain is too long"
    [[ $DOMAIN =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "enter a fully qualified DNS domain"
}

validate_tls_files() {
    [[ -n $TLS_CERT && -n $TLS_KEY ]] || die "both --tls-cert and --tls-key are required"
    [[ $TLS_CERT == /* && $TLS_KEY == /* ]] || die "TLS certificate and key paths must be absolute"
    [[ $TLS_CERT != *$'\n'* && $TLS_KEY != *$'\n'* ]] || die "TLS paths cannot contain newlines"
    [[ -f $TLS_CERT && -r $TLS_CERT ]] || die "TLS certificate is not a readable file: $TLS_CERT"
    [[ -f $TLS_KEY && -r $TLS_KEY ]] || die "TLS private key is not a readable file: $TLS_KEY"

    openssl x509 -in "$TLS_CERT" -noout -checkend 0 >/dev/null 2>&1 || die "TLS certificate is invalid or expired"
    openssl x509 -in "$TLS_CERT" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 || die "TLS certificate does not cover $DOMAIN"

    local cert_key_hash private_key_hash
    cert_key_hash=$(openssl x509 -in "$TLS_CERT" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}') || die "could not read TLS certificate public key"
    private_key_hash=$(openssl pkey -in "$TLS_KEY" -passin pass: -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}') || die "could not read TLS private key"
    [[ -n $cert_key_hash && $cert_key_hash == "$private_key_hash" ]] || die "TLS certificate and private key do not match"
}

ensure_dependencies() {
    local -a missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v unzip >/dev/null 2>&1 || missing+=(unzip)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    command -v sha256sum >/dev/null 2>&1 || missing+=(coreutils)
    command -v python3 >/dev/null 2>&1 || missing+=(python3)
    command -v useradd >/dev/null 2>&1 || missing+=(passwd)
    command -v groupadd >/dev/null 2>&1 || missing+=(passwd)
    command -v userdel >/dev/null 2>&1 || missing+=(passwd)
    command -v groupdel >/dev/null 2>&1 || missing+=(passwd)
    command -v getent >/dev/null 2>&1 || missing+=(libc-bin)
    command -v ufw >/dev/null 2>&1 || missing+=(ufw)
    ((${#missing[@]} == 0)) && return 0

    command -v apt-get >/dev/null 2>&1 || die "missing dependencies (${missing[*]}) and apt-get is unavailable"
    printf 'Installing required packages: %s\n' "${missing[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
}

require_systemd() {
    [[ $EUID -eq 0 ]] || die "run as root"
    [[ -d /run/systemd/system ]] || die "systemd is not running as PID 1; this installer requires a systemd-based VPS/LXC"
    command -v systemctl >/dev/null 2>&1 || die "systemctl is required"
}

load_state() {
    local fields_file="$TEMP_DIR/state-fields"
    python3 - "$STATE_PATH" > "$fields_file" <<'PY' || die "managed state file is invalid"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    state = json.load(source)
if state.get("schema") != 1:
    raise SystemExit(1)
credentials = state.get("credentials", {})
values = [state.get("domain", ""), state.get("tls_cert", ""), state.get("tls_key", "")]
ports = state.get("ports", [])
if len(ports) != 12 or len(set(ports)) != 12:
    raise SystemExit(1)
if any(not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535 for port in ports):
    raise SystemExit(1)
values.extend(str(port) for port in ports)
for name in ("vless", "vmess", "trojan", "shadowsocks"):
    entries = credentials.get(name, [])
    if len(entries) != 3:
        raise SystemExit(1)
    values.extend(entries)
if any(not isinstance(value, str) or "\n" in value for value in values):
    raise SystemExit(1)
for value in values:
    print(value)
PY

    local -a fields=()
    mapfile -t fields < "$fields_file"
    [[ ${#fields[@]} -eq 27 ]] || die "managed state file has an invalid field count"
    DOMAIN=${fields[0]}
    TLS_CERT=${fields[1]}
    TLS_KEY=${fields[2]}
    SELECTED_PORTS=("${fields[@]:3:12}")
    OLD_PORTS=("${SELECTED_PORTS[@]}")
    VLESS_UUIDS=("${fields[@]:15:3}")
    VMESS_UUIDS=("${fields[@]:18:3}")
    TROJAN_PASSWORDS=("${fields[@]:21:3}")
    SS_PASSWORDS=("${fields[@]:24:3}")
}

generate_credentials() {
    local i
    VLESS_UUIDS=()
    VMESS_UUIDS=()
    TROJAN_PASSWORDS=()
    SS_PASSWORDS=()
    for ((i = 0; i < 3; i++)); do
        VLESS_UUIDS+=("$(< /proc/sys/kernel/random/uuid)")
        VMESS_UUIDS+=("$(< /proc/sys/kernel/random/uuid)")
        TROJAN_PASSWORDS+=("$(openssl rand -hex 24)")
        SS_PASSWORDS+=("$(openssl rand -hex 24)")
    done
}

write_render_spec() {
    local spec_path=$1
    printf '%s\0' \
        "$DOMAIN" "$TLS_CERT" "$TLS_KEY" \
        "${SELECTED_PORTS[@]}" \
        "${VLESS_UUIDS[@]}" "${VMESS_UUIDS[@]}" \
        "${TROJAN_PASSWORDS[@]}" "${SS_PASSWORDS[@]}" > "$spec_path"
}

render_artifacts() {
    local config_path=$1 profiles_path=$2 state_path=$3 spec_path=$4
    python3 - "$config_path" "$profiles_path" "$state_path" "$spec_path" <<'PY'
import base64
import json
import sys
from urllib.parse import quote, urlencode

config_path, profiles_path, state_path, spec_path = sys.argv[1:]
raw = open(spec_path, "rb").read().split(b"\0")
if raw and raw[-1] == b"":
    raw.pop()
values = [item.decode("utf-8") for item in raw]
if len(values) != 27:
    raise SystemExit("invalid EZxray render data")

domain, cert, key = values[:3]
ports = [int(value) for value in values[3:15]]
credentials = {
    "vless": values[15:18],
    "vmess": values[18:21],
    "trojan": values[21:24],
    "shadowsocks": values[24:27],
}
if len(set(ports)) != 12:
    raise SystemExit("ports must be unique")

def tls_ws():
    return {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {"certificates": [{"certificateFile": cert, "keyFile": key}]},
        "wsSettings": {"path": "/ws", "headers": {"Host": domain}},
    }

inbounds = []
for protocol, label, port_index in (
    ("vless", "VLESS", 0),
    ("vmess", "VMess", 3),
    ("trojan", "Trojan", 6),
    ("shadowsocks", "Shadowsocks", 9),
):
    for offset in range(3):
        index = port_index + offset
        inbound = {
            "tag": f"ezxray-{protocol}-{offset + 1}",
            "listen": "0.0.0.0",
            "port": ports[index],
            "protocol": protocol,
        }
        secret = credentials[protocol][offset]
        if protocol == "vless":
            inbound["settings"] = {"clients": [{"id": secret}], "decryption": "none"}
            inbound["streamSettings"] = tls_ws()
        elif protocol == "vmess":
            inbound["settings"] = {"clients": [{"id": secret, "alterId": 0}]}
            inbound["streamSettings"] = tls_ws()
        elif protocol == "trojan":
            inbound["settings"] = {"clients": [{"password": secret}]}
            inbound["streamSettings"] = tls_ws()
        else:
            inbound["settings"] = {
                "method": "chacha20-ietf-poly1305",
                "password": secret,
                "network": "tcp,udp",
            }
        inbounds.append(inbound)

config = {
    "log": {"loglevel": "warning"},
    "inbounds": inbounds,
    "outbounds": [{"protocol": "freedom", "tag": "direct"}],
}
with open(config_path, "w", encoding="utf-8") as output:
    json.dump(config, output, indent=2)
    output.write("\n")

profiles = []
for offset, secret in enumerate(credentials["vless"]):
    port = ports[offset]
    query = urlencode({"encryption": "none", "security": "tls", "type": "ws", "host": domain, "path": "/ws", "sni": domain})
    profiles.append(f"VLESS {offset + 1}: vless://{secret}@{domain}:{port}?{query}#{quote(f'VLESS-{offset + 1}', safe='')}")
for offset, secret in enumerate(credentials["vmess"]):
    port = ports[3 + offset]
    label = f"VMess-{offset + 1}"
    payload = {
        "v": "2", "ps": label, "add": domain, "port": str(port), "id": secret,
        "aid": "0", "scy": "auto", "net": "ws", "type": "none", "host": domain,
        "path": "/ws", "tls": "tls", "sni": domain,
    }
    encoded = base64.b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode().rstrip("=")
    profiles.append(f"VMess {offset + 1}: vmess://{encoded}")
for offset, secret in enumerate(credentials["trojan"]):
    port = ports[6 + offset]
    query = urlencode({"security": "tls", "type": "ws", "host": domain, "path": "/ws", "sni": domain})
    profiles.append(f"Trojan {offset + 1}: trojan://{secret}@{domain}:{port}?{query}#{quote(f'Trojan-{offset + 1}', safe='')}")
for offset, secret in enumerate(credentials["shadowsocks"]):
    port = ports[9 + offset]
    userinfo = base64.b64encode(f"chacha20-ietf-poly1305:{secret}".encode()).decode()
    profiles.append(f"Shadowsocks {offset + 1}: ss://{userinfo}@{domain}:{port}#{quote(f'Shadowsocks-{offset + 1}', safe='')}")
with open(profiles_path, "w", encoding="utf-8") as output:
    output.write("\n".join(profiles) + "\n")

state = {
    "schema": 1,
    "version": "v1",
    "domain": domain,
    "tls_cert": cert,
    "tls_key": key,
    "ports": ports,
    "credentials": credentials,
}
with open(state_path, "w", encoding="utf-8") as output:
    json.dump(state, output, indent=2)
    output.write("\n")
PY
}

download_xray() {
    local destination=$1 asset sha256
    case $(uname -m) in
        x86_64|amd64)
            asset="Xray-linux-64.zip"
            sha256="23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"
            ;;
        aarch64|arm64)
            asset="Xray-linux-arm64-v8a.zip"
            sha256="4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c"
            ;;
        *) die "unsupported CPU architecture: $(uname -m)" ;;
    esac

    local archive="$TEMP_DIR/$asset"
    local extract_dir="$TEMP_DIR/xray-release"
    mkdir -p "$extract_dir"
    curl --fail --silent --show-error --location --retry 3 \
        "https://github.com/XTLS/Xray-core/releases/download/${EZXRAY_VERSION}/${asset}" \
        --output "$archive"
    printf '%s  %s\n' "$sha256" "$archive" | sha256sum --check --status || die "Xray release checksum verification failed"
    unzip -q "$archive" xray -d "$extract_dir"
    [[ -f $extract_dir/xray ]] || die "Xray release archive did not contain the xray binary"
    install -m 0755 "$extract_dir/xray" "$destination"
}

write_service_unit() {
    local low_port_capability=""
    local port
    for port in "${SELECTED_PORTS[@]}"; do
        if ((port < 1024)); then
            low_port_capability=$'CapabilityBoundingSet=CAP_NET_BIND_SERVICE\nAmbientCapabilities=CAP_NET_BIND_SERVICE'
            break
        fi
    done

    cat > "$1" <<EOF
[Unit]
Description=EZxray Xray service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG_PATH}
Restart=on-failure
RestartSec=3s
Environment=GOMAXPROCS=1
LimitNOFILE=65535
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
${low_port_capability}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

has_unmanaged_collision() {
    local target
    for target in "$XRAY_CONFIG_PATH" "$PROFILE_PATH" "$STATE_PATH" "$SERVICE_PATH" "$XRAY_BIN" "$TLS_CERT_MANAGED_PATH" "$TLS_KEY_MANAGED_PATH"; do
        if [[ -e $target || -L $target ]]; then
            printf 'EZxray: preserving existing unmanaged path: %s\n' "$target" >&2
            return 0
        fi
    done
    return 1
}

service_is_active() {
    systemctl is-active --quiet "$SERVICE_NAME"
}

service_is_enabled() {
    systemctl is-enabled --quiet "$SERVICE_NAME"
}

save_backup() {
    BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%dT%H%M%S)-$$"
    install -d -m 0700 "$BACKUP_DIR"
    local target
    for target in "$XRAY_CONFIG_PATH" "$PROFILE_PATH" "$STATE_PATH" "$MARKER_PATH" "$SERVICE_PATH" "$XRAY_BIN" "$TLS_CERT_MANAGED_PATH" "$TLS_KEY_MANAGED_PATH"; do
        if [[ -e $target || -L $target ]]; then
            cp -a -- "$target" "$BACKUP_DIR/"
        fi
    done
    printf 'Backup saved to %s\n' "$BACKUP_DIR"
}

report_rollback_failure() {
    printf 'EZxray: rollback warning: %s failed; inspect the service and managed files manually\n' "$1" >&2
    ROLLBACK_FAILED=true
}

rollback_systemctl() {
    local description=$1
    shift
    if ! systemctl "$@" >/dev/null 2>&1; then
        report_rollback_failure "$description"
    fi
}

rollback_changes() {
    local target backup
    ROLLBACK_FAILED=false
    for target in "$XRAY_CONFIG_PATH" "$PROFILE_PATH" "$STATE_PATH" "$MARKER_PATH" "$SERVICE_PATH" "$XRAY_BIN" "$TLS_CERT_MANAGED_PATH" "$TLS_KEY_MANAGED_PATH"; do
        rm -f -- "$target.new.$$" || report_rollback_failure "removing temporary file $target.new.$$"
    done
    if [[ $RECONFIGURE == true ]]; then
        rollback_systemctl "stopping $SERVICE_NAME" stop "$SERVICE_NAME"
        for target in "$XRAY_CONFIG_PATH" "$PROFILE_PATH" "$STATE_PATH" "$MARKER_PATH" "$SERVICE_PATH" "$XRAY_BIN" "$TLS_CERT_MANAGED_PATH" "$TLS_KEY_MANAGED_PATH"; do
            backup="$BACKUP_DIR/${target##*/}"
            if [[ -e $backup || -L $backup ]]; then
                if ! install -d -m 0755 "$(dirname "$target")" || ! cp -a -- "$backup" "$target"; then
                    report_rollback_failure "restoring $target"
                fi
            else
                rm -f -- "$target" || report_rollback_failure "removing newly created $target"
            fi
        done
        rollback_systemctl "reloading the systemd manager" daemon-reload
        if [[ $SERVICE_WAS_ENABLED == true ]]; then
            rollback_systemctl "enabling $SERVICE_NAME" enable "$SERVICE_NAME"
        else
            rollback_systemctl "disabling $SERVICE_NAME" disable "$SERVICE_NAME"
        fi
        if [[ $SERVICE_WAS_ACTIVE == true ]]; then
            rollback_systemctl "restarting restored $SERVICE_NAME" restart "$SERVICE_NAME"
        fi
    else
        if [[ -e $SERVICE_PATH || -L $SERVICE_PATH ]]; then
            rollback_systemctl "disabling $SERVICE_NAME" disable --now "$SERVICE_NAME"
        fi
        for target in "$XRAY_CONFIG_PATH" "$PROFILE_PATH" "$STATE_PATH" "$MARKER_PATH" "$SERVICE_PATH" "$XRAY_BIN" "$TLS_CERT_MANAGED_PATH" "$TLS_KEY_MANAGED_PATH"; do
            rm -f -- "$target" || report_rollback_failure "removing newly created $target"
        done
        rollback_systemctl "reloading the systemd manager" daemon-reload
    fi
    if [[ ${SERVICE_USER_CREATED:-false} == true ]]; then
        userdel "$SERVICE_USER" >/dev/null 2>&1 || report_rollback_failure "removing the $SERVICE_USER account"
    fi
    if [[ ${SERVICE_GROUP_CREATED:-false} == true ]]; then
        groupdel "$SERVICE_GROUP" >/dev/null 2>&1 || report_rollback_failure "removing the $SERVICE_GROUP group"
    fi
}

on_exit() {
    local status=$?
    trap - EXIT
    if [[ ${MUTATION_STARTED:-false} == true && $status -ne 0 ]]; then
        printf 'EZxray: installation failed; restoring managed files\n' >&2
        rollback_changes
        if [[ ${ROLLBACK_FAILED:-false} == true ]]; then
            printf 'EZxray: rollback was incomplete; the original installation error is still exit status %s\n' "$status" >&2
        fi
    fi
    if [[ -n ${TEMP_DIR:-} && -d $TEMP_DIR ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
    exit "$status"
}

detect_ssh_ports() {
    local client_ip client_port server_ip connection_port extra config_output key value port
    local -A seen=()
    SSH_PORTS=()

    read -r client_ip client_port server_ip connection_port extra <<< "${SSH_CONNECTION:-}"
    if [[ ${connection_port:-} =~ ^[0-9]{1,5}$ ]]; then
        port=$((10#$connection_port))
        if ((port >= 1 && port <= 65535)); then
            SSH_PORTS+=("$port")
            seen[$port]=1
        fi
    fi

    if command -v sshd >/dev/null 2>&1; then
        config_output=$(sshd -T 2>/dev/null || true)
        while read -r key value _; do
            [[ $key == port && ${value:-} =~ ^[0-9]{1,5}$ ]] || continue
            port=$((10#$value))
            ((port >= 1 && port <= 65535)) || continue
            if [[ -z ${seen[$port]+present} ]]; then
                SSH_PORTS+=("$port")
                seen[$port]=1
            fi
        done <<< "$config_output"
    fi
}

other_firewall_manager_active() {
    local manager
    for manager in firewalld.service nftables.service netfilter-persistent.service; do
        if systemctl is-active --quiet "$manager" >/dev/null 2>&1; then
            printf 'EZxray: %s is active; leaving UFW inactive to avoid competing firewall managers.\n' "$manager" >&2
            return 0
        fi
    done
    return 1
}

open_firewall_if_available() {
    local environment firewall_status firewall_active=false firewall_failed=false
    local ssh_rules_ok=true xray_rules_ok=true port protocol
    local -a ports_to_allow=()
    local -A seen_ports=()

    environment=$(systemd-detect-virt --container 2>/dev/null || true)
    if ! firewall_status=$(ufw status 2>/dev/null); then
        printf 'EZxray: Xray is installed, but UFW status could not be read; firewall rules were not changed.\n' >&2
        if [[ -n $environment && $environment != none ]]; then
            printf 'Container detected (%s): verify the host/provider firewall and forwarding for TCP and UDP on the selected ports, 443, and 53.\n' "$environment" >&2
        fi
        return 1
    fi
    if [[ ${firewall_status,,} == *'status: active'* ]]; then
        firewall_active=true
    fi

    # Do not widen SSH access on an already active firewall. Its current SSH
    # policy is already in force; only add the requested Xray service ports.
    if [[ $firewall_active != true ]]; then
        detect_ssh_ports
        if ((${#SSH_PORTS[@]} == 0)); then
            printf 'EZxray: could not detect an SSH port; UFW rules will be staged, but UFW will remain inactive to avoid locking out access.\n' >&2
            firewall_failed=true
        else
            for port in "${SSH_PORTS[@]}"; do
                if ! ufw allow in "$port/tcp" >/dev/null; then
                    printf 'EZxray: failed to add the SSH allow rule for TCP port %s.\n' "$port" >&2
                    ssh_rules_ok=false
                    firewall_failed=true
                fi
            done
        fi
    fi

    ports_to_allow=("${SELECTED_PORTS[@]}" 443 53)
    for port in "${ports_to_allow[@]}"; do
        [[ -z ${seen_ports[$port]+present} ]] || continue
        seen_ports[$port]=1
        for protocol in tcp udp; do
            if ! ufw allow in "$port/$protocol" >/dev/null; then
                printf 'EZxray: failed to add the %s allow rule for port %s.\n' "$protocol" "$port" >&2
                xray_rules_ok=false
                firewall_failed=true
            fi
        done
    done

    if [[ $xray_rules_ok != true ]]; then
        printf 'EZxray: some requested UFW rules could not be added; review `ufw status`.\n' >&2
    fi

    if [[ $firewall_active != true ]]; then
        if ((${#SSH_PORTS[@]} > 0)) && [[ $ssh_rules_ok == true && $xray_rules_ok == true ]]; then
            if other_firewall_manager_active; then
                firewall_failed=true
            else
                printf 'UFW was inactive; enabling it applies its existing default policy to all inbound traffic. Other services need existing allow rules.\n' >&2
                if ufw --force enable >/dev/null; then
                    printf 'UFW is enabled with SSH access allowed first.\n'
                else
                    printf 'EZxray: UFW rules were added, but enabling UFW failed; check `ufw status` and the VPS host/provider firewall.\n' >&2
                    firewall_failed=true
                fi
            fi
        elif ((${#SSH_PORTS[@]} > 0)); then
            printf 'EZxray: UFW was not enabled because required allow rules could not be confirmed.\n' >&2
            firewall_failed=true
        fi
    fi

    printf 'UFW inbound rules requested: TCP and UDP on the 12 selected ports, plus 443 and 53.\n'
    if [[ -n $environment && $environment != none ]]; then
        printf 'Container detected (%s): also permit and forward TCP and UDP on the selected ports, 443, and 53 at the VPS host/provider.\n' "$environment"
    fi
    if [[ $firewall_failed == true ]]; then
        printf 'EZxray is installed, but firewall setup is incomplete; review `ufw status` and rerun with --reconfigure after resolving the issue.\n' >&2
        return 1
    fi
}

reload_service_for_current_mode() {
    systemctl daemon-reload
    if [[ $RECONFIGURE == true ]]; then
        if [[ $SERVICE_WAS_ACTIVE == true ]]; then
            systemctl restart "$SERVICE_NAME"
        fi
    else
        systemctl enable --now "$SERVICE_NAME"
    fi
}

ensure_service_account() {
    SERVICE_USER_CREATED=false
    SERVICE_GROUP_CREATED=false

    if ! getent group "$SERVICE_GROUP" >/dev/null; then
        groupadd --system "$SERVICE_GROUP" || die "could not create the $SERVICE_GROUP system group"
        SERVICE_GROUP_CREATED=true
    fi
    if ! getent passwd "$SERVICE_USER" >/dev/null; then
        useradd --system --gid "$SERVICE_GROUP" --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER" || die "could not create the $SERVICE_USER system account"
        SERVICE_USER_CREATED=true
    fi
}

validate_service_account() {
    local passwd_entry group_entry user_gid group_gid group_members
    passwd_entry=$(getent passwd "$SERVICE_USER" || true)
    group_entry=$(getent group "$SERVICE_GROUP" || true)

    if [[ $RECONFIGURE != true ]]; then
        [[ -z $passwd_entry && -z $group_entry ]] || die "the dedicated $SERVICE_USER account or group already exists; refusing to reuse it"
        return 0
    fi

    if [[ -n $passwd_entry ]]; then
        [[ -n $group_entry ]] || die "the managed service account exists without its $SERVICE_GROUP group"
        IFS=: read -r _ _ _ user_gid _ _ _ <<< "$passwd_entry"
        IFS=: read -r _ _ group_gid group_members <<< "$group_entry"
        [[ $user_gid == "$group_gid" ]] || die "the $SERVICE_USER account does not use the expected primary group"
        [[ -z $group_members || $group_members == "$SERVICE_USER" ]] || die "the $SERVICE_GROUP group contains unrelated accounts"
    else
        [[ -z $group_entry ]] || die "the $SERVICE_GROUP group exists without the managed service account"
    fi
}

point_config_to_managed_tls() {
    python3 - "$1" "$TLS_CERT_MANAGED_PATH" "$TLS_KEY_MANAGED_PATH" <<'PY'
import json
import sys

path, certificate, private_key = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    config = json.load(source)
for inbound in config.get("inbounds", []):
    tls = inbound.get("streamSettings", {}).get("tlsSettings")
    if not tls:
        continue
    for item in tls.get("certificates", []):
        item["certificateFile"] = certificate
        item["keyFile"] = private_key
with open(path, "w", encoding="utf-8") as output:
    json.dump(config, output, indent=2)
    output.write("\n")
PY
}

parse_arguments() {
    CLI_DOMAIN=""
    CLI_TLS_CERT=""
    CLI_TLS_KEY=""
    CLI_PORTS=""
    CLI_PORTS_SET=false
    RECONFIGURE=false

    while (($#)); do
        case $1 in
            --domain)
                (($# >= 2)) || die "--domain requires a value"
                CLI_DOMAIN=$2
                shift 2
                ;;
            --domain=*) CLI_DOMAIN=${1#*=}; shift ;;
            --tls-cert)
                (($# >= 2)) || die "--tls-cert requires a value"
                CLI_TLS_CERT=$2
                shift 2
                ;;
            --tls-cert=*) CLI_TLS_CERT=${1#*=}; shift ;;
            --tls-key)
                (($# >= 2)) || die "--tls-key requires a value"
                CLI_TLS_KEY=$2
                shift 2
                ;;
            --tls-key=*) CLI_TLS_KEY=${1#*=}; shift ;;
            --ports)
                (($# >= 2)) || die "--ports requires a comma-separated list"
                CLI_PORTS=$2
                CLI_PORTS_SET=true
                shift 2
                ;;
            --ports=*) CLI_PORTS=${1#*=}; CLI_PORTS_SET=true; shift ;;
            --reconfigure) RECONFIGURE=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown option: $1" ;;
        esac
    done
}

main() {
    set -Eeuo pipefail
    umask 077
    parse_arguments "$@"

    if [[ -e $MARKER_PATH || -L $MARKER_PATH ]]; then
        if [[ $RECONFIGURE != true ]]; then
            printf 'EZxray is already marked as installed. No files or services were changed. Use --reconfigure to update it.\n'
            return 0
        fi
        [[ -f $STATE_PATH ]] || die "managed state is missing; refusing to overwrite the installation"
    elif [[ $RECONFIGURE == true ]]; then
        die "--reconfigure requires an EZxray managed installation"
    elif has_unmanaged_collision; then
        die "existing files were left unchanged; inspect them before installing EZxray"
    fi

    require_systemd
    TEMP_DIR=$(mktemp -d)
    MUTATION_STARTED=false
    SERVICE_WAS_ACTIVE=false
    SERVICE_WAS_ENABLED=false
    SERVICE_USER_CREATED=false
    SERVICE_GROUP_CREATED=false
    trap on_exit EXIT

    if [[ $RECONFIGURE == true ]]; then
        ensure_dependencies
        [[ $(< "$MARKER_PATH") == "EZxray managed ${EZXRAY_VERSION}" ]] || die "managed marker is not recognized; refusing to overwrite files"
        service_is_active && SERVICE_WAS_ACTIVE=true || true
        service_is_enabled && SERVICE_WAS_ENABLED=true || true
        load_state
        DOMAIN=${CLI_DOMAIN:-$DOMAIN}
        TLS_CERT=${CLI_TLS_CERT:-$TLS_CERT}
        TLS_KEY=${CLI_TLS_KEY:-$TLS_KEY}
        if [[ $CLI_PORTS_SET == true ]]; then
            parse_port_list "$CLI_PORTS" || die "--ports must contain exactly 12 unique ports from 1 through 65535"
        fi
    else
        DOMAIN=$CLI_DOMAIN
        TLS_CERT=$CLI_TLS_CERT
        TLS_KEY=$CLI_TLS_KEY
        if [[ -t 0 ]]; then
            [[ -n $DOMAIN ]] || read -r -p 'Public DNS domain: ' DOMAIN
            [[ -n $TLS_CERT ]] || read -r -p 'Absolute TLS certificate/full-chain path: ' TLS_CERT
            [[ -n $TLS_KEY ]] || read -r -p 'Absolute TLS private-key path: ' TLS_KEY
        fi
        [[ -n $DOMAIN && -n $TLS_CERT && -n $TLS_KEY ]] || die "provide --domain, --tls-cert and --tls-key (or run interactively)"
    fi

    validate_domain
    ensure_dependencies
    validate_tls_files
    validate_service_account

    if [[ $CLI_PORTS_SET == true && $RECONFIGURE != true ]]; then
        parse_port_list "$CLI_PORTS" || die "--ports must contain exactly 12 unique ports from 1 through 65535"
    elif [[ $RECONFIGURE != true ]]; then
        select_automatic_ports
    fi
    for port in "${SELECTED_PORTS[@]}"; do
        port_is_available "$port" || die "port $port is already bound; no existing process was stopped"
    done

    if [[ $RECONFIGURE != true ]]; then
        generate_credentials
    fi

    write_render_spec "$TEMP_DIR/render-spec"
    render_artifacts "$TEMP_DIR/config.json" "$TEMP_DIR/profiles.txt" "$TEMP_DIR/state.json" "$TEMP_DIR/render-spec" || die "could not render Xray config and profiles"
    write_service_unit "$TEMP_DIR/ezxray.service"
    printf 'EZxray managed %s\n' "$EZXRAY_VERSION" > "$TEMP_DIR/managed"

    if [[ -x $XRAY_BIN ]]; then
        XRAY_FOR_TEST=$XRAY_BIN
    else
        mkdir -p "$TEMP_DIR/release"
        download_xray "$TEMP_DIR/release/xray"
        XRAY_FOR_TEST="$TEMP_DIR/release/xray"
    fi
    "$XRAY_FOR_TEST" run -test -config "$TEMP_DIR/config.json" || die "Xray rejected the generated configuration"

    if [[ $RECONFIGURE == true ]]; then
        save_backup
    fi
    MUTATION_STARTED=true
    install -d -m 0755 "$(dirname "$XRAY_CONFIG_PATH")" "$XRAY_RELEASE_DIR" "$(dirname "$PROFILE_PATH")" "$EZXRAY_DIR" "$(dirname "$SERVICE_PATH")"
    ensure_service_account
    install -o root -g "$SERVICE_GROUP" -m 0640 "$TLS_CERT" "$TLS_CERT_MANAGED_PATH.new.$$"
    mv -f -- "$TLS_CERT_MANAGED_PATH.new.$$" "$TLS_CERT_MANAGED_PATH"
    install -o root -g "$SERVICE_GROUP" -m 0640 "$TLS_KEY" "$TLS_KEY_MANAGED_PATH.new.$$"
    mv -f -- "$TLS_KEY_MANAGED_PATH.new.$$" "$TLS_KEY_MANAGED_PATH"
    point_config_to_managed_tls "$TEMP_DIR/config.json" || die "could not set managed TLS paths in Xray config"
    "$XRAY_FOR_TEST" run -test -config "$TEMP_DIR/config.json" || die "Xray rejected the final managed configuration"

    if [[ $XRAY_FOR_TEST != "$XRAY_BIN" ]]; then
        install -m 0755 "$XRAY_FOR_TEST" "$XRAY_BIN.new.$$"
        mv -f -- "$XRAY_BIN.new.$$" "$XRAY_BIN"
    fi
    install -o root -g "$SERVICE_GROUP" -m 0640 "$TEMP_DIR/config.json" "$XRAY_CONFIG_PATH.new.$$"
    mv -f -- "$XRAY_CONFIG_PATH.new.$$" "$XRAY_CONFIG_PATH"
    install -m 0600 "$TEMP_DIR/profiles.txt" "$PROFILE_PATH.new.$$"
    mv -f -- "$PROFILE_PATH.new.$$" "$PROFILE_PATH"
    install -m 0600 "$TEMP_DIR/state.json" "$STATE_PATH.new.$$"
    mv -f -- "$STATE_PATH.new.$$" "$STATE_PATH"
    install -m 0644 "$TEMP_DIR/ezxray.service" "$SERVICE_PATH.new.$$"
    mv -f -- "$SERVICE_PATH.new.$$" "$SERVICE_PATH"
    if [[ $RECONFIGURE != true ]]; then
        install -m 0600 "$TEMP_DIR/managed" "$MARKER_PATH.new.$$"
        mv -f -- "$MARKER_PATH.new.$$" "$MARKER_PATH"
    fi

    reload_service_for_current_mode
    MUTATION_STARTED=false
    open_firewall_if_available

    if [[ $RECONFIGURE == true && $SERVICE_WAS_ACTIVE != true ]]; then
        printf '\nEZxray was reconfigured; its previously inactive service remains stopped. Profiles: %s\n' "$PROFILE_PATH"
    else
        printf '\nEZxray is active. Generated 12 profiles: %s\n' "$PROFILE_PATH"
    fi
    printf 'Automatic port selection excludes 443; explicitly supplied 443 is allowed when free.\n'
    printf 'TLS files are copied into %s; rerun with --reconfigure after renewing the source certificate and key.\n' "$EZXRAY_DIR"
    printf 'No bandwidth shaping is configured; the VPS/provider link remains the speed limit.\n'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
