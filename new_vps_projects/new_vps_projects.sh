#!/usr/bin/env bash

readonly DOCKER_KEYRING_DIR="/etc/apt/keyrings"
readonly DOCKER_KEY_FILE="${DOCKER_KEYRING_DIR}/docker.asc"
readonly DOCKER_SOURCE_FILE="/etc/apt/sources.list.d/docker.sources"

die() {
    printf '[!] %s\n' "$*" >&2
    exit 1
}

run_required() {
    local description="$1"
    shift
    "$@" || die "$description failed"
}

require_command() {
    local name
    for name in "$@"; do
        command -v "$name" >/dev/null 2>&1 || die "required command is missing: $name"
    done
}

preflight() {
    (($# == 0)) || die "this script takes no arguments"
    require_command id apt-get
    [[ $(id -u) == 0 ]] || die "run this script as root"
    [[ -t 0 ]] || die "a terminal is required to choose Docker or Podman"
    [[ -r /etc/os-release ]] || die "could not read /etc/os-release"

    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) ;;
        *) die "unsupported distribution '${ID:-unknown}'; this installer supports Debian and Ubuntu" ;;
    esac
}

choose_engine() {
    local choice
    while true; do
        printf '\nChoose a container engine to install:\n  1) Docker\n  2) Podman\nSelection [1-2]: '
        if ! IFS= read -r choice; then
            die "no container engine was selected"
        fi

        case "${choice,,}" in
            1|docker) ENGINE_CHOICE="docker"; return 0 ;;
            2|podman) ENGINE_CHOICE="podman"; return 0 ;;
            *) printf '[!] Invalid choice. Enter 1 (Docker) or 2 (Podman).\n' >&2 ;;
        esac
    done
}

install_docker() {
    local codename architecture
    codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    [[ $codename =~ ^[a-zA-Z0-9._-]+$ ]] || die "could not determine a valid Debian/Ubuntu release codename"
    require_command dpkg install chmod
    architecture="$(dpkg --print-architecture)" || die "could not determine the system architecture"
    [[ $architecture =~ ^[a-z0-9-]+$ ]] || die "dpkg returned an invalid architecture: $architecture"

    printf '[+] Installing Docker Engine from Docker’s official apt repository\n'
    run_required "updating apt package lists" apt-get update
    run_required "installing Docker repository prerequisites" apt-get install -y ca-certificates curl
    require_command curl
    run_required "creating Docker apt keyring directory" install -d -m 0755 -- "$DOCKER_KEYRING_DIR"
    curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
        --output "$DOCKER_KEY_FILE" "https://download.docker.com/linux/${ID}/gpg" ||
        die "downloading Docker’s official apt signing key failed"
    run_required "setting Docker apt key permissions" chmod a+r -- "$DOCKER_KEY_FILE"

    printf 'Types: deb\nURIs: https://download.docker.com/linux/%s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: %s\n' \
        "$ID" "$codename" "$architecture" "$DOCKER_KEY_FILE" > "$DOCKER_SOURCE_FILE" ||
        die "writing Docker’s apt repository configuration failed"

    run_required "updating apt package lists for Docker" apt-get update
    run_required "installing Docker Engine, Buildx, and Compose" apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    if command -v systemctl >/dev/null 2>&1; then
        run_required "enabling and starting Docker" systemctl enable --now docker
    fi
    printf '[+] Docker Engine, Buildx, and Compose are installed.\n'
}

install_podman() {
    printf '[+] Installing Podman from the %s apt repository\n' "$ID"
    run_required "updating apt package lists" apt-get update
    run_required "installing Podman" apt-get install -y podman
    printf '[+] Podman is installed.\n'
}

install_selected_engine() {
    case "${ENGINE_CHOICE:-}" in
        docker) install_docker ;;
        podman) install_podman ;;
        *) die "choose Docker or Podman before installing an engine" ;;
    esac
}

main() {
    preflight "$@"
    choose_engine
    install_selected_engine
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -Eeuo pipefail
    main "$@"
fi
