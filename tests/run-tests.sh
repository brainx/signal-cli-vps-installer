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
  : >"$TMP_DIR/stdout"
  : >"$TMP_DIR/stderr"
  if "$@" >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr"; then
    pass "$name"
  else
    fail "$name"
  fi
}

expect_failure() {
  local name="$1"
  shift
  : >"$TMP_DIR/stdout"
  : >"$TMP_DIR/stderr"
  if "$@" >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr"; then
    fail "$name"
  else
    pass "$name"
  fi
}

expect_output_contains() {
  local name="$1"
  local needle="$2"
  shift 2
  : >"$TMP_DIR/stdout"
  : >"$TMP_DIR/stderr"
  if "$@" >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr" && { grep -Fq "$needle" "$TMP_DIR/stdout" || grep -Fq "$needle" "$TMP_DIR/stderr"; }; then
    pass "$name"
  else
    fail "$name"
  fi
}

expect_output_not_contains() {
  local name="$1"
  local needle="$2"
  shift 2
  : >"$TMP_DIR/stdout"
  : >"$TMP_DIR/stderr"
  if "$@" >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr" && ! grep -Fxq "$needle" "$TMP_DIR/stdout" && ! grep -Fxq "$needle" "$TMP_DIR/stderr"; then
    pass "$name"
  else
    fail "$name"
  fi
}

expect_output_not_contains_text() {
  local name="$1"
  local needle="$2"
  shift 2
  : >"$TMP_DIR/stdout"
  : >"$TMP_DIR/stderr"
  if "$@" >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr" && ! grep -Fq "$needle" "$TMP_DIR/stdout" && ! grep -Fq "$needle" "$TMP_DIR/stderr"; then
    pass "$name"
  else
    fail "$name"
  fi
}

file_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

make_fixture_archives() {
  NATIVE_FIXTURE_ARCHIVE="$TMP_DIR/signal-cli-0.0.0-Linux-native.tar.gz"
  JVM_FIXTURE_ARCHIVE="$TMP_DIR/signal-cli-0.0.0.tar.gz"

  tar -czf "$NATIVE_FIXTURE_ARCHIVE" -C "$ROOT_DIR/tests/fixtures/native" signal-cli-0.0.0-Linux-native
  tar -czf "$JVM_FIXTURE_ARCHIVE" -C "$ROOT_DIR/tests/fixtures/jvm" signal-cli-0.0.0
}

make_fixture_archives

expect_success "help exits successfully" "$INSTALLER" --help
expect_failure "invalid account fails" "$INSTALLER" --dry-run --account 316123 --version 0.14.5
expect_failure "invalid install mode fails" "$INSTALLER" --dry-run --install-mode nope --version 0.14.5
expect_failure "port zero fails" "$INSTALLER" --dry-run --bind 127.0.0.1:0 --version 0.14.5
expect_failure "port over range fails" "$INSTALLER" --dry-run --bind 127.0.0.1:65536 --version 0.14.5
expect_failure "non-numeric port fails" "$INSTALLER" --dry-run --bind localhost:abc --version 0.14.5
expect_failure "public bind fails without opt-in" "$INSTALLER" --dry-run --bind 0.0.0.0:8080 --version 0.14.5
expect_success "public bind succeeds with opt-in in dry-run" "$INSTALLER" --dry-run --allow-public-bind --bind 0.0.0.0:8080 --version 0.14.5
expect_failure "bind rejects shell semicolon" "$INSTALLER" --dry-run --allow-public-bind --bind '127.0.0.1:8080;id' --version 0.14.5
expect_failure "bind rejects command substitution" "$INSTALLER" --dry-run --allow-public-bind --bind '$(id):8080' --version 0.14.5
expect_failure "bind rejects quoted host" "$INSTALLER" --dry-run --allow-public-bind --bind '"host":8080' --version 0.14.5
expect_failure "bind rejects dollar expansion" "$INSTALLER" --dry-run --allow-public-bind --bind '$HOST:8080' --version 0.14.5
expect_success "bind accepts private IPv4 with opt-in" "$INSTALLER" --dry-run --allow-public-bind --bind 10.0.0.5:8080 --version 0.14.5
expect_success "bind accepts hostname with opt-in" "$INSTALLER" --dry-run --allow-public-bind --bind signal.internal:8080 --version 0.14.5
expect_success "bind accepts IPv6 localhost" "$INSTALLER" --dry-run --bind '[::1]:8080' --version 0.14.5
expect_failure "device name rejects newline" "$INSTALLER" --dry-run --device-name $'bad\nname' --version 0.14.5
expect_output_contains "dry-run latest prints bootstrap plan" "ensure bootstrap packages" "$INSTALLER" --dry-run --account +31612345678
expect_output_not_contains "no-ufw excludes ufw package" "  ufw" "$INSTALLER" --dry-run --no-ufw --version 0.14.5
expect_output_not_contains "no-fail2ban excludes fail2ban package" "  fail2ban" "$INSTALLER" --dry-run --no-fail2ban --version 0.14.5
expect_failure "native mode fails on non-x86 arch" env TEST_UNAME_M=aarch64 "$INSTALLER" --dry-run --install-mode native --version 0.14.5
expect_success "uninstall dry-run preserves data by default" "$ROOT_DIR/scripts/uninstall.sh" --dry-run
expect_success "uninstall purge-data dry-run does not prompt" "$ROOT_DIR/scripts/uninstall.sh" --dry-run --purge-data
expect_success "upgrade dry-run works" env TEST_UNAME_M=x86_64 "$ROOT_DIR/scripts/upgrade-signal-cli.sh" --dry-run --version 0.0.0 --install-mode native --sha256 0000000000000000000000000000000000000000000000000000000000000000
expect_output_not_contains_text "upgrade dry-run does not prompt for Signal account" "Signal account number" env TEST_UNAME_M=x86_64 "$ROOT_DIR/scripts/upgrade-signal-cli.sh" --dry-run --version 0.0.0 --install-mode native --sha256 0000000000000000000000000000000000000000000000000000000000000000
expect_output_not_contains_text "upgrade dry-run does not prompt for linked device name" "Linked device name" env TEST_UNAME_M=x86_64 "$ROOT_DIR/scripts/upgrade-signal-cli.sh" --dry-run --version 0.0.0 --install-mode native --sha256 0000000000000000000000000000000000000000000000000000000000000000
expect_output_not_contains_text "upgrade dry-run does not ask SSH hardening" "Disable SSH password login" env TEST_UNAME_M=x86_64 "$ROOT_DIR/scripts/upgrade-signal-cli.sh" --dry-run --version 0.0.0 --install-mode native --sha256 0000000000000000000000000000000000000000000000000000000000000000
expect_success "rollback dry-run works" "$ROOT_DIR/scripts/rollback-signal-cli.sh" --dry-run --to-version 0.0.0 --install-mode native

expect_success "fixture native install writes binary and symlink" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  artifact="$2"
  digest="$3"
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" ./install.sh \
    --no-link \
    --no-ufw \
    --no-fail2ban \
    --no-sysctl-hardening \
    --no-unattended-upgrades \
    --no-ssh-hardening \
    --install-mode native \
    --version 0.0.0 \
    --artifact-file "$artifact" \
    --sha256 "$digest" >/dev/null
  test -x "$root/opt/signal-cli-native-0.0.0/signal-cli"
  test -L "$root/usr/local/bin/signal-cli"
  test -f "$root/etc/default/signal-cli"
  test -f "$root/etc/systemd/system/signal-cli.service"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "fixture jvm install writes launcher and symlink" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  artifact="$2"
  digest="$3"
  TEST_MODE=true INSTALL_ROOT="$root" ./install.sh \
    --no-link \
    --no-ufw \
    --no-fail2ban \
    --no-sysctl-hardening \
    --no-unattended-upgrades \
    --no-ssh-hardening \
    --install-mode jvm \
    --version 0.0.0 \
    --artifact-file "$artifact" \
    --sha256 "$digest" >/dev/null
  test -x "$root/opt/signal-cli-0.0.0/bin/signal-cli"
  test -L "$root/usr/local/bin/signal-cli"
  test -f "$root/etc/default/signal-cli"
  test -f "$root/etc/systemd/system/signal-cli.service"
' bash "$ROOT_DIR" "$JVM_FIXTURE_ARCHIVE" "$(file_sha256 "$JVM_FIXTURE_ARCHIVE")"

expect_success "fixture upgrade is binary-only and non-interactive" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  artifact="$2"
  digest="$3"
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" scripts/upgrade-signal-cli.sh \
    --no-restart \
    --install-mode native \
    --version 0.0.0 \
    --artifact-file "$artifact" \
    --sha256 "$digest" >/dev/null
  test -x "$root/opt/signal-cli-native-0.0.0/signal-cli"
  test -L "$root/usr/local/bin/signal-cli"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_output_contains "test-mode skips Signal linking" "[test-mode] skip Signal device linking" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  artifact="$2"
  digest="$3"
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" ./install.sh \
    --account +31612345678 \
    --no-ufw \
    --no-fail2ban \
    --no-sysctl-hardening \
    --no-unattended-upgrades \
    --no-ssh-hardening \
    --install-mode native \
    --version 0.0.0 \
    --artifact-file "$artifact" \
    --sha256 "$digest"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_output_contains "test-mode skips initial receive" "[test-mode] skip initial receive" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  artifact="$2"
  digest="$3"
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" ./install.sh \
    --account +31612345678 \
    --no-ufw \
    --no-fail2ban \
    --no-sysctl-hardening \
    --no-unattended-upgrades \
    --no-ssh-hardening \
    --install-mode native \
    --version 0.0.0 \
    --artifact-file "$artifact" \
    --sha256 "$digest"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "link QR renderer uses only Signal link URI" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh

  work_dir="$(mktemp -d)"
  trap '\''rm -rf "$work_dir"'\'' EXIT
  fake_bin="$work_dir/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/qrencode" <<'\''EOF'\''
#!/usr/bin/env bash
set -Eeuo pipefail
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    -t|--level)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
payload="$(cat)"
printf "%s\n" "$payload" >> "$QR_PAYLOAD_LOG"
if [[ -n "$output" ]]; then
  printf "%s\n" "$payload" > "$output"
fi
EOF
  chmod +x "$fake_bin/qrencode"

  export PATH="$fake_bin:$PATH"
  export QR_PAYLOAD_LOG="$work_dir/payloads"
  link_uri="sgnl://linkdevice?uuid=abc123&pub_key=def456"
  {
    printf "Open Signal on your phone\n"
    printf "%s\n" "$link_uri"
    printf "Waiting for scan\n"
  } | render_signal_link_qr "$work_dir/link.png" >/dev/null

  test "$(wc -l < "$QR_PAYLOAD_LOG" | tr -d " ")" = "2"
  test "$(sort -u "$QR_PAYLOAD_LOG")" = "$link_uri"
  test "$(cat "$work_dir/link.png")" = "$link_uri"
' bash "$ROOT_DIR"

expect_success "fixture rollback switches symlink" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  mkdir -p "$root/opt/signal-cli-native-0.0.0" "$root/usr/local/bin"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$root/opt/signal-cli-native-0.0.0/signal-cli"
  chmod +x "$root/opt/signal-cli-native-0.0.0/signal-cli"
  TEST_MODE=true INSTALL_ROOT="$root" scripts/rollback-signal-cli.sh \
    --no-restart \
    --to-version 0.0.0 \
    --install-mode native >/dev/null
  test -L "$root/usr/local/bin/signal-cli"
' bash "$ROOT_DIR"

expect_failure "rollback refuses missing target" env TEST_MODE=true INSTALL_ROOT="$(mktemp -d)" "$ROOT_DIR/scripts/rollback-signal-cli.sh" --no-restart --to-version 9.9.9 --install-mode native

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
  source_dir="$(mktemp -d)"
  SIGNAL_CLI_ASSET=fixture.tar.gz
  SIGNAL_CLI_ARTIFACT="$work_dir/$SIGNAL_CLI_ASSET"
  SIGNAL_CLI_TMPDIR="$work_dir"
  VERIFY_MODE=sha256
  TEST_MODE=true
  printf fixture > "$SIGNAL_CLI_ARTIFACT"
  digest="$(sha256_file "$SIGNAL_CLI_ARTIFACT")"
  printf "%s  %s\n" "$digest" "$SIGNAL_CLI_ASSET" > "$source_dir/checksums.txt"
  CHECKSUM_URL="file://$source_dir/checksums.txt"
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

expect_success "systemd unit verifies when systemd-analyze exists" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  work_dir="$(mktemp -d)"
  DATA_DIR="$work_dir/data"
  CONFIG_FILE="$work_dir/signal-cli.env"
  WRAPPER_FILE="$work_dir/signal-cli-daemon-start"
  OPT_DIR="$work_dir/opt"
  LOCAL_BIN_DIR="$work_dir/bin"
  mkdir -p "$DATA_DIR" "$OPT_DIR" "$LOCAL_BIN_DIR"
  printf "#!/usr/bin/env bash\nexit 0\n" > "$WRAPPER_FILE"
  chmod +x "$WRAPPER_FILE"
  rendered="$work_dir/signal-cli.service"
  render_systemd_service > "$rendered"
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "$rendered"
  fi
' bash "$ROOT_DIR"

printf '\nTests passed: %d\n' "$PASS_COUNT"
if [[ "$FAIL_COUNT" -ne 0 ]]; then
  printf 'Tests failed: %d\n' "$FAIL_COUNT" >&2
  exit 1
fi
