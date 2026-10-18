#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || {
    printf '[!] Could not determine the directory containing new_vps.sh\n' >&2
    exit 1
}

MASTERDNS_CONFIG_URL="https://raw.githubusercontent.com/ashkan-esz/script/main/master_dns_g69_server_config.toml"
MASTERDNS_INSTALLER_URL="https://raw.githubusercontent.com/masterking32/MasterDnsVPN/main/server_linux_install.sh"
MASTERDNS_VERSION="v2026.04.05.191930-7757d2d"
MASTERDNS_ENCRYPT_KEY="953c72f45cc7518051016382586d7a87"
SSH_CIPHERS="chacha20-poly1305@openssh.com,aes256-gcm@openssh.com"

SYSCTL_QDISC_FILE="/etc/sysctl.d/99-sshuttle.conf"
SYSCTL_IPV6_FILE="/etc/sysctl.d/99-disable-ipv6.conf"
SSHD_CONFIG="/etc/ssh/sshd_config"
ENCRYPT_KEY_FILE="/root/encrypt_key.txt"
MASTERDNS_CONFIG_FILE="/root/server_config.toml"
XRAY_INSTALLER_URL="https://raw.githubusercontent.com/ashkan-esz/script/main/new_vps_xray.sh"
XRAY_INSTALLER="$SCRIPT_DIR/new_vps_xray.sh"

SSH_BLOCK_BEGIN="# BEGIN new_vps.sh managed SSH settings"
SSH_BLOCK_END="# END new_vps.sh managed SSH settings"
STEP="startup"
TEMP_DIR=""
SSH_BACKUP=""
SSH_TEMP_FILE=""
SSH_SERVICE_UNIT=""

die() {
    printf '[!] %s: %s\n' "$STEP" "$*" >&2
    exit 1
}

on_error() {
    local status="$1"
    trap - ERR
    printf '[!] Setup failed during %s (exit status %s).\n' "$STEP" "$status" >&2
    exit "$status"
}

cleanup() {
    local status=$?
    trap - EXIT

    if [[ -n ${SSH_TEMP_FILE:-} ]]; then
        rm -f -- "$SSH_TEMP_FILE" || true
    fi
    if [[ -n ${TEMP_DIR:-} && -d $TEMP_DIR ]]; then
        rm -rf -- "$TEMP_DIR" || true
    fi

    return "$status"
}

require_command() {
    local name
    for name in "$@"; do
        command -v "$name" >/dev/null 2>&1 || die "required command is missing: $name"
    done
}

run_required() {
    local description="$1"
    shift
    "$@" || die "$description failed"
}

is_root() {
    [[ $(id -u) == 0 ]]
}

has_interactive_terminal() {
    [[ -t 0 ]]
}

validate_port() {
    local supplied_port=${PORT:-6060}
    local numeric_port

    [[ $supplied_port =~ ^[0-9]{1,5}$ ]] ||
        die "PORT must be a TCP port from 1 through 65535"

    numeric_port=$((10#$supplied_port))
    ((numeric_port >= 1 && numeric_port <= 65535)) ||
        die "PORT must be a TCP port from 1 through 65535"

    PORT="$numeric_port"
}

detect_ssh_service() {
    local candidate

    for candidate in ssh.service sshd.service; do
        if systemctl list-unit-files --no-legend "$candidate" 2>/dev/null |
            awk -v wanted="$candidate" '$1 == wanted { found = 1 } END { exit !found }'; then
            SSH_SERVICE_UNIT="$candidate"
            return 0
        fi
    done

    die "could not find an ssh.service or sshd.service systemd unit"
}

preflight() {
    (($# == 0)) || die "this script takes no arguments; set PORT in the environment"
    is_root || die "run this script as root"
    validate_port
    has_interactive_terminal ||
        die "a terminal is required because the Xray installer is invoked without arguments"

    [[ -f $SSHD_CONFIG && ! -L $SSHD_CONFIG && -r $SSHD_CONFIG ]] ||
        die "SSH configuration is missing, unreadable, or not a regular file: $SSHD_CONFIG"

    require_command \
        id apt-get systemctl sshd bash mktemp install awk chmod chown cp mv rm dirname curl \
        useradd chpasswd sysctl
    detect_ssh_service

    if ! sshd -t -f "$SSHD_CONFIG"; then
        die "the existing SSH configuration is invalid; no setup changes were made"
    fi
}

create_gang_user() {
    printf '[+] Creating user -> gang:Gang!@#123 \n'
    useradd -m gang || true
    printf '%s\n' 'gang:Gang!@#123' | chpasswd
}

install_base_packages() {
    printf '[+] Updating system\n'
    run_required "apt-get update" apt-get update
    run_required "base package installation" apt-get install -y \
        ca-certificates curl gnupg unzip htop make sudo \
        iptables-persistent

    require_command curl sysctl iptables netfilter-persistent useradd chpasswd sshd
}

write_sysctl_settings() {
    run_required "creating sysctl configuration directory" install -d -m 0755 -- "$(dirname -- "$SYSCTL_QDISC_FILE")"
    run_required "creating IPv6 sysctl configuration directory" install -d -m 0755 -- "$(dirname -- "$SYSCTL_IPV6_FILE")"

    printf '%s\n' 'net.core.default_qdisc = fq' > "$SYSCTL_QDISC_FILE" ||
        die "writing fq sysctl configuration failed"
    printf '%s\n' \
        'net.ipv6.conf.all.disable_ipv6 = 1' \
        'net.ipv6.conf.default.disable_ipv6 = 1' > "$SYSCTL_IPV6_FILE" ||
        die "writing IPv6 sysctl configuration failed"
}

configure_mss_clamping() {
    printf '[+] Adding TCP MSS clamping\n'
    if ! iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
        run_required "adding the TCP MSS iptables rule" \
            iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu
    fi
    run_required "saving persistent iptables rules" netfilter-persistent save
}

disable_optional_services() {
    printf '[+] Disabling unnecessary services (safe on small VPS)\n'
    systemctl disable --now snapd 2>/dev/null || true
    systemctl disable --now unattended-upgrades 2>/dev/null || true
}

download_file() {
    local url="$1"
    local destination="$2"

    curl --fail --silent --show-error --location --retry 3 \
        --connect-timeout 15 --output "$destination" "$url"
}

prepare_xray_installer() {
    [[ -f $XRAY_INSTALLER && -r $XRAY_INSTALLER ]] && return 0

    XRAY_INSTALLER="$TEMP_DIR/new_vps_xray.sh"
    printf '[+] Downloading Xray installer\n'
    download_file "$XRAY_INSTALLER_URL" "$XRAY_INSTALLER" ||
        die "downloading the Xray installer failed"
    [[ -s $XRAY_INSTALLER ]] || die "the downloaded Xray installer is empty"
}

install_masterdns() {
    local key_staging="$TEMP_DIR/encrypt_key.txt"
    local config_staging="$TEMP_DIR/server_config.toml"
    local installer_staging="$TEMP_DIR/masterdns-installer.sh"

    printf '[+] Installing master dns vpn key\n'
    printf '%s\n' "$MASTERDNS_ENCRYPT_KEY" > "$key_staging" ||
        die "staging the MasterDNS key failed"

    printf '[+] Downloading master dns vpn configuration\n'
    download_file "$MASTERDNS_CONFIG_URL" "$config_staging" ||
        die "downloading the MasterDNS configuration failed"

    printf '[+] Downloading master dns vpn installer\n'
    download_file "$MASTERDNS_INSTALLER_URL" "$installer_staging" ||
        die "downloading the MasterDNS installer failed"

    run_required "installing the MasterDNS key" install -m 0600 -- "$key_staging" "$ENCRYPT_KEY_FILE"
    run_required "installing the MasterDNS configuration" \
        install -m 0600 -- "$config_staging" "$MASTERDNS_CONFIG_FILE"

    printf '[+] Installing master dns vpn script (c.g69.lol)\n'
    run_required "running the MasterDNS installer" bash "$installer_staging" --version "$MASTERDNS_VERSION"
}

rewrite_sshd_config() {
    local cleaned_config="$TEMP_DIR/sshd_config.cleaned"
    local managed_block="$TEMP_DIR/sshd_config.managed"

    if ! cat > "$managed_block" <<EOF
$SSH_BLOCK_BEGIN
TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 3
Compression no
UseDNS no
Ciphers $SSH_CIPHERS
AllowTcpForwarding yes
GatewayPorts yes
$SSH_BLOCK_END
EOF
    then
        die "could not write the managed SSH settings block"
    fi

    if ! awk -v begin="$SSH_BLOCK_BEGIN" -v end="$SSH_BLOCK_END" '
        $0 == begin { inside = 1; next }
        $0 == end { inside = 0; next }
        !inside { print }
        END { if (inside) exit 2 }
    ' "$SSHD_CONFIG" > "$cleaned_config"; then
        die "an incomplete managed SSH settings block already exists"
    fi

    SSH_TEMP_FILE="$(mktemp "${SSHD_CONFIG}.new.XXXXXXXX")" ||
        die "could not create a temporary SSH configuration file"
    if ! cat "$managed_block" > "$SSH_TEMP_FILE"; then
        die "could not write the managed SSH settings to the temporary configuration"
    fi
    if ! cat "$cleaned_config" >> "$SSH_TEMP_FILE"; then
        die "could not append the existing SSH configuration to the temporary configuration"
    fi
    chmod --reference="$SSHD_CONFIG" "$SSH_TEMP_FILE" ||
        die "could not preserve SSH configuration permissions"
    chown --reference="$SSHD_CONFIG" "$SSH_TEMP_FILE" ||
        die "could not preserve SSH configuration ownership"
    mv -- "$SSH_TEMP_FILE" "$SSHD_CONFIG" ||
        die "could not atomically replace the SSH configuration"
    SSH_TEMP_FILE=""
}

restore_sshd_config() {
    [[ -n $SSH_BACKUP && -f $SSH_BACKUP ]] ||
        die "cannot restore SSH configuration because the backup is missing"
    cp --preserve=all -- "$SSH_BACKUP" "$SSHD_CONFIG" ||
        die "failed to restore the original SSH configuration from $SSH_BACKUP"
}

configure_ssh() {
    STEP="configuring SSH"
    printf '[+] Configuring SSH and reverse tunneling\n'

    SSH_BACKUP="$(mktemp "${SSHD_CONFIG}.backup.XXXXXXXX")" ||
        die "could not create an SSH configuration backup"
    cp --preserve=all -- "$SSHD_CONFIG" "$SSH_BACKUP" ||
        die "could not copy the SSH configuration to its backup"
    rewrite_sshd_config

    if ! sshd -t -f "$SSHD_CONFIG"; then
        restore_sshd_config
        die "sshd rejected the updated configuration; the original file was restored"
    fi

    if ! systemctl restart "$SSH_SERVICE_UNIT"; then
        restore_sshd_config
        if ! systemctl restart "$SSH_SERVICE_UNIT"; then
            printf '[!] SSH restart also failed after restoring the original configuration.\n' >&2
        fi
        die "SSH restart failed; the original configuration was restored"
    fi

    printf '[+] SSH configuration backup saved to %s\n' "$SSH_BACKUP"
}

run_xray_installer() {
    local status_output

    printf '[+] Installing new_vps_xray.sh\n'
    run_required "running the Xray installer" bash "$XRAY_INSTALLER"
    if ! status_output="$(bash "$XRAY_INSTALLER" --status)"; then
        die "could not verify Xray installation status"
    fi
    [[ $status_output == *$'Installation: installed'* ]] ||
        die "the Xray menu returned without a valid managed installation"
}

configure_ufw_port() {
    local firewall_status

    if ! command -v ufw >/dev/null 2>&1; then
        printf '[+] UFW is not installed; no reverse-tunnel firewall rule added\n'
        return 0
    fi

    if ! firewall_status="$(ufw status 2>&1)"; then
        die "could not read UFW status: $firewall_status"
    fi

    case "$firewall_status" in
        *"Status: active"*)
            printf '[+] Opening TCP port %s in UFW\n' "$PORT"
            run_required "adding the reverse-tunnel UFW rule" ufw allow "$PORT/tcp"
            ;;
        *"Status: inactive"*)
            printf '[+] UFW is inactive; the reverse-tunnel TCP rule was not enabled\n'
            ;;
        *)
            die "could not determine UFW status; review it before continuing"
            ;;
    esac
}

run_setup() {
    STEP="creating the gang user"
    run_required "creating the gang user" create_gang_user

    STEP="updating system packages"
    run_required "updating system packages" install_base_packages

    STEP="writing and applying sysctl settings"
    printf '[+] Enabling fq and disabling IPv6\n'
    run_required "writing sysctl settings" write_sysctl_settings
    run_required "applying sysctl settings" sysctl --system

    STEP="saving the TCP MSS rule"
    run_required "configuring TCP MSS clamping" configure_mss_clamping

    STEP="disabling optional services"
    run_required "disabling optional services" disable_optional_services

    STEP="installing MasterDNS"
    run_required "installing MasterDNS" install_masterdns

    STEP="installing Xray"
    run_required "installing Xray" run_xray_installer

    run_required "configuring SSH" configure_ssh

    STEP="configuring the reverse-tunnel firewall rule"
    run_required "configuring the reverse-tunnel firewall rule" configure_ufw_port

    printf '[✓] Server setup complete\n'
    printf '[+] Better to change the password\n'
}

main() {
    set -Eeuo pipefail
    umask 077
    trap 'on_error "$?"' ERR
    trap cleanup EXIT

    STEP="preflight checks"
    preflight "$@"

    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/new-vps.XXXXXXXX")"
    prepare_xray_installer
    run_setup
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
