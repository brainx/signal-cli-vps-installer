#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../install.sh
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

main_rollback() {
  trap on_error ERR

  parse_rollback_args "$@"
  require_root "$@"

  [[ -n "$ROLLBACK_VERSION" ]] || die "--to-version is required."
  [[ "$INSTALL_MODE" =~ ^(native|jvm)$ ]] || die "--install-mode must be native or jvm."

  local target
  target="$(target_for_version "$ROLLBACK_VERSION" "$INSTALL_MODE")"

  cat <<EOF

Rollback plan:
  Target version: $ROLLBACK_VERSION
  Install mode: $INSTALL_MODE
  Target binary: $target
  Link path: $LOCAL_BIN_DIR/signal-cli
  Restart service: $(if is_true "$ROLLBACK_NO_RESTART"; then printf 'false'; else printf 'true'; fi)
EOF

  if is_dry_run; then
    return 0
  fi

  [[ -x "$target" ]] || die "Rollback target is not executable: $target"
  switch_signal_cli_symlink "$target"
  run_cmd "$LOCAL_BIN_DIR/signal-cli" --version

  if ! is_true "$ROLLBACK_NO_RESTART"; then
    run_cmd maybe_systemctl restart signal-cli
    health_check
  fi

  printf '\nRollback complete.\n'
}

main_rollback "$@"
