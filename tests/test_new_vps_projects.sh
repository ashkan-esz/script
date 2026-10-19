#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
PROJECTS_DIR="$TMP_DIR/projects"
export PROJECTS_DIR
ID=debian
export NGINX_CONFIG_FILE="$PROJECTS_DIR/nginx.conf"
export ACME_WEBROOT="$PROJECTS_DIR/acme-webroot"
export LETSENCRYPT_DIR="$TMP_DIR/etc/letsencrypt"
export CERTBOT_DEPLOY_HOOK_DIR="$TMP_DIR/etc/letsencrypt/renewal-hooks/deploy"

source "$ROOT_DIR/new_vps_projects/new_vps_projects.sh"

ENGINE_LOG="$TMP_DIR/engine.log"
APT_LOG="$TMP_DIR/apt.log"
START_LOG="$TMP_DIR/start.log"
MENU_OUTPUT="$TMP_DIR/menu-output"
STAGE_OUTPUT="$TMP_DIR/stage-output"
SIDE_EFFECT_LOG="$TMP_DIR/side-effects.log"
PUBLIC_SETUP_LOG="$TMP_DIR/public-setup.log"
: > "$ENGINE_LOG"
: > "$APT_LOG"
: > "$START_LOG"
: > "$SIDE_EFFECT_LOG"
: > "$PUBLIC_SETUP_LOG"

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
    printf 'apt-get %s\n' "$*" >> "$PUBLIC_SETUP_LOG"
}

docker() {
    printf 'docker %s\n' "$*" >> "$START_LOG"
    [[ ${COMPOSE_FAIL:-0} == 0 ]]
}

podman-compose() {
    printf 'podman-compose %s\n' "$*" >> "$START_LOG"
    [[ ${COMPOSE_FAIL:-0} == 0 ]]
}

systemctl() {
    printf 'systemctl %s\n' "$*" >> "$SIDE_EFFECT_LOG"
    printf 'systemctl %s\n' "$*" >> "$PUBLIC_SETUP_LOG"
}

ufw() {
    printf 'ufw %s\n' "$*" >> "$SIDE_EFFECT_LOG"
    printf 'ufw %s\n' "$*" >> "$PUBLIC_SETUP_LOG"
}

certbot() {
    local domain=""
    printf 'certbot %s\n' "$*" >> "$PUBLIC_SETUP_LOG"
    [[ ${CERTBOT_FAIL:-0} == 0 ]] || return 1
    while (($#)); do
        if [[ $1 == --cert-name && $# -ge 2 ]]; then
            domain="$2"
            shift 2
        else
            shift
        fi
    done
    [[ -n $domain ]] || return 1
    mkdir -p -- "$LETSENCRYPT_DIR/live/$domain"
    : > "$LETSENCRYPT_DIR/live/$domain/fullchain.pem"
    : > "$LETSENCRYPT_DIR/live/$domain/privkey.pem"
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
assert_contains "$(< "$COMPOSE_FILE")" "image: nginx" \
    "Nginx should use an unpinned image reference"
if grep -q '@sha256:' "$COMPOSE_FILE"; then
    fail "Compose image references should remain unpinned"
fi
if grep -Eq '^[[:space:]]*image: ghcr.io/ashkan-esz/(slowmeet|crab-dump)(:|@)' "$COMPOSE_FILE"; then
    fail "Compose image references should not use pinned tags or digests"
fi
[[ $(grep -c 'network_mode: host' "$COMPOSE_FILE") == 3 ]] ||
    fail "all services should keep host networking"
assert_contains "$(< "$COMPOSE_FILE")" 'profiles:' "Nginx should be profile-gated"
assert_contains "$(< "$COMPOSE_FILE")" '      - public' "the public profile should be opt-in"
assert_contains "$(< "$COMPOSE_FILE")" './nginx.conf:/etc/nginx/conf.d/default.conf:ro' \
    "the Compose Nginx service should mount its staged config"
assert_contains "$(< "$COMPOSE_FILE")" '/etc/letsencrypt:/etc/letsencrypt:ro' \
    "the Compose Nginx service should read host-managed certificates"
assert_contains "$(< "$COMPOSE_FILE")" './acme-webroot:/var/www/letsencrypt:ro' \
    "the Compose Nginx service should serve the shared ACME webroot"
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
assert_contains "$(< "$COMPOSE_FILE")" 'DASHBOARD_USERNAME: "admin"' \
    "Crab Dump's non-secret dashboard username should stay in Compose"
assert_contains "$(< "$COMPOSE_FILE")" 'ENCRYPTION_TYPE: "age-passphrase"' \
    "Crab Dump's non-secret encryption setting should stay in Compose"
if grep -Eq '^(HTTP_PUBLISH_|ICE_UDP_|ICE_PUBLIC_IP=|STUN_SERVERS=|TURN_URLS=|TURN_CREDENTIAL_TTL_SECONDS=)' \
    "$SLOW_MEET_ENV_FILE"; then
    fail "SlowMeet's non-secret application settings should stay in Compose"
fi
if grep -Eq '^(DB_NAME_0|TG_CHAT_ID_0|DASHBOARD_USERNAME|ENCRYPTION_TYPE)=' "$CRAB_DUMP_ENV_FILE"; then
    fail "Crab Dump's non-secret application settings should stay in Compose"
fi
assert_contains "$(< "$PODMAN_SERVICE_FILE")" "WorkingDirectory=$PROJECTS_DIR" \
    "Podman systemd unit should use the resolved projects directory"
if grep -q -- '--profile public' "$PODMAN_SERVICE_FILE"; then
    fail "public profile should not be enabled for a direct-access stack"
fi
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
START_LINE="$(grep -n 'After editing the environment files' "$STAGE_OUTPUT" | cut -d: -f1)"
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
PUBLIC_ACCESS_CHOICE=no
install_selected_engine > "$STAGE_OUTPUT"
assert_contains "$(< "$APT_LOG")" "install -y podman podman-compose" \
    "Podman installation should include the Compose provider"
PUBLIC_ACCESS_CHOICE=yes
stage_podman_service
assert_contains "$(< "$PODMAN_SERVICE_FILE")" "ExecStart=/usr/bin/podman-compose --profile public up -d" \
    "the managed Podman unit should enable the public profile when selected"
assert_contains "$(< "$PODMAN_SERVICE_FILE")" "ExecStop=/usr/bin/podman-compose --profile public down" \
    "the managed Podman unit should stop the same public profile"
UNIT_BACKUPS=("$PODMAN_SERVICE_FILE".backup-*)
((${#UNIT_BACKUPS[@]} >= 1)) || fail "changing the managed Podman unit profile should create a backup"
PUBLIC_ACCESS_CHOICE=no
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

: > "$PUBLIC_SETUP_LOG"
PUBLIC_ACCESS_CHOICE="no"
choose_public_access <<< "no" > "$STAGE_OUTPUT"
assert_eq "$PUBLIC_ACCESS_CHOICE" "no" "public-access setup should default to skipped"
[[ ! -s $PUBLIC_SETUP_LOG ]] || fail "skipping public access must not install packages or change host state"
choose_public_access <<< $'yes\nMEET.EXAMPLE.COM\nops@example.com' > "$STAGE_OUTPUT"
assert_eq "$PUBLIC_ACCESS_CHOICE" "yes" "the opt-in response should select public setup"
assert_eq "$PUBLIC_ACCESS_DOMAIN" "meet.example.com" "the DNS hostname should be normalized"
assert_eq "$PUBLIC_ACCESS_EMAIL" "ops@example.com" "the ACME email should be retained"
PUBLIC_ACCESS_CHOICE="no"

if (configure_slowmeet_public_access bad-domain ops@example.com) > "$STAGE_OUTPUT" 2>&1; then
    fail "invalid TLS domains should be rejected"
fi
[[ ! -s $PUBLIC_SETUP_LOG ]] || fail "invalid TLS input must be rejected before host changes"

cp -- "$ROOT_DIR/new_vps_projects/compose.yaml" "$COMPOSE_FILE"
ENGINE_CHOICE=docker
: > "$PUBLIC_SETUP_LOG"
CERTBOT_FAIL=1
export CERTBOT_FAIL
if (configure_slowmeet_public_access meet.example.com ops@example.com) > "$STAGE_OUTPUT" 2>&1; then
    fail "certificate issuance failure should stop public-access setup"
fi
unset CERTBOT_FAIL
assert_contains "$(< "$NGINX_CONFIG_FILE")" "location /" "failed certificate setup should retain a valid HTTP bootstrap config"
assert_contains "$(< "$NGINX_CONFIG_FILE")" "return 404" "failed certificate setup should not leave a TLS config without a certificate"
assert_contains "$(< "$STAGE_OUTPUT")" "Check DNS and public TCP port 80" \
    "certificate failures should include recovery guidance"
assert_contains "$(< "$PUBLIC_SETUP_LOG")" "ufw allow 80/tcp" "public setup should allow HTTP for ACME"
assert_contains "$(< "$PUBLIC_SETUP_LOG")" "ufw allow 443/tcp" "public setup should allow HTTPS"
assert_contains "$(< "$PUBLIC_SETUP_LOG")" "ufw allow 50000:50100/udp" "public setup should allow SlowMeet media"
if grep -q '^ufw enable' "$PUBLIC_SETUP_LOG"; then
    fail "public setup must preserve UFW's enabled state"
fi
assert_contains "$(< "$COMPOSE_FILE")" 'HTTP_ADDR: ":1102"' \
    "a failed certificate request should leave the Compose listener unchanged"
assert_contains "$(< "$START_LOG")" "docker compose --profile public up -d nginx" \
    "public setup should start the Compose Nginx service for ACME"
if grep -Eq 'compose .*up .* (slowmeet|crab-dump)' "$START_LOG"; then
    fail "public setup must leave the app containers stopped"
fi

: > "$PUBLIC_SETUP_LOG"
configure_slowmeet_public_access meet.example.com ops@example.com > "$STAGE_OUTPUT"
assert_contains "$(< "$COMPOSE_FILE")" 'HTTP_ADDR: "127.0.0.1:1102"' \
    "proxy mode should bind the host-network HTTP backend to loopback"
assert_contains "$(< "$COMPOSE_FILE")" 'HTTP_PUBLISH_ADDRESS: "meet.example.com"' \
    "proxy mode should configure the public SlowMeet hostname in Compose"
assert_contains "$(< "$COMPOSE_FILE")" 'network_mode: host' \
    "proxy setup should retain host networking"
assert_contains "$(< "$NGINX_CONFIG_FILE")" "listen 443 ssl http2" \
    "Nginx should serve the HTTPS virtual host"
assert_contains "$(< "$NGINX_CONFIG_FILE")" "proxy_pass http://127.0.0.1:1102" \
    "Nginx should proxy to the private SlowMeet listener"
assert_contains "$(< "$NGINX_CONFIG_FILE")" "proxy_set_header Upgrade" \
    "Nginx should forward WebSocket upgrades"
assert_contains "$(< "$NGINX_CONFIG_FILE")" 'map $http_upgrade' \
    "Nginx should configure WebSocket connection handling"
assert_contains "$(< "$PUBLIC_SETUP_LOG")" "certbot certonly --webroot" \
    "TLS issuance should use the ACME webroot flow"
assert_contains "$(< "$PUBLIC_SETUP_LOG")" "--deploy-hook $CERTBOT_DEPLOY_HOOK_DIR/vps-projects-nginx-reload" \
    "initial issuance should install the Compose Nginx renewal hook"
assert_contains "$(< "$CERTBOT_DEPLOY_HOOK_DIR/vps-projects-nginx-reload")" \
    "docker compose --profile public exec -T nginx nginx -s reload" \
    "automatic certificate renewals should reload the Compose Nginx service"
bash -n "$CERTBOT_DEPLOY_HOOK_DIR/vps-projects-nginx-reload" ||
    fail "generated Certbot renewal hook should have valid Bash syntax"
[[ $(stat -c '%a' "$CERTBOT_DEPLOY_HOOK_DIR/vps-projects-nginx-reload") == 750 ]] ||
    fail "generated Certbot renewal hook should only be executable by its owner/group"
assert_contains "$(< "$START_LOG")" "docker compose --profile public exec -T nginx nginx -t" \
    "the TLS Nginx configuration should be validated in the running container"
assert_contains "$(< "$START_LOG")" "docker compose --profile public exec -T nginx nginx -s reload" \
    "Nginx should reload after installing the TLS config"
assert_contains "$(< "$PUBLIC_SETUP_LOG")" "systemctl enable --now certbot.timer" \
    "host Certbot should renew certificates automatically"
assert_contains "$(< "$APT_LOG")" "install -y certbot ufw" \
    "Certbot and UFW should remain host-managed"
if grep -q 'install -y nginx' "$APT_LOG"; then
    fail "Nginx should run from Compose, not be installed on the host"
fi
if grep -q '^ufw allow 1102' "$PUBLIC_SETUP_LOG"; then
    fail "the private SlowMeet HTTP backend must not receive a public UFW allow rule"
fi
shopt -s nullglob
PROXY_COMPOSE_BACKUPS=("$COMPOSE_FILE".backup-*)
((${#PROXY_COMPOSE_BACKUPS[@]} >= 1)) || fail "proxy setup should back up Compose before changing it"
assert_contains "$(< "$START_LOG")" "docker compose --profile public up -d nginx" \
    "proxy setup should start Nginx only"
if grep -Eq 'compose .*up .* (slowmeet|crab-dump)' "$START_LOG"; then
    fail "proxy setup must not start app containers"
fi

OLD_NGINX_CONFIG="$(< "$NGINX_CONFIG_FILE")"
id() {
    [[ ${1:-} == -u ]] && { printf '0\n'; return 0; }
    command id "$@"
}
main --refresh-compose > "$STAGE_OUTPUT"
unset -f id
assert_contains "$(< "$NGINX_CONFIG_FILE")" "server_name meet.example.com" \
    "refresh should regenerate the managed proxy config using the configured domain"
assert_contains "$(< "$COMPOSE_FILE")" 'HTTP_ADDR: "127.0.0.1:1102"' \
    "refresh should preserve the proxy loopback listener"
assert_contains "$(< "$COMPOSE_FILE")" 'HTTP_PUBLISH_ADDRESS: "meet.example.com"' \
    "refresh should preserve the configured public address"
NGINX_BACKUPS=("$NGINX_CONFIG_FILE".backup-*)
((${#NGINX_BACKUPS[@]} >= 1)) || fail "proxy config refresh should make a timestamped backup"
printf '%s\n' "$OLD_NGINX_CONFIG" | grep -q "server_name meet.example.com" ||
    fail "the previous Nginx config should contain the configured public domain"

printf 'operator-managed nginx config\n' > "$NGINX_CONFIG_FILE"
: > "$PUBLIC_SETUP_LOG"
if (configure_slowmeet_public_access meet.example.com ops@example.com) > "$STAGE_OUTPUT" 2>&1; then
    fail "public setup should refuse to overwrite unmanaged Compose Nginx configuration"
fi
assert_eq "$(< "$NGINX_CONFIG_FILE")" "operator-managed nginx config" \
    "unmanaged Nginx configuration should be preserved"
[[ ! -s $PUBLIC_SETUP_LOG ]] || fail "Nginx conflicts should be detected before host changes"

printf 'PASS: staging, optional Compose Nginx/TLS/UFW setup, loopback proxy, backups, and app containers remain stopped\n'
