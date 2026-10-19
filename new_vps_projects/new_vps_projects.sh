#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECTS_DIR="${PROJECTS_DIR:-/opt/vps-projects}"
readonly COMPOSE_TEMPLATE="$SCRIPT_DIR/compose.yaml"
readonly CRAB_DUMP_ENV_TEMPLATE="$SCRIPT_DIR/crab_dump.sample.env"
readonly SLOW_MEET_ENV_TEMPLATE="$SCRIPT_DIR/slow_meet.sample.env"
readonly PODMAN_SERVICE_TEMPLATE="$SCRIPT_DIR/podman-compose.service"

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
    require_command id apt-get install chmod
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

preflight_refresh_compose() {
    require_command id cp date install mktemp mv rm
    [[ $(id -u) == 0 ]] || die "run this script as root to refresh the Compose file"
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
    require_command docker
    docker compose version >/dev/null || die "Docker Compose v2 is unavailable after installation"
    if command -v systemctl >/dev/null 2>&1; then
        run_required "enabling and starting Docker" systemctl enable --now docker
    fi
    printf '[+] Docker Engine, Buildx, and Compose are installed.\n'
}

install_podman() {
    printf '[+] Installing Podman from the %s apt repository\n' "$ID"
    run_required "updating apt package lists" apt-get update
    run_required "installing Podman and its Compose provider" apt-get install -y podman podman-compose
    require_command podman podman-compose
    printf '[+] Podman and podman-compose are installed.\n'
}

copy_project_file_if_missing() {
    local source="$1" destination="$2" mode="$3" description="$4"

    [[ -f $source && ! -L $source && -r $source ]] ||
        die "$description template is missing, unreadable, or not a regular file: $source"

    if [[ -e $destination || -L $destination ]]; then
        [[ -f $destination && ! -L $destination ]] ||
            die "$description destination is not a regular file: $destination"
        if [[ $mode == 0600 ]]; then
            run_required "restricting permissions on $destination" chmod 0600 -- "$destination"
        fi
        printf '[+] Preserving existing %s: %s\n' "$description" "$destination"
        return 0
    fi

    run_required "copying $description" install -m "$mode" -- "$source" "$destination"
}

stage_podman_service() {
    local destination="$PROJECTS_DIR/podman-compose.service"
    local working_directory temporary_file line working_directory_found=0

    [[ -f $PODMAN_SERVICE_TEMPLATE && ! -L $PODMAN_SERVICE_TEMPLATE && -r $PODMAN_SERVICE_TEMPLATE ]] ||
        die "Podman systemd unit template is missing, unreadable, or not a regular file: $PODMAN_SERVICE_TEMPLATE"

    if [[ -e $destination || -L $destination ]]; then
        [[ -f $destination && ! -L $destination ]] ||
            die "Podman systemd unit destination is not a regular file: $destination"
        printf '[+] Preserving existing Podman systemd unit: %s\n' "$destination"
        return 0
    fi

    working_directory="$(cd -- "$PROJECTS_DIR" && pwd -P)" ||
        die "could not resolve the projects directory for the Podman systemd unit"
    [[ $working_directory != *$'\n'* ]] || die "projects directory path cannot contain a newline"
    working_directory="${working_directory//\\/\\\\}"
    working_directory="${working_directory//%/%%}"

    temporary_file="$(mktemp -- "$PROJECTS_DIR/.podman-compose.service.XXXXXX")" ||
        die "could not stage the Podman systemd unit"
    if ! while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == WorkingDirectory=* ]]; then
            printf 'WorkingDirectory=%s\n' "$working_directory" || return 1
            working_directory_found=1
        else
            printf '%s\n' "$line" || return 1
        fi
    done < "$PODMAN_SERVICE_TEMPLATE" > "$temporary_file"; then
        rm -f -- "$temporary_file"
        die "rendering the Podman systemd unit failed"
    fi
    if ((working_directory_found == 0)); then
        rm -f -- "$temporary_file"
        die "Podman systemd unit template has no WorkingDirectory setting"
    fi
    if ! install -m 0644 -- "$temporary_file" "$destination"; then
        rm -f -- "$temporary_file"
        die "staging the Podman systemd unit failed"
    fi
    rm -f -- "$temporary_file"
}

refresh_compose() {
    local compose_file="$PROJECTS_DIR/compose.yaml"
    local timestamp backup_file temporary_file

    [[ ! -L $PROJECTS_DIR && -d $PROJECTS_DIR ]] ||
        die "projects directory is missing or is a symlink: $PROJECTS_DIR"
    [[ -f $COMPOSE_TEMPLATE && ! -L $COMPOSE_TEMPLATE && -r $COMPOSE_TEMPLATE ]] ||
        die "Compose template is missing, unreadable, or not a regular file: $COMPOSE_TEMPLATE"
    [[ -f $compose_file && ! -L $compose_file ]] ||
        die "Compose destination is missing or is not a regular file: $compose_file"

    timestamp="$(date +%Y%m%d-%H%M%S)" || die "could not create a backup timestamp"
    backup_file="$(mktemp -- "${compose_file}.backup-${timestamp}.XXXXXX")" ||
        die "could not reserve a unique Compose backup path"

    temporary_file="$(mktemp -- "$PROJECTS_DIR/.compose.yaml.XXXXXX")" ||
        { rm -f -- "$backup_file"; die "could not stage the refreshed Compose file"; }
    if ! install -m 0644 -- "$COMPOSE_TEMPLATE" "$temporary_file"; then
        rm -f -- "$temporary_file"
        die "staging the refreshed Compose file failed"
    fi
    if ! cp -p -- "$compose_file" "$backup_file"; then
        rm -f -- "$backup_file"
        rm -f -- "$temporary_file"
        die "backing up the existing Compose file failed"
    fi
    if ! mv -f -- "$temporary_file" "$compose_file"; then
        rm -f -- "$temporary_file"
        die "installing the refreshed Compose file failed; the backup is at $backup_file"
    fi

    printf '[+] Compose file refreshed. Previous configuration was saved to %s\n' "$backup_file"
}

check_placeholder_credentials() {
    local file="$1" line key value

    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*# || $line != *=* ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            DATABASE_URL_*|TG_BOT_TOKEN|DASHBOARD_PASSWORD|AGE_PASSPHRASE|ADMIN_PASSWORD|MEETING_PASSWORD|TURN_PASSWORD|TURN_SHARED_SECRET)
                case "$value" in
                    *replace-with*|*use-a-long-unique*|*change-me*|*changeme*|*your-secret*)
                        printf '[!] Placeholder credential remains in %s (%s).\n' "${file##*/}" "$key"
                        PLACEHOLDER_FOUND=1
                        ;;
                esac
                ;;
        esac
    done < "$file"
}

read_env_value() {
    local file="$1" wanted_key="$2" line value=""

    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == "$wanted_key="* ]] || continue
        value="${line#*=}"
    done < "$file"
    printf '%s' "$value"
}

read_compose_slowmeet_host_port() {
    local file="$1" line mapping

    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *'"0.0.0.0:'*':8080/tcp"'* ]] || continue
        mapping="${line#*0.0.0.0:}"
        mapping="${mapping%%:8080/tcp*}"
        printf '%s' "$mapping"
        return 0
    done < "$file"
    return 1
}

validate_project_configuration() {
    local crab_dump_env="$PROJECTS_DIR/crab_dump.env"
    local slow_meet_env="$PROJECTS_DIR/slow_meet.env"
    local compose_file="$PROJECTS_DIR/compose.yaml"
    local configured_port published_port
    local PLACEHOLDER_FOUND=0

    check_placeholder_credentials "$crab_dump_env"
    check_placeholder_credentials "$slow_meet_env"
    if ((PLACEHOLDER_FOUND)); then
        printf '[!] Replace the placeholder credentials before starting the stack.\n'
    else
        printf '[+] No placeholder credentials were found in the staged environment files.\n'
    fi

    configured_port="$(read_env_value "$slow_meet_env" HTTP_PUBLISH_PORT)"
    published_port="$(read_compose_slowmeet_host_port "$compose_file" || true)"
    if [[ $configured_port =~ ^[0-9]{1,5}$ && $configured_port == "$published_port" ]]; then
        printf '[+] SlowMeet HTTP_PUBLISH_PORT matches the published host port (%s).\n' "$configured_port"
    else
        printf '[!] SlowMeet HTTP_PUBLISH_PORT (%s) does not match the Compose host port (%s); align them before starting the stack.\n' \
            "${configured_port:-missing}" "${published_port:-missing}"
    fi
}

prepare_project_stack() {
    [[ ! -L $PROJECTS_DIR ]] || die "projects directory must not be a symlink: $PROJECTS_DIR"
    [[ ! -e $PROJECTS_DIR || -d $PROJECTS_DIR ]] ||
        die "projects path exists and is not a directory: $PROJECTS_DIR"
    run_required "creating projects directory" install -d -m 0750 -- "$PROJECTS_DIR"

    copy_project_file_if_missing "$COMPOSE_TEMPLATE" "$PROJECTS_DIR/compose.yaml" 0644 "Compose file"
    copy_project_file_if_missing "$CRAB_DUMP_ENV_TEMPLATE" "$PROJECTS_DIR/crab_dump.env" 0600 "Crab Dump environment"
    copy_project_file_if_missing "$SLOW_MEET_ENV_TEMPLATE" "$PROJECTS_DIR/slow_meet.env" 0600 "SlowMeet environment"
    stage_podman_service

    printf '\n[+] Project configuration is staged in %s; containers were not started.\n' "$PROJECTS_DIR"
    validate_project_configuration
    printf '[!] SlowMeet needs inbound TCP 1102 and UDP 50000-50100 when exposed; firewall rules were left unchanged.\n'
    printf '[!] Docker-published ports can bypass UFW filtering; check the host and provider firewall settings.\n'
    printf '[!] This container-only setup does not configure a reverse proxy or TLS.\n'
    printf '[+] After editing the environment files, run from %s:\n' "$PROJECTS_DIR"
    case "${ENGINE_CHOICE:-}" in
        docker) printf '    docker compose up -d\n' ;;
        podman)
            printf '    podman-compose up -d\n'
            printf '[+] Optional Podman startup on reboot, after editing the environment files:\n'
            printf '    sudo install -m 0644 podman-compose.service /etc/systemd/system/vps-projects-podman.service\n'
            printf '    sudo systemctl daemon-reload\n'
            printf '    sudo systemctl enable --now vps-projects-podman.service\n'
            ;;
        *) die "choose Docker or Podman before preparing projects" ;;
    esac
    printf '[+] To refresh Compose from this installer template later, run: sudo bash %q --refresh-compose\n' \
        "$SCRIPT_DIR/new_vps_projects.sh"
}

install_selected_engine() {
    case "${ENGINE_CHOICE:-}" in
        docker) install_docker ;;
        podman) install_podman ;;
        *) die "choose Docker or Podman before installing an engine" ;;
    esac
    prepare_project_stack
}

main() {
    if (($# == 1)) && [[ $1 == --refresh-compose ]]; then
        preflight_refresh_compose
        refresh_compose
        return 0
    fi

    preflight "$@"
    choose_engine
    install_selected_engine
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -Eeuo pipefail
    main "$@"
fi
