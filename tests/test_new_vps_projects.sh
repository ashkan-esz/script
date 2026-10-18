#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/new_vps_projects/new_vps_projects.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
ENGINE_LOG="$TMP_DIR/engine.log"
MENU_OUTPUT="$TMP_DIR/menu-output"
: > "$ENGINE_LOG"

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

install_podman() {
    printf 'podman\n' >> "$ENGINE_LOG"
}

choose_engine <<<"1" > "$MENU_OUTPUT"
assert_eq "${ENGINE_CHOICE:-}" "docker" "Docker menu choice should be retained"
install_selected_engine
assert_eq "$(< "$ENGINE_LOG")" "docker" "Docker choice should install Docker"
assert_contains "$(< "$MENU_OUTPUT")" "Podman" "menu should offer Podman"

: > "$ENGINE_LOG"
choose_engine <<< $'invalid\n2' > "$MENU_OUTPUT" 2>&1
assert_eq "${ENGINE_CHOICE:-}" "podman" "menu should accept a valid choice after invalid input"
install_selected_engine
assert_eq "$(< "$ENGINE_LOG")" "podman" "Podman choice should install Podman"
assert_contains "$(< "$MENU_OUTPUT")" "Invalid choice" "invalid input should be explained"

printf 'PASS: project engine menu and dispatch\n'
