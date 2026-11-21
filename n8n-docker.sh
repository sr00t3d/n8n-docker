#!/usr/bin/env bash
# ==============================================================================
#  n8n-docker.sh — Universal Self-Hosted n8n Queue-Mode Stack Manager
# ==============================================================================
#  Author  : Percio Castelo <percio@perciocastelo.com.br>
#  Website : https://perciocastelo.com.br
#  Project : https://perciocastelo.com.br/projetos/en/n8n-docker.html
#  Repo    : https://github.com/sr00t3d/n8n-docker
#  License : Apache-2.0
#  Version : 2.0.0
# ==============================================================================

set -uo pipefail

readonly SCRIPT_NAME="n8n-docker.sh"
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

# Runtime options
ACTION=""
FORMAT="table"
DRY_RUN=0
QUIET=0
NO_COLOR=0
FORCE=0
WORKERS=1
DOMAIN_ARG=""
PORT_ARG="5678"
TIMEZONE_ARG="America/Sao_Paulo"
BACKUP_DIR="${SCRIPT_DIR}/backups"

# Detected environment
RUNTIME="none"
COMPOSE_CMD=""
OS_PRETTY="unknown"
TIMESTAMP_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# Colors
RED="" GREEN="" YELLOW="" CYAN="" BOLD="" RESET=""
OK="[OK]" ATT="[!]" FAIL="[ERR]"

init_colors() {
  if [[ "$NO_COLOR" -eq 0 && -t 1 && -z "${NO_COLOR:-}" && "$FORMAT" == "table" ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
    OK="${GREEN}[OK]${RESET}"
    ATT="${YELLOW}[!]${RESET}"
    FAIL="${RED}[ERR]${RESET}"
  else
    RED="" GREEN="" YELLOW="" CYAN="" BOLD="" RESET=""
    OK="[OK]" ATT="[!]" FAIL="[ERR]"
  fi
}

show_help() {
  cat <<'USAGE'
n8n-docker.sh v2.0.0 — Universal Self-Hosted n8n Queue-Mode Stack Manager

Usage:
  n8n-docker.sh <action> [options]

Actions:
  --init                     Generate .env with strong random secrets (chmod 600)
  --status, --preflight      Audit runtime (Docker/Podman), .env security, listen port & containers
  --up                       Start stack (PostgreSQL 17 + Redis 7 + n8n + workers)
  --down                     Stop and remove stack containers (preserves volumes)
  --restart                  Restart stack services
  --update                   Pull latest images and recreate containers safely
  --logs                     Tail n8n and n8n-worker logs
  --backup                   Create chmod 600 gzipped PostgreSQL backup in ./backups/
  --install-systemd          Install and enable portable n8n-docker.service unit (requires root)

Options:
  --domain <fqdn>            Domain for N8N_HOST / N8N_WEBHOOK_URL when running --init
  --port <port>              Host loopback listen port for --init (default: 5678)
  --tz <timezone>            Timezone for --init (default: America/Sao_Paulo)
  --workers <N>              Number of n8n-worker replicas for --up/--update/--install-systemd (default: 1)
  --backup-dir <dir>         Custom backup output directory (default: ./backups)
  --force                    Overwrite existing .env on --init
  --dry-run                  Preview planned actions without modifying the system
  -o, --output <fmt>         Output format: table (default), json, csv
  -q, --quiet                Suppress banner header
  --no-color                 Disable ANSI colors
  -V, --version              Show version and exit
  -h, --help                 Show this help and exit

Examples:
  ./n8n-docker.sh --init --domain n8n.example.com
  ./n8n-docker.sh --status -o json
  ./n8n-docker.sh --up --workers 2
  ./n8n-docker.sh --backup --dry-run
  sudo ./n8n-docker.sh --install-systemd
USAGE
}

detect_env() {
  if [[ -r /etc/os-release ]]; then
    OS_PRETTY="$(awk -F= '/^PRETTY_NAME=/ {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || printf 'linux')"
  fi

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    RUNTIME="docker"
    COMPOSE_CMD="docker compose"
  elif command -v podman-compose >/dev/null 2>&1; then
    RUNTIME="podman"
    COMPOSE_CMD="podman-compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    RUNTIME="docker-legacy"
    COMPOSE_CMD="docker-compose"
  fi
}

gen_secret() {
  local len="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$((len / 2))"
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
  fi
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

run_compose() {
  if [[ -z "$COMPOSE_CMD" ]]; then
    printf '%s No Docker Compose or Podman Compose runtime found.\n' "$FAIL" >&2
    exit 1
  fi
  # shellcheck disable=SC2086
  $COMPOSE_CMD -f "$COMPOSE_FILE" "$@"
}

action_init() {
  local domain="${DOMAIN_ARG:-n8n.example.com}"
  if [[ -f "$ENV_FILE" && "$FORCE" -eq 0 ]]; then
    printf '%s %s already exists. Use --force to regenerate.\n' "$ATT" "$ENV_FILE"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$FORMAT" == "json" ]]; then
      printf '{"action":"init","dry_run":true,"env_file":"%s","domain":"%s","timezone":"%s","permissions":"600"}\n' \
        "$(json_escape "$ENV_FILE")" "$(json_escape "$domain")" "$(json_escape "$TIMEZONE_ARG")"
    else
      printf '%s [DRY-RUN] Would generate %s (chmod 600) for domain %s (TZ=%s) with random encryption/PG/Redis secrets.\n' \
        "$ATT" "$ENV_FILE" "$domain" "$TIMEZONE_ARG"
    fi
    return 0
  fi

  local enc_key pg_root pg_app redis_pw
  enc_key="$(gen_secret 48)"
  pg_root="$(gen_secret 32)"
  pg_app="$(gen_secret 32)"
  redis_pw="$(gen_secret 32)"

  (
    umask 077
    cat <<EOF > "$ENV_FILE"
# Generated by ${SCRIPT_NAME} v${SCRIPT_VERSION} on ${TIMESTAMP_UTC}
N8N_VERSION=stable
N8N_HOST=${domain}
N8N_PORT=5678
N8N_LISTEN_PORT=${PORT_ARG}
N8N_BIND_ADDR=127.0.0.1
N8N_PROTOCOL=https
N8N_WEBHOOK_URL=https://${domain}/
N8N_ENCRYPTION_KEY=${enc_key}
GENERIC_TIMEZONE=${TIMEZONE_ARG}
TZ=${TIMEZONE_ARG}

POSTGRES_DB=n8n
POSTGRES_USER=postgres
POSTGRES_PASSWORD=${pg_root}
POSTGRES_NON_ROOT_USER=n8n_user
POSTGRES_NON_ROOT_PASSWORD=${pg_app}

REDIS_PASSWORD=${redis_pw}
QUEUE_BULL_REDIS_DB=0
EOF
    chmod 600 "$ENV_FILE"
  )
  printf '%s Created %s with strong random secrets (chmod 600) for %s.\n' "$OK" "$ENV_FILE" "$domain"
}

action_status() {
  local ram_mb disk_gb env_state="missing" env_perms="none" listen_port="5678" port_state="free" compose_valid="skipped"
  ram_mb="$(awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || printf '0')"
  disk_gb="$(df -BG "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {gsub(/G/, "", $4); print $4}' || printf '0')"

  if [[ -f "$ENV_FILE" ]]; then
    env_state="present"
    env_perms="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || printf 'unknown')"
    local env_port
    env_port="$(awk -F= '/^N8N_LISTEN_PORT=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$ENV_FILE" 2>/dev/null || true)"
    [[ -n "$env_port" ]] && listen_port="$env_port"
  fi

  if command -v ss >/dev/null 2>&1 && ss -tuln 2>/dev/null | grep -qE ":${listen_port}[[:space:]]"; then
    port_state="in-use"
  fi

  if [[ -n "$COMPOSE_CMD" && -f "$COMPOSE_FILE" ]]; then
    local ef="$ENV_EXAMPLE"
    [[ -f "$ENV_FILE" ]] && ef="$ENV_FILE"
    if $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ef" config --quiet >/dev/null 2>&1; then
      compose_valid="valid"
    else
      compose_valid="invalid"
    fi
  fi

  case "$FORMAT" in
    json)
      cat <<EOF
{
  "tool": "${SCRIPT_NAME}",
  "version": "${SCRIPT_VERSION}",
  "timestamp": "$(json_escape "$TIMESTAMP_UTC")",
  "os": "$(json_escape "$OS_PRETTY")",
  "runtime": "$(json_escape "$RUNTIME")",
  "compose_cmd": "$(json_escape "${COMPOSE_CMD:-none}")",
  "compose_file_valid": "$(json_escape "$compose_valid")",
  "ram_mb": ${ram_mb:-0},
  "disk_free_gb": ${disk_gb:-0},
  "env_file": "$(json_escape "$env_state")",
  "env_perms": "$(json_escape "$env_perms")",
  "listen_port": ${listen_port},
  "port_status": "$(json_escape "$port_state")"
}
EOF
      ;;
    csv)
      printf 'os,runtime,compose_valid,ram_mb,disk_free_gb,env_file,env_perms,listen_port,port_status\n'
      printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
        "$OS_PRETTY" "$RUNTIME" "$compose_valid" "$ram_mb" "$disk_gb" "$env_state" "$env_perms" "$listen_port" "$port_state"
      ;;
    table)
      if [[ "$QUIET" -eq 0 ]]; then
        printf '%s=====================================================================%s\n' "$CYAN" "$RESET"
        printf ' %s%s v%s%s | Universal n8n Stack Audit | %s\n' "$BOLD" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$RESET" "$TIMESTAMP_UTC"
        printf '%s=====================================================================%s\n' "$CYAN" "$RESET"
      fi
      printf '  OS             : %s\n' "$OS_PRETTY"
      printf '  Runtime        : %s (%s)\n' "$RUNTIME" "${COMPOSE_CMD:-not installed}"
      printf '  Compose Config : %s\n' "$compose_valid"
      printf '  RAM / Disk Free: %s MB / %s GB\n' "$ram_mb" "$disk_gb"
      printf '  .env File      : %s (permissions: %s)\n' "$env_state" "$env_perms"
      printf '  Port %-10s: %s\n' "$listen_port" "$port_state"
      ;;
  esac
}

action_up() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%s [DRY-RUN] Would run: %s -f %s up -d --scale n8n-worker=%s\n' "$ATT" "${COMPOSE_CMD:-docker compose}" "$COMPOSE_FILE" "$WORKERS"
    return 0
  fi
  [[ -f "$ENV_FILE" ]] || { printf '%s Missing .env file. Run: ./%s --init\n' "$FAIL" "$SCRIPT_NAME" >&2; exit 1; }
  run_compose up -d --scale "n8n-worker=${WORKERS}"
  printf '%s n8n stack started (%s worker(s)).\n' "$OK" "$WORKERS"
}

action_down() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%s [DRY-RUN] Would run: %s -f %s down\n' "$ATT" "${COMPOSE_CMD:-docker compose}" "$COMPOSE_FILE"
    return 0
  fi
  run_compose down
}

action_restart() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%s [DRY-RUN] Would run: %s -f %s restart\n' "$ATT" "${COMPOSE_CMD:-docker compose}" "$COMPOSE_FILE"
    return 0
  fi
  run_compose restart
}

action_update() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%s [DRY-RUN] Would pull latest images and run up -d --scale n8n-worker=%s\n' "$ATT" "$WORKERS"
    return 0
  fi
  run_compose pull
  run_compose up -d --scale "n8n-worker=${WORKERS}"
  printf '%s n8n stack updated.\n' "$OK"
}

action_logs() {
  run_compose logs -f --tail=100 n8n n8n-worker
}

action_backup() {
  local ts outfile
  ts="$(date -u '+%Y%m%d-%H%M%S')"
  outfile="${BACKUP_DIR}/n8n-pg-${ts}.sql.gz"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%s [DRY-RUN] Would dump PostgreSQL database to %s (chmod 600)\n' "$ATT" "$outfile"
    return 0
  fi
  [[ -f "$ENV_FILE" ]] || { printf '%s Missing .env file.\n' "$FAIL" >&2; exit 1; }
  local pg_user pg_db
  pg_user="$(awk -F= '/^POSTGRES_USER=/ {print $2; exit}' "$ENV_FILE")"
  pg_db="$(awk -F= '/^POSTGRES_DB=/ {print $2; exit}' "$ENV_FILE")"
  if ! (
    set -euo pipefail
    umask 077
    mkdir -p "$BACKUP_DIR"
    run_compose exec -T postgres pg_dump --clean --if-exists -U "${pg_user:-postgres}" "${pg_db:-n8n}" | gzip -9 > "$outfile"
    chmod 600 "$outfile"
  ) || [[ ! -s "$outfile" ]]; then
    rm -f "$outfile"
    printf '%s PostgreSQL backup failed.\n' "$FAIL" >&2
    exit 1
  fi
  printf '%s Backup saved to %s (chmod 600).\n' "$OK" "$outfile"
}

action_install_systemd() {
  local unit_path="/etc/systemd/system/n8n-docker.service"
  local exec_bin
  if [[ "$RUNTIME" == "podman" ]]; then
    exec_bin="$(command -v podman-compose)"
  else
    exec_bin="$(command -v docker 2>/dev/null || printf '/usr/bin/docker') compose"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%s [DRY-RUN] Would write %s (WorkingDirectory=%s, ExecStart=%s -f docker-compose.yml up -d --scale n8n-worker=%s)\n' \
      "$ATT" "$unit_path" "$SCRIPT_DIR" "$exec_bin" "$WORKERS"
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    printf '%s --install-systemd requires root privileges.\n' "$FAIL" >&2
    exit 1
  fi

  cat <<EOF > "$unit_path"
[Unit]
Description=Universal n8n Queue-Mode Docker Stack
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${exec_bin} -f ${COMPOSE_FILE} up -d --scale n8n-worker=${WORKERS}
ExecStop=${exec_bin} -f ${COMPOSE_FILE} down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable n8n-docker.service
  printf '%s Installed and enabled %s\n' "$OK" "$unit_path"
}

main() {
  detect_env
  [[ "$#" -eq 0 ]] && { show_help; exit 1; }

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -h|--help)            show_help; exit 0 ;;
      -V|--version)         printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
      --init)               ACTION="init"; shift ;;
      --status|--preflight) ACTION="status"; shift ;;
      --up)                 ACTION="up"; shift ;;
      --down)               ACTION="down"; shift ;;
      --restart)            ACTION="restart"; shift ;;
      --update)             ACTION="update"; shift ;;
      --logs)               ACTION="logs"; shift ;;
      --backup)             ACTION="backup"; shift ;;
      --install-systemd)    ACTION="install-systemd"; shift ;;
      --domain)             DOMAIN_ARG="${2:-}"; shift 2 ;;
      --port)               PORT_ARG="${2:-5678}"; shift 2 ;;
      --tz)                 TIMEZONE_ARG="${2:-America/Sao_Paulo}"; shift 2 ;;
      --workers)            WORKERS="${2:-1}"; shift 2 ;;
      --backup-dir)         BACKUP_DIR="${2:-$BACKUP_DIR}"; shift 2 ;;
      --force)              FORCE=1; shift ;;
      --dry-run)            DRY_RUN=1; shift ;;
      -q|--quiet)           QUIET=1; shift ;;
      --no-color)           NO_COLOR=1; shift ;;
      -o|--output)          FORMAT="${2:-table}"; shift 2 ;;
      --output=*)           FORMAT="${1#*=}"; shift ;;
      *)                    printf '[ERR] Unknown option: %s (use -h for help)\n' "$1" >&2; exit 1 ;;
    esac
  done

  case "$FORMAT" in
    table|json|csv) ;;
    *) printf '[ERR] Invalid output format: %s (expected table, json, or csv)\n' "$FORMAT" >&2; exit 1 ;;
  esac

  init_colors

  case "$ACTION" in
    init)            action_init ;;
    status)          action_status ;;
    up)              action_up ;;
    down)            action_down ;;
    restart)         action_restart ;;
    update)          action_update ;;
    logs)            action_logs ;;
    backup)          action_backup ;;
    install-systemd) action_install_systemd ;;
    *)               printf '%s No action specified. Use -h for help.\n' "$FAIL" >&2; exit 1 ;;
  esac
}

main "$@"
