#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/new_vps.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
COMMAND_LOG="$TMP_DIR/commands.log"
: > "$COMMAND_LOG"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    [[ $1 == "$2" ]] || fail "$3 (expected '$2', got '$1')"
}

assert_contains() {
    [[ $1 == *"$2"* ]] || fail "$3"
}

record() {
    printf '%s\n' "$*" >> "$COMMAND_LOG"
}

cat() {
    if [[ -n ${CAT_FAIL_SOURCE:-} && ${1:-} == "$CAT_FAIL_SOURCE" ]]; then
        return 1
    fi
    command cat "$@"
}

is_root() {
    [[ ${TEST_ROOT_OK:-1} == 1 ]]
}

has_interactive_terminal() {
    [[ ${TEST_HAS_TTY:-1} == 1 ]]
}

systemctl() {
    case $1 in
        list-unit-files)
            printf 'ssh.service enabled enabled\n'
            ;;
        restart)
            record "systemctl $*"
            [[ ${SSH_RESTART_FAIL:-0} != 1 ]]
            ;;
        disable)
            record "systemctl $*"
            return 0
            ;;
        *)
            record "systemctl $*"
            return 0
            ;;
    esac
}

sshd() {
    record "sshd $*"
    [[ ${SSH_VALIDATE_FAIL:-0} != 1 ]]
}

ufw() {
    case $1 in
        status)
            printf 'Status: %s\n' "${UFW_TEST_STATUS:-active}"
            ;;
        allow)
            record "ufw $*"
            ;;
        *)
            return 1
            ;;
    esac
}

curl() {
    local output=""
    local url=""
    while (($#)); do
        case $1 in
            --output)
                output=$2
                shift 2
                ;;
            https://*)
                url=$1
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    record "curl $url"
    [[ ${CURL_FAIL:-0} != 1 ]] || return 22
    if [[ $url == *server_config.toml ]]; then
        printf 'stub_config = true\n' > "$output"
    elif [[ $url == *server_linux_install.sh ]]; then
        cat > "$output" <<'CHILD'
#!/usr/bin/env bash
[[ ${MASTERDNS_CHILD_FAIL:-0} != 1 ]] || exit 23
printf '%s\n' "$*" >> "$CHILD_ARGS_LOG"
CHILD
    else
        printf 'stub content\n' > "$output"
    fi
}

expect_failure() {
    local label="$1"
    shift
    local output="$TMP_DIR/failure-output"

    if ( "$@" ) > "$output" 2>&1; then
        fail "$label should fail"
    fi
}

PORT=080
validate_port
assert_eq "$PORT" "80" "PORT should be normalized as a decimal number"
if ( PORT=65536; validate_port ) > "$TMP_DIR/invalid-port" 2>&1; then
    fail "PORT above 65535 should be rejected"
fi
(
    unset PORT
    validate_port
    assert_eq "$PORT" "6060" "unset PORT should default to 6060"
)
(
    PORT=
    validate_port
    assert_eq "$PORT" "6060" "empty PORT should default to 6060"
)

SSHD_CONFIG="$TMP_DIR/sshd_config"
XRAY_INSTALLER="$TMP_DIR/new_vps_xray.sh"
TEMP_DIR="$TMP_DIR/ssh-temp"
SSH_SERVICE_UNIT="ssh.service"
mkdir -p "$TEMP_DIR"
printf 'Include /etc/ssh/sshd_config.d/*.conf\n# existing comment\n' > "$SSHD_CONFIG"
printf '#!/usr/bin/env bash\nexit 0\n' > "$XRAY_INSTALLER"

TEST_HAS_TTY=0 PORT=80 expect_failure "non-TTY preflight" preflight
TEST_HAS_TTY=1 PORT=80 preflight

PORT=54321
UFW_TEST_STATUS=active
: > "$COMMAND_LOG"
configure_ufw_port
assert_contains "$(< "$COMMAND_LOG")" "ufw allow 54321/tcp" "active UFW should allow PORT over TCP"

UFW_TEST_STATUS=inactive
: > "$COMMAND_LOG"
configure_ufw_port
if [[ -s $COMMAND_LOG ]]; then
    fail "inactive UFW must not receive a firewall rule"
fi

DOWNLOAD_DESTINATION="$TMP_DIR/downloaded"
download_file "https://example.invalid/installer.sh" "$DOWNLOAD_DESTINATION"
assert_contains "$(< "$COMMAND_LOG")" "curl https://example.invalid/installer.sh" "download should invoke curl"
if ( CURL_FAIL=1; download_file "https://example.invalid/fail.sh" "$TMP_DIR/failed-download" ); then
    fail "download_file should propagate curl failures"
fi

ENCRYPT_KEY_FILE="$TMP_DIR/encrypt_key.txt"
MASTERDNS_CONFIG_FILE="$TMP_DIR/server_config.toml"
TEMP_DIR="$TMP_DIR/masterdns-temp"
mkdir -p "$TEMP_DIR"
CHILD_ARGS_LOG="$TMP_DIR/masterdns-args.log"
export CHILD_ARGS_LOG
install_masterdns
assert_eq "$(< "$CHILD_ARGS_LOG")" "--version $MASTERDNS_VERSION" "MasterDNS version argument should be preserved"
assert_eq "$(< "$MASTERDNS_CONFIG_FILE")" "stub_config = true" "downloaded MasterDNS config should be installed"
assert_eq "$(stat -c '%a' "$ENCRYPT_KEY_FILE")" "600" "MasterDNS key should be private"

rm -f -- "$ENCRYPT_KEY_FILE" "$MASTERDNS_CONFIG_FILE"
if ( CURL_FAIL=1; install_masterdns ) > "$TMP_DIR/masterdns-download-failure" 2>&1; then
    fail "MasterDNS download failures should stop installation"
fi
[[ ! -e $ENCRYPT_KEY_FILE && ! -e $MASTERDNS_CONFIG_FILE ]] ||
    fail "MasterDNS files should not be replaced until all downloads succeed"

XRAY_INSTALLER="$TMP_DIR/xray-child.sh"
XRAY_CHILD_LOG="$TMP_DIR/xray-child.log"
export XRAY_CHILD_LOG
cat > "$XRAY_INSTALLER" <<'CHILD'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$XRAY_CHILD_LOG"
if [[ ${1:-} == --status ]]; then
    printf 'Installation: %s\n' "${XRAY_TEST_STATUS:-installed}"
    exit "${XRAY_STATUS_EXIT:-0}"
fi
[[ ${XRAY_CHILD_FAIL:-0} != 1 ]] || exit 23
CHILD
run_xray_installer
assert_eq "$(< "$XRAY_CHILD_LOG")" $'\n--status' "Xray should retain its no-argument menu invocation and verify status afterward"
if ( export XRAY_CHILD_FAIL=1; run_xray_installer ) > "$TMP_DIR/xray-child-failure" 2>&1; then
    fail "a failed Xray child should fail the parent step"
fi
if ( export XRAY_TEST_STATUS='not installed'; run_xray_installer ) > "$TMP_DIR/xray-not-installed" 2>&1; then
    fail "Xray menu exit without an installation should be rejected"
fi

SSH_ORIGINAL="$(< "$SSHD_CONFIG")"
configure_ssh
configure_ssh
SSH_UPDATED="$(< "$SSHD_CONFIG")"
assert_eq "$(grep -Fc "$SSH_BLOCK_BEGIN" "$SSHD_CONFIG")" "1" "SSH settings block should be idempotent"
assert_eq "$(grep -Fc 'AllowTcpForwarding yes' "$SSHD_CONFIG")" "1" "AllowTcpForwarding should appear once"
assert_eq "$(grep -Fc 'GatewayPorts yes' "$SSHD_CONFIG")" "1" "GatewayPorts should appear once"

printf '%s\n' "$SSH_ORIGINAL" > "$SSHD_CONFIG"
SSH_ORIGINAL="$(< "$SSHD_CONFIG")"
if ( export CAT_FAIL_SOURCE="$TEMP_DIR/sshd_config.cleaned"; run_required "configuring SSH" configure_ssh ) > "$TMP_DIR/ssh-write-failure" 2>&1; then
    fail "a failed SSH configuration assembly should fail"
fi
assert_eq "$(< "$SSHD_CONFIG")" "$SSH_ORIGINAL" "failed SSH configuration assembly must leave the original file intact"

if ( SSH_VALIDATE_FAIL=1; configure_ssh ) > "$TMP_DIR/ssh-validation-failure" 2>&1; then
    fail "invalid SSH configuration should fail"
fi
assert_eq "$(< "$SSHD_CONFIG")" "$SSH_ORIGINAL" "invalid SSH configuration should restore the backup"

if ( SSH_RESTART_FAIL=1; configure_ssh ) > "$TMP_DIR/ssh-restart-failure" 2>&1; then
    fail "failed SSH restart should fail"
fi
assert_eq "$(< "$SSHD_CONFIG")" "$SSH_ORIGINAL" "failed SSH restart should restore the backup"

record_stage() {
    local stage="$1"
    record "stage $stage"
    [[ ${FAIL_STAGE:-} != "$stage" ]]
}

create_gang_user() { record_stage create_gang_user; }
install_base_packages() { record_stage install_base_packages; }
write_sysctl_settings() { record_stage write_sysctl_settings; }
sysctl() { record_stage sysctl; }
configure_mss_clamping() { record_stage configure_mss_clamping; }
disable_optional_services() { record_stage disable_optional_services; }
install_masterdns() { record_stage install_masterdns; }
run_xray_installer() { record_stage run_xray_installer; }
configure_ssh() { record_stage configure_ssh; }
configure_ufw_port() { record_stage configure_ufw_port; }

run_mocked_main() (
    PORT=54321
    TEST_ROOT_OK=1
    TEST_HAS_TTY=1
    SSHD_CONFIG="$TMP_DIR/main_sshd_config"
    XRAY_INSTALLER="$TMP_DIR/main_xray_installer"
    printf 'Port 22\n' > "$SSHD_CONFIG"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$XRAY_INSTALLER"
    main
)

: > "$COMMAND_LOG"
if ! SUCCESS_OUTPUT="$(run_mocked_main 2>&1)"; then
    fail "mocked full setup should succeed: $SUCCESS_OUTPUT"
fi
assert_contains "$SUCCESS_OUTPUT" "Server setup complete" "successful setup should report completion"

: > "$COMMAND_LOG"
if ( FAIL_STAGE=install_masterdns; run_mocked_main ) > "$TMP_DIR/stopped-output" 2>&1; then
    fail "a failed MasterDNS stage should stop the setup"
fi
STOPPED_OUTPUT="$(< "$TMP_DIR/stopped-output")"
assert_contains "$STOPPED_OUTPUT" "failed during installing MasterDNS" "failure should identify its stage"
if [[ $STOPPED_OUTPUT == *"Server setup complete"* ]]; then
    fail "failed setup must not print the completion message"
fi
if [[ $(< "$COMMAND_LOG") == *"stage run_xray_installer"* ]]; then
    fail "setup should not continue after a failed MasterDNS stage"
fi

printf 'PASS: new_vps preflight, downloads, Xray status, SSH rollback, UFW, and failure propagation\n'
