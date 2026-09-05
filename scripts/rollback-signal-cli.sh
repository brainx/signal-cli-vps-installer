#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=install.sh
source "$ROOT_DIR/install.sh"

ROLLBACK_VERSION="${ROLLBACK_VERSION:-}"
ROLLBACK_NO_RESTART="${ROLLBACK_NO_RESTART:-false}"

usage_rollback() {
  cat <<EOF
Usage:
  sudo $0 --to-version VERSION --install-mode native|jvm [options]

Options:
  --to-version VERSION         Existing installed signal-cli version to restore.
  --install-mode native|jvm    Version layout to restore.
  --dry-run                    Print the rollback plan without changing the system.
  --no-restart                 Do not restart or health-check the service after switching binaries.
  -h, --help                   Show this help.
EOF
}

parse_rollback_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to-version)
        [[ $# -ge 2 ]] || die "--to-version requires a value"
        ROLLBACK_VERSION="$2"
        shift 2
        ;;
      --install-mode)
        [[ $# -ge 2 ]] || die "--install-mode requires native or jvm"
        INSTALL_MODE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --no-restart)
        ROLLBACK_NO_RESTART="true"
        shift
        ;;
      -h | --help)
        usage_rollback
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

target_for_version() {
  local version="$1"
  local mode="$2"

  case "$mode" in
    native) printf '%s/signal-cli-native-%s/signal-cli\n' "$OPT_DIR" "$version" ;;
    jvm) printf '%s/signal-cli-%s/bin/signal-cli\n' "$OPT_DIR" "$version" ;;
    *) die "--install-mode must be native or jvm for rollback." ;;
  esac
}

validate_rollback_version() {
  [[ "$ROLLBACK_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && "$ROLLBACK_VERSION" != *..* ]] || die "Invalid --to-version. Refusing path separators or traversal."
}

validate_rollback_target() {
  local line reported_version="" target="$1" version_output

  [[ -f "$target" && ! -L "$target" && -x "$target" ]] || die "Rollback target is not an executable regular file: $target"

  if ! version_output="$("$target" --version 2>&1)"; then
    die "Rollback target failed its pre-activation version check: $target"
  fi

  while IFS= read -r line; do
    if [[ "$line" =~ ^signal-cli[[:space:]]+([^[:space:]]+) ]]; then
      reported_version="${BASH_REMATCH[1]}"
      break
    fi
  done <<<"$version_output"

  [[ "$reported_version" == "$ROLLBACK_VERSION" ]] || die "Rollback target reports version '${reported_version:-unknown}', expected '$ROLLBACK_VERSION'."
}

print_rollback_plan() {
  local target="$1"

  cat <<EOF

Rollback plan:
  Target version: $ROLLBACK_VERSION
  Install mode: $INSTALL_MODE
  Target binary: $target
  Link path: $LOCAL_BIN_DIR/signal-cli
  Restart service: $(if is_true "$ROLLBACK_NO_RESTART"; then printf 'false'; else printf 'true'; fi)
  Health bind: $HTTP_BIND
EOF
}

main_rollback() {
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
  SIGNAL_CLI_TRANSACTION_COMMITTED="false"
  clear_signal_cli_replacement_state

  parse_rollback_args "$@"
  require_root "$@"

  [[ -n "$ROLLBACK_VERSION" ]] || die "--to-version is required."
  [[ "$INSTALL_MODE" =~ ^(native|jvm)$ ]] || die "--install-mode must be native or jvm."
  validate_rollback_version

  local target
  target="$(target_for_version "$ROLLBACK_VERSION" "$INSTALL_MODE")"

  if is_dry_run; then
    if ! is_true "$ROLLBACK_NO_RESTART"; then
      load_installed_http_bind_for_dry_run_plan
    fi
    print_rollback_plan "$target"
    return 0
  fi

  acquire_lifecycle_lock
  validate_managed_signal_cli_link
  if ! is_true "$ROLLBACK_NO_RESTART"; then
    load_installed_http_bind
  fi
  print_rollback_plan "$target"
  if [[ -L "$LOCAL_BIN_DIR/signal-cli" ]]; then
    SIGNAL_CLI_PREVIOUS_TARGET="$(readlink -f "$LOCAL_BIN_DIR/signal-cli" 2>/dev/null || true)"
    [[ -n "$SIGNAL_CLI_PREVIOUS_TARGET" && -x "$SIGNAL_CLI_PREVIOUS_TARGET" ]] || die "Active signal-cli link does not resolve to an executable target."
  else
    SIGNAL_CLI_RESTORE_ABSENT_LINK="true"
  fi
  if ! is_true "$ROLLBACK_NO_RESTART"; then
    capture_signal_cli_service_state
  fi

  validate_managed_signal_cli_target "$target" "$INSTALL_MODE" "$ROLLBACK_VERSION" ||
    die "Rollback target is not a trusted installer-managed or safe legacy executable: $target"
  validate_rollback_target "$target"
  switch_signal_cli_symlink "$target"
  run_cmd "$LOCAL_BIN_DIR/signal-cli" --version

  if ! is_true "$ROLLBACK_NO_RESTART"; then
    SIGNAL_CLI_SERVICE_STATE_MUTATED="true"
    run_cmd maybe_systemctl restart signal-cli
    health_check
  fi

  commit_signal_cli_transaction

  printf '\nRollback complete.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main_rollback "$@"
fi
