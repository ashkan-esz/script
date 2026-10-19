#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
PROJECTS_DIR="$TMP_DIR/projects"
export PROJECTS_DIR
ID=debian

source "$ROOT_DIR/new_vps_projects/new_vps_projects.sh"

ENGINE_LOG="$TMP_DIR/engine.log"
APT_LOG="$TMP_DIR/apt.log"
START_LOG="$TMP_DIR/start.log"
MENU_OUTPUT="$TMP_DIR/menu-output"
STAGE_OUTPUT="$TMP_DIR/stage-output"
SIDE_EFFECT_LOG="$TMP_DIR/side-effects.log"
: > "$ENGINE_LOG"
: > "$APT_LOG"
: > "$START_LOG"
: > "$SIDE_EFFECT_LOG"

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

set_compose_slowmeet_value() {
    local key="$1" value="$2"
    sed -i "s|^      ${key}: .*|      ${key}: \"${value}\"|" "$COMPOSE_FILE"
}

install_docker() {
    printf 'docker\n' >> "$ENGINE_LOG"
}

apt-get() {
    printf '%s\n' "$*" >> "$APT_LOG"
}

docker() {
    printf 'docker %s\n' "$*" >> "$START_LOG"
}

podman-compose() {
    printf 'podman-compose %s\n' "$*" >> "$START_LOG"
}

systemctl() {
    printf 'systemctl %s\n' "$*" >> "$SIDE_EFFECT_LOG"
}

ufw() {
    printf 'ufw %s\n' "$*" >> "$SIDE_EFFECT_LOG"
}

iptables() {
    printf 'iptables %s\n' "$*" >> "$SIDE_EFFECT_LOG"
}

choose_engine <<<"1" > "$MENU_OUTPUT"
assert_eq "${ENGINE_CHOICE:-}" "docker" "Docker menu choice should be retained"
install_selected_engine > "$STAGE_OUTPUT"
assert_eq "$(< "$ENGINE_LOG")" "docker" "Docker choice should install Docker"
assert_contains "$(< "$MENU_OUTPUT")" "Podman" "menu should offer Podman"

COMPOSE_FILE="$PROJECTS_DIR/compose.yaml"
CRAB_DUMP_ENV_FILE="$PROJECTS_DIR/crab_dump.env"
SLOW_MEET_ENV_FILE="$PROJECTS_DIR/slow_meet.env"
PODMAN_SERVICE_FILE="$PROJECTS_DIR/podman-compose.service"
[[ -f $COMPOSE_FILE ]] || fail "Compose file should be staged"
[[ -f $CRAB_DUMP_ENV_FILE ]] || fail "Crab Dump env file should be staged"
[[ -f $SLOW_MEET_ENV_FILE ]] || fail "SlowMeet env file should be staged"
[[ -f $PODMAN_SERVICE_FILE ]] || fail "optional Podman systemd unit should be staged"
[[ $(stat -c '%a' "$CRAB_DUMP_ENV_FILE") == 600 ]] || fail "Crab Dump env file should be mode 0600"
[[ $(stat -c '%a' "$SLOW_MEET_ENV_FILE") == 600 ]] || fail "SlowMeet env file should be mode 0600"
cmp -s "$ROOT_DIR/new_vps_projects/crab_dump.sample.env" "$CRAB_DUMP_ENV_FILE" ||
    fail "Crab Dump env file should be copied from its sample"
cmp -s "$ROOT_DIR/new_vps_projects/slow_meet.sample.env" "$SLOW_MEET_ENV_FILE" ||
    fail "SlowMeet env file should be copied from its sample"
assert_contains "$(< "$COMPOSE_FILE")" "crab-dump:" "Compose should include Crab Dump"
assert_contains "$(< "$COMPOSE_FILE")" "slowmeet:" "Compose should include SlowMeet"
assert_contains "$(< "$COMPOSE_FILE")" "image: ghcr.io/ashkan-esz/slowmeet" \
    "SlowMeet should keep its floating image reference"
assert_contains "$(< "$COMPOSE_FILE")" "image: ghcr.io/ashkan-esz/crab-dump" \
    "Crab Dump should keep its floating image reference"
if grep -q '@sha256:' "$COMPOSE_FILE"; then
    fail "Compose image references should remain unpinned"
fi
if grep -Eq '^[[:space:]]*image: ghcr.io/ashkan-esz/(slowmeet|crab-dump)(:|@)' "$COMPOSE_FILE"; then
    fail "Compose image references should not use pinned tags or digests"
fi
[[ $(grep -c 'network_mode: host' "$COMPOSE_FILE") == 2 ]] ||
    fail "both services should keep host networking"
assert_contains "$(< "$COMPOSE_FILE")" 'HTTP_ADDR: ":1102"' \
    "SlowMeet should bind directly to host port 1102"
assert_contains "$(< "$COMPOSE_FILE")" \
    'HTTP_PUBLISH_ADDRESS: "replace-with-server-public-ip-or-domain"' \
    "SlowMeet's advertised address should stay in Compose"
assert_contains "$(< "$COMPOSE_FILE")" 'HTTP_PUBLISH_PORT: "1102"' \
    "SlowMeet's advertised port should stay in Compose"
if grep -q '^[[:space:]]*ports:' "$COMPOSE_FILE"; then
    fail "host-network services should not configure Compose port mappings"
fi
assert_contains "$(< "$COMPOSE_FILE")" 'mem_limit: "50mb"' \
    "Crab Dump's memory limit should remain unchanged"
assert_contains "$(< "$COMPOSE_FILE")" 'memswap_limit: "50mb"' \
    "Crab Dump's memory-plus-swap limit should remain unchanged"
assert_contains "$(< "$COMPOSE_FILE")" 'cpus: "0.20"' \
    "Crab Dump's CPU limit should remain unchanged"
assert_contains "$(< "$COMPOSE_FILE")" 'DB_NAME_0: "app"' \
    "Crab Dump's non-secret database name should stay in Compose"
assert_contains "$(< "$COMPOSE_FILE")" 'TG_CHAT_ID_0: "123456"' \
    "Crab Dump's non-secret chat ID should stay in Compose"
if grep -Eq '^(HTTP_PUBLISH_|ICE_UDP_|ICE_PUBLIC_IP=|STUN_SERVERS=|TURN_URLS=|TURN_CREDENTIAL_TTL_SECONDS=)' \
    "$SLOW_MEET_ENV_FILE"; then
    fail "SlowMeet's non-secret application settings should stay in Compose"
fi
if grep -Eq '^(DB_NAME_0|TG_CHAT_ID_0|DASHBOARD_USERNAME|ENCRYPTION_TYPE)=' "$CRAB_DUMP_ENV_FILE"; then
    fail "Crab Dump's non-secret application settings should stay in Compose"
fi
assert_contains "$(< "$PODMAN_SERVICE_FILE")" "WorkingDirectory=$PROJECTS_DIR" \
    "Podman systemd unit should use the resolved projects directory"
assert_contains "$(< "$STAGE_OUTPUT")" "Placeholder credential remains" \
    "default credentials should be flagged before start instructions"
assert_contains "$(< "$STAGE_OUTPUT")" "HTTP_PUBLISH_PORT matches the HTTP_ADDR host-listener port (1102)" \
    "default SlowMeet publish ports should match"
assert_contains "$(< "$STAGE_OUTPUT")" "HTTP_PUBLISH_ADDRESS must be a reachable server IP or DNS name" \
    "the placeholder advertised address should be flagged"
assert_contains "$(< "$STAGE_OUTPUT")" "Host and cloud firewall rules were left unchanged" \
    "host-network firewall behavior should be documented"
assert_contains "$(< "$STAGE_OUTPUT")" "host TCP 1102 and UDP 50000-50100" \
    "SlowMeet's host-network port requirements should be shown"
VALIDATION_LINE="$(grep -n 'HTTP_PUBLISH_PORT matches' "$STAGE_OUTPUT" | cut -d: -f1)"
START_LINE="$(grep -n 'After editing compose.yaml and the environment files' "$STAGE_OUTPUT" | cut -d: -f1)"
((VALIDATION_LINE < START_LINE)) || fail "configuration checks should appear before start instructions"

printf 'DATABASE_URL_0=postgresql://user:custom@127.0.0.1:5432/app\n' > "$CRAB_DUMP_ENV_FILE"
printf 'ADMIN_PASSWORD=custom-password\nTURN_PASSWORD=custom-turn-password\n' > "$SLOW_MEET_ENV_FILE"
set_compose_slowmeet_value HTTP_PUBLISH_ADDRESS meet.example.com
set_compose_slowmeet_value HTTP_PUBLISH_PORT 1103
prepare_project_stack > "$STAGE_OUTPUT"
assert_contains "$(< "$STAGE_OUTPUT")" \
    "HTTP_PUBLISH_PORT (1103) does not match the HTTP_ADDR host-listener port (1102)" \
    "mismatched SlowMeet publish ports should be flagged"
assert_contains "$(< "$STAGE_OUTPUT")" "HTTP_PUBLISH_ADDRESS is configured" \
    "a valid SlowMeet advertised address should be accepted"

set_compose_slowmeet_value HTTP_PUBLISH_ADDRESS 0.0.0.0
set_compose_slowmeet_value HTTP_PUBLISH_PORT 1102
prepare_project_stack > "$STAGE_OUTPUT"
assert_contains "$(< "$STAGE_OUTPUT")" \
    "HTTP_PUBLISH_ADDRESS must be a reachable server IP or DNS name" \
    "a wildcard SlowMeet advertised address should be rejected"

printf 'local-crab-config\n' > "$CRAB_DUMP_ENV_FILE"
printf 'TURN_PASSWORD=custom-turn-password\nlocal-slowmeet-config\n' > "$SLOW_MEET_ENV_FILE"
printf 'local-compose-config\n' > "$COMPOSE_FILE"

: > "$MENU_OUTPUT"
choose_engine <<< $'invalid\n2' > "$MENU_OUTPUT" 2>&1
assert_eq "${ENGINE_CHOICE:-}" "podman" "menu should accept a valid choice after invalid input"
install_selected_engine > "$STAGE_OUTPUT"
assert_contains "$(< "$APT_LOG")" "install -y podman podman-compose" \
    "Podman installation should include the Compose provider"
assert_contains "$(< "$MENU_OUTPUT")" "Invalid choice" "invalid input should be explained"
assert_contains "$(< "$STAGE_OUTPUT")" "systemctl enable --now vps-projects-podman.service" \
    "the optional Podman systemd unit should only be offered as a manual action"
assert_eq "$(< "$CRAB_DUMP_ENV_FILE")" "local-crab-config" "existing Crab Dump env should be preserved"
assert_eq "$(< "$SLOW_MEET_ENV_FILE")" $'TURN_PASSWORD=custom-turn-password\nlocal-slowmeet-config' \
    "existing SlowMeet env should be preserved"
assert_eq "$(< "$COMPOSE_FILE")" "local-compose-config" "existing Compose settings should be preserved on reruns"

id() {
    [[ ${1:-} == -u ]] && { printf '0\n'; return 0; }
    command id "$@"
}
main --refresh-compose > "$STAGE_OUTPUT"
main --refresh-compose > "$STAGE_OUTPUT"
unset -f id
shopt -s nullglob
COMPOSE_BACKUPS=("$COMPOSE_FILE".backup-*)
[[ ${#COMPOSE_BACKUPS[@]} == 2 ]] || fail "repeated Compose refresh should create unique backups"
BACKUP_PRESERVED=0
for backup_file in "${COMPOSE_BACKUPS[@]}"; do
    if [[ $(< "$backup_file") == local-compose-config ]]; then
        BACKUP_PRESERVED=1
    fi
done
((BACKUP_PRESERVED == 1)) || fail "Compose refresh should preserve the previous configuration in a backup"
assert_contains "$(< "$STAGE_OUTPUT")" "Compose file refreshed." "Compose refresh should report success"
cmp -s "$ROOT_DIR/new_vps_projects/compose.yaml" "$COMPOSE_FILE" ||
    fail "Compose refresh should install the current template"
assert_eq "$(< "$CRAB_DUMP_ENV_FILE")" "local-crab-config" \
    "Compose refresh should not replace Crab Dump environment"
assert_eq "$(< "$SLOW_MEET_ENV_FILE")" $'TURN_PASSWORD=custom-turn-password\nlocal-slowmeet-config' \
    "Compose refresh should not replace SlowMeet environment"
[[ ! -s $START_LOG ]] || fail "setup must not start containers"
[[ ! -s $SIDE_EFFECT_LOG ]] || fail "staging must not change firewall or systemd state"

printf 'PASS: engine selection, host-network Compose staging, validation, backups, env preservation, and no container or firewall changes\n'
