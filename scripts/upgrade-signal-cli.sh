#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../install.sh
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
  Link path: $LOCAL_BIN_DIR/signal-cli
EOF
}

main_upgrade() {
  trap on_error ERR
  trap cleanup EXIT

  parse_upgrade_args "$@"
  parse_args "${INSTALL_ARGS[@]}"
  require_root "${INSTALL_ARGS[@]}"
  validate_inputs
  choose_install_mode
  preflight_checks
  install_bootstrap_packages
  resolve_signal_cli_version
  build_signal_cli_asset_url
  print_upgrade_plan

  if is_dry_run; then
    return 0
  fi

  local previous_target new_target
  previous_target="$(readlink -f "$LOCAL_BIN_DIR/signal-cli" 2>/dev/null || true)"

  download_signal_cli_artifact
  verify_signal_cli_artifact
  install_signal_cli_from_artifact

  new_target="$(readlink -f "$LOCAL_BIN_DIR/signal-cli" 2>/dev/null || true)"

  if ! is_true "$UPGRADE_NO_RESTART"; then
    run_cmd maybe_systemctl restart signal-cli
    health_check
  fi

  cat <<EOF

Upgrade complete.
Previous binary: ${previous_target:-unknown}
New binary:      ${new_target:-unknown}
Rollback hint:   scripts/rollback-signal-cli.sh --to-version PREVIOUS_VERSION --install-mode $INSTALL_MODE
EOF
}

main_upgrade "$@"
