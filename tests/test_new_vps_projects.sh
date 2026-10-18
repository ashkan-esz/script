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
: > "$ENGINE_LOG"
: > "$APT_LOG"
: > "$START_LOG"

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

choose_engine <<<"1" > "$MENU_OUTPUT"
assert_eq "${ENGINE_CHOICE:-}" "docker" "Docker menu choice should be retained"
install_selected_engine
assert_eq "$(< "$ENGINE_LOG")" "docker" "Docker choice should install Docker"
assert_contains "$(< "$MENU_OUTPUT")" "Podman" "menu should offer Podman"

COMPOSE_FILE="$PROJECTS_DIR/compose.yaml"
CRAB_DUMP_ENV_FILE="$PROJECTS_DIR/crab_dump.env"
SLOW_MEET_ENV_FILE="$PROJECTS_DIR/slow_meet.env"
[[ -f $COMPOSE_FILE ]] || fail "Compose file should be staged"
[[ -f $CRAB_DUMP_ENV_FILE ]] || fail "Crab Dump env file should be staged"
[[ -f $SLOW_MEET_ENV_FILE ]] || fail "SlowMeet env file should be staged"
[[ $(stat -c '%a' "$CRAB_DUMP_ENV_FILE") == 600 ]] || fail "Crab Dump env file should be mode 0600"
[[ $(stat -c '%a' "$SLOW_MEET_ENV_FILE") == 600 ]] || fail "SlowMeet env file should be mode 0600"
cmp -s "$ROOT_DIR/new_vps_projects/crab_dump.sample.env" "$CRAB_DUMP_ENV_FILE" ||
    fail "Crab Dump env file should be copied from its sample"
cmp -s "$ROOT_DIR/new_vps_projects/slow_meet.sample.env" "$SLOW_MEET_ENV_FILE" ||
    fail "SlowMeet env file should be copied from its sample"
assert_contains "$(< "$COMPOSE_FILE")" "crab-dump:" "Compose should include Crab Dump"
assert_contains "$(< "$COMPOSE_FILE")" "slowmeet:" "Compose should include SlowMeet"
assert_contains "$(< "$COMPOSE_FILE")" \
    "ghcr.io/ashkan-esz/slowmeet@sha256:b2bdb42041d32d852575edd6e712346d947bf3b6d3f027895364f3c62797dc68" \
    "SlowMeet should use the verified upstream image digest"
assert_contains "$(< "$COMPOSE_FILE")" \
    "ghcr.io/ashkan-esz/crab-dump@sha256:818cdcc52e2a439b10a6e9876fb95faa40433cc6ba89d63e53e35264f56e9f78" \
    "Crab Dump should use the verified upstream image digest"

printf 'local-crab-config\n' > "$CRAB_DUMP_ENV_FILE"
printf 'local-slowmeet-config\n' > "$SLOW_MEET_ENV_FILE"

: > "$MENU_OUTPUT"
choose_engine <<< $'invalid\n2' > "$MENU_OUTPUT" 2>&1
assert_eq "${ENGINE_CHOICE:-}" "podman" "menu should accept a valid choice after invalid input"
install_selected_engine
assert_contains "$(< "$APT_LOG")" "install -y podman podman-compose" \
    "Podman installation should include the Compose provider"
assert_contains "$(< "$MENU_OUTPUT")" "Invalid choice" "invalid input should be explained"
assert_eq "$(< "$CRAB_DUMP_ENV_FILE")" "local-crab-config" "existing Crab Dump env should be preserved"
assert_eq "$(< "$SLOW_MEET_ENV_FILE")" "local-slowmeet-config" "existing SlowMeet env should be preserved"
[[ ! -s $START_LOG ]] || fail "setup must not start containers"

printf 'PASS: engine selection, Compose staging, env preservation, provider install, and copy-only setup\n'
