#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SERVICE_NAME="signal-cli"
DATA_DIR="/var/lib/signal-cli"
CONFIG_FILE="/etc/default/signal-cli"
WRAPPER_FILE="/usr/local/sbin/signal-cli-daemon-start"
SERVICE_FILE="/etc/systemd/system/signal-cli.service"
FAIL2BAN_FILE="/etc/fail2ban/jail.d/sshd.local"
SYSCTL_FILE="/etc/sysctl.d/99-signal-cli-server-hardening.conf"
SSH_HARDENING_FILE="/etc/ssh/sshd_config.d/99-signal-cli-hardening.conf"

DRY_RUN="${DRY_RUN:-false}"
PURGE_DATA="false"
PURGE_BINARIES="false"
PURGE_HARDENING="false"
ASSUME_YES="false"

log() { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  sudo $0 [options]

Options:
  --dry-run          Print what would be removed without changing the system.
  --purge-data       Remove $DATA_DIR. Requires confirmation or --yes.
  --purge-binaries   Remove signal-cli files under /opt and /usr/local/bin/signal-cli.
  --purge-hardening  Remove installer-created fail2ban, sysctl, and SSH hardening files.
  --yes              Skip confirmation prompts for explicitly requested purge actions.
  -h, --help         Show this help.
EOF
}

is_true() {
  case "${1,,}" in
    1 | true | yes | y | on) return 0 ;;
    *) return 1 ;;
  esac
}

run_cmd() {
  if is_true "$DRY_RUN"; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --purge-data)
        PURGE_DATA="true"
        shift
        ;;
      --purge-binaries)
        PURGE_BINARIES="true"
        shift
        ;;
      --purge-hardening)
        PURGE_HARDENING="true"
        shift
        ;;
      --yes)
        ASSUME_YES="true"
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

require_root() {
  if is_true "$DRY_RUN"; then
    return 0
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
  fi
}

confirm_purge_data() {
  if ! is_true "$PURGE_DATA" || is_true "$DRY_RUN" || is_true "$ASSUME_YES"; then
    return 0
  fi

  if [[ ! -r /dev/tty ]]; then
    die "--purge-data requires --yes when no interactive terminal is available."
  fi

  local answer
  printf 'This will permanently remove linked-device state in %s.\n' "$DATA_DIR" > /dev/tty
  read -r -p 'Type "remove signal-cli data" to continue: ' answer < /dev/tty || true
  [[ "$answer" == "remove signal-cli data" ]] || die "Data purge confirmation did not match."
}

print_plan() {
  cat <<EOF

Uninstall plan:
  Stop service: $SERVICE_NAME
  Remove service file: $SERVICE_FILE
  Remove wrapper: $WRAPPER_FILE
  Remove runtime config: $CONFIG_FILE
  Purge data: $PURGE_DATA
  Purge binaries: $PURGE_BINARIES
  Purge hardening files: $PURGE_HARDENING

Preserved by default:
  $DATA_DIR
  /opt/signal-cli-*
  /opt/signal-cli-native-*
  /usr/local/bin/signal-cli
EOF
}

main() {
  parse_args "$@"
  require_root "$@"
  confirm_purge_data
  print_plan

  log "Stopping and disabling service."
  run_cmd systemctl disable --now "$SERVICE_NAME" || true

  log "Removing service-managed files."
  run_cmd rm -f "$SERVICE_FILE"
  run_cmd rm -f "$WRAPPER_FILE"
  run_cmd rm -f "$CONFIG_FILE"
  run_cmd systemctl daemon-reload || true

  if is_true "$PURGE_HARDENING"; then
    log "Removing installer-created hardening files."
    run_cmd rm -f "$FAIL2BAN_FILE"
    run_cmd rm -f "$SYSCTL_FILE"
    run_cmd rm -f "$SSH_HARDENING_FILE"
  fi

  if is_true "$PURGE_BINARIES"; then
    log "Removing signal-cli binaries."
    run_cmd rm -f /usr/local/bin/signal-cli
    run_cmd rm -rf /opt/signal-cli-* /opt/signal-cli-native-*
  fi

  if is_true "$PURGE_DATA"; then
    log "Removing linked-device state."
    run_cmd rm -rf "$DATA_DIR"
  else
    warn "Preserved linked-device state in $DATA_DIR."
  fi
}

main "$@"
