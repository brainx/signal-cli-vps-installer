#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=install.sh
source "$ROOT_DIR/install.sh"

UPGRADE_NO_RESTART="${UPGRADE_NO_RESTART:-false}"
INSTALL_ARGS=()

usage_upgrade() {
  cat <<EOF
Usage:
  sudo $0 [options]

Options:
  --version VERSION            Target signal-cli version. Default: latest.
  --install-mode auto|native|jvm
  --artifact-file PATH         Use a local release artifact instead of downloading one.
  --verify auto|sha256|none    Release artifact verification mode. Default: auto.
  --sha256 SHA256              Expected SHA256 for the downloaded release artifact.
  --checksum-url URL           HTTPS URL to a SHA256 checksum file.
  --allow-unverified-download  Permit an install without checksum verification.
  --dry-run                    Print the upgrade plan without changing the system.
  --no-restart                 Do not restart or health-check the service after switching binaries.
  -h, --help                   Show this help.
EOF
}

parse_upgrade_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-restart)
        UPGRADE_NO_RESTART="true"
        shift
        ;;
      -h | --help)
        usage_upgrade
        exit 0
        ;;
      *)
        INSTALL_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

print_upgrade_plan() {
  cat <<EOF

Upgrade plan:
  Install mode: $INSTALL_MODE
  signal-cli version: $RESOLVED_VERSION
  Artifact: $SIGNAL_CLI_ASSET
  Artifact URL: $SIGNAL_CLI_URL
  Verification mode: $VERIFY_MODE
  SHA256 provided: $(if [[ -n "$EXPECTED_SHA256" ]]; then printf 'yes'; else printf 'no'; fi)
  Checksum URL: ${CHECKSUM_URL:-none}
  Unverified download allowed: $ALLOW_UNVERIFIED_DOWNLOAD
  Restart service: $(if is_true "$UPGRADE_NO_RESTART"; then printf 'false'; else printf 'true'; fi)
  Health bind: $HTTP_BIND
  Link path: $LOCAL_BIN_DIR/signal-cli
EOF
}

print_upgrade_rollback_hint() {
  local managed_opt_dir previous_dir previous_mode previous_target previous_version

  previous_target="${1:-$SIGNAL_CLI_PREVIOUS_TARGET}"

  managed_opt_dir="$(readlink -f "$OPT_DIR" 2>/dev/null || true)"
  [[ -n "$managed_opt_dir" ]] || managed_opt_dir="$OPT_DIR"

  case "$previous_target" in
    "$managed_opt_dir"/signal-cli-native-*/signal-cli)
      previous_dir="${previous_target%/signal-cli}"
      previous_mode="native"
      previous_version="${previous_dir##*/signal-cli-native-}"
      ;;
    "$managed_opt_dir"/signal-cli-*/bin/signal-cli)
      previous_dir="${previous_target%/bin/signal-cli}"
      previous_mode="jvm"
      previous_version="${previous_dir##*/signal-cli-}"
      ;;
    *)
      printf 'Rollback hint:   Previous binary is not in a recognized managed layout.\n'
      return 0
      ;;
  esac

  if [[ ! "$previous_version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ || "$previous_version" == *..* ]]; then
    printf 'Rollback hint:   Previous binary version could not be derived safely.\n'
    return 0
  fi

  printf 'Rollback hint:   scripts/rollback-signal-cli.sh --to-version %s --install-mode %s\n' "$previous_version" "$previous_mode"
}

validate_upgrade_inputs() {
  # Upgrade is binary-only. It must not prompt for account, device,
  # bind, or SSH hardening choices.
  RUN_LINK="false"
  SSH_HARDENING="false"
  SIGNAL_ACCOUNT="${SIGNAL_ACCOUNT:-}"
  validate_common_release_inputs
}

main_upgrade() {
  trap on_lifecycle_error ERR
  trap 'on_lifecycle_signal HUP' HUP
  trap 'on_lifecycle_signal INT' INT
  trap 'on_lifecycle_signal TERM' TERM
  trap cleanup EXIT

  local original_args=("$@")

  SIGNAL_CLI_PREVIOUS_TARGET=""
  SIGNAL_CLI_ACTIVATED_TARGET=""
  SIGNAL_CLI_RESTORE_ABSENT_LINK="false"
  SIGNAL_CLI_PRESERVE_STAGING_DIR="false"
  SIGNAL_CLI_SERVICE_WAS_ACTIVE="false"
  SIGNAL_CLI_SERVICE_STATE_MUTATED="false"
  SIGNAL_CLI_TRANSACTION_COMMITTED="false"
  clear_signal_cli_replacement_state

  parse_upgrade_args "$@"
  parse_args "${INSTALL_ARGS[@]}"
  RUN_LINK="false"
  SSH_HARDENING="false"
  require_root "${original_args[@]}"
  validate_upgrade_inputs
  choose_install_mode
  preflight_checks
  if ! is_dry_run; then
    validate_managed_signal_cli_link
  fi
  install_bootstrap_packages
  resolve_signal_cli_version
  build_signal_cli_asset_url

  if is_dry_run; then
    if ! is_true "$UPGRADE_NO_RESTART"; then
      load_installed_http_bind_for_dry_run_plan
    fi
    print_upgrade_plan
    return 0
  fi

  local new_target previous_target_for_summary
  acquire_lifecycle_lock
  validate_managed_signal_cli_link
  if ! is_true "$UPGRADE_NO_RESTART"; then
    load_installed_http_bind
  fi
  print_upgrade_plan
  if [[ -L "$LOCAL_BIN_DIR/signal-cli" ]]; then
    SIGNAL_CLI_PREVIOUS_TARGET="$(readlink -f "$LOCAL_BIN_DIR/signal-cli" 2>/dev/null || true)"
  else
    SIGNAL_CLI_RESTORE_ABSENT_LINK="true"
  fi
  if ! is_true "$UPGRADE_NO_RESTART"; then
    capture_signal_cli_service_state
  fi

  download_signal_cli_artifact
  verify_signal_cli_artifact
  install_signal_cli_from_artifact

  new_target="$(readlink -f "$LOCAL_BIN_DIR/signal-cli" 2>/dev/null || true)"

  if ! is_true "$UPGRADE_NO_RESTART"; then
    SIGNAL_CLI_SERVICE_STATE_MUTATED="true"
    run_cmd maybe_systemctl restart signal-cli
    health_check
  fi

  previous_target_for_summary="$SIGNAL_CLI_PREVIOUS_TARGET"
  commit_signal_cli_transaction

  cat <<EOF

Upgrade complete.
Previous binary: ${previous_target_for_summary:-unknown}
New binary:      ${new_target:-unknown}
EOF
  print_upgrade_rollback_hint "$previous_target_for_summary"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main_upgrade "$@"
fi
