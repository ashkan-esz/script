#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECTS_DIR="${PROJECTS_DIR:-/opt/vps-projects}"
readonly COMPOSE_TEMPLATE="$SCRIPT_DIR/compose.yaml"
readonly CRAB_DUMP_ENV_TEMPLATE="$SCRIPT_DIR/crab_dump.sample.env"
readonly SLOW_MEET_ENV_TEMPLATE="$SCRIPT_DIR/slow_meet.sample.env"
readonly PODMAN_SERVICE_TEMPLATE="$SCRIPT_DIR/podman-compose.service"
readonly NGINX_BOOTSTRAP_TEMPLATE="$SCRIPT_DIR/nginx/http.conf"
readonly NGINX_TLS_TEMPLATE="$SCRIPT_DIR/nginx/tls.conf"
readonly SLOWMEET_PUBLIC_DOMAIN="meet.g69.lol"

readonly DOCKER_KEYRING_DIR="/etc/apt/keyrings"
readonly DOCKER_KEY_FILE="${DOCKER_KEYRING_DIR}/docker.asc"
readonly DOCKER_SOURCE_FILE="/etc/apt/sources.list.d/docker.sources"
readonly NGINX_CONFIG_FILE="${NGINX_CONFIG_FILE:-${PROJECTS_DIR}/nginx.conf}"
readonly ACME_WEBROOT="${ACME_WEBROOT:-${PROJECTS_DIR}/acme-webroot}"
readonly LETSENCRYPT_DIR="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
readonly CERTBOT_DEPLOY_HOOK_DIR="${CERTBOT_DEPLOY_HOOK_DIR:-${LETSENCRYPT_DIR}/renewal-hooks/deploy}"
readonly MANAGED_CONFIG_MARKER="# Managed by new_vps_projects.sh"
export NGINX_CONFIG_FILE ACME_WEBROOT LETSENCRYPT_DIR

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

compose_path_environment() {
    printf 'NGINX_CONFIG_FILE=%q ACME_WEBROOT=%q LETSENCRYPT_DIR=%q' \
        "$NGINX_CONFIG_FILE" "$ACME_WEBROOT" "$LETSENCRYPT_DIR"
}

systemd_environment_line() {
    local name="$1" value="$2"

    [[ $name =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "invalid systemd environment variable name: $name"
    [[ ! $value =~ [[:cntrl:]] ]] || die "systemd environment values cannot contain control characters"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    value="${value//\`/\\\`}"
    value="${value//%/%%}"
    printf 'Environment="%s=%s"\n' "$name" "$value"
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
    require_command id cp date install mktemp mv rm grep awk
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

validate_public_access_inputs() {
    local domain="$1" email="$2"

    [[ ${#domain} -le 253 && $domain =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
        die "enter a valid lowercase DNS hostname for SlowMeet TLS"
    [[ $email =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] ||
        die "enter a valid email address for certificate notices"
}

choose_public_access() {
    local choice email

    printf '\nConfigure public SlowMeet access with Nginx, TLS, and UFW rules? [y/N]: '
    IFS= read -r choice || choice=""
    case "${choice,,}" in
        ""|n|no)
            PUBLIC_ACCESS_CHOICE="no"
            return 0
            ;;
        y|yes) ;;
        *) die "answer yes or no to the public-access setup prompt" ;;
    esac

    printf 'ACME certificate email: '
    IFS= read -r email || die "an email address is required for TLS setup"
    validate_public_access_inputs "$SLOWMEET_PUBLIC_DOMAIN" "$email"

    PUBLIC_ACCESS_CHOICE="yes"
    PUBLIC_ACCESS_DOMAIN="$SLOWMEET_PUBLIC_DOMAIN"
    PUBLIC_ACCESS_EMAIL="$email"
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
    local working_directory temporary_file line profile_args=""
    local working_directory_found=0 exec_start_found=0 exec_stop_found=0 environment_settings_found=0
    local destination_is_managed=0

    [[ -f $PODMAN_SERVICE_TEMPLATE && ! -L $PODMAN_SERVICE_TEMPLATE && -r $PODMAN_SERVICE_TEMPLATE ]] ||
        die "Podman systemd unit template is missing, unreadable, or not a regular file: $PODMAN_SERVICE_TEMPLATE"

    if [[ -e $destination || -L $destination ]]; then
        [[ -f $destination && ! -L $destination ]] ||
            die "Podman systemd unit destination is not a regular file: $destination"
        if grep -Fqx -- "$MANAGED_CONFIG_MARKER" "$destination"; then
            destination_is_managed=1
        else
            printf '[+] Preserving existing Podman systemd unit: %s\n' "$destination"
            return 0
        fi
    fi

    working_directory="$(cd -- "$PROJECTS_DIR" && pwd -P)" ||
        die "could not resolve the projects directory for the Podman systemd unit"
    [[ $working_directory != *$'\n'* ]] || die "projects directory path cannot contain a newline"
    working_directory="${working_directory//\\/\\\\}"
    working_directory="${working_directory//%/%%}"
    [[ ${PUBLIC_ACCESS_CHOICE:-no} == yes ]] && profile_args=" --profile public"

    temporary_file="$(mktemp -- "$PROJECTS_DIR/.podman-compose.service.XXXXXX")" ||
        die "could not stage the Podman systemd unit"
    if ! while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == WorkingDirectory=* ]]; then
            printf 'WorkingDirectory=%s\n' "$working_directory" || return 1
            systemd_environment_line NGINX_CONFIG_FILE "$NGINX_CONFIG_FILE" || return 1
            systemd_environment_line ACME_WEBROOT "$ACME_WEBROOT" || return 1
            systemd_environment_line LETSENCRYPT_DIR "$LETSENCRYPT_DIR" || return 1
            working_directory_found=1
            environment_settings_found=1
        elif [[ $line == ExecStart=* ]]; then
            printf 'ExecStart=/usr/bin/podman-compose%s up -d\n' "$profile_args" || return 1
            exec_start_found=1
        elif [[ $line == ExecStop=* ]]; then
            printf 'ExecStop=/usr/bin/podman-compose%s down\n' "$profile_args" || return 1
            exec_stop_found=1
        else
            printf '%s\n' "$line" || return 1
        fi
    done < "$PODMAN_SERVICE_TEMPLATE" > "$temporary_file"; then
        rm -f -- "$temporary_file"
        die "rendering the Podman systemd unit failed"
    fi
    if ((working_directory_found == 0 || exec_start_found == 0 || exec_stop_found == 0 || environment_settings_found == 0)); then
        rm -f -- "$temporary_file"
        die "Podman systemd unit template is missing required settings"
    fi
    if ((destination_is_managed)) && cmp -s -- "$temporary_file" "$destination"; then
        rm -f -- "$temporary_file"
        printf '[+] Preserving current managed Podman systemd unit: %s\n' "$destination"
        return 0
    fi
    if ((destination_is_managed)); then
        create_timestamped_backup "$destination"
        printf '[+] Updated managed Podman systemd unit; previous configuration was saved to %s\n' "$BACKUP_PATH"
    fi
    if ! install -m 0644 -- "$temporary_file" "$destination"; then
        rm -f -- "$temporary_file"
        die "staging the Podman systemd unit failed"
    fi
    rm -f -- "$temporary_file"
}

refresh_compose() {
    local compose_file="$PROJECTS_DIR/compose.yaml"
    local timestamp backup_file temporary_file proxy_file domain listen_address listen_port published_address
    local refresh_proxy=no

    [[ ! -L $PROJECTS_DIR && -d $PROJECTS_DIR ]] ||
        die "projects directory is missing or is a symlink: $PROJECTS_DIR"
    [[ -f $COMPOSE_TEMPLATE && ! -L $COMPOSE_TEMPLATE && -r $COMPOSE_TEMPLATE ]] ||
        die "Compose template is missing, unreadable, or not a regular file: $COMPOSE_TEMPLATE"
    [[ -f $compose_file && ! -L $compose_file ]] ||
        die "Compose destination is missing or is not a regular file: $compose_file"

    listen_address="$(read_compose_slowmeet_value "$compose_file" HTTP_ADDR || true)"
    published_address="$(read_compose_slowmeet_value "$compose_file" HTTP_PUBLISH_ADDRESS || true)"
    listen_port="$(read_compose_slowmeet_listen_port "$compose_file" || true)"
    if [[ $listen_address == 127.* && $listen_port == 1102 &&
        $published_address == "$SLOWMEET_PUBLIC_DOMAIN" ]]; then
        domain="$SLOWMEET_PUBLIC_DOMAIN"
        if [[ -f $NGINX_CONFIG_FILE && ! -L $NGINX_CONFIG_FILE &&
            -r $LETSENCRYPT_DIR/live/$domain/fullchain.pem &&
            -r $LETSENCRYPT_DIR/live/$domain/privkey.pem ]]; then
            assert_managed_generated_file "$NGINX_CONFIG_FILE"
            refresh_proxy=yes
        fi
    fi

    timestamp="$(date +%Y%m%d-%H%M%S)" || die "could not create a backup timestamp"
    backup_file="$(mktemp -- "${compose_file}.backup-${timestamp}.XXXXXX")" ||
        die "could not reserve a unique Compose backup path"

    temporary_file="$(mktemp -- "$PROJECTS_DIR/.compose.yaml.XXXXXX")" ||
        { rm -f -- "$backup_file"; die "could not stage the refreshed Compose file"; }
    if ! install -m 0644 -- "$COMPOSE_TEMPLATE" "$temporary_file"; then
        rm -f -- "$temporary_file"
        die "staging the refreshed Compose file failed"
    fi
    if [[ $refresh_proxy == yes ]]; then
        PROXY_HTTP_ADDR="127.0.0.1:$listen_port"
        PROXY_UPSTREAM_PORT="$listen_port"
        proxy_file="$(mktemp -- "$PROJECTS_DIR/.compose.yaml.proxy.XXXXXX")" ||
            { rm -f -- "$temporary_file"; die "could not stage the refreshed public-access Compose file"; }
        if ! render_compose_for_proxy "$temporary_file" "$proxy_file" "$domain"; then
            rm -f -- "$temporary_file" "$proxy_file"
            die "could not preserve public-access settings while refreshing Compose"
        fi
        chmod 0644 -- "$proxy_file" ||
            { rm -f -- "$temporary_file" "$proxy_file"; die "could not set refreshed Compose permissions"; }
        mv -f -- "$proxy_file" "$temporary_file" ||
            { rm -f -- "$temporary_file" "$proxy_file"; die "could not stage refreshed public-access settings"; }
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
    if [[ $refresh_proxy == yes ]]; then
        write_nginx_config tls
        printf '[+] Managed Nginx configuration refreshed with a timestamped backup.\n'
    fi
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

read_compose_slowmeet_value() {
    local file="$1" wanted_key="$2" line value in_slowmeet=0

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == '  slowmeet:' ]]; then
            in_slowmeet=1
            continue
        fi
        if ((in_slowmeet)) && [[ $line =~ ^[^[:space:]] ]]; then
            break
        fi
        ((in_slowmeet)) || continue
        [[ $line =~ ^[[:space:]]+$wanted_key:[[:space:]]* ]] || continue
        value="${line#*"$wanted_key:"}"
        value="${value//\"/}"
        value="${value//[[:space:]]/}"
        printf '%s' "$value"
        return 0
    done < "$file"
    return 1
}

read_compose_slowmeet_listen_port() {
    local file="$1" listen_address

    listen_address="$(read_compose_slowmeet_value "$file" HTTP_ADDR)" || return 1
    [[ $listen_address =~ ^(:|127\.0\.0\.1:)([0-9]{1,5})$ ]] || return 1
    printf '%s' "${BASH_REMATCH[2]}"
}

validate_compose_for_public_access() {
    local domain="$1"
    local compose_file="$PROJECTS_DIR/compose.yaml"
    local listen_address published_address configured_port listen_port

    [[ -f $compose_file && ! -L $compose_file ]] ||
        die "Compose file is missing or is not a regular file: $compose_file"
    listen_address="$(read_compose_slowmeet_value "$compose_file" HTTP_ADDR || true)"
    published_address="$(read_compose_slowmeet_value "$compose_file" HTTP_PUBLISH_ADDRESS || true)"
    configured_port="$(read_compose_slowmeet_value "$compose_file" HTTP_PUBLISH_PORT || true)"
    listen_port="$(read_compose_slowmeet_listen_port "$compose_file" || true)"
    [[ $listen_port =~ ^[0-9]{1,5}$ && $listen_port == "$configured_port" ]] ||
        die "SlowMeet HTTP_PUBLISH_PORT must match its HTTP_ADDR port before proxy setup"
    [[ $listen_port == 1102 ]] ||
        die "SlowMeet must listen on HTTP port 1102 for the checked-in Nginx configuration"
    [[ $published_address == *replace-with* || $published_address == "$domain" ]] ||
        die "SlowMeet HTTP_PUBLISH_ADDRESS is customized; set it to $domain before proxy setup"

    if [[ $listen_address =~ ^:([0-9]{1,5})$ ]]; then
        PROXY_HTTP_ADDR="127.0.0.1:${BASH_REMATCH[1]}"
    elif [[ $listen_address =~ ^127\.0\.0\.1:([0-9]{1,5})$ ]]; then
        PROXY_HTTP_ADDR="$listen_address"
    else
        die "SlowMeet HTTP_ADDR is customized; use :$listen_port or 127.0.0.1:$listen_port before proxy setup"
    fi
    PROXY_UPSTREAM_PORT="$listen_port"
}

create_timestamped_backup() {
    local source="$1" timestamp

    BACKUP_PATH=""
    [[ -e $source || -L $source ]] || return 0
    [[ -f $source && ! -L $source ]] || die "cannot back up a non-regular file: $source"
    timestamp="$(date +%Y%m%d-%H%M%S)" || die "could not create a backup timestamp"
    BACKUP_PATH="$(mktemp -- "${source}.backup-${timestamp}.XXXXXX")" ||
        die "could not reserve a backup path for $source"
    if ! cp -p -- "$source" "$BACKUP_PATH"; then
        rm -f -- "$BACKUP_PATH"
        BACKUP_PATH=""
        die "backing up $source failed"
    fi
}

assert_managed_generated_file() {
    local file="$1"

    [[ -e $file || -L $file ]] || return 0
    [[ -f $file && ! -L $file ]] ||
        die "managed configuration path is not a regular file: $file"
    grep -Fqx -- "$MANAGED_CONFIG_MARKER" "$file" ||
        die "refusing to overwrite unmanaged configuration: $file"
}

preflight_nginx_configuration() {
    [[ -f $NGINX_BOOTSTRAP_TEMPLATE && ! -L $NGINX_BOOTSTRAP_TEMPLATE && -r $NGINX_BOOTSTRAP_TEMPLATE ]] ||
        die "Nginx HTTP bootstrap config is missing, unreadable, or not a regular file: $NGINX_BOOTSTRAP_TEMPLATE"
    [[ -f $NGINX_TLS_TEMPLATE && ! -L $NGINX_TLS_TEMPLATE && -r $NGINX_TLS_TEMPLATE ]] ||
        die "Nginx TLS config is missing, unreadable, or not a regular file: $NGINX_TLS_TEMPLATE"
    grep -Fq "server_name $SLOWMEET_PUBLIC_DOMAIN;" "$NGINX_BOOTSTRAP_TEMPLATE" ||
        die "Nginx HTTP bootstrap config must serve $SLOWMEET_PUBLIC_DOMAIN"
    grep -Fq "server_name $SLOWMEET_PUBLIC_DOMAIN;" "$NGINX_TLS_TEMPLATE" ||
        die "Nginx TLS config must serve $SLOWMEET_PUBLIC_DOMAIN"
    grep -Fq "proxy_pass http://127.0.0.1:1102;" "$NGINX_TLS_TEMPLATE" ||
        die "Nginx TLS config must proxy to the SlowMeet listener on 127.0.0.1:1102"
    assert_managed_generated_file "$NGINX_CONFIG_FILE"
    assert_managed_generated_file "$CERTBOT_DEPLOY_HOOK_DIR/vps-projects-nginx-reload"
}

render_nginx_config() {
    local destination="$1" mode="$2" template

    case "$mode" in
        bootstrap) template="$NGINX_BOOTSTRAP_TEMPLATE" ;;
        tls) template="$NGINX_TLS_TEMPLATE" ;;
        *) return 1 ;;
    esac
    [[ -f $template && ! -L $template && -r $template ]] || return 1
    cp -- "$template" "$destination"
}

write_nginx_config() {
    local mode="$1" temporary_file

    assert_managed_generated_file "$NGINX_CONFIG_FILE"
    temporary_file="$(mktemp -- "$PROJECTS_DIR/.nginx.conf.XXXXXX")" ||
        die "could not stage the Compose Nginx configuration"
    if ! render_nginx_config "$temporary_file" "$mode"; then
        rm -f -- "$temporary_file"
        die "rendering the Compose Nginx configuration failed"
    fi
    create_timestamped_backup "$NGINX_CONFIG_FILE"
    NGINX_CONFIG_LAST_BACKUP="$BACKUP_PATH"
    if ! chmod 0644 -- "$temporary_file" || ! mv -f -- "$temporary_file" "$NGINX_CONFIG_FILE"; then
        rm -f -- "$temporary_file"
        die "installing the Compose Nginx configuration failed"
    fi
}

restore_nginx_config() {
    local backup="$1"

    if [[ -n $backup ]]; then
        cp -p -- "$backup" "$NGINX_CONFIG_FILE" ||
            die "could not restore the previous Compose Nginx configuration; backup: $backup"
    else
        rm -f -- "$NGINX_CONFIG_FILE" || die "could not remove the failed Compose Nginx configuration"
    fi
}

compose_command() {
    case "${ENGINE_CHOICE:-}" in
        docker) docker compose "$@" ;;
        podman) podman-compose "$@" ;;
        *) die "choose Docker or Podman before running Compose commands" ;;
    esac
}

compose_in_project() {
    (cd -- "$PROJECTS_DIR" && compose_command "$@")
}

write_certbot_deploy_hook() {
    local hook_file="$CERTBOT_DEPLOY_HOOK_DIR/vps-projects-nginx-reload"
    local temporary_file quoted_project_dir quoted_nginx_config quoted_acme_webroot quoted_letsencrypt reload_command

    assert_managed_generated_file "$hook_file"
    run_required "creating Certbot deploy-hook directory" install -d -m 0755 -- "$CERTBOT_DEPLOY_HOOK_DIR"
    temporary_file="$(mktemp -- "$CERTBOT_DEPLOY_HOOK_DIR/.vps-projects-nginx-reload.XXXXXX")" ||
        die "could not stage the Certbot Nginx reload hook"
    printf -v quoted_project_dir '%q' "$PROJECTS_DIR"
    printf -v quoted_nginx_config '%q' "$NGINX_CONFIG_FILE"
    printf -v quoted_acme_webroot '%q' "$ACME_WEBROOT"
    printf -v quoted_letsencrypt '%q' "$LETSENCRYPT_DIR"
    case "${ENGINE_CHOICE:-}" in
        docker) reload_command="docker compose --profile public exec -T nginx nginx -s reload" ;;
        podman) reload_command="podman-compose --profile public exec -T nginx nginx -s reload" ;;
        *) rm -f -- "$temporary_file"; die "choose Docker or Podman before installing the Certbot hook" ;;
    esac
    cat > "$temporary_file" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
$MANAGED_CONFIG_MARKER
cd -- $quoted_project_dir
export NGINX_CONFIG_FILE=$quoted_nginx_config
export ACME_WEBROOT=$quoted_acme_webroot
export LETSENCRYPT_DIR=$quoted_letsencrypt
exec $reload_command
EOF
    create_timestamped_backup "$hook_file"
    if ! chmod 0750 -- "$temporary_file" || ! mv -f -- "$temporary_file" "$hook_file"; then
        rm -f -- "$temporary_file"
        die "installing the Certbot Nginx reload hook failed"
    fi
}

render_compose_for_proxy() {
    local source_file="$1" destination="$2" domain="$3"
    local listen_address="$PROXY_HTTP_ADDR"
    local published_address="$domain"
    if ! awk -v address="$listen_address" -v published="$published_address" '
        $0 == "  slowmeet:" { in_slowmeet = 1; print; next }
        in_slowmeet && /^[^[:space:]]/ { in_slowmeet = 0 }
        in_slowmeet && /^[[:space:]]+HTTP_ADDR:[[:space:]]*/ {
            sub(/HTTP_ADDR:.*/, "HTTP_ADDR: \"" address "\"")
            address_count++
        }
        in_slowmeet && /^[[:space:]]+HTTP_PUBLISH_ADDRESS:[[:space:]]*/ {
            sub(/HTTP_PUBLISH_ADDRESS:.*/, "HTTP_PUBLISH_ADDRESS: \"" published "\"")
            published_count++
        }
        { print }
        END {
            if (address_count != 1 || published_count != 1) {
                exit 1
            }
        }
    ' "$source_file" > "$destination"; then
        return 1
    fi
}

update_compose_for_proxy() {
    local domain="$1"
    local compose_file="$PROJECTS_DIR/compose.yaml"
    local temporary_file

    validate_compose_for_public_access "$domain"
    temporary_file="$(mktemp -- "$PROJECTS_DIR/.compose.yaml.proxy.XXXXXX")" ||
        die "could not stage the public-access Compose update"
    if ! render_compose_for_proxy "$compose_file" "$temporary_file" "$domain"; then
        rm -f -- "$temporary_file"
        die "Compose must contain exactly one SlowMeet HTTP_ADDR and HTTP_PUBLISH_ADDRESS setting"
    fi
    chmod 0644 -- "$temporary_file" ||
        { rm -f -- "$temporary_file"; die "setting public-access Compose permissions failed"; }

    create_timestamped_backup "$compose_file"
    COMPOSE_PUBLIC_ACCESS_BACKUP="$BACKUP_PATH"
    if ! mv -f -- "$temporary_file" "$compose_file"; then
        rm -f -- "$temporary_file"
        die "installing the public-access Compose update failed"
    fi
}

restore_compose_after_proxy_failure() {
    local backup="$1"

    [[ -n $backup ]] || return 0
    cp -p -- "$backup" "$PROJECTS_DIR/compose.yaml" ||
        die "could not restore Compose after Nginx setup failed; backup: $backup"
    printf '[!] Restored the previous Compose file from %s.\n' "$backup" >&2
}

configure_slowmeet_public_access() {
    (($# == 1)) || die "public-access setup expects a certificate email"
    local domain="$SLOWMEET_PUBLIC_DOMAIN" email="$1" certificate_dir nginx_backup

    validate_public_access_inputs "$domain" "$email"
    validate_compose_for_public_access "$domain"
    require_command apt-get date install mktemp mv rm cp chmod grep awk systemctl
    preflight_nginx_configuration

    run_required "updating apt package lists for TLS" apt-get update
    run_required "installing host Certbot and UFW" apt-get install -y certbot ufw
    require_command certbot ufw
    run_required "creating ACME webroot" install -d -m 0755 -- "$ACME_WEBROOT"

    run_required "adding the HTTP firewall rule" ufw allow 80/tcp comment 'SlowMeet Nginx HTTP'
    run_required "adding the HTTPS firewall rule" ufw allow 443/tcp comment 'SlowMeet Nginx HTTPS'
    run_required "adding the WebRTC UDP firewall rule" ufw allow 50000:50100/udp comment 'SlowMeet WebRTC media'

    write_nginx_config bootstrap
    write_certbot_deploy_hook
    run_required "starting only the Compose Nginx proxy for ACME" \
        compose_in_project --profile public up -d nginx

    if ! certbot certonly \
        --webroot --webroot-path "$ACME_WEBROOT" --non-interactive --agree-tos \
        --email "$email" --cert-name "$domain" -d "$domain" \
        --deploy-hook "$CERTBOT_DEPLOY_HOOK_DIR/vps-projects-nginx-reload"; then
        printf '[!] Certificate issuance failed; the HTTP ACME site remains active. Check DNS and public TCP port 80, then rerun setup.\n' >&2
        die "requesting the SlowMeet TLS certificate failed"
    fi
    certificate_dir="$LETSENCRYPT_DIR/live/$domain"
    [[ -r $certificate_dir/fullchain.pem && -r $certificate_dir/privkey.pem ]] ||
        die "Certbot completed without readable certificate files in $certificate_dir"

    update_compose_for_proxy "$domain"
    write_nginx_config tls
    nginx_backup="$NGINX_CONFIG_LAST_BACKUP"
    if ! compose_in_project --profile public exec -T nginx nginx -t; then
        restore_nginx_config "$nginx_backup"
        restore_compose_after_proxy_failure "$COMPOSE_PUBLIC_ACCESS_BACKUP"
        die "TLS Compose Nginx configuration failed validation; restored the HTTP configuration"
    fi
    if ! compose_in_project --profile public exec -T nginx nginx -s reload; then
        restore_nginx_config "$nginx_backup"
        restore_compose_after_proxy_failure "$COMPOSE_PUBLIC_ACCESS_BACKUP"
        compose_in_project --profile public exec -T nginx nginx -s reload || true
        die "Compose Nginx could not reload the TLS configuration; restored the previous HTTP configuration"
    fi
    run_required "enabling automatic Certbot renewals" systemctl enable --now certbot.timer

    PUBLIC_ACCESS_CONFIGURED="yes"
    printf '[+] SlowMeet HTTPS is configured for https://%s/.\n' "$domain"
    printf '[+] The Compose Nginx proxy is running; SlowMeet and Crab Dump remain stopped.\n'
    printf '[+] UFW allow rules were added; its existing enabled state and default policies were preserved.\n'
}

print_start_instructions() {
    printf '\n[+] After editing the environment files, start the stack from %s:\n' "$PROJECTS_DIR"
    case "${ENGINE_CHOICE:-}" in
        docker)
            if [[ ${PUBLIC_ACCESS_CONFIGURED:-no} == yes ]]; then
                printf '    %s docker compose --profile public up -d\n' "$(compose_path_environment)"
            else
                printf '    %s docker compose up -d\n' "$(compose_path_environment)"
            fi
            ;;
        podman)
            if [[ ${PUBLIC_ACCESS_CONFIGURED:-no} == yes ]]; then
                printf '    %s podman-compose --profile public up -d\n' "$(compose_path_environment)"
            else
                printf '    %s podman-compose up -d\n' "$(compose_path_environment)"
            fi
            printf '[+] Optional Podman startup on reboot, after editing the environment files:\n'
            printf '    sudo install -m 0644 podman-compose.service /etc/systemd/system/vps-projects-podman.service\n'
            printf '    sudo systemctl daemon-reload\n'
            printf '    sudo systemctl enable --now vps-projects-podman.service\n'
            ;;
        *) die "choose Docker or Podman before printing start instructions" ;;
    esac
    if [[ ${PUBLIC_ACCESS_CONFIGURED:-no} == yes ]]; then
        printf '[+] Nginx serves SlowMeet on TCP 80/443; its HTTP backend is bound to loopback port %s.\n' \
            "$PROXY_UPSTREAM_PORT"
        printf '[!] Confirm the cloud firewall allows TCP 80/443 and UDP 50000-50100.\n'
    else
        printf '[!] SlowMeet uses host networking and listens directly on host TCP 1102 and UDP 50000-50100 when exposed.\n'
        printf '[!] Host and cloud firewall rules were left unchanged; allow those ports only when you are ready to expose SlowMeet.\n'
        printf '[!] The optional Compose Nginx public profile is not configured or started.\n'
    fi
    printf '[+] To refresh Compose and managed Nginx configuration later, run: sudo env %s bash %q --refresh-compose\n' \
        "$(compose_path_environment)" "$SCRIPT_DIR/new_vps_projects.sh"
}

validate_project_configuration() {
    local crab_dump_env="$PROJECTS_DIR/crab_dump.env"
    local slow_meet_env="$PROJECTS_DIR/slow_meet.env"
    local compose_file="$PROJECTS_DIR/compose.yaml"
    local configured_port listen_port published_address
    local PLACEHOLDER_FOUND=0

    check_placeholder_credentials "$crab_dump_env"
    check_placeholder_credentials "$slow_meet_env"
    if ((PLACEHOLDER_FOUND)); then
        printf '[!] Replace the placeholder credentials before starting the stack.\n'
    else
        printf '[+] No placeholder credentials were found in the staged environment files.\n'
    fi

    configured_port="$(read_compose_slowmeet_value "$compose_file" HTTP_PUBLISH_PORT || true)"
    listen_port="$(read_compose_slowmeet_listen_port "$compose_file" || true)"
    if [[ $configured_port =~ ^[0-9]{1,5}$ && $configured_port == "$listen_port" ]]; then
        printf '[+] SlowMeet HTTP_PUBLISH_PORT matches the HTTP_ADDR host-listener port (%s).\n' "$configured_port"
    else
        printf '[!] SlowMeet HTTP_PUBLISH_PORT (%s) does not match the HTTP_ADDR host-listener port (%s); align them before starting the stack.\n' \
            "${configured_port:-missing}" "${listen_port:-missing}"
    fi

    published_address="$(read_compose_slowmeet_value "$compose_file" HTTP_PUBLISH_ADDRESS || true)"
    if [[ -z $published_address || $published_address == 0.0.0.0 || $published_address == :: ||
        $published_address == ::1 || $published_address == localhost || $published_address == 127.* ||
        $published_address == *replace-with* || $published_address == *://* || $published_address =~ [[:space:]] ]]; then
        printf '[!] SlowMeet HTTP_PUBLISH_ADDRESS must be a reachable server IP or DNS name, not a placeholder or wildcard.\n'
    else
        printf '[+] SlowMeet HTTP_PUBLISH_ADDRESS is configured.\n'
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

    printf '\n[+] Project configuration is staged in %s; app containers were not started.\n' "$PROJECTS_DIR"
    validate_project_configuration
}

install_selected_engine() {
    case "${ENGINE_CHOICE:-}" in
        docker) install_docker ;;
        podman) install_podman ;;
        *) die "choose Docker or Podman before installing an engine" ;;
    esac
    prepare_project_stack
    if [[ ${PUBLIC_ACCESS_CHOICE:-no} == yes ]]; then
        configure_slowmeet_public_access "$PUBLIC_ACCESS_EMAIL"
    fi
    print_start_instructions
}

main() {
    if (($# == 1)) && [[ $1 == --refresh-compose ]]; then
        preflight_refresh_compose
        refresh_compose
        return 0
    fi

    preflight "$@"
    choose_engine
    choose_public_access
    install_selected_engine
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -Eeuo pipefail
    main "$@"
fi
