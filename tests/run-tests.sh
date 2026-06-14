#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"
TMP_DIR="$(mktemp -d)"
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '[pass] %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '[fail] %s\n' "$1" >&2
  if [[ -f "$TMP_DIR/stdout" ]]; then
    sed 's/^/[stdout] /' "$TMP_DIR/stdout" >&2
  fi
  if [[ -f "$TMP_DIR/stderr" ]]; then
    sed 's/^/[stderr] /' "$TMP_DIR/stderr" >&2
  fi
}

expect_success() {
  local name="$1"
  shift
  : > "$TMP_DIR/stdout"
  : > "$TMP_DIR/stderr"
  if "$@" > "$TMP_DIR/stdout" 2> "$TMP_DIR/stderr"; then
    pass "$name"
  else
    fail "$name"
  fi
}

expect_failure() {
  local name="$1"
  shift
  : > "$TMP_DIR/stdout"
  : > "$TMP_DIR/stderr"
  if "$@" > "$TMP_DIR/stdout" 2> "$TMP_DIR/stderr"; then
    fail "$name"
  else
    pass "$name"
  fi
}

expect_output_contains() {
  local name="$1"
  local needle="$2"
  shift 2
  : > "$TMP_DIR/stdout"
  : > "$TMP_DIR/stderr"
  if "$@" > "$TMP_DIR/stdout" 2> "$TMP_DIR/stderr" && grep -Fq "$needle" "$TMP_DIR/stdout"; then
    pass "$name"
  else
    fail "$name"
  fi
}

expect_output_not_contains() {
  local name="$1"
  local needle="$2"
  shift 2
  : > "$TMP_DIR/stdout"
  : > "$TMP_DIR/stderr"
  if "$@" > "$TMP_DIR/stdout" 2> "$TMP_DIR/stderr" && ! grep -Fxq "$needle" "$TMP_DIR/stdout"; then
    pass "$name"
  else
    fail "$name"
  fi
}

expect_success "help exits successfully" "$INSTALLER" --help
expect_failure "invalid account fails" "$INSTALLER" --dry-run --account 316123 --version 0.14.5
expect_failure "invalid install mode fails" "$INSTALLER" --dry-run --install-mode nope --version 0.14.5
expect_failure "port zero fails" "$INSTALLER" --dry-run --bind 127.0.0.1:0 --version 0.14.5
expect_failure "port over range fails" "$INSTALLER" --dry-run --bind 127.0.0.1:65536 --version 0.14.5
expect_failure "non-numeric port fails" "$INSTALLER" --dry-run --bind localhost:abc --version 0.14.5
expect_failure "public bind fails without opt-in" "$INSTALLER" --dry-run --bind 0.0.0.0:8080 --version 0.14.5
expect_success "public bind succeeds with opt-in in dry-run" "$INSTALLER" --dry-run --allow-public-bind --bind 0.0.0.0:8080 --version 0.14.5
expect_output_not_contains "no-ufw excludes ufw package" "  ufw" "$INSTALLER" --dry-run --no-ufw --version 0.14.5
expect_output_not_contains "no-fail2ban excludes fail2ban package" "  fail2ban" "$INSTALLER" --dry-run --no-fail2ban --version 0.14.5
expect_failure "native mode fails on non-x86 arch" env TEST_UNAME_M=aarch64 "$INSTALLER" --dry-run --install-mode native --version 0.14.5
expect_success "uninstall dry-run preserves data by default" "$ROOT_DIR/scripts/uninstall.sh" --dry-run
expect_success "uninstall purge-data dry-run does not prompt" "$ROOT_DIR/scripts/uninstall.sh" --dry-run --purge-data

expect_success "sha256 verification accepts correct digest" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  file="$(mktemp)"
  printf test-data > "$file"
  digest="$(sha256_file "$file")"
  verify_sha256 "$file" "$digest" >/dev/null
' bash "$ROOT_DIR"

expect_failure "sha256 verification rejects mismatch" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  file="$(mktemp)"
  printf test-data > "$file"
  verify_sha256 "$file" 0000000000000000000000000000000000000000000000000000000000000000 >/dev/null
' bash "$ROOT_DIR"

expect_failure "verification none requires explicit allow flag" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  VERIFY_MODE=none
  ALLOW_UNVERIFIED_DOWNLOAD=false
  SIGNAL_CLI_ASSET=fixture.tar.gz
  SIGNAL_CLI_ARTIFACT=/tmp/fixture.tar.gz
  verify_signal_cli_artifact
' bash "$ROOT_DIR"

expect_success "checksum-url verification finds matching asset" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  work_dir="$(mktemp -d)"
  SIGNAL_CLI_ASSET=fixture.tar.gz
  SIGNAL_CLI_ARTIFACT="$work_dir/$SIGNAL_CLI_ASSET"
  SIGNAL_CLI_TMPDIR="$work_dir"
  VERIFY_MODE=sha256
  TEST_MODE=true
  printf fixture > "$SIGNAL_CLI_ARTIFACT"
  digest="$(sha256_file "$SIGNAL_CLI_ARTIFACT")"
  printf "%s  %s\n" "$digest" "$SIGNAL_CLI_ASSET" > "$work_dir/checksums.txt"
  CHECKSUM_URL="file://$work_dir/checksums.txt"
  verify_signal_cli_artifact >/dev/null
' bash "$ROOT_DIR"

expect_success "systemd render keeps hardening directives" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  rendered="$(render_systemd_service)"
  grep -Fq "NoNewPrivileges=true" <<< "$rendered"
  grep -Fq "ProtectSystem=strict" <<< "$rendered"
  grep -Fq "CapabilityBoundingSet=" <<< "$rendered"
  grep -Fq "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX" <<< "$rendered"
' bash "$ROOT_DIR"

printf '\nTests passed: %d\n' "$PASS_COUNT"
if [[ "$FAIL_COUNT" -ne 0 ]]; then
  printf 'Tests failed: %d\n' "$FAIL_COUNT" >&2
  exit 1
fi
