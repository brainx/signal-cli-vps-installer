#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

INSTALL_ROOT="${INSTALL_ROOT:-}"
root_path() {
  printf '%s%s\n' "$INSTALL_ROOT" "$1"
}

SERVICE_USER="signal-cli"
SERVICE_GROUP="signal-cli"
DATA_DIR="$(root_path /var/lib/signal-cli)"
CONFIG_FILE="$(root_path /etc/default/signal-cli)"
WRAPPER_FILE="$(root_path /usr/local/sbin/signal-cli-daemon-start)"
SERVICE_FILE="$(root_path /etc/systemd/system/signal-cli.service)"
FAIL2BAN_FILE="$(root_path /etc/fail2ban/jail.d/99-signal-cli-sshd.local)"
SYSCTL_FILE="$(root_path /etc/sysctl.d/99-signal-cli-server-hardening.conf)"
SSH_HARDENING_FILE="$(root_path /etc/ssh/sshd_config.d/99-signal-cli-hardening.conf)"
UNATTENDED_UPGRADES_FILE="$(root_path /etc/apt/apt.conf.d/20auto-upgrades)"
OPT_DIR="$(root_path /opt)"
LOCAL_BIN_DIR="$(root_path /usr/local/bin)"
LIFECYCLE_LOCK_FILE="$(root_path /run/signal-cli-lifecycle.lock)"
LIFECYCLE_LOCK_FALLBACK_DIR="${LIFECYCLE_LOCK_FILE}.test-mkdir"
LIFECYCLE_LOCK_FALLBACK_OWNER_FILE="$LIFECYCLE_LOCK_FALLBACK_DIR/owner"
SIGNAL_CLI_INSTALL_MANIFEST_NAME=".signal-cli-install-manifest"

SIGNAL_ACCOUNT="${SIGNAL_ACCOUNT:-}"
DEVICE_NAME="${DEVICE_NAME:-}"
HTTP_BIND="${HTTP_BIND:-127.0.0.1:8080}"
INSTALL_MODE="${INSTALL_MODE:-auto}" # auto | native | jvm
RUN_LINK="${RUN_LINK:-true}"
ENABLE_UFW="${ENABLE_UFW:-true}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
ENABLE_SYSCTL_HARDENING="${ENABLE_SYSCTL_HARDENING:-true}"
ENABLE_UNATTENDED_UPGRADES="${ENABLE_UNATTENDED_UPGRADES:-true}"
SSH_HARDENING="${SSH_HARDENING:-ask}" # ask | true | false
RUN_APT_UPGRADE="${RUN_APT_UPGRADE:-false}"
VERSION="${VERSION:-}"
ARTIFACT_FILE="${ARTIFACT_FILE:-}"

VERIFY_MODE="${VERIFY_MODE:-auto}" # auto | sha256 | none
ALLOW_UNVERIFIED_DOWNLOAD="${ALLOW_UNVERIFIED_DOWNLOAD:-false}"
EXPECTED_SHA256="${EXPECTED_SHA256:-}"
CHECKSUM_URL="${CHECKSUM_URL:-}"
ALLOW_PUBLIC_BIND="${ALLOW_PUBLIC_BIND:-false}"
DRY_RUN="${DRY_RUN:-false}"
TEST_MODE="${TEST_MODE:-false}"
HEALTH_CHECK_MAX_ATTEMPTS="${HEALTH_CHECK_MAX_ATTEMPTS:-15}"
HEALTH_CHECK_INTERVAL_SECONDS="${HEALTH_CHECK_INTERVAL_SECONDS:-2}"
HEALTH_CHECK_CONNECT_TIMEOUT_SECONDS="${HEALTH_CHECK_CONNECT_TIMEOUT_SECONDS:-2}"
HEALTH_CHECK_REQUEST_TIMEOUT_SECONDS="${HEALTH_CHECK_REQUEST_TIMEOUT_SECONDS:-5}"

RESOLVED_VERSION=""
SIGNAL_CLI_ASSET=""
SIGNAL_CLI_URL=""
SIGNAL_CLI_TMPDIR=""
SIGNAL_CLI_ARTIFACT=""
SIGNAL_CLI_STAGING_DIR=""
SIGNAL_CLI_REPLACED_KIND=""
SIGNAL_CLI_REPLACED_PATH=""
SIGNAL_CLI_REPLACED_BACKUP=""
SIGNAL_CLI_PRESERVE_STAGING_DIR="false"
SIGNAL_CLI_PREVIOUS_TARGET=""
SIGNAL_CLI_ACTIVATED_TARGET=""
SIGNAL_CLI_RESTORE_ABSENT_LINK="false"
SIGNAL_CLI_SERVICE_WAS_ACTIVE="false"
SIGNAL_CLI_SERVICE_STATE_MUTATED="false"
SIGNAL_CLI_TEMP_LINK=""
SIGNAL_CLI_TRANSACTION_COMMITTED="false"
SSH_HARDENING_TRANSACTION_ACTIVE="false"
SSH_HARDENING_HAD_PREVIOUS="false"
SSH_HARDENING_BACKUP_DIR=""
SSH_HARDENING_BACKUP_FILE=""
SSH_HARDENING_RELOAD_ATTEMPTED="false"
SSH_HARDENING_RESTORE_IN_PROGRESS="false"
LIFECYCLE_LOCK_HELD="false"
LIFECYCLE_LOCK_BACKEND=""
LIFECYCLE_LOCK_FD=""
LIFECYCLE_LOCK_OWNER_PID=""
PROMPT_TTY_FD=""
BASE_PACKAGES=()
BOOTSTRAP_PACKAGES=(ca-certificates curl util-linux)
BIND_HOST=""
BIND_PORT=""
CURRENT_STAGE="startup"

log() { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
die() {
  printf '\n[ERROR] %s\n' "$*" >&2
  if declare -F restore_previous_signal_cli_state >/dev/null 2>&1; then
    trap - ERR
    restore_previous_signal_cli_state || true
  fi
  exit 1
}

usage() {
  cat <<EOF
Usage:
  sudo $0 [options]

Options:
  --account +31612345678       Signal account number in international E.164 format.
                               Leave empty for multi-account daemon mode.
  --device-name NAME           Linked device name shown in Signal. Default: <hostname>-signal-cli
  --bind HOST:PORT             JSON-RPC HTTP bind address. Default: 127.0.0.1:8080
  --allow-public-bind          Allow non-localhost JSON-RPC bind. Use only behind authenticated transport.
  --install-mode auto|native|jvm
                               Default: auto. Uses native on x86_64, JVM elsewhere.
  --native                     Same as --install-mode native.
  --jvm                        Same as --install-mode jvm.
  --version VERSION            Pin signal-cli version, for example 0.14.5. Default: latest.
  --signal-cli-version VERSION Same as --version.
  --artifact-file PATH         Use a local release artifact instead of downloading one.
  --verify auto|sha256|none    Release artifact verification mode. Default: auto.
  --sha256 SHA256              Expected SHA256 for the downloaded release artifact.
  --checksum-url URL           HTTPS URL to a SHA256 checksum file containing the release artifact.
  --allow-unverified-download  Permit an install when no checksum material is available.
  --dry-run                    Print the install plan without changing the system.
  --no-link                    Install and start daemon without QR linking now.
  --ssh-hardening              Disable SSH password login and apply SSH hardening.
  --no-ssh-hardening           Do not change SSH config.
  --no-ufw                     Do not install, enable, or configure UFW.
  --no-fail2ban                Do not install, enable, or configure fail2ban.
  --no-sysctl-hardening        Do not install sysctl hardening profile.
  --no-unattended-upgrades     Do not enable unattended security upgrades.
  --apt-upgrade                Run apt-get upgrade -y before install.
  --upgrade                    Deprecated alias for --apt-upgrade.
  -h, --help                   Show this help.

Examples:
  sudo $0 --account +31612345678 --device-name HomeOps-Signal --version 0.14.5 --sha256 SHA256
  sudo $0 --dry-run --account +31612345678 --version 0.14.5
  sudo $0 --verify none --allow-unverified-download --account +31612345678
EOF
}

is_true() {
  case "${1,,}" in
    1 | true | yes | y | on) return 0 ;;
    *) return 1 ;;
  esac
}

is_dry_run() {
  is_true "$DRY_RUN"
}

path_owner_uid() {
  stat -c %u "$1" 2>/dev/null || stat -f %u "$1"
}

path_mode_bits() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

expected_managed_owner_uid() {
  if is_true "$TEST_MODE"; then
    printf '%s\n' "$EUID"
  else
    printf '0\n'
  fi
}

path_is_not_group_or_world_writable() {
  local mode
  mode="$(path_mode_bits "$1")" || return 1
  [[ "$mode" =~ ^[0-7]+$ ]] || return 1
  (((8#$mode & 0022) == 0))
}

open_prompt_tty() {
  if [[ "$PROMPT_TTY_FD" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  PROMPT_TTY_FD=""
  if { exec {PROMPT_TTY_FD}<>/dev/tty; } 2>/dev/null; then
    return 0
  fi

  PROMPT_TTY_FD=""
  return 1
}

close_prompt_tty() {
  if [[ "$PROMPT_TTY_FD" =~ ^[0-9]+$ ]]; then
    { exec {PROMPT_TTY_FD}>&-; } 2>/dev/null || true
  fi
  PROMPT_TTY_FD=""
}

read_prompt_tty() {
  local prompt="$1"
  local result_name="$2"
  local response=""

  open_prompt_tty || return 1
  if ! {
    printf '%s' "$prompt" >&"$PROMPT_TTY_FD" &&
      IFS= read -r response <&"$PROMPT_TTY_FD"
  } 2>/dev/null; then
    close_prompt_tty
    return 1
  fi

  printf -v "$result_name" '%s' "$response"
}

set_stage() {
  CURRENT_STAGE="$1"
}

on_error() {
  local exit_code=$?
  if [[ $# -gt 0 ]]; then
    exit_code="$1"
  fi
  local line_no=${BASH_LINENO[0]:-unknown}
  warn "Installer failed during stage '$CURRENT_STAGE' with exit code $exit_code near line $line_no."
  if ! is_dry_run && command -v journalctl >/dev/null 2>&1; then
    warn "Recent signal-cli service logs, if available:"
    journalctl -u signal-cli -n 40 --no-pager 2>/dev/null || true
  fi
  exit "$exit_code"
}

ensure_lifecycle_lock_parent() {
  local lock_parent="$1"

  if [[ -L "$lock_parent" || (-e "$lock_parent" && ! -d "$lock_parent") ]]; then
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

  if is_dry_run || is_true "$LIFECYCLE_LOCK_HELD"; then
    return 0
  fi

  set_stage "lifecycle lock"
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

  if [[ -L "$LIFECYCLE_LOCK_FILE" || (-e "$LIFECYCLE_LOCK_FILE" && ! -f "$LIFECYCLE_LOCK_FILE") ]]; then
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
  (((8#$lock_mode & 0022) == 0)) || die "Lifecycle lock file must not be group- or world-writable."

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

signal_cli_staging_dir_is_valid() {
  [[ -n "$SIGNAL_CLI_STAGING_DIR" && -d "$SIGNAL_CLI_STAGING_DIR" && ! -L "$SIGNAL_CLI_STAGING_DIR" ]] || return 1
  case "$SIGNAL_CLI_STAGING_DIR" in
    "$OPT_DIR"/.signal-cli-install.*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  trap - ERR

  if is_true "$SSH_HARDENING_TRANSACTION_ACTIVE"; then
    restore_ssh_hardening_transaction || true
  elif [[ -n "$SSH_HARDENING_BACKUP_DIR" ]]; then
    remove_ssh_hardening_backup || true
  fi

  if [[ -n "$SIGNAL_CLI_TEMP_LINK" ]]; then
    if [[ -L "$SIGNAL_CLI_TEMP_LINK" ]]; then
      rm -f -- "$SIGNAL_CLI_TEMP_LINK" || warn "Could not remove signal-cli lifecycle temporary link: $SIGNAL_CLI_TEMP_LINK"
    elif [[ -e "$SIGNAL_CLI_TEMP_LINK" ]]; then
      warn "Refusing to remove unexpected non-symlink lifecycle temporary path: $SIGNAL_CLI_TEMP_LINK"
    fi
    SIGNAL_CLI_TEMP_LINK=""
  fi
  if [[ -n "$SIGNAL_CLI_STAGING_DIR" ]]; then
    if ! signal_cli_staging_dir_is_valid; then
      warn "Refusing to clean an invalid signal-cli staging directory: $SIGNAL_CLI_STAGING_DIR"
    elif ! is_true "$SIGNAL_CLI_PRESERVE_STAGING_DIR"; then
      if rm -rf -- "$SIGNAL_CLI_STAGING_DIR"; then
        SIGNAL_CLI_STAGING_DIR=""
      else
        warn "Could not remove signal-cli staging directory: $SIGNAL_CLI_STAGING_DIR"
      fi
    fi
  fi
  if [[ -n "$SIGNAL_CLI_TMPDIR" && -d "$SIGNAL_CLI_TMPDIR" ]]; then
    rm -rf -- "$SIGNAL_CLI_TMPDIR" || warn "Could not remove signal-cli download temporary directory: $SIGNAL_CLI_TMPDIR"
  fi
  release_lifecycle_lock || true
  close_prompt_tty || true
  return 0
}

clear_signal_cli_replacement_state() {
  SIGNAL_CLI_REPLACED_KIND=""
  SIGNAL_CLI_REPLACED_PATH=""
  SIGNAL_CLI_REPLACED_BACKUP=""
}

commit_signal_cli_transaction() {
  # This is the transaction's atomic commit point. Recovery checks this flag
  # before consulting any of the fields cleared below.
  SIGNAL_CLI_TRANSACTION_COMMITTED="true"
  clear_signal_cli_replacement_state
  SIGNAL_CLI_PREVIOUS_TARGET=""
  SIGNAL_CLI_ACTIVATED_TARGET=""
  SIGNAL_CLI_RESTORE_ABSENT_LINK="false"
  SIGNAL_CLI_SERVICE_WAS_ACTIVE="false"
  SIGNAL_CLI_SERVICE_STATE_MUTATED="false"
  SIGNAL_CLI_PRESERVE_STAGING_DIR="false"
}

preserve_signal_cli_recovery_files() {
  local recovery_dir="$SIGNAL_CLI_STAGING_DIR"
  if signal_cli_staging_dir_is_valid; then
    SIGNAL_CLI_PRESERVE_STAGING_DIR="true"
    warn "Automatic restore failed. Recovery files remain at $recovery_dir."
  else
    warn "Automatic restore failed and no valid staging directory is available for recovery."
  fi
  clear_signal_cli_replacement_state
}

restore_replaced_signal_cli_install() {
  local failed_install restore_target

  [[ -n "$SIGNAL_CLI_REPLACED_KIND" ]] || return 0

  if ! signal_cli_staging_dir_is_valid; then
    warn "Cannot restore a replaced signal-cli install without a valid staging directory."
    preserve_signal_cli_recovery_files
    return 1
  fi
  case "$SIGNAL_CLI_REPLACED_BACKUP" in
    "$SIGNAL_CLI_STAGING_DIR"/*) ;;
    *)
      warn "Refusing replacement recovery from outside the validated staging directory: $SIGNAL_CLI_REPLACED_BACKUP"
      preserve_signal_cli_recovery_files
      return 1
      ;;
  esac

  case "$SIGNAL_CLI_REPLACED_KIND" in
    file)
      if [[ ! -f "$SIGNAL_CLI_REPLACED_BACKUP" || ! -x "$SIGNAL_CLI_REPLACED_BACKUP" ]]; then
        warn "Previous native binary backup is unavailable: $SIGNAL_CLI_REPLACED_BACKUP"
        preserve_signal_cli_recovery_files
        return 1
      fi

      restore_target="$SIGNAL_CLI_STAGING_DIR/restored-native-signal-cli"
      if ! run_cmd install -m 0755 "$SIGNAL_CLI_REPLACED_BACKUP" "$restore_target" ||
        ! run_cmd mv -f "$restore_target" "$SIGNAL_CLI_REPLACED_PATH"; then
        preserve_signal_cli_recovery_files
        return 1
      fi
      ;;
    directory)
      if [[ ! -d "$SIGNAL_CLI_REPLACED_BACKUP" || -L "$SIGNAL_CLI_REPLACED_BACKUP" ]]; then
        warn "Previous signal-cli install backup is unavailable: $SIGNAL_CLI_REPLACED_BACKUP"
        preserve_signal_cli_recovery_files
        return 1
      fi

      failed_install="$SIGNAL_CLI_STAGING_DIR/failed-install"
      run_cmd rm -rf "$failed_install" || true
      if [[ -e "$SIGNAL_CLI_REPLACED_PATH" || -L "$SIGNAL_CLI_REPLACED_PATH" ]]; then
        if ! run_cmd mv "$SIGNAL_CLI_REPLACED_PATH" "$failed_install"; then
          preserve_signal_cli_recovery_files
          return 1
        fi
      fi

      if ! run_cmd mv "$SIGNAL_CLI_REPLACED_BACKUP" "$SIGNAL_CLI_REPLACED_PATH"; then
        if [[ -e "$failed_install" || -L "$failed_install" ]]; then
          run_cmd mv "$failed_install" "$SIGNAL_CLI_REPLACED_PATH" || true
        fi
        preserve_signal_cli_recovery_files
        return 1
      fi
      run_cmd rm -rf "$failed_install" || true
      ;;
    *)
      warn "Unknown signal-cli replacement backup kind: $SIGNAL_CLI_REPLACED_KIND"
      preserve_signal_cli_recovery_files
      return 1
      ;;
  esac

  clear_signal_cli_replacement_state
}

restore_previous_signal_cli_state() {
  is_true "$SIGNAL_CLI_TRANSACTION_COMMITTED" && return 0

  local current_link_target current_target restore_failed=false

  if is_true "$SSH_HARDENING_TRANSACTION_ACTIVE"; then
    warn "Failure occurred after replacing the SSH hardening policy; restoring its previous state."
    if ! restore_ssh_hardening_transaction; then
      restore_failed=true
    fi
  fi

  if [[ -n "$SIGNAL_CLI_REPLACED_KIND" ]]; then
    warn "Failure occurred after replacing an existing install; restoring its previous contents."
    if ! restore_replaced_signal_cli_install; then
      restore_failed=true
    fi
  fi

  if [[ -n "$SIGNAL_CLI_PREVIOUS_TARGET" ]]; then
    current_target="$(readlink -f "$LOCAL_BIN_DIR/signal-cli" 2>/dev/null || true)"
    if [[ "$current_target" != "$SIGNAL_CLI_PREVIOUS_TARGET" ]]; then
      if [[ ! -x "$SIGNAL_CLI_PREVIOUS_TARGET" ]]; then
        warn "Could not restore previous binary because it is no longer executable: $SIGNAL_CLI_PREVIOUS_TARGET"
        restore_failed=true
      else
        warn "Restoring previous active binary: $SIGNAL_CLI_PREVIOUS_TARGET"
        if ! switch_signal_cli_symlink "$SIGNAL_CLI_PREVIOUS_TARGET"; then
          restore_failed=true
        fi
      fi
    fi
  elif is_true "$SIGNAL_CLI_RESTORE_ABSENT_LINK"; then
    if [[ -L "$LOCAL_BIN_DIR/signal-cli" ]]; then
      current_link_target="$(readlink "$LOCAL_BIN_DIR/signal-cli" 2>/dev/null || true)"
      if [[ -n "$SIGNAL_CLI_ACTIVATED_TARGET" && "$current_link_target" == "$SIGNAL_CLI_ACTIVATED_TARGET" ]]; then
        warn "Removing newly activated binary link because no active binary existed before this operation."
        if run_cmd rm -f "$LOCAL_BIN_DIR/signal-cli"; then
          SIGNAL_CLI_ACTIVATED_TARGET=""
          SIGNAL_CLI_RESTORE_ABSENT_LINK="false"
        else
          restore_failed=true
        fi
      else
        warn "Refusing to remove an unexpected signal-cli symlink while restoring prior absence."
        restore_failed=true
      fi
    elif [[ -e "$LOCAL_BIN_DIR/signal-cli" ]]; then
      warn "Refusing to remove an unexpected non-symlink signal-cli executable while restoring prior absence."
      restore_failed=true
    else
      SIGNAL_CLI_RESTORE_ABSENT_LINK="false"
    fi
  fi

  if is_true "$SIGNAL_CLI_SERVICE_STATE_MUTATED"; then
    if is_true "$SIGNAL_CLI_SERVICE_WAS_ACTIVE" && [[ -n "$SIGNAL_CLI_PREVIOUS_TARGET" ]] && ! is_true "$restore_failed"; then
      if maybe_systemctl restart signal-cli; then
        SIGNAL_CLI_SERVICE_STATE_MUTATED="false"
      else
        warn "Previous binary was restored, but restarting the previously active signal-cli service failed."
        restore_failed=true
      fi
    else
      if maybe_systemctl stop signal-cli; then
        SIGNAL_CLI_SERVICE_STATE_MUTATED="false"
      else
        warn "Could not restore the prior inactive signal-cli service state."
        restore_failed=true
      fi
    fi
  fi

  ! is_true "$restore_failed"
}

on_lifecycle_error() {
  local exit_code=$?

  trap - ERR
  restore_previous_signal_cli_state || true
  on_error "$exit_code"
}

on_lifecycle_signal() {
  local signal="${1:-TERM}" exit_code

  case "$signal" in
    HUP) exit_code=129 ;;
    INT) exit_code=130 ;;
    TERM) exit_code=143 ;;
    *) exit_code=1 ;;
  esac

  trap - ERR HUP INT TERM
  warn "Received $signal during stage '$CURRENT_STAGE'; restoring the previous signal-cli state."
  restore_previous_signal_cli_state || true
  exit "$exit_code"
}

run_cmd() {
  if is_dry_run; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

maybe_systemctl() {
  if is_true "$TEST_MODE"; then
    if [[ "${1:-}" == is-active ]]; then
      printf 'inactive\n'
      return 3
    fi
    printf '[test-mode] skip systemctl'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  systemctl "$@"
}

capture_signal_cli_service_state() {
  local service_state=""

  SIGNAL_CLI_SERVICE_WAS_ACTIVE="false"
  service_state="$(maybe_systemctl is-active signal-cli.service 2>&1)" || true

  case "$service_state" in
    active | activating | reloading | deactivating)
      SIGNAL_CLI_SERVICE_WAS_ACTIVE="true"
      ;;
    inactive | failed | not-found) ;;
    *)
      warn "Could not determine the signal-cli service state safely: ${service_state:-no state returned}"
      return 1
      ;;
  esac
}

write_rendered_file() {
  local target="$1"
  local mode="$2"
  local owner="$3"
  local group="$4"
  local renderer="$5"
  local render_exit temp_file
  shift 5

  run_cmd install -d -m 0755 "$(dirname "$target")" || return $?

  if is_dry_run; then
    printf '[dry-run] write %s (mode %s owner %s:%s)\n' "$target" "$mode" "$owner" "$group"
    return 0
  fi

  [[ ! -L "$target" ]] || die "Refusing to replace symlinked privileged file: $target"
  [[ ! -e "$target" || -f "$target" ]] || die "Refusing to replace non-regular privileged file: $target"

  temp_file="$(mktemp "$(dirname "$target")/.$(basename "$target").XXXXXX")" || return $?
  chmod 0600 "$temp_file" || {
    render_exit=$?
    rm -f -- "$temp_file" || warn "Could not remove failed rendered-file temporary path: $temp_file"
    return "$render_exit"
  }

  "$renderer" "$@" >"$temp_file" || {
    render_exit=$?
    rm -f -- "$temp_file" || warn "Could not remove failed rendered-file temporary path: $temp_file"
    return "$render_exit"
  }
  chmod "$mode" "$temp_file" || {
    render_exit=$?
    rm -f -- "$temp_file" || warn "Could not remove failed rendered-file temporary path: $temp_file"
    return "$render_exit"
  }

  if is_true "$TEST_MODE"; then
    printf '[test-mode] skip chown %s:%s %s\n' "$owner" "$group" "$temp_file"
  else
    chown "$owner:$group" "$temp_file" || {
      render_exit=$?
      rm -f -- "$temp_file" || warn "Could not remove failed rendered-file temporary path: $temp_file"
      return "$render_exit"
    }
  fi

  if [[ -L "$target" || (-e "$target" && ! -f "$target") ]]; then
    rm -f -- "$temp_file" || warn "Could not remove unsafe rendered-file temporary path: $temp_file"
    die "Refusing to replace unsafe privileged file target: $target"
  fi

  mv -f "$temp_file" "$target" || {
    render_exit=$?
    rm -f -- "$temp_file" || warn "Could not remove failed rendered-file temporary path: $temp_file"
    return "$render_exit"
  }
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local label answer

  if [[ "$default" == "y" ]]; then
    label="Y/n"
  else
    label="y/N"
  fi

  if ! open_prompt_tty; then
    [[ "$default" == "y" ]]
    return $?
  fi

  while true; do
    answer=""
    read_prompt_tty "$prompt [$label]: " answer || true
    answer="${answer:-$default}"
    case "${answer,,}" in
      y | yes) return 0 ;;
      n | no) return 1 ;;
    esac
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --account)
        [[ $# -ge 2 ]] || die "--account requires a value"
        SIGNAL_ACCOUNT="$2"
        shift 2
        ;;
      --device-name)
        [[ $# -ge 2 ]] || die "--device-name requires a value"
        DEVICE_NAME="$2"
        shift 2
        ;;
      --bind)
        [[ $# -ge 2 ]] || die "--bind requires a value"
        HTTP_BIND="$2"
        shift 2
        ;;
      --allow-public-bind)
        ALLOW_PUBLIC_BIND="true"
        shift
        ;;
      --install-mode)
        [[ $# -ge 2 ]] || die "--install-mode requires auto, native, or jvm"
        INSTALL_MODE="$2"
        shift 2
        ;;
      --native)
        INSTALL_MODE="native"
        shift
        ;;
      --jvm)
        INSTALL_MODE="jvm"
        shift
        ;;
      --version | --signal-cli-version)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        VERSION="$2"
        shift 2
        ;;
      --artifact-file)
        [[ $# -ge 2 ]] || die "--artifact-file requires a value"
        ARTIFACT_FILE="$2"
        shift 2
        ;;
      --verify)
        [[ $# -ge 2 ]] || die "--verify requires auto, sha256, or none"
        VERIFY_MODE="$2"
        shift 2
        ;;
      --sha256)
        [[ $# -ge 2 ]] || die "--sha256 requires a value"
        EXPECTED_SHA256="$2"
        shift 2
        ;;
      --checksum-url)
        [[ $# -ge 2 ]] || die "--checksum-url requires a value"
        CHECKSUM_URL="$2"
        shift 2
        ;;
      --allow-unverified-download)
        ALLOW_UNVERIFIED_DOWNLOAD="true"
        shift
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --no-link)
        RUN_LINK="false"
        shift
        ;;
      --ssh-hardening)
        SSH_HARDENING="true"
        shift
        ;;
      --no-ssh-hardening)
        SSH_HARDENING="false"
        shift
        ;;
      --no-ufw)
        ENABLE_UFW="false"
        shift
        ;;
      --no-fail2ban)
        ENABLE_FAIL2BAN="false"
        shift
        ;;
      --no-sysctl-hardening)
        ENABLE_SYSCTL_HARDENING="false"
        shift
        ;;
      --no-unattended-upgrades)
        ENABLE_UNATTENDED_UPGRADES="false"
        shift
        ;;
      --apt-upgrade)
        RUN_APT_UPGRADE="true"
        shift
        ;;
      --upgrade)
        warn "--upgrade is deprecated. Use --apt-upgrade instead."
        RUN_APT_UPGRADE="true"
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
  if is_dry_run || is_true "$TEST_MODE"; then
    return 0
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
  fi
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  ((port >= 1 && port <= 65535))
}

split_bind() {
  local bind="$1"
  BIND_HOST=""
  BIND_PORT=""

  if [[ "$bind" =~ ^(\[[0-9A-Fa-f:.]+\]):([0-9]+)$ ]]; then
    BIND_HOST="${BASH_REMATCH[1]}"
    BIND_PORT="${BASH_REMATCH[2]}"
    return 0
  fi

  if [[ "$bind" =~ ^([^:]+):([0-9]+)$ ]]; then
    BIND_HOST="${BASH_REMATCH[1]}"
    BIND_PORT="${BASH_REMATCH[2]}"
    return 0
  fi

  return 1
}

validate_ipv4_host() {
  local host="$1"
  local IFS=.
  local -a parts
  local part

  [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  read -r -a parts <<<"$host"
  [[ "${#parts[@]}" -eq 4 ]] || return 1

  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]+$ ]] || return 1
    ((part >= 0 && part <= 255)) || return 1
  done
}

validate_hostname() {
  local host="$1"
  local label

  [[ ${#host} -le 253 ]] || return 1
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  [[ "$host" != *..* ]] || return 1

  local IFS=.
  local -a labels
  read -r -a labels <<<"$host"
  [[ "${#labels[@]}" -gt 0 ]] || return 1

  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
  done
}

validate_bracketed_ipv6() {
  local host="$1"
  local addr part hextet_count=0 has_double_colon=false

  [[ "$host" =~ ^\[[0-9A-Fa-f:.]+\]$ ]] || return 1
  addr="${host:1:${#host}-2}"
  [[ -n "$addr" ]] || return 1
  [[ "$addr" != *:::* ]] || return 1
  [[ "$addr" != :* || "$addr" == ::* ]] || return 1
  [[ "$addr" != *: || "$addr" == *:: ]] || return 1

  if [[ "$addr" == *::* ]]; then
    has_double_colon=true
    [[ "$addr" != *::*::* ]] || return 1
  fi

  local IFS=:
  local -a parts
  read -r -a parts <<<"$addr"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    hextet_count=$((hextet_count + 1))
  done

  if is_true "$has_double_colon"; then
    ((hextet_count < 8))
  else
    ((hextet_count == 8))
  fi
}

contains_shell_unsafe_chars() {
  local value="$1"

  [[ "$value" == *$'\n'* ]] && return 0
  [[ "$value" == *$'\r'* ]] && return 0
  [[ "$value" == *$'\t'* ]] && return 0
  [[ "$value" == *" "* ]] && return 0

  case "$value" in
    *"'"* | *"\""* | *"\`"* | *'$'* | *"\\"* | *";"* | *"&"* | *"|"* | *"<"* | *">"* | *"("* | *")"* | *"{"* | *"}"*) return 0 ;;
  esac

  return 1
}

is_local_bind() {
  local bind="$1"
  [[ "$bind" =~ ^127\.0\.0\.1:([0-9]+)$ ]] && validate_port "${BASH_REMATCH[1]}" && return 0
  [[ "$bind" =~ ^localhost:([0-9]+)$ ]] && validate_port "${BASH_REMATCH[1]}" && return 0
  [[ "$bind" =~ ^\[::1\]:([0-9]+)$ ]] && validate_port "${BASH_REMATCH[1]}" && return 0
  return 1
}

bind_port() {
  local bind="$1"
  if [[ "$bind" =~ ^\[[^]]+\]:([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$bind" =~ ^[^:]+:([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

validate_bind_syntax() {
  local bind="$1"

  if ! split_bind "$bind"; then
    die "Invalid --bind. Expected HOST:PORT, for example 127.0.0.1:8080."
  fi

  if ! validate_port "$BIND_PORT"; then
    die "Invalid --bind port. Expected 1-65535."
  fi

  if contains_shell_unsafe_chars "$bind"; then
    die "Invalid --bind. Refusing shell-unsafe characters."
  fi

  if is_local_bind "$bind"; then
    return 0
  fi

  if [[ "$BIND_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ! validate_ipv4_host "$BIND_HOST"; then
    die "Invalid --bind IPv4 host."
  fi

  if ! validate_ipv4_host "$BIND_HOST" && ! validate_hostname "$BIND_HOST" && ! validate_bracketed_ipv6 "$BIND_HOST"; then
    die "Invalid --bind host. Use IPv4, bracketed IPv6, localhost, or a simple hostname."
  fi
}

validate_bind() {
  validate_bind_syntax "$HTTP_BIND"

  if is_local_bind "$HTTP_BIND"; then
    return 0
  fi

  if ! is_true "$ALLOW_PUBLIC_BIND"; then
    die "Refusing non-localhost bind '$HTTP_BIND'. Use --allow-public-bind only behind VPN, reverse proxy, or authenticated transport."
  fi

  warn "Public/non-localhost bind enabled: $HTTP_BIND. Do not expose signal-cli JSON-RPC directly to the internet."
}

load_installed_http_bind() {
  local candidate="" line assignment_count=0

  [[ -e "$CONFIG_FILE" || -L "$CONFIG_FILE" ]] || return 0
  [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || die "Installed runtime config is not a regular file: $CONFIG_FILE"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == SIGNAL_CLI_HTTP_BIND=* ]]; then
      assignment_count=$((assignment_count + 1))
      if [[ "$line" =~ ^SIGNAL_CLI_HTTP_BIND=\"([^\"]+)\"$ ]]; then
        candidate="${BASH_REMATCH[1]}"
      else
        die "Malformed SIGNAL_CLI_HTTP_BIND assignment in $CONFIG_FILE."
      fi
    fi
  done <"$CONFIG_FILE"

  ((assignment_count == 1)) || die "Expected exactly one SIGNAL_CLI_HTTP_BIND assignment in $CONFIG_FILE."
  validate_bind_syntax "$candidate"
  HTTP_BIND="$candidate"
}

load_installed_http_bind_for_dry_run_plan() {
  local candidate loader_exit

  if [[ ! -f "$CONFIG_FILE" || -L "$CONFIG_FILE" || ! -r "$CONFIG_FILE" ]]; then
    if [[ -e "$CONFIG_FILE" || -L "$CONFIG_FILE" ]]; then
      warn "Installed HTTP bind is unavailable for this dry-run preview; using $HTTP_BIND."
    fi
    return 0
  fi

  if candidate="$({
    if load_installed_http_bind >/dev/null; then
      printf '%s\n' "$HTTP_BIND"
    else
      loader_exit=$?
      exit "$loader_exit"
    fi
  } 2>/dev/null)"; then
    HTTP_BIND="$candidate"
  else
    warn "Installed HTTP bind could not be parsed for this dry-run preview; using $HTTP_BIND."
  fi
}

validate_device_name() {
  [[ -n "$DEVICE_NAME" ]] || die "Device name cannot be empty."
  ((${#DEVICE_NAME} <= 64)) || die "Device name is too long; max 64 characters."
  [[ "$DEVICE_NAME" != *$'\n'* ]] || die "Device name cannot contain newlines."
  [[ "$DEVICE_NAME" != *$'\r'* ]] || die "Device name cannot contain carriage returns."
  [[ ! "$DEVICE_NAME" =~ [[:cntrl:]] ]] || die "Device name cannot contain control characters."
}

validate_common_release_inputs() {
  if [[ ! "$INSTALL_MODE" =~ ^(auto|native|jvm)$ ]]; then
    die "Invalid install mode: $INSTALL_MODE"
  fi

  if [[ -n "$VERSION" ]]; then
    [[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && "$VERSION" != *..* ]] || die "Invalid --version. Refusing path separators or traversal."
  fi

  if [[ ! "$VERIFY_MODE" =~ ^(auto|sha256|none)$ ]]; then
    die "Invalid --verify mode: $VERIFY_MODE"
  fi

  if [[ -n "$EXPECTED_SHA256" && ! "$EXPECTED_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]]; then
    die "Invalid --sha256. Expected a 64-character hexadecimal SHA256 digest."
  fi

  if [[ -n "$CHECKSUM_URL" ]]; then
    if [[ "$CHECKSUM_URL" != https://* ]]; then
      if ! { is_true "$TEST_MODE" && [[ "$CHECKSUM_URL" == file://* ]]; }; then
        die "--checksum-url must be HTTPS."
      fi
    fi
  fi

  if [[ -n "$ARTIFACT_FILE" ]]; then
    [[ "$ARTIFACT_FILE" != http://* && "$ARTIFACT_FILE" != https://* ]] || die "--artifact-file must be a local file path."
    [[ -f "$ARTIFACT_FILE" ]] || die "--artifact-file does not exist: $ARTIFACT_FILE"
  fi
}

validate_inputs() {
  if [[ -z "$DEVICE_NAME" ]]; then
    DEVICE_NAME="$(hostname -s 2>/dev/null || hostname)-signal-cli"
  fi

  if ! is_dry_run && ! is_true "$TEST_MODE"; then
    if [[ -z "$SIGNAL_ACCOUNT" ]]; then
      read_prompt_tty "Signal account number, e.g. +31612345678. Leave blank for multi-account mode: " SIGNAL_ACCOUNT || true
    fi

    local input_device=""
    read_prompt_tty "Linked device name [$DEVICE_NAME]: " input_device || true
    DEVICE_NAME="${input_device:-$DEVICE_NAME}"
  fi

  validate_device_name

  if [[ -n "$SIGNAL_ACCOUNT" && ! "$SIGNAL_ACCOUNT" =~ ^\+[1-9][0-9]{6,14}$ ]]; then
    die "Invalid --account. Use international E.164 format, for example +31612345678."
  fi

  validate_common_release_inputs

  if [[ "$SSH_HARDENING" == "ask" ]]; then
    if is_dry_run; then
      SSH_HARDENING="false"
    elif ask_yes_no "Disable SSH password login and harden SSH config" "n"; then
      SSH_HARDENING="true"
    else
      SSH_HARDENING="false"
    fi
  fi

  validate_bind
}

detect_arch() {
  if [[ -n "${TEST_UNAME_M:-}" ]]; then
    printf '%s\n' "$TEST_UNAME_M"
  else
    uname -m
  fi
}

choose_install_mode() {
  local arch
  arch="$(detect_arch)"

  if [[ "$INSTALL_MODE" == "auto" ]]; then
    case "$arch" in
      x86_64 | amd64) INSTALL_MODE="native" ;;
      *) INSTALL_MODE="jvm" ;;
    esac
  fi

  if [[ "$INSTALL_MODE" == "native" && ! "$arch" =~ ^(x86_64|amd64)$ ]]; then
    die "Native Linux release is expected for x86_64/amd64. Use --install-mode jvm on $arch."
  fi

  log "Install mode: $INSTALL_MODE"
}

preflight_checks() {
  set_stage "preflight"
  log "Running preflight checks."

  if is_dry_run; then
    printf '[dry-run] skip host mutation preflight checks\n'
    return 0
  fi

  if is_true "$TEST_MODE"; then
    printf '[test-mode] skip host mutation preflight checks\n'
    return 0
  fi

  command -v apt-get >/dev/null 2>&1 || die "apt-get not found. This installer supports Debian/Ubuntu only."
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found. This installer requires systemd."
  [[ -d /run/systemd/system ]] || die "systemd does not appear to be PID 1. This installer targets systemd servers."

  if command -v curl >/dev/null 2>&1; then
    curl -fsSI --connect-timeout 10 https://github.com >/dev/null || die "Could not reach github.com with curl."
  fi

  check_disk_space /opt 100
  check_disk_space /var 100
}

check_disk_space() {
  local path="$1"
  local minimum_mb="$2"
  local available_mb

  [[ -d "$path" ]] || die "Required path does not exist: $path"
  available_mb="$(df -Pm "$path" | awk 'NR == 2 {print $4}')"
  [[ "$available_mb" =~ ^[0-9]+$ ]] || die "Could not determine free disk space for $path."
  ((available_mb >= minimum_mb)) || die "Insufficient free disk space on $path. Need at least ${minimum_mb}MB."
}

build_base_packages() {
  BASE_PACKAGES=(ca-certificates curl tar jq qrencode libstdc++6 coreutils)

  if is_true "$ENABLE_UFW"; then
    BASE_PACKAGES+=(ufw)
  fi

  if is_true "$ENABLE_FAIL2BAN"; then
    BASE_PACKAGES+=(fail2ban)
  fi

  if is_true "$ENABLE_UNATTENDED_UPGRADES"; then
    BASE_PACKAGES+=(unattended-upgrades)
  fi
}

install_bootstrap_packages() {
  set_stage "bootstrap packages"

  if is_dry_run; then
    printf '[dry-run] ensure bootstrap packages: %s\n' "${BOOTSTRAP_PACKAGES[*]}"
    return 0
  fi

  if is_true "$TEST_MODE"; then
    printf '[test-mode] skip bootstrap package installation: %s\n' "${BOOTSTRAP_PACKAGES[*]}"
    return 0
  fi

  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v flock >/dev/null 2>&1 || missing+=(util-linux)

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  log "Installing bootstrap packages: ca-certificates ${missing[*]}."
  apt-get update
  apt-get install -y ca-certificates "${missing[@]}"
}

apt_pkg_available() {
  apt-cache show "$1" >/dev/null 2>&1
}

java_major_version() {
  if ! command -v java >/dev/null 2>&1; then
    return 1
  fi
  java -version 2>&1 | awk -F '[".]' '/version/ {print $2; exit}'
}

install_java25_if_needed() {
  local major

  if is_dry_run; then
    printf '[dry-run] ensure Java 25 is installed for JVM mode\n'
    return 0
  fi

  major="$(java_major_version || true)"
  if [[ -n "$major" && "$major" =~ ^[0-9]+$ && "$major" -ge 25 ]]; then
    log "Detected Java $major."
    return 0
  fi

  log "JVM mode needs JRE 25. Trying apt packages."
  if apt_pkg_available openjdk-25-jre-headless; then
    run_cmd apt-get install -y openjdk-25-jre-headless
  elif apt_pkg_available openjdk-25-jre; then
    run_cmd apt-get install -y openjdk-25-jre
  else
    die "No openjdk-25-jre package found in apt. Use --install-mode native on x86_64, or install JRE 25 manually, then rerun."
  fi
}

install_base_packages() {
  set_stage "package installation"

  if is_true "$TEST_MODE"; then
    printf '[test-mode] skip base package installation: %s\n' "${BASE_PACKAGES[*]}"
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive

  log "Updating apt metadata."
  run_cmd apt-get update

  if is_true "$RUN_APT_UPGRADE"; then
    log "Running apt-get upgrade -y."
    run_cmd apt-get upgrade -y
  fi

  log "Installing base packages."
  run_cmd apt-get install -y "${BASE_PACKAGES[@]}"

  if [[ "$INSTALL_MODE" == "jvm" ]]; then
    install_java25_if_needed
  fi
}

latest_signal_cli_version() {
  curl -fsSL -o /dev/null -w '%{url_effective}' \
    https://github.com/AsamK/signal-cli/releases/latest | sed -e 's#^.*/v##'
}

resolve_signal_cli_version() {
  set_stage "version resolution"

  if [[ -n "$VERSION" ]]; then
    RESOLVED_VERSION="$VERSION"
  elif is_dry_run; then
    RESOLVED_VERSION="latest"
  else
    RESOLVED_VERSION="$(latest_signal_cli_version)"
  fi

  [[ -n "$RESOLVED_VERSION" ]] || die "Could not determine signal-cli version."
}

build_signal_cli_asset_url() {
  if [[ "$RESOLVED_VERSION" == "latest" ]]; then
    SIGNAL_CLI_ASSET="latest ${INSTALL_MODE} release artifact"
    SIGNAL_CLI_URL="https://github.com/AsamK/signal-cli/releases/latest"
    return 0
  fi

  if [[ "$INSTALL_MODE" == "native" ]]; then
    SIGNAL_CLI_ASSET="signal-cli-${RESOLVED_VERSION}-Linux-native.tar.gz"
  else
    SIGNAL_CLI_ASSET="signal-cli-${RESOLVED_VERSION}.tar.gz"
  fi

  SIGNAL_CLI_URL="https://github.com/AsamK/signal-cli/releases/download/v${RESOLVED_VERSION}/${SIGNAL_CLI_ASSET}"
}

download_signal_cli_artifact() {
  set_stage "artifact download"
  SIGNAL_CLI_TMPDIR="$(mktemp -d)"
  SIGNAL_CLI_ARTIFACT="$SIGNAL_CLI_TMPDIR/$SIGNAL_CLI_ASSET"

  if [[ -n "$ARTIFACT_FILE" ]]; then
    log "Using local signal-cli artifact: $ARTIFACT_FILE."
    run_cmd cp "$ARTIFACT_FILE" "$SIGNAL_CLI_ARTIFACT"
    return 0
  fi

  log "Downloading signal-cli $RESOLVED_VERSION ($INSTALL_MODE)."
  run_cmd curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "$SIGNAL_CLI_ARTIFACT" "$SIGNAL_CLI_URL"
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    die "No SHA256 tool found. Install sha256sum or shasum."
  fi
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual

  [[ -n "$expected" ]] || die "Expected SHA256 is empty."
  actual="$(sha256_file "$file")"
  if [[ "${actual,,}" != "${expected,,}" ]]; then
    die "SHA256 verification failed for $(basename "$file"). Expected $expected, got $actual."
  fi

  log "SHA256 verification passed for $(basename "$file")."
}

download_checksum_file() {
  local checksum_file="$1"

  if [[ "$CHECKSUM_URL" == file://* ]] && is_true "$TEST_MODE"; then
    cp "${CHECKSUM_URL#file://}" "$checksum_file"
  else
    curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "$checksum_file" "$CHECKSUM_URL"
  fi
}

expected_sha256_from_checksum_file() {
  local checksum_file="$1"
  local asset="$2"

  awk -v asset="$asset" '
    {
      name = $2
      sub(/^\*/, "", name)
      n = split(name, parts, "/")
      base = parts[n]
      if (base == asset) {
        print $1
        exit
      }
    }
  ' "$checksum_file"
}

validate_checksum_file_digest() {
  local digest="$1"

  [[ "$digest" =~ ^[A-Fa-f0-9]{64}$ ]] || die "Checksum entry for $SIGNAL_CLI_ASSET in $CHECKSUM_URL is not a valid SHA256 digest."
}

verify_signal_cli_artifact() {
  set_stage "artifact verification"
  local checksum_file expected

  if is_dry_run; then
    printf '[dry-run] verify %s with mode %s\n' "$SIGNAL_CLI_ASSET" "$VERIFY_MODE"
    return 0
  fi

  case "$VERIFY_MODE" in
    sha256)
      if [[ -n "$EXPECTED_SHA256" ]]; then
        verify_sha256 "$SIGNAL_CLI_ARTIFACT" "$EXPECTED_SHA256"
        return 0
      fi
      if [[ -n "$CHECKSUM_URL" ]]; then
        checksum_file="$SIGNAL_CLI_TMPDIR/checksums.txt"
        download_checksum_file "$checksum_file"
        expected="$(expected_sha256_from_checksum_file "$checksum_file" "$SIGNAL_CLI_ASSET")"
        [[ -n "$expected" ]] || die "No checksum entry for $SIGNAL_CLI_ASSET in $CHECKSUM_URL."
        validate_checksum_file_digest "$expected"
        verify_sha256 "$SIGNAL_CLI_ARTIFACT" "$expected"
        return 0
      fi
      die "--verify sha256 requires --sha256 or --checksum-url."
      ;;
    auto)
      if [[ -n "$EXPECTED_SHA256" ]]; then
        verify_sha256 "$SIGNAL_CLI_ARTIFACT" "$EXPECTED_SHA256"
      elif [[ -n "$CHECKSUM_URL" ]]; then
        checksum_file="$SIGNAL_CLI_TMPDIR/checksums.txt"
        download_checksum_file "$checksum_file"
        expected="$(expected_sha256_from_checksum_file "$checksum_file" "$SIGNAL_CLI_ASSET")"
        [[ -n "$expected" ]] || die "No checksum entry for $SIGNAL_CLI_ASSET in $CHECKSUM_URL."
        validate_checksum_file_digest "$expected"
        verify_sha256 "$SIGNAL_CLI_ARTIFACT" "$expected"
      elif is_true "$ALLOW_UNVERIFIED_DOWNLOAD"; then
        warn "No checksum material provided. Continuing because --allow-unverified-download was set."
      else
        die "No release artifact verification material provided. Pass --sha256, --checksum-url, or explicitly use --verify none --allow-unverified-download."
      fi
      ;;
    none)
      is_true "$ALLOW_UNVERIFIED_DOWNLOAD" || die "--verify none requires --allow-unverified-download."
      warn "Release artifact verification disabled by explicit user request."
      ;;
  esac
}

switch_signal_cli_symlink() {
  local target="$1"
  local link_path="$LOCAL_BIN_DIR/signal-cli"
  local temp_link="$LOCAL_BIN_DIR/signal-cli.new"

  run_cmd install -d -m 0755 "$LOCAL_BIN_DIR" || return $?
  if [[ -e "$temp_link" && ! -L "$temp_link" ]]; then
    warn "Refusing to use an existing non-symlink signal-cli temporary path: $temp_link"
    return 1
  fi
  SIGNAL_CLI_TEMP_LINK="$temp_link"
  run_cmd ln -sfn "$target" "$temp_link" || return $?
  SIGNAL_CLI_ACTIVATED_TARGET="$target"
  run_cmd mv -f "$temp_link" "$link_path" || return $?
  SIGNAL_CLI_TEMP_LINK=""
}

validate_signal_cli_binary_version() {
  local candidate="$1"
  local output product reported_version

  output="$("$candidate" --version)" || return $?
  output="${output%%$'\n'*}"
  IFS=' ' read -r product reported_version _ <<<"$output"

  if [[ "$product" != signal-cli || "$reported_version" != "$RESOLVED_VERSION" ]]; then
    die "signal-cli artifact version does not match requested version $RESOLVED_VERSION."
  fi
}

write_signal_cli_install_manifest() {
  local install_dir="$1" install_mode="$2" install_version="$3" marker marker_tmp

  [[ -d "$install_dir" && ! -L "$install_dir" ]] || die "Cannot write ownership manifest outside a regular install directory: $install_dir"
  marker="$install_dir/$SIGNAL_CLI_INSTALL_MANIFEST_NAME"
  if [[ -L "$marker" || (-e "$marker" && ! -f "$marker") ]]; then
    die "Installer ownership manifest path is not a regular file: $marker"
  fi

  marker_tmp="$(mktemp "$install_dir/.signal-cli-install-manifest.tmp.XXXXXX")"
  if ! printf 'signal-cli-install-manifest-v1\nmode=%s\nversion=%s\n' "$install_mode" "$install_version" >"$marker_tmp"; then
    rm -f "$marker_tmp"
    die "Could not render installer ownership manifest."
  fi
  run_cmd chmod 0444 "$marker_tmp"
  if ! is_true "$TEST_MODE"; then
    run_cmd chown root:root "$marker_tmp"
  fi
  run_cmd mv -f "$marker_tmp" "$marker"
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

validate_managed_jvm_tree() {
  local install_dir="$1" trusted_owner="$2" canonical_install_dir entry resolved_entry

  canonical_install_dir="$(readlink -f "$install_dir" 2>/dev/null)" || return 1
  [[ -n "$canonical_install_dir" ]] || return 1

  if ! find "$install_dir" -mindepth 1 -print0 | while IFS= read -r -d '' entry; do
    [[ "$(path_owner_uid "$entry")" == "$trusted_owner" ]] || exit 1
    if [[ -L "$entry" ]]; then
      resolved_entry="$(readlink -f "$entry" 2>/dev/null)" || exit 1
      case "$resolved_entry" in
        "$canonical_install_dir"/*) ;;
        *) exit 1 ;;
      esac
      [[ -f "$resolved_entry" || -d "$resolved_entry" ]] || exit 1
    else
      [[ -f "$entry" || -d "$entry" ]] || exit 1
      path_is_not_group_or_world_writable "$entry" || exit 1
    fi
  done; then
    return 1
  fi
}

validate_managed_signal_cli_target() {
  local target="$1" expected_mode="${2:-}" expected_version="${3:-}"
  local canonical_target install_dir install_mode marker marker_mode managed_opt_dir target_version trusted_owner
  local bin_dir=""

  [[ -d "$OPT_DIR" && ! -L "$OPT_DIR" ]] || return 1
  managed_opt_dir="$(readlink -f "$OPT_DIR" 2>/dev/null)" || return 1
  canonical_target="$(readlink -f "$target" 2>/dev/null)" || return 1
  [[ -n "$managed_opt_dir" && -n "$canonical_target" ]] || return 1
  [[ -f "$canonical_target" && ! -L "$canonical_target" && -x "$canonical_target" ]] || return 1

  case "$canonical_target" in
    "$managed_opt_dir"/signal-cli-native-*/signal-cli)
      install_mode="native"
      install_dir="${canonical_target%/signal-cli}"
      target_version="${install_dir##*/signal-cli-native-}"
      ;;
    "$managed_opt_dir"/signal-cli-*/bin/signal-cli)
      install_mode="jvm"
      install_dir="${canonical_target%/bin/signal-cli}"
      bin_dir="$install_dir/bin"
      target_version="${install_dir##*/signal-cli-}"
      ;;
    *) return 1 ;;
  esac

  [[ "$(dirname "$install_dir")" == "$managed_opt_dir" ]] || return 1
  [[ "$target_version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && "$target_version" != *..* ]] || return 1
  [[ -z "$expected_mode" || "$install_mode" == "$expected_mode" ]] || return 1
  [[ -z "$expected_version" || "$target_version" == "$expected_version" ]] || return 1
  [[ -d "$install_dir" && ! -L "$install_dir" ]] || return 1
  if [[ -n "$bin_dir" ]]; then
    [[ -d "$bin_dir" && ! -L "$bin_dir" ]] || return 1
  fi

  trusted_owner="$(expected_managed_owner_uid)" || return 1
  [[ "$(path_owner_uid "$managed_opt_dir")" == "$trusted_owner" ]] || return 1
  path_is_not_group_or_world_writable "$managed_opt_dir" || return 1
  [[ "$(path_owner_uid "$install_dir")" == "$trusted_owner" ]] || return 1
  [[ "$(path_owner_uid "$canonical_target")" == "$trusted_owner" ]] || return 1
  path_is_not_group_or_world_writable "$install_dir" || return 1
  path_is_not_group_or_world_writable "$canonical_target" || return 1
  if [[ -n "$bin_dir" ]]; then
    [[ "$(path_owner_uid "$bin_dir")" == "$trusted_owner" ]] || return 1
    path_is_not_group_or_world_writable "$bin_dir" || return 1
    validate_managed_jvm_tree "$install_dir" "$trusted_owner" || return 1
  fi

  marker="$install_dir/$SIGNAL_CLI_INSTALL_MANIFEST_NAME"
  if [[ -e "$marker" || -L "$marker" ]]; then
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    [[ "$(path_owner_uid "$marker")" == "$trusted_owner" ]] || return 1
    marker_mode="$(path_mode_bits "$marker")" || return 1
    [[ "$marker_mode" =~ ^[0-7]+$ ]] || return 1
    ((8#$marker_mode == 0444)) || return 1
    install_manifest_content_is_exact "$marker" "$install_mode" "$target_version" || return 1
  fi
}

validate_managed_signal_cli_link() {
  local link_path="$LOCAL_BIN_DIR/signal-cli" resolved_target

  if [[ -L "$link_path" ]]; then
    resolved_target="$(readlink -f "$link_path" 2>/dev/null || true)"
    validate_managed_signal_cli_target "$resolved_target" ||
      die "Active signal-cli symlink is not a trusted managed executable: $link_path"
  elif [[ -e "$link_path" ]]; then
    die "Refusing to replace non-symlink signal-cli executable at $link_path. Move it aside, then rerun the installer."
  fi
}

validate_existing_native_install_for_replacement() {
  local install_dir="$1" target="$2" dotglob_was_set=false nullglob_was_set=false entry version
  local -a entries=()

  [[ ! -L "$install_dir" ]] || die "Existing native install directory is a symlink: $install_dir"
  [[ -d "$install_dir" ]] || die "Existing native install path is not a directory: $install_dir"
  [[ -f "$target" && ! -L "$target" && -x "$target" ]] ||
    die "Existing native install does not contain the expected regular executable: $target"
  version="${install_dir##*/signal-cli-native-}"
  validate_managed_signal_cli_target "$target" native "$version" ||
    die "Existing native install is not trusted for replacement: $install_dir"

  shopt -q dotglob && dotglob_was_set=true
  shopt -q nullglob && nullglob_was_set=true
  shopt -s dotglob nullglob
  entries=("$install_dir"/*)
  is_true "$dotglob_was_set" || shopt -u dotglob
  is_true "$nullglob_was_set" || shopt -u nullglob

  for entry in "${entries[@]}"; do
    case "${entry##*/}" in
      signal-cli) ;;
      "$SIGNAL_CLI_INSTALL_MANIFEST_NAME")
        [[ -f "$entry" && ! -L "$entry" ]] ||
          die "Existing native installer manifest is not a regular file: $entry"
        ;;
      *)
        die "Refusing to replace native install directory containing an unrelated entry: $entry"
        ;;
    esac
  done
}

validate_existing_jvm_install_for_replacement() {
  local install_dir="$1" target="$2" version="$3" expected_owner marker marker_mode

  [[ -d "$install_dir" && ! -L "$install_dir" ]] ||
    die "Existing JVM install path is not a regular directory: $install_dir"
  [[ -f "$target" && ! -L "$target" && -x "$target" ]] ||
    die "Existing JVM install does not contain the expected regular executable: $target"
  marker="$install_dir/$SIGNAL_CLI_INSTALL_MANIFEST_NAME"
  [[ -f "$marker" && ! -L "$marker" ]] ||
    die "Refusing to replace an unmarked or invalid JVM install directory: $install_dir"

  expected_owner="$(expected_managed_owner_uid)"
  [[ "$(path_owner_uid "$install_dir")" == "$expected_owner" ]] ||
    die "Existing JVM install directory has an unexpected owner: $install_dir"
  [[ "$(path_owner_uid "$target")" == "$expected_owner" ]] ||
    die "Existing JVM executable has an unexpected owner: $target"
  [[ "$(path_owner_uid "$marker")" == "$expected_owner" ]] ||
    die "Existing JVM installer manifest has an unexpected owner: $marker"
  path_is_not_group_or_world_writable "$install_dir" ||
    die "Existing JVM install directory is group- or world-writable: $install_dir"
  path_is_not_group_or_world_writable "$target" ||
    die "Existing JVM executable is group- or world-writable: $target"
  marker_mode="$(path_mode_bits "$marker")" || die "Could not inspect existing JVM installer manifest permissions."
  if [[ ! "$marker_mode" =~ ^[0-7]+$ ]] || ((8#$marker_mode != 0444)); then
    die "Existing JVM installer manifest must have mode 0444: $marker"
  fi
  install_manifest_content_is_exact "$marker" jvm "$version" ||
    die "Existing JVM installer manifest does not match mode/version: $marker"
}

install_signal_cli_from_artifact() {
  set_stage "signal-cli install"
  local candidate had_previous=false install_dir previous_dir promote_exit staged_dir staged_target target

  run_cmd install -d -m 0755 "$OPT_DIR"
  SIGNAL_CLI_STAGING_DIR="$(mktemp -d "$OPT_DIR/.signal-cli-install.XXXXXX")"
  run_cmd chmod 0700 "$SIGNAL_CLI_STAGING_DIR"

  log "Installing signal-cli $RESOLVED_VERSION ($INSTALL_MODE)."
  run_cmd tar xf "$SIGNAL_CLI_ARTIFACT" -C "$SIGNAL_CLI_STAGING_DIR"

  if [[ "$INSTALL_MODE" == "native" ]]; then
    candidate="$(find "$SIGNAL_CLI_STAGING_DIR" -type f -name signal-cli -perm -111 | head -n 1 || true)"
    [[ -n "$candidate" ]] || die "Could not find native signal-cli binary in release archive."

    install_dir="$OPT_DIR/signal-cli-native-${RESOLVED_VERSION}"
    target="$install_dir/signal-cli"
    staged_dir="$SIGNAL_CLI_STAGING_DIR/promoted-install"
    previous_dir="$SIGNAL_CLI_STAGING_DIR/previous-install"
    [[ ! -e "$staged_dir" && ! -L "$staged_dir" && ! -e "$previous_dir" && ! -L "$previous_dir" ]] ||
      die "Release archive contains a reserved installer path."
    run_cmd install -d -m 0755 "$staged_dir"
    staged_target="$staged_dir/signal-cli"
    run_cmd install -m 0755 "$candidate" "$staged_target"
    validate_signal_cli_binary_version "$staged_target"
    write_signal_cli_install_manifest "$staged_dir" native "$RESOLVED_VERSION"

    if [[ -e "$install_dir" || -L "$install_dir" ]]; then
      validate_existing_native_install_for_replacement "$install_dir" "$target"
      SIGNAL_CLI_REPLACED_KIND="directory"
      SIGNAL_CLI_REPLACED_PATH="$install_dir"
      SIGNAL_CLI_REPLACED_BACKUP="$previous_dir"
      if run_cmd mv "$install_dir" "$previous_dir"; then
        had_previous=true
      else
        promote_exit=$?
        clear_signal_cli_replacement_state
        return "$promote_exit"
      fi
    fi

    if run_cmd mv "$staged_dir" "$install_dir"; then
      :
    else
      promote_exit=$?
      if is_true "$had_previous"; then
        restore_replaced_signal_cli_install || true
      else
        run_cmd rm -rf "$install_dir" || true
      fi
      return "$promote_exit"
    fi

    switch_signal_cli_symlink "$target"
  else
    install_dir="$OPT_DIR/signal-cli-${RESOLVED_VERSION}"
    staged_dir="$SIGNAL_CLI_STAGING_DIR/signal-cli-${RESOLVED_VERSION}"
    candidate="$staged_dir/bin/signal-cli"
    target="$install_dir/bin/signal-cli"
    [[ -d "$staged_dir" && ! -L "$staged_dir" ]] || die "Could not find JVM signal-cli launcher in a regular install directory in release archive."
    [[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]] || die "Could not find JVM signal-cli launcher in release archive."
    validate_signal_cli_binary_version "$candidate"
    run_cmd chmod 0755 "$staged_dir" "$candidate"
    if ! is_true "$TEST_MODE"; then
      run_cmd chown -R root:root "$staged_dir"
    fi
    write_signal_cli_install_manifest "$staged_dir" jvm "$RESOLVED_VERSION"

    previous_dir="$SIGNAL_CLI_STAGING_DIR/previous-install"
    [[ ! -e "$previous_dir" && ! -L "$previous_dir" ]] || die "Release archive contains a reserved installer path."
    if [[ -e "$install_dir" || -L "$install_dir" ]]; then
      validate_existing_jvm_install_for_replacement "$install_dir" "$target" "$RESOLVED_VERSION"
      SIGNAL_CLI_REPLACED_KIND="directory"
      SIGNAL_CLI_REPLACED_PATH="$install_dir"
      SIGNAL_CLI_REPLACED_BACKUP="$previous_dir"
      if run_cmd mv "$install_dir" "$previous_dir"; then
        had_previous=true
      else
        promote_exit=$?
        clear_signal_cli_replacement_state
        return "$promote_exit"
      fi
    fi

    if run_cmd mv "$staged_dir" "$install_dir"; then
      :
    else
      promote_exit=$?
      if is_true "$had_previous"; then
        restore_replaced_signal_cli_install || true
      else
        run_cmd rm -rf "$install_dir" || true
      fi
      return "$promote_exit"
    fi

    switch_signal_cli_symlink "$target"
  fi

  run_cmd "$LOCAL_BIN_DIR/signal-cli" --version
}

validate_existing_service_group() {
  local result_name="$1"
  local group_entry group_name _group_password resolved_gid _group_members

  group_entry="$(getent group "$SERVICE_GROUP")" || die "Could not inspect existing group $SERVICE_GROUP."
  IFS=: read -r group_name _group_password resolved_gid _group_members <<<"$group_entry"
  [[ "$group_name" == "$SERVICE_GROUP" && "$resolved_gid" =~ ^[0-9]+$ ]] || die "Existing group $SERVICE_GROUP has an invalid group record."
  [[ "$resolved_gid" != 0 ]] || die "Existing group $SERVICE_GROUP resolves to privileged GID 0."
  printf -v "$result_name" '%s' "$resolved_gid"
}

validate_existing_service_identity() {
  local group_gid=""
  local passwd_entry account_name _password user_uid user_gid _gecos user_home user_shell

  validate_existing_service_group group_gid

  passwd_entry="$(getent passwd "$SERVICE_USER")" || die "Could not inspect existing user $SERVICE_USER."
  IFS=: read -r account_name _password user_uid user_gid _gecos user_home user_shell <<<"$passwd_entry"
  [[ "$account_name" == "$SERVICE_USER" && "$user_uid" =~ ^[0-9]+$ && "$user_gid" =~ ^[0-9]+$ ]] ||
    die "Existing user $SERVICE_USER has an invalid account record."
  [[ "$user_uid" != 0 && "$user_gid" != 0 ]] || die "Existing user $SERVICE_USER resolves to a privileged root identity."
  [[ "$user_gid" == "$group_gid" ]] || die "Existing user $SERVICE_USER does not use $SERVICE_GROUP as its primary group."
  [[ "$user_home" == "$DATA_DIR" ]] || die "Existing user $SERVICE_USER has unexpected home directory $user_home; expected $DATA_DIR."

  case "$user_shell" in
    /usr/sbin/nologin | /sbin/nologin | /usr/bin/false | /bin/false) ;;
    *) die "Existing user $SERVICE_USER is login-enabled; refusing to use it as a service identity." ;;
  esac
}

create_service_user() {
  set_stage "service user"

  if is_true "$TEST_MODE"; then
    log "Creating test-mode data directory."
    run_cmd install -d -m 0700 "$DATA_DIR"
    return 0
  fi

  local nologin_shell
  nologin_shell="$(command -v nologin || true)"
  nologin_shell="${nologin_shell:-/usr/sbin/nologin}"

  if getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
    local _existing_group_gid=""
    validate_existing_service_group _existing_group_gid
  else
    run_cmd groupadd --system "$SERVICE_GROUP"
  fi

  if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    validate_existing_service_identity
  else
    run_cmd useradd --system \
      --gid "$SERVICE_GROUP" \
      --home-dir "$DATA_DIR" \
      --create-home \
      --shell "$nologin_shell" \
      "$SERVICE_USER"
  fi

  run_cmd install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$DATA_DIR"
  run_cmd chown -R "$SERVICE_USER:$SERVICE_GROUP" "$DATA_DIR"
  run_cmd chmod 0700 "$DATA_DIR"
}

detected_ssh_ports() {
  if command -v sshd >/dev/null 2>&1; then
    sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -u
  else
    return 1
  fi
}

load_detected_ssh_ports() {
  local -n ports_ref="$1"
  local output

  ports_ref=()
  output="$(detected_ssh_ports)" || return 1
  [[ -n "$output" ]] || return 1
  mapfile -t ports_ref <<<"$output"
  [[ "${#ports_ref[@]}" -gt 0 ]]
}

configure_ufw() {
  is_true "$ENABLE_UFW" || return 0
  set_stage "ufw configuration"

  if is_true "$TEST_MODE"; then
    printf '[test-mode] skip UFW configuration\n'
    return 0
  fi

  local ports=() port
  if ! load_detected_ssh_ports ports; then
    die "Could not determine SSH port from sshd. Refusing to enable UFW; fix sshd -T or rerun with --no-ufw."
  fi

  log "Configuring UFW."
  run_cmd ufw default deny incoming
  run_cmd ufw default allow outgoing

  for port in "${ports[@]}"; do
    run_cmd ufw allow "${port}/tcp"
  done

  run_cmd ufw --force enable
  if is_dry_run; then
    run_cmd ufw status verbose
  else
    ufw status verbose || true
  fi
}

render_fail2ban_jail() {
  local ports_csv="$1"
  cat <<EOF
[sshd]
enabled = true
backend = systemd
port = ${ports_csv}
maxretry = 5
findtime = 10m
bantime = 1h
EOF
}

configure_fail2ban() {
  is_true "$ENABLE_FAIL2BAN" || return 0
  set_stage "fail2ban configuration"

  local ports=() ports_csv
  load_detected_ssh_ports ports || true
  if [[ "${#ports[@]}" -eq 0 ]]; then
    ports=(22)
  fi
  ports_csv="$(
    IFS=,
    printf '%s' "${ports[*]}"
  )"

  log "Configuring fail2ban for SSH."
  run_cmd install -d -m 0755 "$(dirname "$FAIL2BAN_FILE")"
  write_rendered_file "$FAIL2BAN_FILE" 0644 root root render_fail2ban_jail "$ports_csv"

  run_cmd maybe_systemctl enable --now fail2ban
  run_cmd maybe_systemctl restart fail2ban
}

render_ssh_hardening_config() {
  cat <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
}

ssh_hardening_backup_is_valid() {
  [[ -n "$SSH_HARDENING_BACKUP_DIR" &&
    -d "$SSH_HARDENING_BACKUP_DIR" &&
    ! -L "$SSH_HARDENING_BACKUP_DIR" &&
    "$SSH_HARDENING_BACKUP_FILE" == "$SSH_HARDENING_BACKUP_DIR/ssh-hardening.conf" ]]
}

remove_ssh_hardening_backup() {
  [[ -n "$SSH_HARDENING_BACKUP_DIR" ]] || return 0
  if ! ssh_hardening_backup_is_valid; then
    warn "Refusing to remove an invalid SSH hardening recovery directory: $SSH_HARDENING_BACKUP_DIR"
    return 1
  fi
  if ! rm -rf -- "$SSH_HARDENING_BACKUP_DIR"; then
    warn "Could not remove SSH hardening recovery directory: $SSH_HARDENING_BACKUP_DIR"
    return 1
  fi
  SSH_HARDENING_BACKUP_DIR=""
  SSH_HARDENING_BACKUP_FILE=""
}

begin_ssh_hardening_transaction() {
  local backup_dir

  if is_true "$SSH_HARDENING_TRANSACTION_ACTIVE"; then
    warn "An SSH hardening transaction is already active."
    return 1
  fi

  SSH_HARDENING_HAD_PREVIOUS="false"
  SSH_HARDENING_BACKUP_DIR=""
  SSH_HARDENING_BACKUP_FILE=""
  SSH_HARDENING_RELOAD_ATTEMPTED="false"
  SSH_HARDENING_RESTORE_IN_PROGRESS="false"

  if ! backup_dir="$(mktemp -d)"; then
    warn "Could not create an SSH hardening recovery directory."
    return 1
  fi
  SSH_HARDENING_BACKUP_DIR="$backup_dir"
  SSH_HARDENING_BACKUP_FILE="$backup_dir/ssh-hardening.conf"
  if ! chmod 0700 "$backup_dir"; then
    warn "Could not secure the SSH hardening recovery directory: $backup_dir"
    rm -rf -- "$backup_dir" || warn "Could not remove incomplete SSH hardening recovery directory: $backup_dir"
    SSH_HARDENING_BACKUP_DIR=""
    SSH_HARDENING_BACKUP_FILE=""
    return 1
  fi

  if [[ -f "$SSH_HARDENING_FILE" ]]; then
    if ! cp -p "$SSH_HARDENING_FILE" "$SSH_HARDENING_BACKUP_FILE"; then
      warn "Could not back up the existing SSH hardening file."
      remove_ssh_hardening_backup || true
      return 1
    fi
    SSH_HARDENING_HAD_PREVIOUS="true"
  fi

  # Arm only after recovery state is complete and before replacing the file.
  SSH_HARDENING_TRANSACTION_ACTIVE="true"
}

reload_ssh_service() {
  run_cmd maybe_systemctl reload ssh ||
    run_cmd maybe_systemctl reload sshd ||
    run_cmd maybe_systemctl restart ssh ||
    run_cmd maybe_systemctl restart sshd
}

restore_ssh_hardening_transaction() {
  local restore_temp="" restore_failed=false

  is_true "$SSH_HARDENING_TRANSACTION_ACTIVE" || return 0
  if is_true "$SSH_HARDENING_RESTORE_IN_PROGRESS"; then
    warn "SSH hardening restoration is already in progress. Recovery files remain at $SSH_HARDENING_BACKUP_DIR."
    return 1
  fi
  SSH_HARDENING_RESTORE_IN_PROGRESS="true"

  if is_true "$SSH_HARDENING_HAD_PREVIOUS"; then
    if ! ssh_hardening_backup_is_valid ||
      [[ ! -f "$SSH_HARDENING_BACKUP_FILE" || -L "$SSH_HARDENING_BACKUP_FILE" ]]; then
      restore_failed=true
    elif [[ -L "$SSH_HARDENING_FILE" || (-e "$SSH_HARDENING_FILE" && ! -f "$SSH_HARDENING_FILE") ]]; then
      warn "Refusing to overwrite an unexpected SSH hardening path during restoration: $SSH_HARDENING_FILE"
      restore_failed=true
    elif ! restore_temp="$(mktemp "$(dirname "$SSH_HARDENING_FILE")/.ssh-hardening-restore.XXXXXX")"; then
      restore_failed=true
    elif ! cp -p "$SSH_HARDENING_BACKUP_FILE" "$restore_temp"; then
      restore_failed=true
    elif ! mv -f "$restore_temp" "$SSH_HARDENING_FILE"; then
      restore_failed=true
    else
      restore_temp=""
    fi
  else
    if [[ -L "$SSH_HARDENING_FILE" || -f "$SSH_HARDENING_FILE" ]]; then
      if ! rm -f -- "$SSH_HARDENING_FILE"; then
        restore_failed=true
      fi
    elif [[ -e "$SSH_HARDENING_FILE" ]]; then
      warn "Refusing to remove an unexpected SSH hardening path during restoration: $SSH_HARDENING_FILE"
      restore_failed=true
    fi
  fi

  if [[ -n "$restore_temp" ]]; then
    rm -f -- "$restore_temp" || warn "Could not remove incomplete SSH hardening restore file: $restore_temp"
  fi

  if ! is_true "$restore_failed" && is_true "$SSH_HARDENING_RELOAD_ATTEMPTED"; then
    if ! reload_ssh_service; then
      warn "The prior SSH policy was restored on disk, but reloading it failed."
      restore_failed=true
    fi
  fi

  SSH_HARDENING_RESTORE_IN_PROGRESS="false"
  if is_true "$restore_failed"; then
    warn "SSH hardening restoration is incomplete. Recovery files remain at $SSH_HARDENING_BACKUP_DIR."
    return 1
  fi

  # Disarm before removing the backup. A signal after this point can only leak
  # a harmless recovery copy; it cannot cause a partial second restoration.
  SSH_HARDENING_TRANSACTION_ACTIVE="false"
  SSH_HARDENING_HAD_PREVIOUS="false"
  SSH_HARDENING_RELOAD_ATTEMPTED="false"
  remove_ssh_hardening_backup || true
  return 0
}

commit_ssh_hardening_transaction() {
  is_true "$SSH_HARDENING_TRANSACTION_ACTIVE" || return 0

  SSH_HARDENING_TRANSACTION_ACTIVE="false"
  SSH_HARDENING_HAD_PREVIOUS="false"
  SSH_HARDENING_RELOAD_ATTEMPTED="false"
  SSH_HARDENING_RESTORE_IN_PROGRESS="false"
  remove_ssh_hardening_backup || true
  return 0
}

configure_ssh_hardening() {
  local write_exit

  is_true "$SSH_HARDENING" || return 0
  set_stage "ssh hardening"

  if ! command -v sshd >/dev/null 2>&1; then
    warn "sshd not found; skipping SSH hardening."
    return 0
  fi

  log "Applying SSH hardening."
  run_cmd install -d -m 0755 "$(dirname "$SSH_HARDENING_FILE")" || return 1

  if ! is_dry_run; then
    [[ ! -L "$SSH_HARDENING_FILE" ]] || die "Refusing to replace symlinked privileged file: $SSH_HARDENING_FILE"
    [[ ! -e "$SSH_HARDENING_FILE" || -f "$SSH_HARDENING_FILE" ]] ||
      die "Refusing to replace non-regular privileged file: $SSH_HARDENING_FILE"
    begin_ssh_hardening_transaction || die "Could not initialize SSH hardening recovery state."
  fi

  if write_rendered_file "$SSH_HARDENING_FILE" 0644 root root render_ssh_hardening_config; then
    :
  else
    write_exit=$?
    if ! is_dry_run; then
      restore_ssh_hardening_transaction || true
    fi
    return "$write_exit"
  fi

  if ! is_dry_run && ! is_true "$TEST_MODE" && ! sshd -t; then
    if ! restore_ssh_hardening_transaction; then
      die "SSH config test failed and the previous SSH hardening file could not be restored."
    fi
    die "SSH config test failed. Restored the previous SSH hardening file state."
  fi

  if ! is_dry_run; then
    # Set before the call so a signal after systemctl succeeds but before the
    # shell observes its return still reapplies the restored prior policy.
    SSH_HARDENING_RELOAD_ATTEMPTED="true"
  fi
  if reload_ssh_service; then
    if ! is_dry_run; then
      commit_ssh_hardening_transaction || die "SSH hardening was applied, but its recovery backup could not be removed."
    fi
  else
    if ! is_dry_run && ! restore_ssh_hardening_transaction; then
      die "Every SSH service reload/restart attempt failed and the previous SSH hardening file could not be restored."
    fi
    die "Every SSH service reload/restart attempt failed. Restored the previous SSH hardening file state."
  fi
}

render_sysctl_config() {
  cat <<'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.randomize_va_space = 2
EOF
}

configure_sysctl_hardening() {
  is_true "$ENABLE_SYSCTL_HARDENING" || return 0
  set_stage "sysctl hardening"

  log "Applying conservative sysctl hardening."
  write_rendered_file "$SYSCTL_FILE" 0644 root root render_sysctl_config
  if is_dry_run; then
    run_cmd sysctl --system
  elif is_true "$TEST_MODE"; then
    printf '[test-mode] skip sysctl --system\n'
  else
    sysctl --system >/dev/null || warn "Some sysctl settings could not be applied on this kernel."
  fi
}

render_unattended_upgrades_config() {
  cat <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
}

configure_unattended_upgrades() {
  is_true "$ENABLE_UNATTENDED_UPGRADES" || return 0
  set_stage "unattended upgrades"

  log "Enabling unattended security upgrades."
  write_rendered_file "$UNATTENDED_UPGRADES_FILE" 0644 root root render_unattended_upgrades_config
  run_cmd maybe_systemctl enable --now unattended-upgrades || true
}

render_runtime_config() {
  cat <<EOF
SIGNAL_CLI_DATA_DIR="$DATA_DIR"
SIGNAL_CLI_ACCOUNT="$SIGNAL_ACCOUNT"
SIGNAL_CLI_HTTP_BIND="$HTTP_BIND"
EOF
}

write_runtime_config() {
  set_stage "runtime config"
  log "Writing signal-cli runtime config."
  write_rendered_file "$CONFIG_FILE" 0640 root "$SERVICE_GROUP" render_runtime_config
}

render_wrapper() {
  cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$CONFIG_FILE"

args=(--data-dir "\$SIGNAL_CLI_DATA_DIR")
if [[ -n "\${SIGNAL_CLI_ACCOUNT:-}" ]]; then
  args+=(-a "\$SIGNAL_CLI_ACCOUNT")
fi

exec "$LOCAL_BIN_DIR/signal-cli" "\${args[@]}" daemon --http "\$SIGNAL_CLI_HTTP_BIND"
EOF
}

render_systemd_service() {
  cat <<EOF
[Unit]
Description=signal-cli JSON-RPC daemon
Documentation=https://github.com/AsamK/signal-cli
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
EnvironmentFile=-$CONFIG_FILE
ExecStart=$WRAPPER_FILE
WorkingDirectory=$DATA_DIR
Restart=on-failure
RestartSec=10
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA_DIR
ReadOnlyPaths=$OPT_DIR $LOCAL_BIN_DIR $(root_path /usr/local/sbin)
CapabilityBoundingSet=
AmbientCapabilities=
LockPersonality=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
}

render_signal_link_qr() {
  local qr_file="${1:-}"
  local line=""
  local link_uri=""

  [[ -n "$qr_file" ]] || die "QR output file path is required."

  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line"

    if [[ -z "$link_uri" && "$line" =~ (sgnl://linkdevice[^[:space:]]+) ]]; then
      link_uri="${BASH_REMATCH[1]}"
      printf '%s\n' "$link_uri" | qrencode -t ANSI
      printf '%s\n' "$link_uri" | qrencode -o "$qr_file" --level=H
    fi
  done

  if [[ -z "$link_uri" ]]; then
    warn "signal-cli did not emit a Signal link URI; QR code was not generated."
    return 1
  fi
}

link_signal_device() {
  is_true "$RUN_LINK" || return 0
  set_stage "device linking"

  if is_true "$TEST_MODE"; then
    printf '[test-mode] skip Signal device linking\n'
    return 0
  fi

  if is_dry_run; then
    printf '[dry-run] link Signal device as %s with device name %s\n' "$SERVICE_USER" "$DEVICE_NAME"
    return 0
  fi

  local qr_dir qr_file
  qr_dir="$(mktemp -d)"
  qr_file="$qr_dir/signal-cli-link.png"
  chmod 0700 "$qr_dir"

  if is_true "$SIGNAL_CLI_SERVICE_WAS_ACTIVE"; then
    log "Stopping the active signal-cli service before linking."
    SIGNAL_CLI_SERVICE_STATE_MUTATED="true"
    run_cmd maybe_systemctl stop signal-cli
  fi

  log "Starting Signal linked-device provisioning."
  cat <<EOF

Open Signal on your phone:
  Settings -> Linked devices -> Link new device

Scan the QR code below. Keep this terminal open until signal-cli reports linking is finished.
A PNG copy is also written to: $qr_file

EOF

  runuser -u "$SERVICE_USER" -- env HOME="$DATA_DIR" XDG_DATA_HOME="$DATA_DIR" \
    "$LOCAL_BIN_DIR/signal-cli" --data-dir "$DATA_DIR" link -n "$DEVICE_NAME" |
    render_signal_link_qr "$qr_file"

  chmod 0600 "$qr_file" 2>/dev/null || true
  log "Linking command finished."
}

run_initial_receive() {
  set_stage "initial receive"

  if is_true "$TEST_MODE"; then
    printf '[test-mode] skip initial receive\n'
    return 0
  fi

  if [[ -z "$SIGNAL_ACCOUNT" ]]; then
    warn "No account number configured. Service will run in multi-account mode. JSON-RPC calls must include the account parameter."
    return 0
  fi

  log "Running a short initial receive pass for contacts/groups sync."
  run_cmd timeout 30s runuser -u "$SERVICE_USER" -- env HOME="$DATA_DIR" XDG_DATA_HOME="$DATA_DIR" \
    "$LOCAL_BIN_DIR/signal-cli" --data-dir "$DATA_DIR" -a "$SIGNAL_ACCOUNT" receive || true
}

write_systemd_service() {
  set_stage "systemd service"
  log "Writing systemd service."

  write_rendered_file "$WRAPPER_FILE" 0755 root root render_wrapper

  write_rendered_file "$SERVICE_FILE" 0644 root root render_systemd_service

  run_cmd maybe_systemctl daemon-reload
  SIGNAL_CLI_SERVICE_STATE_MUTATED="true"
  run_cmd maybe_systemctl enable --now signal-cli.service
  if is_true "$SIGNAL_CLI_SERVICE_WAS_ACTIVE" && ! is_true "$RUN_LINK"; then
    run_cmd maybe_systemctl restart signal-cli.service
  fi
}

health_check() {
  local attempt

  set_stage "health check"
  log "Checking signal-cli daemon health."

  if is_dry_run; then
    printf '[dry-run] curl -fsS http://%s/api/v1/check\n' "$HTTP_BIND"
    return 0
  fi

  if is_true "$TEST_MODE"; then
    printf '[test-mode] skip health check http://%s/api/v1/check\n' "$HTTP_BIND"
    return 0
  fi

  [[ "$HEALTH_CHECK_MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || die "HEALTH_CHECK_MAX_ATTEMPTS must be a positive integer."
  [[ "$HEALTH_CHECK_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || die "HEALTH_CHECK_INTERVAL_SECONDS must be a non-negative integer."
  [[ "$HEALTH_CHECK_CONNECT_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "HEALTH_CHECK_CONNECT_TIMEOUT_SECONDS must be a positive integer."
  [[ "$HEALTH_CHECK_REQUEST_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "HEALTH_CHECK_REQUEST_TIMEOUT_SECONDS must be a positive integer."

  for ((attempt = 1; attempt <= HEALTH_CHECK_MAX_ATTEMPTS; attempt++)); do
    if curl -fsS \
      --connect-timeout "$HEALTH_CHECK_CONNECT_TIMEOUT_SECONDS" \
      --max-time "$HEALTH_CHECK_REQUEST_TIMEOUT_SECONDS" \
      "http://${HTTP_BIND}/api/v1/check" >/dev/null; then
      printf '[+] JSON-RPC daemon is reachable at http://%s/api/v1/check\n' "$HTTP_BIND"
      return 0
    fi
    if ((attempt < HEALTH_CHECK_MAX_ATTEMPTS)); then
      sleep "$HEALTH_CHECK_INTERVAL_SECONDS"
    fi
  done

  warn "Health check failed after $HEALTH_CHECK_MAX_ATTEMPTS attempts. Recent logs:"
  journalctl -u signal-cli -n 80 --no-pager || true
  return 1
}

print_install_plan() {
  cat <<EOF

Install plan:
  Account: ${SIGNAL_ACCOUNT:-multi-account mode}
  Device name: $DEVICE_NAME
  Bind: $HTTP_BIND
  Public bind allowed: $ALLOW_PUBLIC_BIND
  Install mode: $INSTALL_MODE
  signal-cli version: $RESOLVED_VERSION
  Verification mode: $VERIFY_MODE
  SHA256 provided: $(if [[ -n "$EXPECTED_SHA256" ]]; then printf 'yes'; else printf 'no'; fi)
  Checksum URL: ${CHECKSUM_URL:-none}
  Unverified download allowed: $ALLOW_UNVERIFIED_DOWNLOAD
  Link now: $RUN_LINK
  UFW: $ENABLE_UFW
  fail2ban: $ENABLE_FAIL2BAN
  SSH hardening: $SSH_HARDENING
  sysctl hardening: $ENABLE_SYSCTL_HARDENING
  unattended upgrades: $ENABLE_UNATTENDED_UPGRADES
  apt upgrade: $RUN_APT_UPGRADE
  Artifact: $SIGNAL_CLI_ASSET
  Artifact URL: $SIGNAL_CLI_URL
Files to write:
  $CONFIG_FILE
  $WRAPPER_FILE
  $SERVICE_FILE
EOF

  if is_true "$ENABLE_SYSCTL_HARDENING"; then
    printf '  %s\n' "$SYSCTL_FILE"
  fi
  if is_true "$ENABLE_FAIL2BAN"; then
    printf '  %s\n' "$FAIL2BAN_FILE"
  fi
  if is_true "$SSH_HARDENING"; then
    printf '  %s\n' "$SSH_HARDENING_FILE"
  fi

  printf 'Packages:\n'
  local package
  for package in "${BASE_PACKAGES[@]}"; do
    printf '  %s\n' "$package"
  done
}

print_summary() {
  cat <<EOF

Done.

Important files:
  Service:      $SERVICE_FILE
  Config:       $CONFIG_FILE
  Data/secrets: $DATA_DIR
  Logs:         journalctl -u signal-cli -f

Health check:
  curl -i http://$HTTP_BIND/api/v1/check

JSON-RPC send test template:
  curl -sS -X POST http://$HTTP_BIND/api/v1/rpc \\
    -H 'Content-Type: application/json' \\
    -d '{
      "jsonrpc": "2.0",
      "method": "send",
      "params": {
        "account": "${SIGNAL_ACCOUNT:-+YOUR_ACCOUNT_NUMBER}",
        "recipient": ["+RECIPIENT_NUMBER"],
        "message": "test from signal-cli"
      },
      "id": 1
    }'

Service control:
  systemctl status signal-cli --no-pager
  systemctl restart signal-cli
EOF
}

main() {
  trap on_lifecycle_error ERR
  trap 'on_lifecycle_signal HUP' HUP
  trap 'on_lifecycle_signal INT' INT
  trap 'on_lifecycle_signal TERM' TERM
  trap cleanup EXIT

  SIGNAL_CLI_PREVIOUS_TARGET=""
  SIGNAL_CLI_ACTIVATED_TARGET=""
  SIGNAL_CLI_RESTORE_ABSENT_LINK="false"
  SIGNAL_CLI_PRESERVE_STAGING_DIR="false"
  SIGNAL_CLI_SERVICE_WAS_ACTIVE="false"
  SIGNAL_CLI_SERVICE_STATE_MUTATED="false"
  SIGNAL_CLI_TEMP_LINK=""
  SIGNAL_CLI_TRANSACTION_COMMITTED="false"
  clear_signal_cli_replacement_state

  parse_args "$@"
  require_root "$@"
  validate_inputs
  choose_install_mode
  preflight_checks
  build_base_packages
  if ! is_dry_run; then
    validate_managed_signal_cli_link
  fi
  install_bootstrap_packages
  resolve_signal_cli_version
  build_signal_cli_asset_url
  print_install_plan

  if is_dry_run; then
    return 0
  fi

  acquire_lifecycle_lock
  validate_managed_signal_cli_link
  if [[ -L "$LOCAL_BIN_DIR/signal-cli" ]]; then
    SIGNAL_CLI_PREVIOUS_TARGET="$(readlink -f "$LOCAL_BIN_DIR/signal-cli" 2>/dev/null || true)"
  else
    SIGNAL_CLI_RESTORE_ABSENT_LINK="true"
  fi
  capture_signal_cli_service_state

  install_base_packages
  download_signal_cli_artifact
  verify_signal_cli_artifact
  install_signal_cli_from_artifact
  create_service_user
  write_runtime_config
  configure_ufw
  configure_fail2ban
  configure_ssh_hardening
  configure_sysctl_hardening
  configure_unattended_upgrades
  link_signal_device
  run_initial_receive
  write_systemd_service
  health_check
  commit_signal_cli_transaction
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
