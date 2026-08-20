#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SERVICE_NAME="signal-cli"
INSTALL_ROOT="${INSTALL_ROOT:-}"
root_path() {
  printf '%s%s\n' "$INSTALL_ROOT" "$1"
}

DATA_DIR="$(root_path /var/lib/signal-cli)"
CONFIG_FILE="$(root_path /etc/default/signal-cli)"
WRAPPER_FILE="$(root_path /usr/local/sbin/signal-cli-daemon-start)"
SERVICE_FILE="$(root_path /etc/systemd/system/signal-cli.service)"
FAIL2BAN_FILE="$(root_path /etc/fail2ban/jail.d/99-signal-cli-sshd.local)"
SYSCTL_FILE="$(root_path /etc/sysctl.d/99-signal-cli-server-hardening.conf)"
SSH_HARDENING_FILE="$(root_path /etc/ssh/sshd_config.d/99-signal-cli-hardening.conf)"
OPT_DIR="$(root_path /opt)"
LOCAL_SIGNAL_CLI="$(root_path /usr/local/bin/signal-cli)"
LIFECYCLE_LOCK_FILE="$(root_path /run/signal-cli-lifecycle.lock)"
LIFECYCLE_LOCK_FALLBACK_DIR="${LIFECYCLE_LOCK_FILE}.test-mkdir"
LIFECYCLE_LOCK_FALLBACK_OWNER_FILE="$LIFECYCLE_LOCK_FALLBACK_DIR/owner"
SIGNAL_CLI_INSTALL_MANIFEST_NAME=".signal-cli-install-manifest"

DRY_RUN="${DRY_RUN:-false}"
PURGE_DATA="false"
PURGE_BINARIES="false"
PURGE_HARDENING="false"
ASSUME_YES="false"
LIFECYCLE_LOCK_HELD="false"
LIFECYCLE_LOCK_BACKEND=""
LIFECYCLE_LOCK_FD=""
LIFECYCLE_LOCK_OWNER_PID=""

log() { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
die() {
  printf '\n[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  sudo $0 [options]

Options:
  --dry-run          Print what would be removed without changing the system.
  --purge-data       Remove $DATA_DIR. Requires confirmation or --yes.
  --purge-binaries   Remove validated installer-managed binaries and their active symlink.
  --purge-hardening  Remove installer-created hardening files; loaded policy may remain active.
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

path_owner_uid() {
  stat -c %u "$1" 2>/dev/null || stat -f %u "$1"
}

path_mode_bits() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

expected_managed_owner_uid() {
  if is_true "${TEST_MODE:-false}"; then
    printf '%s\n' "$EUID"
  else
    printf '0\n'
  fi
}

path_is_not_group_or_world_writable() {
  local mode
  mode="$(path_mode_bits "$1")" || return 1
  [[ "$mode" =~ ^[0-7]+$ ]] || return 1
  (( (8#$mode & 0022) == 0 ))
}

run_cmd() {
  if is_true "$DRY_RUN"; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  elif is_true "${TEST_MODE:-false}" && ! is_true "${TEST_RUN_SYSTEMCTL:-false}" && [[ "${1:-}" == "systemctl" ]]; then
    printf '[test-mode] skip systemctl'
    printf ' %q' "${@:2}"
    printf '\n'
  else
    "$@"
  fi
}

ensure_lifecycle_lock_parent() {
  local lock_parent="$1"

  if [[ -L "$lock_parent" || ( -e "$lock_parent" && ! -d "$lock_parent" ) ]]; then
    die "Lifecycle lock parent is not a regular directory: $lock_parent"
  fi
  if [[ ! -e "$lock_parent" ]]; then
    run_cmd mkdir -p -m 0755 "$lock_parent"
  fi
  [[ -d "$lock_parent" && ! -L "$lock_parent" ]] ||
    die "Lifecycle lock parent is not a regular directory: $lock_parent"
}

acquire_lifecycle_lock() {
  local backend="" expected_owner lock_mode lock_owner lock_parent owner_pid

  if is_true "$DRY_RUN" || is_true "$LIFECYCLE_LOCK_HELD"; then
    return 0
  fi

  lock_parent="$(dirname "$LIFECYCLE_LOCK_FILE")"
  ensure_lifecycle_lock_parent "$lock_parent"

  if [[ "${SIGNAL_CLI_TEST_LOCK_BACKEND:-}" == "mkdir" ]]; then
    is_true "${TEST_MODE:-false}" || die "The mkdir lifecycle-lock backend is restricted to TEST_MODE."
    backend="mkdir"
  elif command -v flock >/dev/null 2>&1; then
    backend="flock"
  elif is_true "${TEST_MODE:-false}"; then
    backend="mkdir"
    warn "flock is unavailable; using the TEST_MODE-only mkdir lifecycle lock."
  else
    die "flock is required for lifecycle locking. Install util-linux and retry."
  fi

  if [[ "$backend" == "mkdir" ]]; then
    if ! mkdir -m 0700 "$LIFECYCLE_LOCK_FALLBACK_DIR" 2>/dev/null; then
      die "Another signal-cli lifecycle operation is already running (lock: $LIFECYCLE_LOCK_FALLBACK_DIR)."
    fi

    owner_pid="${BASHPID:-$$}"
    if ! (umask 077 && printf '%s\n' "$owner_pid" >"$LIFECYCLE_LOCK_FALLBACK_OWNER_FILE"); then
      rmdir "$LIFECYCLE_LOCK_FALLBACK_DIR" 2>/dev/null || true
      die "Could not initialize the TEST_MODE lifecycle lock."
    fi
    LIFECYCLE_LOCK_OWNER_PID="$owner_pid"
    LIFECYCLE_LOCK_BACKEND="mkdir"
    LIFECYCLE_LOCK_HELD="true"
    return 0
  fi

  if [[ -L "$LIFECYCLE_LOCK_FILE" || ( -e "$LIFECYCLE_LOCK_FILE" && ! -f "$LIFECYCLE_LOCK_FILE" ) ]]; then
    die "Lifecycle lock path is not a regular file: $LIFECYCLE_LOCK_FILE"
  fi
  if [[ ! -e "$LIFECYCLE_LOCK_FILE" ]]; then
    if ! (umask 077 && set -o noclobber && : >"$LIFECYCLE_LOCK_FILE") 2>/dev/null; then
      [[ -f "$LIFECYCLE_LOCK_FILE" && ! -L "$LIFECYCLE_LOCK_FILE" ]] ||
        die "Could not create lifecycle lock file: $LIFECYCLE_LOCK_FILE"
    fi
  fi

  [[ -f "$LIFECYCLE_LOCK_FILE" && ! -L "$LIFECYCLE_LOCK_FILE" ]] ||
    die "Lifecycle lock path is not a regular file: $LIFECYCLE_LOCK_FILE"
  expected_owner="$(expected_managed_owner_uid)"
  lock_owner="$(path_owner_uid "$LIFECYCLE_LOCK_FILE")" || die "Could not inspect lifecycle lock ownership."
  [[ "$lock_owner" == "$expected_owner" ]] || die "Lifecycle lock file has an unexpected owner: $LIFECYCLE_LOCK_FILE"
  lock_mode="$(path_mode_bits "$LIFECYCLE_LOCK_FILE")" || die "Could not inspect lifecycle lock permissions."
  [[ "$lock_mode" =~ ^[0-7]+$ ]] || die "Lifecycle lock file has invalid permissions."
  (( (8#$lock_mode & 0022) == 0 )) || die "Lifecycle lock file must not be group- or world-writable."

  if ! exec {LIFECYCLE_LOCK_FD}<>"$LIFECYCLE_LOCK_FILE"; then
    LIFECYCLE_LOCK_FD=""
    die "Could not open lifecycle lock file: $LIFECYCLE_LOCK_FILE"
  fi
  if ! flock -n "$LIFECYCLE_LOCK_FD"; then
    exec {LIFECYCLE_LOCK_FD}>&-
    LIFECYCLE_LOCK_FD=""
    die "Another signal-cli lifecycle operation is already running (lock: $LIFECYCLE_LOCK_FILE)."
  fi

  LIFECYCLE_LOCK_BACKEND="flock"
  LIFECYCLE_LOCK_HELD="true"
}

release_lifecycle_lock() {
  local recorded_owner="" release_failed=false

  is_true "$LIFECYCLE_LOCK_HELD" || return 0

  if [[ "$LIFECYCLE_LOCK_BACKEND" == "flock" ]]; then
    if [[ "$LIFECYCLE_LOCK_FD" =~ ^[0-9]+$ ]]; then
      if ! flock -u "$LIFECYCLE_LOCK_FD"; then
        warn "Could not explicitly unlock lifecycle lock: $LIFECYCLE_LOCK_FILE"
        release_failed=true
      fi
      if ! exec {LIFECYCLE_LOCK_FD}>&-; then
        warn "Could not close lifecycle lock descriptor: $LIFECYCLE_LOCK_FILE"
        release_failed=true
      fi
    else
      warn "Lifecycle lock descriptor is unavailable: $LIFECYCLE_LOCK_FILE"
      release_failed=true
    fi
  elif [[ "$LIFECYCLE_LOCK_BACKEND" == "mkdir" ]]; then
    if [[ -L "$LIFECYCLE_LOCK_FALLBACK_OWNER_FILE" ]]; then
      warn "Refusing to release lifecycle lock with a symlinked owner marker: $LIFECYCLE_LOCK_FALLBACK_OWNER_FILE"
      release_failed=true
    elif [[ -f "$LIFECYCLE_LOCK_FALLBACK_OWNER_FILE" ]]; then
      recorded_owner="$(<"$LIFECYCLE_LOCK_FALLBACK_OWNER_FILE")"
      if [[ "$recorded_owner" != "$LIFECYCLE_LOCK_OWNER_PID" ]]; then
        warn "Lifecycle lock ownership changed; leaving it in place: $LIFECYCLE_LOCK_FALLBACK_DIR"
        release_failed=true
      else
        rm -f -- "$LIFECYCLE_LOCK_FALLBACK_OWNER_FILE"
      fi
    fi

    if ! is_true "$release_failed" && [[ -d "$LIFECYCLE_LOCK_FALLBACK_DIR" ]]; then
      if ! rmdir "$LIFECYCLE_LOCK_FALLBACK_DIR"; then
        warn "Could not release lifecycle lock: $LIFECYCLE_LOCK_FALLBACK_DIR"
        release_failed=true
      fi
    fi
  else
    warn "Lifecycle lock backend state is invalid."
    release_failed=true
  fi

  LIFECYCLE_LOCK_HELD="false"
  LIFECYCLE_LOCK_BACKEND=""
  LIFECYCLE_LOCK_FD=""
  LIFECYCLE_LOCK_OWNER_PID=""
  ! is_true "$release_failed"
}

cleanup() {
  release_lifecycle_lock || true
}

stop_and_disable_service() {
  log "Stopping and disabling service."
  run_cmd systemctl disable --now "$SERVICE_NAME" || warn "systemctl could not disable and stop $SERVICE_NAME; checking its state."

  if is_true "$DRY_RUN" || { is_true "${TEST_MODE:-false}" && ! is_true "${TEST_RUN_SYSTEMCTL:-false}"; }; then
    return 0
  fi

  local service_state="" load_state=""
  service_state="$(run_cmd systemctl is-active "$SERVICE_NAME" 2>/dev/null)" || true
  case "$service_state" in
    inactive | failed)
      return 0
      ;;
    active | activating | reloading | deactivating)
      die "$SERVICE_NAME service is still active; refusing to remove its files."
      ;;
  esac

  if load_state="$(run_cmd systemctl show "$SERVICE_NAME" --property=LoadState --value 2>/dev/null)" && [[ "$load_state" == "not-found" ]]; then
    return 0
  fi

  die "Could not confirm that $SERVICE_NAME is inactive or absent; refusing to remove its files."
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
  if is_true "$DRY_RUN" || is_true "${TEST_MODE:-false}"; then
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

  local answer tty_fd
  if ! { exec {tty_fd}<>/dev/tty; } 2>/dev/null; then
    die "--purge-data requires --yes when no interactive terminal is available."
  fi

  printf 'This will permanently remove linked-device state in %s.\n' "$DATA_DIR" >&"$tty_fd"
  printf 'Type "remove signal-cli data" to continue: ' >&"$tty_fd"
  IFS= read -r answer <&"$tty_fd" || true
  exec {tty_fd}>&-
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
  $OPT_DIR/signal-cli-*
  $OPT_DIR/signal-cli-native-*
  $LOCAL_SIGNAL_CLI
EOF
}

is_valid_install_version() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && "$1" != *..* ]]
}

install_manifest_content_is_exact() {
  local marker="$1" install_mode="$2" version="$3" actual expected expected_size marker_size
  expected="$(printf 'signal-cli-install-manifest-v1\nmode=%s\nversion=%s\n' "$install_mode" "$version")"
  expected_size=$((${#expected} + 1))
  marker_size="$(wc -c <"$marker")" || return 1
  marker_size="${marker_size//[[:space:]]/}"
  [[ "$marker_size" == "$expected_size" ]] || return 1
  actual="$(<"$marker")" || return 1
  [[ "$actual" == "$expected" ]]
}

is_managed_install_dir() {
  local candidate="$1" base version executable install_mode marker marker_mode expected_owner
  [[ -d "$candidate" && ! -L "$candidate" ]] || return 1
  base="${candidate##*/}"

  case "$base" in
    signal-cli-native-*)
      version="${base#signal-cli-native-}"
      executable="$candidate/signal-cli"
      install_mode="native"
      ;;
    signal-cli-*)
      version="${base#signal-cli-}"
      executable="$candidate/bin/signal-cli"
      install_mode="jvm"
      ;;
    *)
      return 1
      ;;
  esac

  is_valid_install_version "$version" || return 1
  marker="$candidate/$SIGNAL_CLI_INSTALL_MANIFEST_NAME"
  [[ -f "$executable" && ! -L "$executable" && -x "$executable" ]] || return 1
  [[ -f "$marker" && ! -L "$marker" ]] || return 1

  expected_owner="$(expected_managed_owner_uid)"
  [[ "$(path_owner_uid "$candidate")" == "$expected_owner" ]] || return 1
  [[ "$(path_owner_uid "$executable")" == "$expected_owner" ]] || return 1
  [[ "$(path_owner_uid "$marker")" == "$expected_owner" ]] || return 1
  path_is_not_group_or_world_writable "$candidate" || return 1
  path_is_not_group_or_world_writable "$executable" || return 1
  marker_mode="$(path_mode_bits "$marker")" || return 1
  [[ "$marker_mode" =~ ^[0-7]+$ ]] || return 1
  (( 8#$marker_mode == 0444 )) || return 1
  install_manifest_content_is_exact "$marker" "$install_mode" "$version"
}

trusted_managed_opt_dir() {
  local managed_opt_dir expected_owner

  [[ -d "$OPT_DIR" && ! -L "$OPT_DIR" ]] || return 1
  managed_opt_dir="$(readlink -f "$OPT_DIR" 2>/dev/null)" || return 1
  [[ -n "$managed_opt_dir" && -d "$managed_opt_dir" && ! -L "$managed_opt_dir" ]] || return 1
  expected_owner="$(expected_managed_owner_uid)" || return 1
  [[ "$(path_owner_uid "$managed_opt_dir")" == "$expected_owner" ]] || return 1
  path_is_not_group_or_world_writable "$managed_opt_dir" || return 1
  printf '%s\n' "$managed_opt_dir"
}

is_managed_active_symlink() {
  local target install_dir managed_opt_dir
  [[ -L "$LOCAL_SIGNAL_CLI" ]] || return 1
  managed_opt_dir="$(trusted_managed_opt_dir)" || return 1
  target="$(readlink -f "$LOCAL_SIGNAL_CLI" 2>/dev/null)" || return 1
  [[ -n "$managed_opt_dir" && -n "$target" ]] || return 1

  case "$target" in
    "$managed_opt_dir"/signal-cli-native-*/signal-cli)
      install_dir="${target%/signal-cli}"
      ;;
    "$managed_opt_dir"/signal-cli-*/bin/signal-cli)
      install_dir="${target%/bin/signal-cli}"
      ;;
    *)
      return 1
      ;;
  esac

  [[ "$(dirname "$install_dir")" == "$managed_opt_dir" ]] || return 1
  is_managed_install_dir "$install_dir"
}

purge_managed_binaries() {
  local candidate managed_opt_dir
  local -a candidates=()

  if is_true "$DRY_RUN"; then
    managed_opt_dir="$OPT_DIR"
  elif ! managed_opt_dir="$(trusted_managed_opt_dir)"; then
    die "Refusing binary purge because the managed install root is untrusted: $OPT_DIR"
  fi

  if is_managed_active_symlink; then
    run_cmd rm -f -- "$LOCAL_SIGNAL_CLI"
  elif [[ -e "$LOCAL_SIGNAL_CLI" || -L "$LOCAL_SIGNAL_CLI" ]]; then
    warn "Preserved unvalidated active executable at $LOCAL_SIGNAL_CLI."
  fi

  shopt -s nullglob
  candidates=("$managed_opt_dir"/signal-cli-*)
  shopt -u nullglob
  for candidate in "${candidates[@]}"; do
    if is_managed_install_dir "$candidate"; then
      run_cmd rm -rf -- "$candidate"
    else
      warn "Preserved unvalidated path $candidate."
    fi
  done
}

main() {
  parse_args "$@"
  require_root "$@"
  confirm_purge_data
  print_plan

  acquire_lifecycle_lock
  stop_and_disable_service

  log "Removing service-managed files."
  run_cmd rm -f "$SERVICE_FILE"
  run_cmd rm -f "$WRAPPER_FILE"
  run_cmd rm -f "$CONFIG_FILE"
  run_cmd systemctl daemon-reload

  if is_true "$PURGE_HARDENING"; then
    log "Removing installer-created hardening files."
    run_cmd rm -f "$FAIL2BAN_FILE"
    run_cmd rm -f "$SYSCTL_FILE"
    run_cmd rm -f "$SSH_HARDENING_FILE"
  fi

  if is_true "$PURGE_BINARIES"; then
    log "Removing signal-cli binaries."
    purge_managed_binaries
  fi

  if is_true "$PURGE_DATA"; then
    log "Removing linked-device state."
    run_cmd rm -rf "$DATA_DIR"
  else
    warn "Preserved linked-device state in $DATA_DIR."
  fi
}

trap cleanup EXIT
main "$@"
