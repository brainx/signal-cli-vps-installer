#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"
TMP_DIR="$(mktemp -d)"
export TMPDIR="$TMP_DIR"
REAL_MKTEMP="$(command -v mktemp)"
TEST_BIN_DIR="$TMP_DIR/test-bin"
mkdir -p "$TEST_BIN_DIR"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'if [[ "$#" -eq 0 ]]; then' \
  '  exec "$REAL_MKTEMP" "$TMPDIR/tmp.XXXXXXXXXX"' \
  'fi' \
  'if [[ "$#" -eq 1 && "$1" == "-d" ]]; then' \
  '  exec "$REAL_MKTEMP" -d "$TMPDIR/tmp.XXXXXXXXXX"' \
  'fi' \
  'exec "$REAL_MKTEMP" "$@"' >"$TEST_BIN_DIR/mktemp"
chmod +x "$TEST_BIN_DIR/mktemp"
export REAL_MKTEMP
export PATH="$TEST_BIN_DIR:$PATH"

# Ubuntu exercises util-linux flock directly. macOS lacks the command, so the
# suite provides a test-only CLI shim backed by the same kernel flock(2) API.
if ! command -v flock >/dev/null 2>&1; then
  cat >"$TEST_BIN_DIR/flock" <<'EOF'
#!/usr/bin/env perl
use strict;
use warnings;
use Fcntl qw(LOCK_EX LOCK_NB LOCK_UN);

my ($operation, $fd) = @ARGV;
exit 64 unless defined $operation && defined $fd && $fd =~ /^[0-9]+$/;
open(my $handle, ">&=$fd") or exit 64;

if ($operation eq "-n") {
  exit(flock($handle, LOCK_EX | LOCK_NB) ? 0 : 1);
}
if ($operation eq "-u") {
  exit(flock($handle, LOCK_UN) ? 0 : 1);
}
exit 64;
EOF
  chmod +x "$TEST_BIN_DIR/flock"
fi

LIFECYCLE_LOCK_HOLDER="$TEST_BIN_DIR/lifecycle-lock-holder"
cat >"$LIFECYCLE_LOCK_HOLDER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
installer="$1"
install_root="$2"
ready_file="$3"
release_fifo="$4"
backend="${5:-flock}"

export TEST_MODE=true INSTALL_ROOT="$install_root"
if [[ "$backend" == "mkdir" ]]; then
  export SIGNAL_CLI_TEST_LOCK_BACKEND=mkdir
else
  unset SIGNAL_CLI_TEST_LOCK_BACKEND || true
fi

# shellcheck source=install.sh
source "$installer"
trap cleanup EXIT
acquire_lifecycle_lock
: >"$ready_file"
IFS= read -r _ <"$release_fifo"
EOF
chmod +x "$LIFECYCLE_LOCK_HOLDER"
export LIFECYCLE_LOCK_HOLDER
LIFECYCLE_LOCK_PROBE="$TEST_BIN_DIR/lifecycle-lock-probe"
cat >"$LIFECYCLE_LOCK_PROBE" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
installer="$1"
install_root="$2"
backend="${3:-flock}"

export TEST_MODE=true INSTALL_ROOT="$install_root"
if [[ "$backend" == "mkdir" ]]; then
  export SIGNAL_CLI_TEST_LOCK_BACKEND=mkdir
else
  unset SIGNAL_CLI_TEST_LOCK_BACKEND || true
fi

# shellcheck source=install.sh
source "$installer"
trap cleanup EXIT
acquire_lifecycle_lock
EOF
chmod +x "$LIFECYCLE_LOCK_PROBE"
export LIFECYCLE_LOCK_PROBE
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

expect_success "nested test temp allocations stay inside suite temp directory" bash -c '
  set -Eeuo pipefail
  nested_tmp="$(mktemp -d)"
  trap '\''rm -rf "$nested_tmp"'\'' EXIT
  case "$nested_tmp" in
    "$1"/*) ;;
    *) exit 1 ;;
  esac
' bash "$TMP_DIR"

make_fixture_archives() {
  NATIVE_FIXTURE_ARCHIVE="$TMP_DIR/signal-cli-0.0.0-Linux-native.tar.gz"
  JVM_FIXTURE_ARCHIVE="$TMP_DIR/signal-cli-0.0.0.tar.gz"
  BROKEN_NATIVE_FIXTURE_ARCHIVE="$TMP_DIR/signal-cli-0.0.1-Linux-native.tar.gz"
  REPLACEMENT_NATIVE_FIXTURE_ARCHIVE="$TMP_DIR/replacement-signal-cli-0.0.0-Linux-native.tar.gz"
  MALFORMED_JVM_FIXTURE_ARCHIVE="$TMP_DIR/malformed-signal-cli-0.0.0.tar.gz"

  tar -czf "$NATIVE_FIXTURE_ARCHIVE" -C "$ROOT_DIR/tests/fixtures/native" signal-cli-0.0.0-Linux-native
  tar -czf "$JVM_FIXTURE_ARCHIVE" -C "$ROOT_DIR/tests/fixtures/jvm" signal-cli-0.0.0

  mkdir -p "$TMP_DIR/broken-native/signal-cli-0.0.1-Linux-native"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ "${1:-}" == "--version" ]]; then' \
    '  exit 42' \
    'fi' \
    'exit 0' >"$TMP_DIR/broken-native/signal-cli-0.0.1-Linux-native/signal-cli"
  chmod +x "$TMP_DIR/broken-native/signal-cli-0.0.1-Linux-native/signal-cli"
  tar -czf "$BROKEN_NATIVE_FIXTURE_ARCHIVE" -C "$TMP_DIR/broken-native" signal-cli-0.0.1-Linux-native

  mkdir -p "$TMP_DIR/replacement-native/signal-cli-0.0.0-Linux-native"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ "${1:-}" == "--version" ]]; then' \
    '  echo "signal-cli 0.0.0 replacement"' \
    '  exit 0' \
    'fi' \
    'exit 0' >"$TMP_DIR/replacement-native/signal-cli-0.0.0-Linux-native/signal-cli"
  chmod +x "$TMP_DIR/replacement-native/signal-cli-0.0.0-Linux-native/signal-cli"
  tar -czf "$REPLACEMENT_NATIVE_FIXTURE_ARCHIVE" -C "$TMP_DIR/replacement-native" signal-cli-0.0.0-Linux-native

  mkdir -p "$TMP_DIR/malformed-jvm/unexpected/bin"
  cp "$ROOT_DIR/tests/fixtures/jvm/signal-cli-0.0.0/bin/signal-cli" "$TMP_DIR/malformed-jvm/unexpected/bin/signal-cli"
  tar -czf "$MALFORMED_JVM_FIXTURE_ARCHIVE" -C "$TMP_DIR/malformed-jvm" unexpected
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
expect_failure "bind rejects invalid IPv4-like host" "$INSTALLER" --dry-run --allow-public-bind --bind 1.2.3.999:8080 --version 0.14.5
expect_failure "bind rejects invalid hostname label" "$INSTALLER" --dry-run --allow-public-bind --bind bad-.example:8080 --version 0.14.5
expect_failure "bind rejects invalid bracketed IPv6" "$INSTALLER" --dry-run --allow-public-bind --bind '[::::]:8080' --version 0.14.5
expect_failure "bind rejects leading single-colon IPv6" "$INSTALLER" --dry-run --allow-public-bind --bind '[:1:2:3:4:5:6:7:8]:8080' --version 0.14.5
expect_failure "bind rejects trailing single-colon IPv6" "$INSTALLER" --dry-run --allow-public-bind --bind '[1:2:3:4:5:6:7:8:]:8080' --version 0.14.5
expect_success "bind accepts private IPv4 with opt-in" "$INSTALLER" --dry-run --allow-public-bind --bind 10.0.0.5:8080 --version 0.14.5
expect_success "bind accepts hostname with opt-in" "$INSTALLER" --dry-run --allow-public-bind --bind signal.internal:8080 --version 0.14.5
expect_success "bind accepts IPv6 localhost" "$INSTALLER" --dry-run --bind '[::1]:8080' --version 0.14.5
expect_failure "device name rejects newline" "$INSTALLER" --dry-run --device-name $'bad\nname' --version 0.14.5
expect_success "detached installer prompts fall back without tty errors" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  output="$root/install-output"
  if command -v setsid >/dev/null 2>&1; then
    detach=(setsid)
  else
    detach=(perl -MPOSIX -e "POSIX::setsid(); exec @ARGV")
  fi

  set +e
  "${detach[@]}" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    source ./install.sh
    DRY_RUN=false
    TEST_MODE=false
    SIGNAL_ACCOUNT=+31612345678
    DEVICE_NAME=detached-test
    VERSION=0.0.0
    VERIFY_MODE=none
    ALLOW_UNVERIFIED_DOWNLOAD=true
    SSH_HARDENING=ask
    validate_inputs
    test "$SSH_HARDENING" = false
  '\'' bash "$1" </dev/null >"$output" 2>&1
  validate_rc=$?
  set -e

  test "$validate_rc" -eq 0
  ! grep -Fq "/dev/tty" "$output"
' bash "$ROOT_DIR"
expect_output_contains "dry-run latest prints bootstrap plan" "ensure bootstrap packages" "$INSTALLER" --dry-run --account +31612345678
expect_output_contains "bootstrap plan includes util-linux for flock" "util-linux" "$INSTALLER" --dry-run --account +31612345678
expect_output_not_contains "no-ufw excludes ufw package" "  ufw" "$INSTALLER" --dry-run --no-ufw --version 0.14.5
expect_output_not_contains "no-fail2ban excludes fail2ban package" "  fail2ban" "$INSTALLER" --dry-run --no-fail2ban --version 0.14.5
expect_failure "native mode fails on non-x86 arch" env TEST_UNAME_M=aarch64 "$INSTALLER" --dry-run --install-mode native --version 0.14.5
expect_success "uninstall dry-run preserves data by default" "$ROOT_DIR/scripts/uninstall.sh" --dry-run
expect_success "uninstall purge-data dry-run does not prompt" "$ROOT_DIR/scripts/uninstall.sh" --dry-run --purge-data
expect_output_contains "uninstall dry-run respects install root" "/tmp/test-root/var/lib/signal-cli" env TEST_MODE=true INSTALL_ROOT=/tmp/test-root "$ROOT_DIR/scripts/uninstall.sh" --dry-run --purge-data --purge-binaries --purge-hardening
expect_success "uninstall preserves files while service remains active" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  fake_bin="$root/fake-bin"
  service_file="$root/etc/systemd/system/signal-cli.service"
  wrapper_file="$root/usr/local/sbin/signal-cli-daemon-start"
  config_file="$root/etc/default/signal-cli"
  mkdir -p "$fake_bin" "$(dirname "$service_file")" "$(dirname "$wrapper_file")" "$(dirname "$config_file")"
  printf "service\n" >"$service_file"
  printf "wrapper\n" >"$wrapper_file"
  printf "config\n" >"$config_file"
  cat >"$fake_bin/systemctl" <<'\''EOF'\''
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  disable) exit 0 ;;
  is-active) printf "active\n"; exit 0 ;;
  show) printf "loaded\n"; exit 0 ;;
  daemon-reload) exit 0 ;;
  *) exit 64 ;;
esac
EOF
  chmod +x "$fake_bin/systemctl"
  output="$root/uninstall-output"

  if PATH="$fake_bin:$PATH" TEST_MODE=true TEST_RUN_SYSTEMCTL=true INSTALL_ROOT="$root" \
    scripts/uninstall.sh >"$output" 2>&1; then
    exit 1
  fi

  grep -Fq "service is still active" "$output"
  test -f "$service_file"
  test -f "$wrapper_file"
  test -f "$config_file"
' bash "$ROOT_DIR"
expect_success "uninstall preserves files when service state is unknown" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  fake_bin="$root/fake-bin"
  service_file="$root/etc/systemd/system/signal-cli.service"
  wrapper_file="$root/usr/local/sbin/signal-cli-daemon-start"
  config_file="$root/etc/default/signal-cli"
  mkdir -p "$fake_bin" "$(dirname "$service_file")" "$(dirname "$wrapper_file")" "$(dirname "$config_file")"
  printf "service\n" >"$service_file"
  printf "wrapper\n" >"$wrapper_file"
  printf "config\n" >"$config_file"
  cat >"$fake_bin/systemctl" <<'\''EOF'\''
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  disable) exit 23 ;;
  is-active) exit 125 ;;
  show) printf "loaded\n"; exit 0 ;;
  daemon-reload) exit 0 ;;
  *) exit 64 ;;
esac
EOF
  chmod +x "$fake_bin/systemctl"

  if PATH="$fake_bin:$PATH" TEST_MODE=true TEST_RUN_SYSTEMCTL=true INSTALL_ROOT="$root" \
    scripts/uninstall.sh >/dev/null 2>&1; then
    exit 1
  fi

  test -f "$service_file"
  test -f "$wrapper_file"
  test -f "$config_file"
' bash "$ROOT_DIR"
expect_success "uninstall proceeds when systemd reports unit not found" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  fake_bin="$root/fake-bin"
  service_file="$root/etc/systemd/system/signal-cli.service"
  wrapper_file="$root/usr/local/sbin/signal-cli-daemon-start"
  config_file="$root/etc/default/signal-cli"
  mkdir -p "$fake_bin" "$(dirname "$service_file")" "$(dirname "$wrapper_file")" "$(dirname "$config_file")"
  printf "service\n" >"$service_file"
  printf "wrapper\n" >"$wrapper_file"
  printf "config\n" >"$config_file"
  cat >"$fake_bin/systemctl" <<'\''EOF'\''
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  disable) exit 5 ;;
  is-active) printf "unknown\n"; exit 4 ;;
  show) printf "not-found\n"; exit 0 ;;
  daemon-reload) exit 0 ;;
  *) exit 64 ;;
esac
EOF
  chmod +x "$fake_bin/systemctl"

  PATH="$fake_bin:$PATH" TEST_MODE=true TEST_RUN_SYSTEMCTL=true INSTALL_ROOT="$root" \
    scripts/uninstall.sh >/dev/null

  test ! -e "$service_file"
  test ! -e "$wrapper_file"
  test ! -e "$config_file"
' bash "$ROOT_DIR"
expect_success "uninstall proceeds after a failed stop reports inactive" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  fake_bin="$root/fake-bin"
  service_file="$root/etc/systemd/system/signal-cli.service"
  mkdir -p "$fake_bin" "$(dirname "$service_file")"
  printf "service\n" >"$service_file"
  cat >"$fake_bin/systemctl" <<'\''EOF'\''
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  disable) exit 23 ;;
  is-active) printf "inactive\n"; exit 3 ;;
  daemon-reload) exit 0 ;;
  *) exit 64 ;;
esac
EOF
  chmod +x "$fake_bin/systemctl"

  PATH="$fake_bin:$PATH" TEST_MODE=true TEST_RUN_SYSTEMCTL=true INSTALL_ROOT="$root" \
    scripts/uninstall.sh >/dev/null

  test ! -e "$service_file"
' bash "$ROOT_DIR"
expect_success "uninstall propagates daemon-reload failure" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  fake_bin="$root/fake-bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/systemctl" <<'\''EOF'\''
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  disable) exit 0 ;;
  is-active) printf "inactive\n"; exit 3 ;;
  daemon-reload) exit 31 ;;
  *) exit 64 ;;
esac
EOF
  chmod +x "$fake_bin/systemctl"

  if PATH="$fake_bin:$PATH" TEST_MODE=true TEST_RUN_SYSTEMCTL=true INSTALL_ROOT="$root" \
    scripts/uninstall.sh >/dev/null 2>&1; then
    exit 1
  fi
' bash "$ROOT_DIR"
expect_success "binary purge preserves unmarked paths without executing candidates" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  native_probe="$root/native-executed"
  jvm_probe="$root/jvm-executed"
  native_dir="$root/opt/signal-cli-native-0.0.0"
  jvm_dir="$root/opt/signal-cli-0.0.1"
  custom_dir="$root/opt/signal-cli-customer-backup"
  invalid_native_dir="$root/opt/signal-cli-native-not-an-installed-version"
  incomplete_dir="$root/opt/signal-cli-9.9.9"
  mismatched_dir="$root/opt/signal-cli-1.2.3"
  bare_version_dir="$root/opt/signal-cli-native-2.3.4"
  active_binary="$root/usr/local/bin/signal-cli"
  mkdir -p "$native_dir" "$jvm_dir/bin" "$custom_dir" "$invalid_native_dir" "$incomplete_dir" "$mismatched_dir/bin" "$bare_version_dir" "$(dirname "$active_binary")"
  printf "#!/usr/bin/env bash\ntouch %q\nprintf \"signal-cli 0.0.0\\n\"\n" "$native_probe" >"$native_dir/signal-cli"
  printf "#!/usr/bin/env bash\ntouch %q\nprintf \"signal-cli 0.0.1\\n\"\n" "$jvm_probe" >"$jvm_dir/bin/signal-cli"
  printf "#!/usr/bin/env bash\nprintf \"signal-cli 9.9.9\\n\"\n" >"$mismatched_dir/bin/signal-cli"
  printf "#!/usr/bin/env bash\nprintf \"2.3.4\\n\"\n" >"$bare_version_dir/signal-cli"
  chmod +x "$native_dir/signal-cli" "$jvm_dir/bin/signal-cli" "$mismatched_dir/bin/signal-cli" "$bare_version_dir/signal-cli"
  printf "keep\n" >"$custom_dir/marker"
  printf "keep\n" >"$invalid_native_dir/marker"
  printf "keep\n" >"$incomplete_dir/marker"
  printf "administrator-owned\n" >"$active_binary"

  TEST_MODE=true INSTALL_ROOT="$root" scripts/uninstall.sh --purge-binaries >/dev/null

  test ! -e "$native_probe"
  test ! -e "$jvm_probe"
  test -x "$native_dir/signal-cli"
  test -x "$jvm_dir/bin/signal-cli"
  test -f "$custom_dir/marker"
  test -f "$invalid_native_dir/marker"
  test -f "$incomplete_dir/marker"
  test -x "$mismatched_dir/bin/signal-cli"
  test -x "$bare_version_dir/signal-cli"
  test "$(cat "$active_binary")" = "administrator-owned"
' bash "$ROOT_DIR"
expect_success "binary purge removes a validated managed symlink" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  install_dir="$root/opt/signal-cli-native-0.0.0"
  active_link="$root/usr/local/bin/signal-cli"
  execution_probe="$root/candidate-executed"
  mkdir -p "$install_dir" "$(dirname "$active_link")"
  printf "#!/usr/bin/env bash\ntouch %q\nprintf \"signal-cli 0.0.0\\n\"\n" "$execution_probe" >"$install_dir/signal-cli"
  chmod +x "$install_dir/signal-cli"
  printf "signal-cli-install-manifest-v1\nmode=native\nversion=0.0.0\n" >"$install_dir/.signal-cli-install-manifest"
  chmod 0444 "$install_dir/.signal-cli-install-manifest"
  ln -s "$install_dir/signal-cli" "$active_link"

  TEST_MODE=true INSTALL_ROOT="$root" scripts/uninstall.sh --purge-binaries >/dev/null

  test ! -L "$active_link"
  test ! -e "$install_dir"
  test ! -e "$execution_probe"
' bash "$ROOT_DIR"
expect_success "binary purge removes a relative symlink to a validated managed install" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  install_dir="$root/opt/signal-cli-native-0.0.0"
  active_link="$root/usr/local/bin/signal-cli"
  mkdir -p "$install_dir" "$(dirname "$active_link")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$install_dir/signal-cli"
  chmod 0755 "$install_dir/signal-cli"
  printf "signal-cli-install-manifest-v1\nmode=native\nversion=0.0.0\n" >"$install_dir/.signal-cli-install-manifest"
  chmod 0444 "$install_dir/.signal-cli-install-manifest"
  ln -s "../../../opt/signal-cli-native-0.0.0/signal-cli" "$active_link"

  TEST_MODE=true INSTALL_ROOT="$root" scripts/uninstall.sh --purge-binaries >/dev/null

  test ! -L "$active_link"
  test ! -e "$install_dir"
' bash "$ROOT_DIR"
expect_success "binary purge preserves an active symlink to a nested lookalike layout" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  install_dir="$root/opt/signal-cli-native-outer/nested/signal-cli-native-0.0.0"
  active_link="$root/usr/local/bin/signal-cli"
  mkdir -p "$install_dir" "$(dirname "$active_link")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$install_dir/signal-cli"
  chmod 0755 "$install_dir/signal-cli"
  printf "signal-cli-install-manifest-v1\nmode=native\nversion=0.0.0\n" >"$install_dir/.signal-cli-install-manifest"
  chmod 0444 "$install_dir/.signal-cli-install-manifest"
  ln -s "$install_dir/signal-cli" "$active_link"

  TEST_MODE=true INSTALL_ROOT="$root" scripts/uninstall.sh --purge-binaries >/dev/null 2>&1

  test -L "$active_link"
  test -d "$install_dir"
' bash "$ROOT_DIR"
expect_success "binary purge fails closed before mutation when OPT_DIR is untrusted" bash -c '
  set -Eeuo pipefail
  cd "$1"

  for trust_failure in writable unexpected_owner; do
    root="$(mktemp -d)"
    install_dir="$root/opt/signal-cli-native-0.0.0"
    active_link="$root/usr/local/bin/signal-cli"
    output="$root/purge-output"
    mkdir -p "$install_dir" "$(dirname "$active_link")"
    cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$install_dir/signal-cli"
    chmod 0755 "$install_dir/signal-cli"
    printf "signal-cli-install-manifest-v1\nmode=native\nversion=0.0.0\n" >"$install_dir/.signal-cli-install-manifest"
    chmod 0444 "$install_dir/.signal-cli-install-manifest"
    ln -s "$install_dir/signal-cli" "$active_link"
    if [[ "$trust_failure" == writable ]]; then
      chmod 0777 "$root/opt"
    fi

    set +e
    TEST_MODE=true INSTALL_ROOT="$root" TRUST_FAILURE="$trust_failure" bash -c '\''
      set -Eeuo pipefail
      source scripts/uninstall.sh
      if [[ "$TRUST_FAILURE" == unexpected_owner ]]; then
        path_owner_uid() {
          if [[ "$(readlink -f "$1")" == "$(readlink -f "$OPT_DIR")" ]]; then
            printf "424242\n"
          else
            stat -c %u "$1" 2>/dev/null || stat -f %u "$1"
          fi
        }
      fi
      purge_managed_binaries
    '\'' >"$output" 2>&1
    purge_rc=$?
    set -e

    test "$purge_rc" -ne 0
    grep -Fq "Refusing binary purge because the managed install root is untrusted" "$output"
    test -L "$active_link"
    test -d "$install_dir"
    test -x "$install_dir/signal-cli"
  done
' bash "$ROOT_DIR"
expect_success "binary purge accepts marked installer versions with build metadata" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  version="0.0.0-rc.1+build.7"
  install_dir="$root/opt/signal-cli-native-$version"
  execution_probe="$root/candidate-executed"
  mkdir -p "$install_dir"
  printf "#!/usr/bin/env bash\ntouch %q\nprintf \"signal-cli %s\\n\"\n" "$execution_probe" "$version" >"$install_dir/signal-cli"
  chmod 0755 "$install_dir/signal-cli"
  printf "signal-cli-install-manifest-v1\nmode=native\nversion=%s\n" "$version" >"$install_dir/.signal-cli-install-manifest"
  chmod 0444 "$install_dir/.signal-cli-install-manifest"

  TEST_MODE=true INSTALL_ROOT="$root" scripts/uninstall.sh --purge-binaries >/dev/null

  test ! -e "$install_dir"
  test ! -e "$execution_probe"
' bash "$ROOT_DIR"
expect_success "binary purge preserves tampered managed-install metadata" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  marker_target="$root/external-marker"
  printf "signal-cli-install-manifest-v1\nmode=native\nversion=0.0.1\n" >"$marker_target"
  chmod 0444 "$marker_target"

  make_candidate() {
    local install_dir="$1"
    local version="$2"
    mkdir -p "$install_dir"
    printf "#!/usr/bin/env bash\nprintf \"signal-cli %s\\n\"\n" "$version" >"$install_dir/signal-cli"
    chmod 0755 "$install_dir/signal-cli"
    printf "signal-cli-install-manifest-v1\nmode=native\nversion=%s\n" "$version" >"$install_dir/.signal-cli-install-manifest"
    chmod 0444 "$install_dir/.signal-cli-install-manifest"
  }

  writable_marker="$root/opt/signal-cli-native-0.0.0"
  symlink_marker="$root/opt/signal-cli-native-0.0.1"
  writable_executable="$root/opt/signal-cli-native-0.0.2"
  writable_directory="$root/opt/signal-cli-native-0.0.3"
  bad_content="$root/opt/signal-cli-native-0.0.4"
  make_candidate "$writable_marker" 0.0.0
  make_candidate "$symlink_marker" 0.0.1
  make_candidate "$writable_executable" 0.0.2
  make_candidate "$writable_directory" 0.0.3
  make_candidate "$bad_content" 0.0.4

  chmod 0666 "$writable_marker/.signal-cli-install-manifest"
  rm "$symlink_marker/.signal-cli-install-manifest"
  ln -s "$marker_target" "$symlink_marker/.signal-cli-install-manifest"
  chmod 0775 "$writable_executable/signal-cli"
  chmod 0775 "$writable_directory"
  chmod 0644 "$bad_content/.signal-cli-install-manifest"
  printf "signal-cli-install-manifest-v1\nmode=native\nversion=9.9.9\n" >"$bad_content/.signal-cli-install-manifest"
  chmod 0444 "$bad_content/.signal-cli-install-manifest"

  TEST_MODE=true INSTALL_ROOT="$root" scripts/uninstall.sh --purge-binaries >/dev/null

  test -d "$writable_marker"
  test -d "$symlink_marker"
  test -d "$writable_executable"
  test -d "$writable_directory"
  test -d "$bad_content"
' bash "$ROOT_DIR"
expect_success "occupied lifecycle lock blocks uninstall mutation" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  ready="$root/lock-ready"
  release_fifo="$root/lock-release"
  service_file="$root/etc/systemd/system/signal-cli.service"
  mkdir -p "$(dirname "$service_file")"
  mkfifo "$release_fifo"
  printf "service\n" >"$service_file"

  "$LIFECYCLE_LOCK_HOLDER" "$1/install.sh" "$root" "$ready" "$release_fifo" &
  holder_pid=$!
  cleanup_holder() {
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
  }
  trap cleanup_holder EXIT
  for _ in {1..100}; do
    [[ -e "$ready" ]] && break
    sleep 0.02
  done
  test -e "$ready"

  if TEST_MODE=true INSTALL_ROOT="$root" scripts/uninstall.sh >/dev/null 2>&1; then
    exit 1
  fi

  test -f "$service_file"
  printf "release\n" >"$release_fifo"
  wait "$holder_pid"
  trap - EXIT
' bash "$ROOT_DIR"
expect_success "uninstall releases its lifecycle lock on completion" bash -c '
  set -Eeuo pipefail
  cd "$1"
  for backend in flock mkdir; do
    root="$(mktemp -d)"
    lock_env=()
    if [[ "$backend" == mkdir ]]; then
      lock_env+=(SIGNAL_CLI_TEST_LOCK_BACKEND=mkdir)
    fi

    env TEST_MODE=true INSTALL_ROOT="$root" "${lock_env[@]}" scripts/uninstall.sh >/dev/null
    "$LIFECYCLE_LOCK_PROBE" "$1/install.sh" "$root" "$backend"
  done
' bash "$ROOT_DIR"
expect_success "uninstall releases its lifecycle lock on HUP INT and TERM" bash -c '
  set -Eeuo pipefail
  cd "$1"
  for signal in HUP INT TERM; do
    root="$(mktemp -d)"
    fake_bin="$root/fake-bin"
    mkdir -p "$fake_bin"
    cat >"$fake_bin/systemctl" <<'\''EOF'\''
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  disable)
    printf "seen\n" >"$INSTALL_ROOT/lock-seen"
    kill -s "$TEST_SIGNAL" "$PPID"
    ;;
esac
EOF
    chmod +x "$fake_bin/systemctl"

    set +e
    PATH="$fake_bin:$PATH" TEST_MODE=true TEST_RUN_SYSTEMCTL=true TEST_SIGNAL="$signal" INSTALL_ROOT="$root" \
      scripts/uninstall.sh >/dev/null 2>&1
    uninstall_rc=$?
    set -e

    test "$uninstall_rc" -ne 0
    test -f "$root/lock-seen"
    "$LIFECYCLE_LOCK_PROBE" "$1/install.sh" "$root" flock
  done
' bash "$ROOT_DIR"
expect_success "noninteractive data purge requires --yes" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  output="$root/uninstall-output"
  if command -v setsid >/dev/null 2>&1; then
    detach=(setsid)
  else
    detach=(perl -MPOSIX -e "POSIX::setsid(); exec @ARGV")
  fi

  if TEST_MODE=true INSTALL_ROOT="$root" "${detach[@]}" scripts/uninstall.sh --purge-data \
    </dev/null >"$output" 2>&1; then
    exit 1
  fi

  grep -Fq -- "--purge-data requires --yes when no interactive terminal is available" "$output"
' bash "$ROOT_DIR"
expect_success "upgrade dry-run works" env TEST_UNAME_M=x86_64 "$ROOT_DIR/scripts/upgrade-signal-cli.sh" --dry-run --version 0.0.0 --install-mode native --sha256 0000000000000000000000000000000000000000000000000000000000000000
expect_output_not_contains_text "upgrade dry-run does not prompt for Signal account" "Signal account number" env TEST_UNAME_M=x86_64 "$ROOT_DIR/scripts/upgrade-signal-cli.sh" --dry-run --version 0.0.0 --install-mode native --sha256 0000000000000000000000000000000000000000000000000000000000000000
expect_output_not_contains_text "upgrade dry-run does not prompt for linked device name" "Linked device name" env TEST_UNAME_M=x86_64 "$ROOT_DIR/scripts/upgrade-signal-cli.sh" --dry-run --version 0.0.0 --install-mode native --sha256 0000000000000000000000000000000000000000000000000000000000000000
expect_output_not_contains_text "upgrade dry-run does not ask SSH hardening" "Disable SSH password login" env TEST_UNAME_M=x86_64 "$ROOT_DIR/scripts/upgrade-signal-cli.sh" --dry-run --version 0.0.0 --install-mode native --sha256 0000000000000000000000000000000000000000000000000000000000000000
expect_success "rollback dry-run works" "$ROOT_DIR/scripts/rollback-signal-cli.sh" --dry-run --to-version 0.0.0 --install-mode native

expect_success "upgrade dry-run bind preview is best-effort and lock-free" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  lock_marker="$root/lock-attempted"
  mkdir -p "$root/etc/default"
  printf "unreadable-or-malformed\n" >"$root/etc/default/signal-cli"

  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" LOCK_MARKER="$lock_marker" bash -c '\''
    set -Eeuo pipefail
    source scripts/upgrade-signal-cli.sh
    load_installed_http_bind() { return 91; }
    acquire_lifecycle_lock() {
      : >"$LOCK_MARKER"
      return 92
    }
    main_upgrade \
      --dry-run \
      --install-mode native \
      --version 0.0.0 \
      --sha256 0000000000000000000000000000000000000000000000000000000000000000 >/dev/null
  '\''

  test ! -e "$lock_marker"
' bash "$ROOT_DIR"

expect_success "rollback dry-run bind preview is best-effort and lock-free" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  lock_marker="$root/lock-attempted"
  mkdir -p "$root/etc/default"
  printf "unreadable-or-malformed\n" >"$root/etc/default/signal-cli"

  TEST_MODE=true INSTALL_ROOT="$root" LOCK_MARKER="$lock_marker" bash -c '\''
    set -Eeuo pipefail
    source scripts/rollback-signal-cli.sh
    load_installed_http_bind() { return 91; }
    acquire_lifecycle_lock() {
      : >"$LOCK_MARKER"
      return 92
    }
    main_rollback --dry-run --to-version 0.0.0 --install-mode native >/dev/null
  '\''

  test ! -e "$lock_marker"
' bash "$ROOT_DIR"

expect_success "upgrade loads bind and prints its plan from a locked snapshot" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  plan_marker="$root/locked-plan"
  output="$root/upgrade-output"

  set +e
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" PLAN_MARKER="$plan_marker" bash -c '\''
    set -Eeuo pipefail
    source scripts/upgrade-signal-cli.sh
    load_installed_http_bind() {
      is_true "$LIFECYCLE_LOCK_HELD" || return 81
      HTTP_BIND=127.0.0.1:9181
    }
    print_upgrade_plan() {
      is_true "$LIFECYCLE_LOCK_HELD" || return 82
      test "$HTTP_BIND" = 127.0.0.1:9181
      : >"$PLAN_MARKER"
      return 83
    }
    journalctl() { :; }
    main_upgrade \
      --install-mode native \
      --version 0.0.0 \
      --artifact-file "$2" \
      --sha256 "$3"
  '\'' bash "$1" "$2" "$3" >"$output" 2>&1
  upgrade_rc=$?
  set -e

  test "$upgrade_rc" -eq 83
  test -f "$plan_marker"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "rollback loads bind and prints its plan from a locked snapshot" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  plan_marker="$root/locked-plan"
  output="$root/rollback-output"

  set +e
  TEST_MODE=true INSTALL_ROOT="$root" PLAN_MARKER="$plan_marker" bash -c '\''
    set -Eeuo pipefail
    source scripts/rollback-signal-cli.sh
    load_installed_http_bind() {
      is_true "$LIFECYCLE_LOCK_HELD" || return 81
      HTTP_BIND=127.0.0.1:9182
    }
    cat() {
      is_true "$LIFECYCLE_LOCK_HELD" || return 82
      test "$HTTP_BIND" = 127.0.0.1:9182
      : >"$PLAN_MARKER"
      return 83
    }
    journalctl() { :; }
    main_rollback --to-version 0.0.0 --install-mode native
  '\'' >"$output" 2>&1
  rollback_rc=$?
  set -e

  test "$rollback_rc" -eq 83
  test -f "$plan_marker"
' bash "$ROOT_DIR"

expect_success "installer rejects unsafe active symlinks before bootstrap mutation" bash -c '
  set -Eeuo pipefail
  cd "$1"

  for target_kind in dangling directory non_executable external_executable; do
    root="$(mktemp -d)"
    link="$root/usr/local/bin/signal-cli"
    target="$root/active-target"
    bootstrap_marker="$root/bootstrap-mutated"
    output="$root/install-output"
    mkdir -p "$(dirname "$link")"
    case "$target_kind" in
      dangling) ;;
      directory) mkdir -p "$target" ;;
      non_executable)
        printf "not executable\n" >"$target"
        chmod 0644 "$target"
        ;;
      external_executable)
        cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$target"
        chmod 0755 "$target"
        ;;
    esac
    ln -s "$target" "$link"

    set +e
    TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" BOOTSTRAP_MARKER="$bootstrap_marker" bash -c '\''
      set -Eeuo pipefail
      cd "$1"
      source ./install.sh
      install_bootstrap_packages() { : >"$BOOTSTRAP_MARKER"; }
      journalctl() { :; }
      main \
        --no-link \
        --no-ufw \
        --no-fail2ban \
        --no-sysctl-hardening \
        --no-unattended-upgrades \
        --no-ssh-hardening \
        --install-mode native \
        --version 0.0.0 \
        --artifact-file "$2" \
        --sha256 "$3"
    '\'' bash "$1" "$2" "$3" >"$output" 2>&1
    install_rc=$?
    set -e

    test "$install_rc" -ne 0
    grep -Fq "is not a trusted managed executable" "$output"
    test ! -e "$bootstrap_marker"
    test -L "$link"
    test "$(readlink "$link")" = "$target"
    test ! -e "$root/opt/signal-cli-native-0.0.0"
  done
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "fixture native install writes binary and symlink" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  artifact="$2"
  digest="$3"
  marker="$root/opt/signal-cli-native-0.0.0/.signal-cli-install-manifest"
  file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
  file_owner() { stat -c %u "$1" 2>/dev/null || stat -f %u "$1"; }
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
  test -f "$marker"
  test ! -L "$marker"
  expected_manifest="$(printf "signal-cli-install-manifest-v1\nmode=native\nversion=0.0.0\n")"
  test "$(cat "$marker")" = "$expected_manifest"
  test "$(file_mode "$marker")" = 444
  test "$(file_owner "$marker")" = "$(id -u)"
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
  marker="$root/opt/signal-cli-0.0.0/.signal-cli-install-manifest"
  file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
  file_owner() { stat -c %u "$1" 2>/dev/null || stat -f %u "$1"; }
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
  test -f "$marker"
  test ! -L "$marker"
  expected_manifest="$(printf "signal-cli-install-manifest-v1\nmode=jvm\nversion=0.0.0\n")"
  test "$(cat "$marker")" = "$expected_manifest"
  test "$(file_mode "$marker")" = 444
  test "$(file_owner "$marker")" = "$(id -u)"
  test -L "$root/usr/local/bin/signal-cli"
  test -f "$root/etc/default/signal-cli"
  test -f "$root/etc/systemd/system/signal-cli.service"
' bash "$ROOT_DIR" "$JVM_FIXTURE_ARCHIVE" "$(file_sha256 "$JVM_FIXTURE_ARCHIVE")"

expect_success "native install rejects an existing install-directory symlink" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  victim="$root/victim"
  install_dir="$root/opt/signal-cli-native-0.0.0"
  mkdir -p "$victim" "$(dirname "$install_dir")"
  printf "preserve\n" >"$victim/sentinel"
  ln -s "$victim" "$install_dir"

  if TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" ./install.sh \
    --no-link \
    --no-ufw \
    --no-fail2ban \
    --no-sysctl-hardening \
    --no-unattended-upgrades \
    --no-ssh-hardening \
    --install-mode native \
    --version 0.0.0 \
    --artifact-file "$2" \
    --sha256 "$3" >/dev/null 2>&1; then
    exit 1
  fi

  test -L "$install_dir"
  test "$(cat "$victim/sentinel")" = preserve
  test ! -e "$victim/signal-cli"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "installer writes the ownership manifest before link activation" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  marker_seen="$root/marker-seen"

  set +e
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" ARTIFACT="$2" MARKER_SEEN="$marker_seen" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    source ./install.sh
    trap cleanup EXIT
    INSTALL_MODE=native
    RESOLVED_VERSION=0.0.0
    SIGNAL_CLI_ARTIFACT="$ARTIFACT"
    switch_signal_cli_symlink() {
      marker="$OPT_DIR/signal-cli-native-0.0.0/.signal-cli-install-manifest"
      test -f "$marker"
      test ! -L "$marker"
      expected_manifest="$(printf "signal-cli-install-manifest-v1\nmode=native\nversion=0.0.0\n")"
      test "$(cat "$marker")" = "$expected_manifest"
      : >"$MARKER_SEEN"
      install -d -m 0755 "$LOCAL_BIN_DIR"
      ln -sfn "$1" "$LOCAL_BIN_DIR/signal-cli"
    }
    install_signal_cli_from_artifact
  '\'' bash "$1" >/dev/null 2>&1
  install_rc=$?
  set -e

  test "$install_rc" -eq 0
  test -f "$marker_seen"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE"

expect_success "generated privileged files have explicit restrictive modes" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  artifact="$2"
  digest="$3"
  file_mode() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
  }

  umask 000
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" ./install.sh \
    --no-link \
    --no-ufw \
    --no-ssh-hardening \
    --install-mode native \
    --version 0.0.0 \
    --artifact-file "$artifact" \
    --sha256 "$digest" >/dev/null

  test "$(file_mode "$root/etc/default/signal-cli")" = 640
  test "$(file_mode "$root/usr/local/sbin/signal-cli-daemon-start")" = 755
  test "$(file_mode "$root/etc/systemd/system/signal-cli.service")" = 644
  test "$(file_mode "$root/etc/fail2ban/jail.d/99-signal-cli-sshd.local")" = 644
  test "$(file_mode "$root/etc/sysctl.d/99-signal-cli-server-hardening.conf")" = 644
  test "$(file_mode "$root/etc/apt/apt.conf.d/20auto-upgrades")" = 644
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "installer refuses a symlinked privileged config target" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  victim="$root/victim"
  service_file="$root/etc/systemd/system/signal-cli.service"
  mkdir -p "$(dirname "$service_file")"
  printf "do-not-overwrite\n" >"$victim"
  ln -s "$victim" "$service_file"

  if TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" ./install.sh \
    --no-link \
    --no-ufw \
    --no-fail2ban \
    --no-sysctl-hardening \
    --no-unattended-upgrades \
    --no-ssh-hardening \
    --install-mode native \
    --version 0.0.0 \
    --artifact-file "$2" \
    --sha256 "$3" >/dev/null 2>&1; then
    exit 1
  fi

  test -L "$service_file"
  test "$(cat "$victim")" = do-not-overwrite
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "failed config rendering preserves the previous file atomically" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  service_file="$root/etc/systemd/system/signal-cli.service"
  mkdir -p "$(dirname "$service_file")"
  printf "original-service\n" >"$service_file"
  output="$root/install-output"

  set +e
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    source ./install.sh
    render_systemd_service() {
      printf "partial-service\n"
      return 88
    }
    journalctl() { :; }
    main \
      --no-link \
      --no-ufw \
      --no-fail2ban \
      --no-sysctl-hardening \
      --no-unattended-upgrades \
      --no-ssh-hardening \
      --install-mode native \
      --version 0.0.0 \
      --artifact-file "$2" \
      --sha256 "$3"
  '\'' bash "$1" "$2" "$3" >"$output" 2>&1
  install_rc=$?
  set -e

  test "$install_rc" -eq 88
  test "$(cat "$service_file")" = original-service
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "rendered-file setup failures stop before target replacement" bash -c '
  set -Eeuo pipefail
  cd "$1"

  for failure_stage in directory initial_mode; do
    root="$(mktemp -d)"
    target="$root/config/service.conf"
    mkdir -p "$(dirname "$target")"
    printf "original\n" >"$target"

    TEST_MODE=true INSTALL_ROOT="$root" FAILURE_STAGE="$failure_stage" TARGET="$target" bash -c '\''
      set -Eeuo pipefail
      source ./install.sh
      render_candidate() { printf "replacement\n"; }
      install() {
        if [[ "$FAILURE_STAGE" == directory && "${1:-}" == -d ]]; then
          return 81
        fi
        command install "$@"
      }
      chmod() {
        if [[ "$FAILURE_STAGE" == initial_mode && "${1:-}" == 0600 ]]; then
          return 82
        fi
        command chmod "$@"
      }

      if write_rendered_file "$TARGET" 0644 root root render_candidate >/dev/null 2>&1; then
        exit 1
      fi
      test "$(cat "$TARGET")" = original
    '\''
  done
' bash "$ROOT_DIR"

expect_success "rendered-file move failure preserves target and removes same-directory temp" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  target="$root/config/service.conf"
  mkdir -p "$(dirname "$target")"
  printf "original\n" >"$target"

  TEST_MODE=true INSTALL_ROOT="$root" TARGET="$target" bash -c '\''
    set -Eeuo pipefail
    source ./install.sh
    render_candidate() { printf "replacement\n"; }
    mv() { return 79; }

    set +e
    write_rendered_file "$TARGET" 0644 root root render_candidate >/dev/null 2>&1
    write_rc=$?
    set -e
    test "$write_rc" -eq 79
    test "$(cat "$TARGET")" = original
    shopt -s nullglob
    temps=("$(dirname "$TARGET")/.$(basename "$TARGET")."*)
    test "${#temps[@]}" -eq 0
  '\''
' bash "$ROOT_DIR"

expect_success "local artifact version must match the requested version" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  output="$root/install-output"

  if TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" ./install.sh \
    --no-link \
    --no-ufw \
    --no-fail2ban \
    --no-sysctl-hardening \
    --no-unattended-upgrades \
    --no-ssh-hardening \
    --install-mode native \
    --version 9.9.9 \
    --artifact-file "$2" \
    --sha256 "$3" >"$output" 2>&1; then
    exit 1
  fi

  grep -Fq "does not match requested version 9.9.9" "$output"
  test ! -e "$root/usr/local/bin/signal-cli"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "no-link reinstall restarts a previously active service" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  old_target="$root/opt/signal-cli-native-previous/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  restart_marker="$root/restarted"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$link")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
  chmod +x "$old_target"
  ln -s "$old_target" "$link"

  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" RESTART_MARKER="$restart_marker" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    source ./install.sh
    maybe_systemctl() {
      if [[ "${1:-}" == is-active ]]; then
        printf "active\n"
        return 0
      fi
      if [[ "${1:-}" == restart && "${2:-}" == signal-cli.service ]]; then
        : >"$RESTART_MARKER"
      fi
      return 0
    }
    main \
      --no-link \
      --no-ufw \
      --no-fail2ban \
      --no-sysctl-hardening \
      --no-unattended-upgrades \
      --no-ssh-hardening \
      --install-mode native \
      --version 0.0.0 \
      --artifact-file "$2" \
      --sha256 "$3" >/dev/null
  '\'' bash "$1" "$2" "$3"

  test -f "$restart_marker"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "failed fresh install removes its link and restores an inactive service" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  stop_marker="$root/stopped"
  link="$root/usr/local/bin/signal-cli"
  output="$root/install-output"

  set +e
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" STOP_MARKER="$stop_marker" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    source ./install.sh
    maybe_systemctl() {
      if [[ "${1:-}" == is-active ]]; then
        printf "inactive\n"
        return 3
      fi
      if [[ "${1:-}" == stop && "${2:-}" == signal-cli ]]; then
        : >"$STOP_MARKER"
      fi
      return 0
    }
    health_check() {
      set_stage "forced fresh install health failure"
      return 75
    }
    journalctl() { :; }
    main \
      --no-link \
      --no-ufw \
      --no-fail2ban \
      --no-sysctl-hardening \
      --no-unattended-upgrades \
      --no-ssh-hardening \
      --install-mode native \
      --version 0.0.0 \
      --artifact-file "$2" \
      --sha256 "$3"
  '\'' bash "$1" "$2" "$3" >"$output" 2>&1
  install_rc=$?
  set -e

  test "$install_rc" -eq 75
  test ! -e "$link"
  test ! -L "$link"
  test -f "$stop_marker"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "fresh install recovery does not trust readlink -f for an absent link" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  link="$root/usr/local/bin/signal-cli"
  output="$root/install-output"

  set +e
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    source ./install.sh
    readlink() {
      if [[ "${1:-}" == -f && "${2:-}" == "$LOCAL_BIN_DIR/signal-cli" && ! -L "$LOCAL_BIN_DIR/signal-cli" ]]; then
        printf "%s\n" "$LOCAL_BIN_DIR/signal-cli"
        return 0
      fi
      command readlink "$@"
    }
    maybe_systemctl() {
      if [[ "${1:-}" == is-active ]]; then
        printf "inactive\n"
        return 3
      fi
      return 0
    }
    health_check() {
      set_stage "forced Linux-style absent-link recovery failure"
      return 75
    }
    journalctl() { :; }
    main \
      --no-link \
      --no-ufw \
      --no-fail2ban \
      --no-sysctl-hardening \
      --no-unattended-upgrades \
      --no-ssh-hardening \
      --install-mode native \
      --version 0.0.0 \
      --artifact-file "$2" \
      --sha256 "$3"
  '\'' bash "$1" "$2" "$3" >"$output" 2>&1
  install_rc=$?
  set -e

  test "$install_rc" -eq 75
  test ! -e "$link"
  test ! -L "$link"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "failed reinstall preserves a previously inactive service" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  old_target="$root/opt/signal-cli-native-previous/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  stop_marker="$root/stopped"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$link")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
  chmod +x "$old_target"
  ln -s "$old_target" "$link"

  set +e
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" STOP_MARKER="$stop_marker" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    source ./install.sh
    maybe_systemctl() {
      if [[ "${1:-}" == is-active ]]; then
        printf "inactive\n"
        return 3
      fi
      if [[ "${1:-}" == stop && "${2:-}" == signal-cli ]]; then
        : >"$STOP_MARKER"
      fi
      return 0
    }
    health_check() {
      set_stage "forced inactive reinstall health failure"
      return 76
    }
    journalctl() { :; }
    main \
      --no-link \
      --no-ufw \
      --no-fail2ban \
      --no-sysctl-hardening \
      --no-unattended-upgrades \
      --no-ssh-hardening \
      --install-mode native \
      --version 0.0.0 \
      --artifact-file "$2" \
      --sha256 "$3"
  '\'' bash "$1" "$2" "$3" >/dev/null 2>&1
  install_rc=$?
  set -e

  test "$install_rc" -eq 76
  test "$(readlink -f "$link")" = "$(readlink -f "$old_target")"
  test -f "$stop_marker"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "signal after symlink promotion restores prior absence" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  target="$root/opt/signal-cli-native-0.0.0/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  mkdir -p "$(dirname "$target")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$target"
  chmod +x "$target"

  set +e
  TEST_MODE=true INSTALL_ROOT="$root" TARGET="$target" bash -c '\''
    set -Eeuo pipefail
    source ./install.sh
    trap "on_lifecycle_signal TERM" TERM
    trap cleanup EXIT
    SIGNAL_CLI_RESTORE_ABSENT_LINK=true
    mv() {
      command mv "$@"
      kill -TERM "$BASHPID"
    }
    switch_signal_cli_symlink "$TARGET"
  '\'' >/dev/null 2>&1
  switch_rc=$?
  set -e

  test "$switch_rc" -eq 143
  test ! -e "$link"
  test ! -L "$link"
' bash "$ROOT_DIR"

expect_success "replacement recovery reports a failed symlink move and cleanup removes its temp link" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  old_target="$root/opt/signal-cli-native-old/signal-cli"
  new_target="$root/opt/signal-cli-native-new/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  temp_link="$root/usr/local/bin/signal-cli.new"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$new_target")" "$(dirname "$link")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$new_target"
  chmod +x "$old_target" "$new_target"
  ln -s "$new_target" "$link"

  TEST_MODE=true INSTALL_ROOT="$root" OLD_TARGET="$old_target" NEW_TARGET="$new_target" bash -c '\''
    set -Eeuo pipefail
    source ./install.sh
    SIGNAL_CLI_PREVIOUS_TARGET="$OLD_TARGET"
    mv() { return 83; }

    if restore_previous_signal_cli_state >/dev/null 2>&1; then
      exit 1
    fi
    test "$(readlink "$LOCAL_BIN_DIR/signal-cli")" = "$NEW_TARGET"
    test "$SIGNAL_CLI_TEMP_LINK" = "$LOCAL_BIN_DIR/signal-cli.new"
    test -L "$SIGNAL_CLI_TEMP_LINK"
    cleanup
    test ! -e "$LOCAL_BIN_DIR/signal-cli.new"
    test ! -L "$LOCAL_BIN_DIR/signal-cli.new"
  '\''

  test "$(readlink "$link")" = "$new_target"
  test ! -e "$temp_link"
  test ! -L "$temp_link"
' bash "$ROOT_DIR"

expect_success "symlink switching refuses an existing non-symlink temp path" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  target="$root/opt/signal-cli-native-0.0.0/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  temp_dir="$root/usr/local/bin/signal-cli.new"
  mkdir -p "$(dirname "$target")" "$temp_dir"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$target"
  chmod +x "$target"
  printf "preserve\n" >"$temp_dir/sentinel"

  TEST_MODE=true INSTALL_ROOT="$root" TARGET="$target" bash -c '\''
    set -Eeuo pipefail
    source ./install.sh
    if switch_signal_cli_symlink "$TARGET" >/dev/null 2>&1; then
      exit 1
    fi
  '\''

  test ! -e "$link"
  test ! -L "$link"
  test -d "$temp_dir"
  test "$(cat "$temp_dir/sentinel")" = preserve
  shopt -s nullglob
  entries=("$temp_dir"/*)
  test "${#entries[@]}" -eq 1
' bash "$ROOT_DIR"

expect_success "EXIT cleanup ignores removal errors and still releases resources" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  release_marker="$root/released"
  tty_marker="$root/tty-closed"
  output="$root/cleanup-output"

  set +e
  TEST_MODE=true INSTALL_ROOT="$root" RELEASE_MARKER="$release_marker" TTY_MARKER="$tty_marker" bash -c '\''
    set -Eeuo pipefail
    source ./install.sh
    mkdir -p "$LOCAL_BIN_DIR"
    ln -s "$INSTALL_ROOT/target" "$LOCAL_BIN_DIR/signal-cli.new"
    SIGNAL_CLI_TEMP_LINK="$LOCAL_BIN_DIR/signal-cli.new"
    rm() { return 55; }
    release_lifecycle_lock() { : >"$RELEASE_MARKER"; }
    close_prompt_tty() { : >"$TTY_MARKER"; }
    journalctl() { :; }
    trap on_lifecycle_error ERR
    trap cleanup EXIT
    exit 0
  '\'' >"$output" 2>&1
  cleanup_rc=$?
  set -e

  test "$cleanup_rc" -eq 0
  test -f "$release_marker"
  test -f "$tty_marker"
  grep -Fq "Could not remove signal-cli lifecycle temporary link" "$output"
' bash "$ROOT_DIR"

expect_success "a signal during successful install cleanup never rolls back the committed state" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  old_target="$root/opt/signal-cli-native-previous/signal-cli"
  new_target="$root/opt/signal-cli-native-0.0.0/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  systemctl_log="$root/systemctl-log"
  output="$root/install-output"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$link")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
  chmod 0755 "$old_target"
  ln -s "$old_target" "$link"

  set +e
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" SYSTEMCTL_LOG="$systemctl_log" bash -c '\''
    set -Eeuo pipefail
    source ./install.sh
    signal_sent=false
    rm() {
      if [[ -n "$SIGNAL_CLI_STAGING_DIR" &&
        "${1:-}" == -rf && "${2:-}" == -- && "${3:-}" == "$SIGNAL_CLI_STAGING_DIR" &&
        "$signal_sent" == false ]]; then
        command rm "$@"
        signal_sent=true
        kill -TERM "$BASHPID"
        return 143
      fi
      command rm "$@"
    }
    maybe_systemctl() {
      if [[ "${1:-}" == is-active ]]; then
        printf "active\n"
        return 0
      fi
      printf "%s\n" "$*" >>"$SYSTEMCTL_LOG"
      return 0
    }
    journalctl() { :; }
    main \
      --no-link \
      --no-ufw \
      --no-fail2ban \
      --no-sysctl-hardening \
      --no-unattended-upgrades \
      --no-ssh-hardening \
      --install-mode native \
      --version 0.0.0 \
      --artifact-file "$2" \
      --sha256 "$3"
  '\'' bash "$1" "$2" "$3" >"$output" 2>&1
  install_rc=$?
  set -e

  test "$install_rc" -eq 143
  test "$(readlink -f "$link")" = "$(readlink -f "$new_target")"
  ! grep -Fxq "restart signal-cli" "$systemctl_log"
  ! grep -Fxq "stop signal-cli" "$systemctl_log"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "lifecycle lock serializes callers and cleanup releases it" bash -c '
  set -Eeuo pipefail
  cd "$1"
  for backend in flock mkdir; do
    root="$(mktemp -d)"
    ready="$root/lock-ready"
    release_fifo="$root/lock-release"
    mkfifo "$release_fifo"
    "$LIFECYCLE_LOCK_HOLDER" "$1/install.sh" "$root" "$ready" "$release_fifo" "$backend" &
    holder_pid=$!
    cleanup_holder() {
      kill "$holder_pid" 2>/dev/null || true
      wait "$holder_pid" 2>/dev/null || true
    }
    trap cleanup_holder EXIT
    for _ in {1..100}; do
      [[ -e "$ready" ]] && break
      sleep 0.02
    done
    test -e "$ready"

    if "$LIFECYCLE_LOCK_PROBE" "$1/install.sh" "$root" "$backend" >/dev/null 2>&1; then
      exit 1
    fi

    printf "release\n" >"$release_fifo"
    wait "$holder_pid"
    "$LIFECYCLE_LOCK_PROBE" "$1/install.sh" "$root" "$backend"
    trap - EXIT
  done
' bash "$ROOT_DIR"

expect_success "lifecycle lock uses the root-only run namespace" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  INSTALL_ROOT="$root"
  source ./install.sh
  test "$LIFECYCLE_LOCK_FILE" = "$root/run/signal-cli-lifecycle.lock"
' bash "$ROOT_DIR"

expect_success "lifecycle locking preserves an existing lock-parent mode" bash -c '
  set -Eeuo pipefail
  cd "$1"
  file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

  installer_root="$(mktemp -d)"
  mkdir -p "$installer_root/run"
  chmod 1777 "$installer_root/run"
  installer_mode_before="$(file_mode "$installer_root/run")"
  "$LIFECYCLE_LOCK_PROBE" "$1/install.sh" "$installer_root" flock
  test "$(file_mode "$installer_root/run")" = "$installer_mode_before"

  uninstall_root="$(mktemp -d)"
  mkdir -p "$uninstall_root/run"
  chmod 1777 "$uninstall_root/run"
  uninstall_mode_before="$(file_mode "$uninstall_root/run")"
  TEST_MODE=true INSTALL_ROOT="$uninstall_root" scripts/uninstall.sh >/dev/null
  test "$(file_mode "$uninstall_root/run")" = "$uninstall_mode_before"
' bash "$ROOT_DIR"

expect_success "flock lifecycle lock recovers after holder SIGKILL" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  ready="$root/lock-ready"
  release_fifo="$root/lock-release"
  mkfifo "$release_fifo"
  "$LIFECYCLE_LOCK_HOLDER" "$1/install.sh" "$root" "$ready" "$release_fifo" flock &
  holder_pid=$!
  for _ in {1..100}; do
    [[ -e "$ready" ]] && break
    sleep 0.02
  done
  test -e "$ready"

  kill -KILL "$holder_pid"
  wait "$holder_pid" 2>/dev/null || true

  "$LIFECYCLE_LOCK_PROBE" "$1/install.sh" "$root" flock
' bash "$ROOT_DIR"

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

expect_success "upgrade --no-restart skips service-state capture and malformed config" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  capture_probe="$root/service-state-captured"
  mkdir -p "$root/etc/default"
  printf "SIGNAL_CLI_HTTP_BIND=not-a-valid-bind\n" >"$root/etc/default/signal-cli"

  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" CAPTURE_PROBE="$capture_probe" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    source scripts/upgrade-signal-cli.sh
    capture_signal_cli_service_state() {
      : >"$CAPTURE_PROBE"
      return 91
    }
    journalctl() { :; }
    main_upgrade \
      --no-restart \
      --install-mode native \
      --version 0.0.0 \
      --artifact-file "$2" \
      --sha256 "$3" >/dev/null
  '\'' bash "$1" "$2" "$3"

  test ! -e "$capture_probe"
  test -L "$root/usr/local/bin/signal-cli"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "upgrade health check uses installed HTTP bind" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  mkdir -p "$root/etc/default"
  printf '\''SIGNAL_CLI_HTTP_BIND="127.0.0.1:9876"\n'\'' > "$root/etc/default/signal-cli"
  output="$root/upgrade-output"

  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" scripts/upgrade-signal-cli.sh \
    --install-mode native \
    --version 0.0.0 \
    --artifact-file "$2" \
    --sha256 "$3" >"$output"

  grep -Fq "skip health check http://127.0.0.1:9876/api/v1/check" "$output"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "upgrade rollback hint identifies previous JVM version" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  old_target="$root/opt/signal-cli-0.0.0/bin/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$link")"
  cp tests/fixtures/jvm/signal-cli-0.0.0/bin/signal-cli "$old_target"
  chmod +x "$old_target"
  ln -s "$old_target" "$link"
  output="$root/upgrade-output"

  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" scripts/upgrade-signal-cli.sh \
    --no-restart \
    --install-mode native \
    --version 0.0.0 \
    --artifact-file "$2" \
    --sha256 "$3" >"$output"

  grep -Fq "scripts/rollback-signal-cli.sh --to-version 0.0.0 --install-mode jvm" "$output"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "occupied lifecycle lock blocks upgrade mutation" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  old_target="$root/opt/signal-cli-native-previous/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  ready="$root/lock-ready"
  release_fifo="$root/lock-release"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$link")"
  mkfifo "$release_fifo"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
  chmod +x "$old_target"
  ln -s "$old_target" "$link"

  "$LIFECYCLE_LOCK_HOLDER" "$1/install.sh" "$root" "$ready" "$release_fifo" &
  holder_pid=$!
  cleanup_holder() {
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
  }
  trap cleanup_holder EXIT
  for _ in {1..100}; do
    [[ -e "$ready" ]] && break
    sleep 0.02
  done
  test -e "$ready"

  if TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" scripts/upgrade-signal-cli.sh \
    --no-restart \
    --install-mode native \
    --version 0.0.0 \
    --artifact-file "$2" \
    --sha256 "$3" >/dev/null 2>&1; then
    exit 1
  fi

  test "$(readlink -f "$link")" = "$(readlink -f "$old_target")"
  test ! -e "$root/opt/signal-cli-native-0.0.0"
  printf "release\n" >"$release_fifo"
  wait "$holder_pid"
  trap - EXIT
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "upgrade refuses a non-symlink active binary" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  active_binary="$root/usr/local/bin/signal-cli"
  mkdir -p "$(dirname "$active_binary")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$active_binary"
  chmod +x "$active_binary"
  output="$root/upgrade-output"

  if TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" scripts/upgrade-signal-cli.sh \
    --no-restart \
    --install-mode native \
    --version 0.0.0 \
    --artifact-file "$2" \
    --sha256 "$3" >"$output" 2>&1; then
    exit 1
  fi

  grep -Fq "Refusing to replace non-symlink signal-cli executable" "$output"
  test -f "$active_binary"
  test ! -L "$active_binary"
  test "$($active_binary --version)" = "signal-cli 0.0.0 fixture"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "upgrade rejects an unresolved active symlink before bootstrap mutation" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  link="$root/usr/local/bin/signal-cli"
  missing_target="$root/missing-signal-cli"
  bootstrap_marker="$root/bootstrap-mutated"
  output="$root/upgrade-output"
  mkdir -p "$(dirname "$link")"
  ln -s "$missing_target" "$link"

  set +e
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" BOOTSTRAP_MARKER="$bootstrap_marker" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    source scripts/upgrade-signal-cli.sh
    install_bootstrap_packages() { : >"$BOOTSTRAP_MARKER"; }
    journalctl() { :; }
    main_upgrade \
      --no-restart \
      --install-mode native \
      --version 0.0.0 \
      --artifact-file "$2" \
      --sha256 "$3"
  '\'' bash "$1" "$2" "$3" >"$output" 2>&1
  upgrade_rc=$?
  set -e

  test "$upgrade_rc" -ne 0
  grep -Fq "is not a trusted managed executable" "$output"
  test ! -e "$bootstrap_marker"
  test -L "$link"
  test "$(readlink "$link")" = "$missing_target"
  test ! -e "$root/opt/signal-cli-native-0.0.0"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "upgrade rejects an executable active symlink outside managed layouts" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  link="$root/usr/local/bin/signal-cli"
  external_target="$root/operator-bin/signal-cli"
  bootstrap_marker="$root/bootstrap-mutated"
  output="$root/upgrade-output"
  mkdir -p "$(dirname "$link")" "$(dirname "$external_target")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$external_target"
  chmod 0755 "$external_target"
  ln -s "$external_target" "$link"

  set +e
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" BOOTSTRAP_MARKER="$bootstrap_marker" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    source scripts/upgrade-signal-cli.sh
    install_bootstrap_packages() { : >"$BOOTSTRAP_MARKER"; }
    journalctl() { :; }
    main_upgrade \
      --no-restart \
      --install-mode native \
      --version 0.0.0 \
      --artifact-file "$2" \
      --sha256 "$3"
  '\'' bash "$1" "$2" "$3" >"$output" 2>&1
  upgrade_rc=$?
  set -e

  test "$upgrade_rc" -ne 0
  test ! -e "$bootstrap_marker"
  test -L "$link"
  test "$(readlink "$link")" = "$external_target"
  test ! -e "$root/opt/signal-cli-native-0.0.0"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "managed target validation rejects an untrusted OPT_DIR ancestor" bash -c '
  set -Eeuo pipefail
  cd "$1"

  for trust_failure in writable unexpected_owner; do
    root="$(mktemp -d)"
    target="$root/opt/signal-cli-native-0.0.0/signal-cli"
    mkdir -p "$(dirname "$target")"
    cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$target"
    chmod 0755 "$target"

    TEST_MODE=true INSTALL_ROOT="$root" TRUST_FAILURE="$trust_failure" TARGET="$target" bash -c '\''
      set -Eeuo pipefail
      source ./install.sh
      if [[ "$TRUST_FAILURE" == writable ]]; then
        chmod 0777 "$OPT_DIR"
      else
        path_owner_uid() {
          if [[ "$(readlink -f "$1")" == "$(readlink -f "$OPT_DIR")" ]]; then
            printf "424242\n"
          else
            stat -c %u "$1" 2>/dev/null || stat -f %u "$1"
          fi
        }
      fi

      if validate_managed_signal_cli_target "$TARGET" native 0.0.0; then
        exit 1
      fi
    '\''
  done
' bash "$ROOT_DIR"

expect_success "managed JVM validation rejects untrusted runtime-tree entries" bash -c '
  set -Eeuo pipefail
  cd "$1"

  for trust_failure in writable_lib unexpected_owner external_symlink; do
    root="$(mktemp -d)"
    install_dir="$root/opt/signal-cli-0.0.0"
    target="$install_dir/bin/signal-cli"
    library="$install_dir/lib/runtime.jar"
    external="$root/operator/runtime.jar"
    mkdir -p "$(dirname "$target")" "$(dirname "$library")" "$(dirname "$external")"
    cp tests/fixtures/jvm/signal-cli-0.0.0/bin/signal-cli "$target"
    chmod 0755 "$target"
    printf "trusted-runtime\n" >"$library"
    chmod 0644 "$library"

    case "$trust_failure" in
      writable_lib)
        chmod 0666 "$library"
        ;;
      unexpected_owner)
        ;;
      external_symlink)
        printf "operator-runtime\n" >"$external"
        rm "$library"
        ln -s "$external" "$library"
        ;;
    esac

    TEST_MODE=true INSTALL_ROOT="$root" TRUST_FAILURE="$trust_failure" TARGET="$target" LIBRARY="$library" bash -c '\''
      set -Eeuo pipefail
      source ./install.sh
      if [[ "$TRUST_FAILURE" == unexpected_owner ]]; then
        path_owner_uid() {
          if [[ "$(readlink -f "$1")" == "$(readlink -f "$LIBRARY")" ]]; then
            printf "424242\n"
          else
            stat -c %u "$1" 2>/dev/null || stat -f %u "$1"
          fi
        }
      fi

      if validate_managed_signal_cli_target "$TARGET" jvm 0.0.0; then
        exit 1
      fi
    '\''
  done
' bash "$ROOT_DIR"

expect_success "managed target validation rejects nested lookalike layouts" bash -c '
  set -Eeuo pipefail
  cd "$1"

  for install_mode in native jvm; do
    root="$(mktemp -d)"
    if [[ "$install_mode" == native ]]; then
      install_dir="$root/opt/signal-cli-native-outer/nested/signal-cli-native-0.0.0"
      target="$install_dir/signal-cli"
      fixture="tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli"
    else
      install_dir="$root/opt/signal-cli-outer/nested/signal-cli-0.0.0"
      target="$install_dir/bin/signal-cli"
      fixture="tests/fixtures/jvm/signal-cli-0.0.0/bin/signal-cli"
    fi
    mkdir -p "$(dirname "$target")"
    cp "$fixture" "$target"
    chmod 0755 "$target"

    TEST_MODE=true INSTALL_ROOT="$root" TARGET="$target" INSTALL_MODE="$install_mode" bash -c '\''
      set -Eeuo pipefail
      source ./install.sh
      if validate_managed_signal_cli_target "$TARGET" "$INSTALL_MODE" 0.0.0; then
        exit 1
      fi
    '\''
  done
' bash "$ROOT_DIR"

expect_success "failed native upgrade keeps previous active binary" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  old_target="$root/opt/signal-cli-native-0.0.0/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$link")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
  chmod +x "$old_target"
  ln -s "$old_target" "$link"
  output="$root/upgrade-output"

  if TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" scripts/upgrade-signal-cli.sh \
    --no-restart \
    --install-mode native \
    --version 0.0.1 \
    --artifact-file "$2" \
    --sha256 "$3" >"$output" 2>&1; then
    exit 1
  fi

  grep -Fq "Installer failed during stage '\''signal-cli install'\'' with exit code 42" "$output"
  test "$(readlink "$link")" = "$old_target"
  test "$($link --version)" = "signal-cli 0.0.0 fixture"
' bash "$ROOT_DIR" "$BROKEN_NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$BROKEN_NATIVE_FIXTURE_ARCHIVE")"

expect_success "failed upgrade health check restores previous binary" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  old_target="$root/opt/signal-cli-native-previous/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$link")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
  chmod +x "$old_target"
  ln -s "$old_target" "$link"
  systemctl_log="$root/systemctl-log"
  output="$root/upgrade-output"

  set +e
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" SYSTEMCTL_LOG="$systemctl_log" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    artifact="$2"
    digest="$3"
    source scripts/upgrade-signal-cli.sh
    maybe_systemctl() {
      if [[ "${1:-}" == "is-active" ]]; then
        printf "active\n"
        return 0
      fi
      printf "%s %s\n" "${1:-}" "${2:-}" >> "$SYSTEMCTL_LOG"
    }
    health_check() {
      set_stage "forced health check failure"
      expected_target="$INSTALL_ROOT/opt/signal-cli-native-0.0.0/signal-cli"
      [[ "$(readlink -f "$LOCAL_BIN_DIR/signal-cli")" == "$(readlink -f "$expected_target")" ]] || return 97
      return 55
    }
    journalctl() { :; }
    main_upgrade \
      --install-mode native \
      --version 0.0.0 \
      --artifact-file "$artifact" \
      --sha256 "$digest"
  '\'' bash "$1" "$2" "$3" >"$output" 2>&1
  upgrade_rc=$?
  set -e

  test "$upgrade_rc" -eq 55
  grep -Fq "Installer failed during stage '\''forced health check failure'\'' with exit code 55" "$output"
  test "$(readlink -f "$link")" = "$(readlink -f "$old_target")"
  test "$($link --version)" = "signal-cli 0.0.0 fixture"
  test "$(grep -Fxc "restart signal-cli" "$systemctl_log")" -eq 2
  ! grep -Fq "stop signal-cli" "$systemctl_log"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "failed upgrade restores absence of an active binary" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  link="$root/usr/local/bin/signal-cli"
  systemctl_log="$root/systemctl-log"
  output="$root/upgrade-output"

  set +e
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" SYSTEMCTL_LOG="$systemctl_log" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    artifact="$2"
    digest="$3"
    source scripts/upgrade-signal-cli.sh
    maybe_systemctl() {
      printf "%s %s\n" "${1:-}" "${2:-}" >> "$SYSTEMCTL_LOG"
      if [[ "${1:-}" == "is-active" ]]; then
        printf "inactive\n"
        return 3
      fi
    }
    health_check() {
      set_stage "forced health failure without previous binary"
      [[ -L "$LOCAL_BIN_DIR/signal-cli" ]] || return 98
      return 58
    }
    journalctl() { :; }
    main_upgrade \
      --install-mode native \
      --version 0.0.0 \
      --artifact-file "$artifact" \
      --sha256 "$digest"
  '\'' bash "$1" "$2" "$3" >"$output" 2>&1
  upgrade_rc=$?
  set -e

  test "$upgrade_rc" -eq 58
  test ! -e "$link"
  test ! -L "$link"
  grep -Fxq "stop signal-cli" "$systemctl_log"
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "upgrade signals restore the previous binary" bash -c '
  set -Eeuo pipefail
  cd "$1"

  for signal_and_rc in HUP:129 INT:130 TERM:143; do
    signal="${signal_and_rc%%:*}"
    expected_rc="${signal_and_rc##*:}"
    root="$(mktemp -d)"
    old_target="$root/opt/signal-cli-native-previous/signal-cli"
    link="$root/usr/local/bin/signal-cli"
    mkdir -p "$(dirname "$old_target")" "$(dirname "$link")"
    cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
    chmod +x "$old_target"
    ln -s "$old_target" "$link"

    set +e
    TEST_MODE=true TEST_UNAME_M=x86_64 TEST_SIGNAL="$signal" INSTALL_ROOT="$root" bash -c '\''
      set -Eeuo pipefail
      cd "$1"
      artifact="$2"
      digest="$3"
      source scripts/upgrade-signal-cli.sh
      health_check() {
        kill -s "$TEST_SIGNAL" "$BASHPID"
        return 99
      }
      main_upgrade \
        --install-mode native \
        --version 0.0.0 \
        --artifact-file "$artifact" \
        --sha256 "$digest"
    '\'' bash "$1" "$2" "$3" >/dev/null 2>&1
    upgrade_rc=$?
    set -e

    test "$upgrade_rc" -eq "$expected_rc"
    test "$(readlink -f "$link")" = "$(readlink -f "$old_target")"
    test "$("$link" --version)" = "signal-cli 0.0.0 fixture"
    rm -rf "$root"
  done
' bash "$ROOT_DIR" "$NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$NATIVE_FIXTURE_ARCHIVE")"

expect_success "failed same-version upgrade restores previous binary contents" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  old_target="$root/opt/signal-cli-native-0.0.0/signal-cli"
  manifest="$root/opt/signal-cli-native-0.0.0/.signal-cli-install-manifest"
  link="$root/usr/local/bin/signal-cli"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$link")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
  chmod +x "$old_target"
  ln -s "$old_target" "$link"
  test ! -e "$manifest"
  output="$root/upgrade-output"

  set +e
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    artifact="$2"
    digest="$3"
    source scripts/upgrade-signal-cli.sh
    health_check() {
      set_stage "forced same-version health check failure"
      [[ "$("$LOCAL_BIN_DIR/signal-cli" --version)" == "signal-cli 0.0.0 replacement" ]] || return 98
      return 56
    }
    journalctl() { :; }
    main_upgrade \
      --install-mode native \
      --version 0.0.0 \
      --artifact-file "$artifact" \
      --sha256 "$digest"
  '\'' bash "$1" "$2" "$3" >"$output" 2>&1
  upgrade_rc=$?
  set -e

  test "$upgrade_rc" -eq 56
  grep -Fq "Installer failed during stage '\''forced same-version health check failure'\'' with exit code 56" "$output"
  test "$(readlink -f "$link")" = "$(readlink -f "$old_target")"
  test "$($link --version)" = "signal-cli 0.0.0 fixture"
  test ! -e "$manifest"
' bash "$ROOT_DIR" "$REPLACEMENT_NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$REPLACEMENT_NATIVE_FIXTURE_ARCHIVE")"

expect_success "native reinstall refuses to discard unrelated install-directory entries" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  old_target="$root/opt/signal-cli-native-0.0.0/signal-cli"
  operator_file="$root/opt/signal-cli-native-0.0.0/operator-note"
  link="$root/usr/local/bin/signal-cli"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$link")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
  chmod 0755 "$old_target"
  printf "preserve\n" >"$operator_file"
  ln -s "$old_target" "$link"

  if TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" scripts/upgrade-signal-cli.sh \
    --no-restart \
    --install-mode native \
    --version 0.0.0 \
    --artifact-file "$2" \
    --sha256 "$3" >/dev/null 2>&1; then
    exit 1
  fi

  test "$(cat "$operator_file")" = preserve
  test "$($old_target --version)" = "signal-cli 0.0.0 fixture"
  test "$(readlink -f "$link")" = "$(readlink -f "$old_target")"
' bash "$ROOT_DIR" "$REPLACEMENT_NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$REPLACEMENT_NATIVE_FIXTURE_ARCHIVE")"

expect_success "signal in native directory-promotion window restores the prior install" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  old_target="$root/opt/signal-cli-native-0.0.0/signal-cli"
  manifest="$root/opt/signal-cli-native-0.0.0/.signal-cli-install-manifest"
  link="$root/usr/local/bin/signal-cli"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$link")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
  chmod 0755 "$old_target"
  ln -s "$old_target" "$link"

  set +e
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    source scripts/upgrade-signal-cli.sh
    mv() {
      command mv "$@"
      if [[ "${1:-}" == "$OPT_DIR/signal-cli-native-0.0.0" &&
        "${2:-}" == "$SIGNAL_CLI_STAGING_DIR/previous-install" ]]; then
        kill -TERM "$BASHPID"
      fi
    }
    journalctl() { :; }
    main_upgrade \
      --no-restart \
      --install-mode native \
      --version 0.0.0 \
      --artifact-file "$2" \
      --sha256 "$3" >/dev/null
  '\'' bash "$1" "$2" "$3" >/dev/null 2>&1
  upgrade_rc=$?
  set -e

  test "$upgrade_rc" -eq 143
  test -x "$old_target"
  test "$($old_target --version)" = "signal-cli 0.0.0 fixture"
  test "$(readlink -f "$link")" = "$(readlink -f "$old_target")"
  test ! -e "$manifest"
' bash "$ROOT_DIR" "$REPLACEMENT_NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$REPLACEMENT_NATIVE_FIXTURE_ARCHIVE")"

expect_success "failed direct reinstall restores previous binary contents" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  old_target="$root/opt/signal-cli-native-0.0.0/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$link")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
  chmod +x "$old_target"
  ln -s "$old_target" "$link"
  output="$root/install-output"

  set +e
  TEST_MODE=true TEST_UNAME_M=x86_64 INSTALL_ROOT="$root" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    artifact="$2"
    digest="$3"
    source ./install.sh
    create_service_user() {
      set_stage "forced direct reinstall failure"
      [[ "$("$LOCAL_BIN_DIR/signal-cli" --version)" == "signal-cli 0.0.0 replacement" ]] || return 98
      return 57
    }
    journalctl() { :; }
    main \
      --no-link \
      --no-ufw \
      --no-fail2ban \
      --no-sysctl-hardening \
      --no-unattended-upgrades \
      --no-ssh-hardening \
      --install-mode native \
      --version 0.0.0 \
      --artifact-file "$artifact" \
      --sha256 "$digest"
  '\'' bash "$1" "$2" "$3" >"$output" 2>&1
  install_rc=$?
  set -e

  test "$install_rc" -eq 57
  grep -Fq "Installer failed during stage '\''forced direct reinstall failure'\'' with exit code 57" "$output"
  test "$(readlink -f "$link")" = "$(readlink -f "$old_target")"
  test "$($link --version)" = "signal-cli 0.0.0 fixture"
' bash "$ROOT_DIR" "$REPLACEMENT_NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$REPLACEMENT_NATIVE_FIXTURE_ARCHIVE")"

expect_success "lifecycle signals restore the previous binary before cleanup" bash -c '
  set -Eeuo pipefail
  cd "$1"

  for signal in HUP INT TERM; do
    root="$(mktemp -d)"
    old_target="$root/opt/signal-cli-native-0.0.0/signal-cli"
    link="$root/usr/local/bin/signal-cli"
    mkdir -p "$(dirname "$old_target")" "$(dirname "$link")"
    cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
    chmod +x "$old_target"
    ln -s "$old_target" "$link"

    set +e
    TEST_MODE=true TEST_UNAME_M=x86_64 TEST_SIGNAL="$signal" INSTALL_ROOT="$root" bash -c '\''
      set -Eeuo pipefail
      cd "$1"
      source ./install.sh
      create_service_user() {
        set_stage "forced lifecycle signal"
        kill -s "$TEST_SIGNAL" "$BASHPID"
        return 99
      }
      main \
        --no-link \
        --no-ufw \
        --no-fail2ban \
        --no-sysctl-hardening \
        --no-unattended-upgrades \
        --no-ssh-hardening \
        --install-mode native \
        --version 0.0.0 \
        --artifact-file "$2" \
        --sha256 "$3"
    '\'' bash "$1" "$2" "$3" "$signal" >/dev/null 2>&1
    install_rc=$?
    set -e

    case "$signal" in
      HUP) expected_rc=129 ;;
      INT) expected_rc=130 ;;
      TERM) expected_rc=143 ;;
    esac
    test "$install_rc" -eq "$expected_rc"
    test "$($link --version)" = "signal-cli 0.0.0 fixture"
  done
' bash "$ROOT_DIR" "$REPLACEMENT_NATIVE_FIXTURE_ARCHIVE" "$(file_sha256 "$REPLACEMENT_NATIVE_FIXTURE_ARCHIVE")"

expect_success "malformed JVM replacement preserves existing install" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  old_target="$root/opt/signal-cli-0.0.0/bin/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$link")"
  cp tests/fixtures/jvm/signal-cli-0.0.0/bin/signal-cli "$old_target"
  chmod +x "$old_target"
  ln -s "$old_target" "$link"
  output="$root/install-output"

  if TEST_MODE=true INSTALL_ROOT="$root" ./install.sh \
    --no-link \
    --no-ufw \
    --no-fail2ban \
    --no-sysctl-hardening \
    --no-unattended-upgrades \
    --no-ssh-hardening \
    --install-mode jvm \
    --version 0.0.0 \
    --artifact-file "$2" \
    --sha256 "$3" >"$output" 2>&1; then
    exit 1
  fi

  grep -Fq "Could not find JVM signal-cli launcher" "$output"
  test -x "$old_target"
  test "$(readlink "$link")" = "$old_target"
  test "$($link --version)" = "signal-cli 0.0.0 fixture"
' bash "$ROOT_DIR" "$MALFORMED_JVM_FIXTURE_ARCHIVE" "$(file_sha256 "$MALFORMED_JVM_FIXTURE_ARCHIVE")"

expect_success "JVM install refuses non-directory existing install paths" bash -c '
  set -Eeuo pipefail
  cd "$1"

  for existing_kind in symlink file; do
    root="$(mktemp -d)"
    install_dir="$root/opt/signal-cli-0.0.0"
    mkdir -p "$(dirname "$install_dir")"
    if [[ "$existing_kind" == symlink ]]; then
      victim="$root/operator-directory"
      mkdir -p "$victim"
      printf "preserve\n" >"$victim/sentinel"
      ln -s "$victim" "$install_dir"
    else
      printf "preserve\n" >"$install_dir"
    fi

    if TEST_MODE=true INSTALL_ROOT="$root" ./install.sh \
      --no-link \
      --no-ufw \
      --no-fail2ban \
      --no-sysctl-hardening \
      --no-unattended-upgrades \
      --no-ssh-hardening \
      --install-mode jvm \
      --version 0.0.0 \
      --artifact-file "$2" \
      --sha256 "$3" >/dev/null 2>&1; then
      exit 1
    fi

    if [[ "$existing_kind" == symlink ]]; then
      test -L "$install_dir"
      test "$(cat "$victim/sentinel")" = preserve
    else
      test -f "$install_dir"
      test ! -L "$install_dir"
      test "$(cat "$install_dir")" = preserve
    fi
    rm -rf "$root"
  done
' bash "$ROOT_DIR" "$JVM_FIXTURE_ARCHIVE" "$(file_sha256 "$JVM_FIXTURE_ARCHIVE")"

expect_success "JVM install preserves an unmarked operator-managed tree" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  old_target="$root/opt/signal-cli-0.0.0/bin/signal-cli"
  operator_file="$root/opt/signal-cli-0.0.0/operator-note"
  mkdir -p "$(dirname "$old_target")"
  cp tests/fixtures/jvm/signal-cli-0.0.0/bin/signal-cli "$old_target"
  chmod 0755 "$old_target"
  printf "preserve\n" >"$operator_file"

  if TEST_MODE=true INSTALL_ROOT="$root" ./install.sh \
    --no-link \
    --no-ufw \
    --no-fail2ban \
    --no-sysctl-hardening \
    --no-unattended-upgrades \
    --no-ssh-hardening \
    --install-mode jvm \
    --version 0.0.0 \
    --artifact-file "$2" \
    --sha256 "$3" >/dev/null 2>&1; then
    exit 1
  fi

  test -x "$old_target"
  test "$(cat "$operator_file")" = preserve
  test ! -e "$root/opt/signal-cli-0.0.0/.signal-cli-install-manifest"
' bash "$ROOT_DIR" "$JVM_FIXTURE_ARCHIVE" "$(file_sha256 "$JVM_FIXTURE_ARCHIVE")"

expect_success "failed JVM promotion restores existing install" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  old_target="$root/opt/signal-cli-0.0.0/bin/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  fake_bin="$root/fake-bin"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$link")" "$fake_bin"
  cp tests/fixtures/jvm/signal-cli-0.0.0/bin/signal-cli "$old_target"
  chmod +x "$old_target"
  printf "signal-cli-install-manifest-v1\nmode=jvm\nversion=0.0.0\n" >"$root/opt/signal-cli-0.0.0/.signal-cli-install-manifest"
  chmod 0444 "$root/opt/signal-cli-0.0.0/.signal-cli-install-manifest"
  ln -s "$old_target" "$link"

  real_mv="$(command -v mv)"
  cat >"$fake_bin/mv" <<'\''EOF'\''
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  */extract/signal-cli-0.0.0 | */.signal-cli-install.*/signal-cli-0.0.0)
    if [[ "${2:-}" == "$FAIL_MV_DEST" ]]; then
      exit 73
    fi
    ;;
esac
exec "$REAL_MV" "$@"
EOF
  chmod +x "$fake_bin/mv"
  output="$root/install-output"

  if PATH="$fake_bin:$PATH" REAL_MV="$real_mv" FAIL_MV_DEST="$root/opt/signal-cli-0.0.0" \
    TEST_MODE=true INSTALL_ROOT="$root" ./install.sh \
    --no-link \
    --no-ufw \
    --no-fail2ban \
    --no-sysctl-hardening \
    --no-unattended-upgrades \
    --no-ssh-hardening \
    --install-mode jvm \
    --version 0.0.0 \
    --artifact-file "$2" \
    --sha256 "$3" >"$output" 2>&1; then
    exit 1
  fi

  grep -Fq "Installer failed during stage '\''signal-cli install'\'' with exit code 73" "$output"
  test -x "$old_target"
  test "$(readlink "$link")" = "$old_target"
  test "$($link --version)" = "signal-cli 0.0.0 fixture"
' bash "$ROOT_DIR" "$JVM_FIXTURE_ARCHIVE" "$(file_sha256 "$JVM_FIXTURE_ARCHIVE")"

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

expect_success "device linking aborts when the running service cannot stop" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  runuser_marker="$(mktemp)"
  rm -f "$runuser_marker"
  RUN_LINK=true
  DRY_RUN=false
  TEST_MODE=false
  SIGNAL_CLI_SERVICE_WAS_ACTIVE=true
  maybe_systemctl() { return 33; }
  runuser() {
    : >"$runuser_marker"
    return 0
  }

  set +e
  (set -e; link_signal_device) >/dev/null 2>&1
  link_rc=$?
  set -e

  test "$link_rc" -eq 33
  test ! -e "$runuser_marker"
' bash "$ROOT_DIR"

expect_success "fresh device linking skips service stop when prior service was inactive" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  systemctl_marker="$(mktemp)"
  linked_marker="$(mktemp)"
  rm -f "$systemctl_marker" "$linked_marker"
  RUN_LINK=true
  DRY_RUN=false
  TEST_MODE=false
  SIGNAL_CLI_SERVICE_WAS_ACTIVE=false
  maybe_systemctl() {
    : >"$systemctl_marker"
    return 45
  }
  runuser() { printf "sgnl://linkdevice#fixture\n"; }
  render_signal_link_qr() {
    cat >/dev/null
    : >"$linked_marker"
  }

  link_signal_device >/dev/null

  test ! -e "$systemctl_marker"
  test -f "$linked_marker"
' bash "$ROOT_DIR"

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
printf "%s\n" "$*" >> "$QR_ARG_LOG"
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
  export QR_ARG_LOG="$work_dir/qr-args"
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
  grep -Fxq -- "-t ANSI" "$QR_ARG_LOG"
  ! grep -Fxq -- "-t utf8" "$QR_ARG_LOG"
' bash "$ROOT_DIR"

expect_success "fixture rollback switches symlink" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  mkdir -p "$root/opt/signal-cli-native-0.0.0" "$root/usr/local/bin"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$root/opt/signal-cli-native-0.0.0/signal-cli"
  chmod +x "$root/opt/signal-cli-native-0.0.0/signal-cli"
  TEST_MODE=true INSTALL_ROOT="$root" scripts/rollback-signal-cli.sh \
    --no-restart \
    --to-version 0.0.0 \
    --install-mode native >/dev/null
  test -L "$root/usr/local/bin/signal-cli"
  "$LIFECYCLE_LOCK_PROBE" "$1/install.sh" "$root" flock
' bash "$ROOT_DIR"

expect_success "rollback health check uses installed HTTP bind" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  target="$root/opt/signal-cli-native-0.0.0/signal-cli"
  mkdir -p "$(dirname "$target")" "$root/etc/default"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$target"
  chmod +x "$target"
  printf '\''SIGNAL_CLI_HTTP_BIND="127.0.0.1:9876"\n'\'' > "$root/etc/default/signal-cli"
  output="$root/rollback-output"

  TEST_MODE=true INSTALL_ROOT="$root" scripts/rollback-signal-cli.sh \
    --to-version 0.0.0 \
    --install-mode native >"$output"

  grep -Fq "skip health check http://127.0.0.1:9876/api/v1/check" "$output"
' bash "$ROOT_DIR"

expect_success "rollback refuses an unmanaged active binary" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  target="$root/opt/signal-cli-native-0.0.0/signal-cli"
  active="$root/usr/local/bin/signal-cli"
  mkdir -p "$(dirname "$target")" "$(dirname "$active")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$target"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$active"
  chmod +x "$target" "$active"

  if TEST_MODE=true INSTALL_ROOT="$root" scripts/rollback-signal-cli.sh \
    --no-restart \
    --to-version 0.0.0 \
    --install-mode native >/dev/null 2>&1; then
    exit 1
  fi

  test -f "$active"
  test ! -L "$active"
  test "$("$active" --version)" = "signal-cli 0.0.0 fixture"
' bash "$ROOT_DIR"

expect_success "rollback rejects a target reporting another version before activation" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  old_target="$root/opt/signal-cli-native-0.0.0/signal-cli"
  target="$root/opt/signal-cli-native-9.9.9/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$target")" "$(dirname "$link")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$target"
  chmod +x "$old_target" "$target"
  ln -s "$old_target" "$link"

  if TEST_MODE=true INSTALL_ROOT="$root" scripts/rollback-signal-cli.sh \
    --no-restart \
    --to-version 9.9.9 \
    --install-mode native >/dev/null 2>&1; then
    exit 1
  fi

  test "$(readlink -f "$link")" = "$(readlink -f "$old_target")"
' bash "$ROOT_DIR"

expect_success "rollback rejects untrusted targets before executing them as root" bash -c '
  set -Eeuo pipefail
  cd "$1"

  for trust_failure in writable_binary tampered_manifest; do
    root="$(mktemp -d)"
    install_dir="$root/opt/signal-cli-native-0.0.2"
    target="$install_dir/signal-cli"
    marker="$install_dir/.signal-cli-install-manifest"
    executed_marker="$root/target-executed"
    link="$root/usr/local/bin/signal-cli"
    output="$root/rollback-output"
    mkdir -p "$install_dir"
    printf "%s\n" \
      "#!/usr/bin/env bash" \
      "set -Eeuo pipefail" \
      ": >\"$executed_marker\"" \
      "printf \"signal-cli 0.0.2 fixture\\n\"" >"$target"
    chmod 0755 "$target"
    if [[ "$trust_failure" == writable_binary ]]; then
      chmod 0777 "$target"
    else
      printf "signal-cli-install-manifest-v1\nmode=native\nversion=9.9.9\n" >"$marker"
      chmod 0444 "$marker"
    fi

    set +e
    TEST_MODE=true INSTALL_ROOT="$root" scripts/rollback-signal-cli.sh \
      --no-restart \
      --to-version 0.0.2 \
      --install-mode native >"$output" 2>&1
    rollback_rc=$?
    set -e

    test "$rollback_rc" -ne 0
    test ! -e "$executed_marker"
    test ! -e "$link"
    test ! -L "$link"
  done
' bash "$ROOT_DIR"

expect_success "rollback restores previous target after active binary command failure" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  old_target="$root/opt/signal-cli-native-0.0.0/signal-cli"
  target="$root/opt/signal-cli-native-0.0.1/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$target")" "$(dirname "$link")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
  printf '\''%s\n'\'' \
    '\''#!/usr/bin/env bash'\'' \
    '\''set -euo pipefail'\'' \
    '\''if [[ "${1:-}" == "--version" ]]; then'\'' \
    '\''  if [[ "$0" == */usr/local/bin/signal-cli ]]; then exit 73; fi'\'' \
    '\''  echo "signal-cli 0.0.1 fixture"'\'' \
    '\''fi'\'' > "$target"
  chmod +x "$old_target" "$target"
  ln -s "$old_target" "$link"
  output="$root/rollback-output"

  set +e
  TEST_MODE=true INSTALL_ROOT="$root" scripts/rollback-signal-cli.sh \
    --no-restart \
    --to-version 0.0.1 \
    --install-mode native >"$output" 2>&1
  rollback_rc=$?
  set -e

  test "$rollback_rc" -eq 73
  test "$(readlink -f "$link")" = "$(readlink -f "$old_target")"
  test "$("$link" --version)" = "signal-cli 0.0.0 fixture"
' bash "$ROOT_DIR"

expect_success "rollback restores previous target after service restart failure" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  old_target="$root/opt/signal-cli-native-0.0.0/signal-cli"
  target="$root/opt/signal-cli-native-0.0.1/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$target")" "$(dirname "$link")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
  sed '\''s/0\.0\.0/0.0.1/g'\'' tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli > "$target"
  chmod +x "$old_target" "$target"
  ln -s "$old_target" "$link"
  output="$root/rollback-output"

  set +e
  TEST_MODE=true INSTALL_ROOT="$root" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    set -- --dry-run --to-version 0.0.1 --install-mode native
    source scripts/rollback-signal-cli.sh >/dev/null
    DRY_RUN=false
    maybe_systemctl() {
      if [[ "${1:-}" == "is-active" ]]; then
        printf "inactive\n"
        return 3
      fi
      return 71
    }
    journalctl() { :; }
    main_rollback --to-version 0.0.1 --install-mode native
  '\'' bash "$1" >"$output" 2>&1
  rollback_rc=$?
  set -e

  test "$rollback_rc" -eq 71
  test "$(readlink -f "$link")" = "$(readlink -f "$old_target")"
  test "$("$link" --version)" = "signal-cli 0.0.0 fixture"
' bash "$ROOT_DIR"

expect_success "rollback restores previous target after health failure" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  old_target="$root/opt/signal-cli-native-0.0.0/signal-cli"
  target="$root/opt/signal-cli-native-0.0.1/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$target")" "$(dirname "$link")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
  sed '\''s/0\.0\.0/0.0.1/g'\'' tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli > "$target"
  chmod +x "$old_target" "$target"
  ln -s "$old_target" "$link"
  systemctl_log="$root/systemctl-log"
  output="$root/rollback-output"

  set +e
  TEST_MODE=true INSTALL_ROOT="$root" SYSTEMCTL_LOG="$systemctl_log" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    set -- --dry-run --to-version 0.0.1 --install-mode native
    source scripts/rollback-signal-cli.sh >/dev/null
    DRY_RUN=false
    maybe_systemctl() {
      if [[ "${1:-}" == "is-active" ]]; then
        printf "inactive\n"
        return 3
      fi
      printf "%s %s\n" "${1:-}" "${2:-}" >> "$SYSTEMCTL_LOG"
    }
    health_check() { return 72; }
    journalctl() { :; }
    main_rollback --to-version 0.0.1 --install-mode native
  '\'' bash "$1" >"$output" 2>&1
  rollback_rc=$?
  set -e

  test "$rollback_rc" -eq 72
  test "$(readlink -f "$link")" = "$(readlink -f "$old_target")"
  test "$("$link" --version)" = "signal-cli 0.0.0 fixture"
  test "$(grep -Fxc "restart signal-cli" "$systemctl_log")" -eq 1
  grep -Fxq "stop signal-cli" "$systemctl_log"
' bash "$ROOT_DIR"

expect_success "failed rollback restores absence of an active binary" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  target="$root/opt/signal-cli-native-0.0.0/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  systemctl_log="$root/systemctl-log"
  mkdir -p "$(dirname "$target")"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$target"
  chmod +x "$target"
  output="$root/rollback-output"

  set +e
  TEST_MODE=true INSTALL_ROOT="$root" SYSTEMCTL_LOG="$systemctl_log" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    set -- --dry-run --no-restart --to-version 0.0.0 --install-mode native
    source scripts/rollback-signal-cli.sh >/dev/null
    DRY_RUN=false
    maybe_systemctl() {
      printf "%s %s\n" "${1:-}" "${2:-}" >> "$SYSTEMCTL_LOG"
      if [[ "${1:-}" == "is-active" ]]; then
        printf "inactive\n"
        return 3
      fi
    }
    health_check() {
      [[ -L "$LOCAL_BIN_DIR/signal-cli" ]] || return 98
      return 74
    }
    journalctl() { :; }
    main_rollback --to-version 0.0.0 --install-mode native
  '\'' bash "$1" >"$output" 2>&1
  rollback_rc=$?
  set -e

  test "$rollback_rc" -eq 74
  test ! -e "$link"
  test ! -L "$link"
  grep -Fxq "stop signal-cli" "$systemctl_log"
' bash "$ROOT_DIR"

expect_success "rollback restores previous target on HUP INT and TERM" bash -c '
  set -Eeuo pipefail
  cd "$1"

  for signal_and_rc in HUP:129 INT:130 TERM:143; do
    signal="${signal_and_rc%%:*}"
    expected_rc="${signal_and_rc##*:}"
    root="$(mktemp -d)"
    old_target="$root/opt/signal-cli-native-0.0.0/signal-cli"
    target="$root/opt/signal-cli-native-0.0.1/signal-cli"
    link="$root/usr/local/bin/signal-cli"
    mkdir -p "$(dirname "$old_target")" "$(dirname "$target")" "$(dirname "$link")"
    cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
    sed '\''s/0\.0\.0/0.0.1/g'\'' tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli > "$target"
    chmod +x "$old_target" "$target"
    ln -s "$old_target" "$link"

    set +e
    TEST_MODE=true TEST_SIGNAL="$signal" INSTALL_ROOT="$root" bash -c '\''
      set -Eeuo pipefail
      cd "$1"
      set -- --dry-run --to-version 0.0.1 --install-mode native
      source scripts/rollback-signal-cli.sh >/dev/null
      DRY_RUN=false
      signal_sent=false
      maybe_systemctl() {
        if [[ "${1:-}" == "is-active" ]]; then
          printf "active\n"
          return 0
        fi
        if ! is_true "$signal_sent"; then
          signal_sent=true
          kill -s "$TEST_SIGNAL" "$BASHPID"
        fi
      }
      health_check() { return 99; }
      main_rollback --to-version 0.0.1 --install-mode native
    '\'' bash "$1" >/dev/null 2>&1
    rollback_rc=$?
    set -e

    test "$rollback_rc" -eq "$expected_rc"
    test "$(readlink -f "$link")" = "$(readlink -f "$old_target")"
    test "$("$link" --version)" = "signal-cli 0.0.0 fixture"
    rm -rf "$root"
  done
' bash "$ROOT_DIR"

expect_success "rollback --no-restart skips service-state capture and malformed config" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  target="$root/opt/signal-cli-native-0.0.0/signal-cli"
  capture_probe="$root/service-state-captured"
  mkdir -p "$(dirname "$target")" "$root/etc/default"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$target"
  chmod 0755 "$target"
  printf "SIGNAL_CLI_HTTP_BIND=not-a-valid-bind\n" >"$root/etc/default/signal-cli"

  TEST_MODE=true INSTALL_ROOT="$root" CAPTURE_PROBE="$capture_probe" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    set -- --dry-run --to-version 0.0.0 --install-mode native
    source scripts/rollback-signal-cli.sh >/dev/null
    DRY_RUN=false
    capture_signal_cli_service_state() {
      : >"$CAPTURE_PROBE"
      return 91
    }
    journalctl() { :; }
    main_rollback --no-restart --to-version 0.0.0 --install-mode native >/dev/null
  '\'' bash "$1"

  test ! -e "$capture_probe"
  test "$(readlink -f "$root/usr/local/bin/signal-cli")" = "$(readlink -f "$target")"
' bash "$ROOT_DIR"

expect_success "occupied lifecycle lock blocks rollback mutation" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  old_target="$root/opt/signal-cli-native-0.0.0/signal-cli"
  target="$root/opt/signal-cli-native-0.0.1/signal-cli"
  link="$root/usr/local/bin/signal-cli"
  ready="$root/lock-ready"
  release_fifo="$root/lock-release"
  mkdir -p "$(dirname "$old_target")" "$(dirname "$target")" "$(dirname "$link")"
  mkfifo "$release_fifo"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$old_target"
  sed '\''s/0\.0\.0/0.0.1/g'\'' tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli > "$target"
  chmod +x "$old_target" "$target"
  ln -s "$old_target" "$link"

  "$LIFECYCLE_LOCK_HOLDER" "$1/install.sh" "$root" "$ready" "$release_fifo" &
  holder_pid=$!
  cleanup_holder() {
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
  }
  trap cleanup_holder EXIT
  for _ in {1..100}; do
    [[ -e "$ready" ]] && break
    sleep 0.02
  done
  test -e "$ready"

  if TEST_MODE=true INSTALL_ROOT="$root" scripts/rollback-signal-cli.sh \
    --no-restart \
    --to-version 0.0.1 \
    --install-mode native >/dev/null 2>&1; then
    exit 1
  fi

  test "$(readlink -f "$link")" = "$(readlink -f "$old_target")"
  printf "release\n" >"$release_fifo"
  wait "$holder_pid"
  trap - EXIT
' bash "$ROOT_DIR"

expect_success "rollback dry-run does not contend for lifecycle lock" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  trap '\''rm -rf "$root"'\'' EXIT
  mkdir -p "$root/run"
  : >"$root/run/signal-cli-lifecycle.lock"
  TEST_MODE=true INSTALL_ROOT="$root" scripts/rollback-signal-cli.sh \
    --dry-run \
    --to-version 0.0.0 \
    --install-mode native >/dev/null
' bash "$ROOT_DIR"

expect_failure "rollback refuses missing target" env TEST_MODE=true INSTALL_ROOT="$(mktemp -d)" "$ROOT_DIR/scripts/rollback-signal-cli.sh" --no-restart --to-version 9.9.9 --install-mode native

expect_failure "rollback rejects path traversal version" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  mkdir -p "$root/opt/signal-cli-native-0.0.0" "$root/tmp/evil" "$root/usr/local/bin"
  printf "#!/usr/bin/env bash\nprintf fake-version\\\\n\n" > "$root/tmp/evil/signal-cli"
  chmod +x "$root/tmp/evil/signal-cli"
  TEST_MODE=true INSTALL_ROOT="$root" scripts/rollback-signal-cli.sh \
    --no-restart \
    --to-version "0.0.0/../../tmp/evil" \
    --install-mode native >/dev/null
' bash "$ROOT_DIR"

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

expect_success "installed HTTP bind loader accepts one exact validated assignment" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  INSTALL_ROOT="$root"
  source ./install.sh
  mkdir -p "$(dirname "$CONFIG_FILE")"
  printf '\''SIGNAL_CLI_ACCOUNT="+31612345678"\nSIGNAL_CLI_HTTP_BIND="[2001:db8::1]:9876"\n'\'' >"$CONFIG_FILE"
  ALLOW_PUBLIC_BIND=false

  load_installed_http_bind
  test "$HTTP_BIND" = "[2001:db8::1]:9876"
' bash "$ROOT_DIR"

expect_failure "installed HTTP bind loader rejects duplicate assignments" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  INSTALL_ROOT="$root"
  source ./install.sh
  mkdir -p "$(dirname "$CONFIG_FILE")"
  printf '\''SIGNAL_CLI_HTTP_BIND="127.0.0.1:8080"\nSIGNAL_CLI_HTTP_BIND="127.0.0.1:9876"\n'\'' >"$CONFIG_FILE"
  load_installed_http_bind
' bash "$ROOT_DIR"

expect_success "installed HTTP bind loader never evaluates config content" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  marker="$root/evaluated"
  INSTALL_ROOT="$root"
  source ./install.sh
  mkdir -p "$(dirname "$CONFIG_FILE")"
  printf '\''SIGNAL_CLI_HTTP_BIND="$(touch %s):8080"\n'\'' "$marker" >"$CONFIG_FILE"
  if (load_installed_http_bind >/dev/null 2>&1); then
    exit 1
  fi
  test ! -e "$marker"
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

expect_success "health check polls until a later attempt succeeds" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  attempts_file="$(mktemp)"
  printf "0\n" >"$attempts_file"
  DRY_RUN=false
  TEST_MODE=false
  HTTP_BIND=127.0.0.1:8080
  HEALTH_CHECK_MAX_ATTEMPTS=5
  HEALTH_CHECK_INTERVAL_SECONDS=0
  sleep() { :; }
  curl() {
    attempts="$(cat "$attempts_file")"
    attempts=$((attempts + 1))
    printf "%s\n" "$attempts" >"$attempts_file"
    ((attempts >= 3))
  }
  journalctl() { :; }

  health_check >/dev/null
  test "$(cat "$attempts_file")" = 3
' bash "$ROOT_DIR"

expect_success "every health request has finite connection and response timeouts" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  args_file="$(mktemp)"
  DRY_RUN=false
  TEST_MODE=false
  HTTP_BIND=127.0.0.1:8080
  HEALTH_CHECK_MAX_ATTEMPTS=1
  HEALTH_CHECK_CONNECT_TIMEOUT_SECONDS=3
  HEALTH_CHECK_REQUEST_TIMEOUT_SECONDS=7
  curl() {
    printf "%s\n" "$@" >"$args_file"
    return 0
  }

  health_check >/dev/null
  awk '\''
    $0 == "--connect-timeout" { getline; connect = $0 }
    $0 == "--max-time" { getline; request = $0 }
    END { exit !(connect == 3 && request == 7) }
  '\'' "$args_file"
' bash "$ROOT_DIR"

expect_failure "health check fails when daemon is unreachable" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  DRY_RUN=false
  TEST_MODE=false
  HTTP_BIND=127.0.0.1:9
  sleep() { :; }
  curl() { return 7; }
  journalctl() { :; }
  health_check
' bash "$ROOT_DIR"

expect_failure "ufw refuses when SSH port detection fails" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  DRY_RUN=true
  TEST_MODE=false
  ENABLE_UFW=true
  detected_ssh_ports() { return 1; }
  configure_ufw
' bash "$ROOT_DIR"

expect_success "service-state capture classifies transitional and error states" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  TEST_SERVICE_STATE=""
  TEST_SERVICE_RC=0
  maybe_systemctl() {
    printf "%s\n" "$TEST_SERVICE_STATE"
    return "$TEST_SERVICE_RC"
  }

  for TEST_SERVICE_STATE in active activating reloading deactivating; do
    TEST_SERVICE_RC=0
    [[ "$TEST_SERVICE_STATE" != deactivating ]] || TEST_SERVICE_RC=3
    SIGNAL_CLI_SERVICE_WAS_ACTIVE=false
    capture_signal_cli_service_state
    is_true "$SIGNAL_CLI_SERVICE_WAS_ACTIVE"
  done

  for TEST_SERVICE_STATE in inactive failed not-found; do
    TEST_SERVICE_RC=3
    SIGNAL_CLI_SERVICE_WAS_ACTIVE=true
    capture_signal_cli_service_state
    ! is_true "$SIGNAL_CLI_SERVICE_WAS_ACTIVE"
  done

  for TEST_SERVICE_STATE in unknown "Failed to connect to bus: No such file or directory"; do
    TEST_SERVICE_RC=1
    SIGNAL_CLI_SERVICE_WAS_ACTIVE=true
    if capture_signal_cli_service_state 2>/dev/null; then
      exit 1
    fi
    ! is_true "$SIGNAL_CLI_SERVICE_WAS_ACTIVE"
  done
' bash "$ROOT_DIR"

expect_failure "service-state restore reports a required stop failure" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  SIGNAL_CLI_SERVICE_STATE_MUTATED=true
  SIGNAL_CLI_SERVICE_WAS_ACTIVE=false
  maybe_systemctl() { return 71; }
  restore_previous_signal_cli_state
' bash "$ROOT_DIR"

expect_success "failed replacement recovery never retries through root failed-install" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  command_log="$root/recovery-commands"
  INSTALL_ROOT="$root"
  source ./install.sh
  mkdir -p "$OPT_DIR" "$OPT_DIR/signal-cli-0.0.0" "$LOCAL_BIN_DIR"
  SIGNAL_CLI_STAGING_DIR="$(mktemp -d "$OPT_DIR/.signal-cli-install.XXXXXX")"
  original_staging_dir="$SIGNAL_CLI_STAGING_DIR"
  mkdir -p "$SIGNAL_CLI_STAGING_DIR/previous-install"
  SIGNAL_CLI_REPLACED_KIND=directory
  SIGNAL_CLI_REPLACED_PATH="$OPT_DIR/signal-cli-0.0.0"
  SIGNAL_CLI_REPLACED_BACKUP="$SIGNAL_CLI_STAGING_DIR/previous-install"
  run_cmd() {
    if [[ "${1:-}" == rm && "${2:-}" == -rf ]]; then
      printf "%s\n" "${3:-}" >>"$command_log"
    fi
    if [[ "${1:-}" == mv && "${2:-}" == "$SIGNAL_CLI_REPLACED_PATH" ]]; then
      return 77
    fi
  }

  restore_previous_signal_cli_state || true
  restore_previous_signal_cli_state || true

  test "$SIGNAL_CLI_STAGING_DIR" = "$original_staging_dir"
  test "$SIGNAL_CLI_PRESERVE_STAGING_DIR" = true
  test -z "$SIGNAL_CLI_REPLACED_KIND"
  ! grep -Fxq "/failed-install" "$command_log"
' bash "$ROOT_DIR"

expect_failure "existing login-enabled signal-cli user is rejected" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  TEST_MODE=false
  getent() {
    case "${1:-}:${2:-}" in
      group:signal-cli) printf "signal-cli:x:1000:\n" ;;
      passwd:signal-cli) printf "signal-cli:x:1000:1000:Existing User:/var/lib/signal-cli:/bin/bash\n" ;;
      *) return 2 ;;
    esac
  }
  id() {
    [[ "${1:-}" == -u && "${2:-}" == signal-cli ]]
  }
  run_cmd() { :; }

  create_service_user
' bash "$ROOT_DIR"

expect_failure "existing signal-cli user rejects a deceptive false-suffix shell" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  TEST_MODE=false
  getent() {
    case "${1:-}:${2:-}" in
      group:signal-cli) printf "signal-cli:x:1000:\n" ;;
      passwd:signal-cli) printf "signal-cli:x:1000:1000:Existing User:/var/lib/signal-cli:/tmp/attacker/false\n" ;;
      *) return 2 ;;
    esac
  }
  id() {
    [[ "${1:-}" == -u && "${2:-}" == signal-cli ]]
  }
  run_cmd() { :; }

  create_service_user
' bash "$ROOT_DIR"

expect_failure "existing signal-cli identity cannot resolve to root" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  TEST_MODE=false
  getent() {
    case "${1:-}:${2:-}" in
      group:signal-cli) printf "signal-cli:x:1000:\n" ;;
      passwd:signal-cli) printf "signal-cli:x:0:1000:Service User:/var/lib/signal-cli:/usr/sbin/nologin\n" ;;
      *) return 2 ;;
    esac
  }
  id() {
    [[ "${1:-}" == -u && "${2:-}" == signal-cli ]]
  }
  run_cmd() { :; }

  create_service_user
' bash "$ROOT_DIR"

expect_failure "existing signal-cli group cannot resolve to GID 0 when user is absent" bash -c '
  set -Eeuo pipefail
  cd "$1"
  source ./install.sh
  TEST_MODE=false
  getent() {
    case "${1:-}:${2:-}" in
      group:signal-cli) printf "signal-cli:x:0:\n" ;;
      *) return 2 ;;
    esac
  }
  id() {
    [[ "${1:-}" == -u && "${2:-}" == signal-cli ]] && return 1
    return 2
  }
  run_cmd() { :; }

  create_service_user
' bash "$ROOT_DIR"

expect_success "SSH hardening signals restore prior file or prior absence and remove backups" bash -c '
  set -Eeuo pipefail
  cd "$1"
  file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
  file_owner() { stat -c %u "$1" 2>/dev/null || stat -f %u "$1"; }
  file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

  for prior_state in existing absent; do
    for signal_and_rc in HUP:129 INT:130 TERM:143; do
      signal="${signal_and_rc%%:*}"
      expected_rc="${signal_and_rc##*:}"
      root="$(mktemp -d)"
      fake_bin="$root/fake-bin"
      config="$root/etc/ssh/sshd_config.d/99-signal-cli-hardening.conf"
      backup_marker="$root/backup-path"
      reload_log="$root/reload-log"
      output="$root/hardening-output"
      mkdir -p "$fake_bin" "$(dirname "$config")"
      printf "#!/usr/bin/env bash\nexit 0\n" >"$fake_bin/sshd"
      chmod +x "$fake_bin/sshd"
      if [[ "$prior_state" == existing ]]; then
        printf "operator-policy\n" >"$config"
        chmod 0600 "$config"
        touch -t 202001020304.05 "$config"
        expected_mode="$(file_mode "$config")"
        expected_owner="$(file_owner "$config")"
        expected_mtime="$(file_mtime "$config")"
      fi

      set +e
      PATH="$fake_bin:$PATH" TEST_MODE=true INSTALL_ROOT="$root" TEST_SIGNAL="$signal" BACKUP_MARKER="$backup_marker" RELOAD_LOG="$reload_log" bash -c '\''
        set -Eeuo pipefail
        source ./install.sh
        trap "on_lifecycle_signal HUP" HUP
        trap "on_lifecycle_signal INT" INT
        trap "on_lifecycle_signal TERM" TERM
        trap cleanup EXIT
        SSH_HARDENING=true
        signal_sent=false
        maybe_systemctl() {
          if is_true "${SSH_HARDENING_RESTORE_IN_PROGRESS:-false}"; then
            printf "restore %s %s\n" "${1:-}" "${2:-}" >>"$RELOAD_LOG"
            return 0
          fi
          if ! is_true "$signal_sent"; then
            signal_sent=true
            printf "%s\n" "${SSH_HARDENING_BACKUP_DIR:-}" >"$BACKUP_MARKER"
            kill -s "$TEST_SIGNAL" "$BASHPID"
          fi
          return 0
        }
        configure_ssh_hardening
      '\'' >"$output" 2>&1
      hardening_rc=$?
      set -e

      test "$hardening_rc" -eq "$expected_rc"
      if [[ "$prior_state" == existing ]]; then
        test "$(cat "$config")" = operator-policy
        test "$(file_mode "$config")" = "$expected_mode"
        test "$(file_owner "$config")" = "$expected_owner"
        test "$(file_mtime "$config")" = "$expected_mtime"
      else
        test ! -e "$config"
        test ! -L "$config"
      fi
      backup_dir="$(cat "$backup_marker")"
      test -n "$backup_dir"
      test ! -e "$backup_dir"
      grep -Fq "restore " "$reload_log"
    done
  done
' bash "$ROOT_DIR"

expect_success "SSH signal after successful reload re-applies the restored policy" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  fake_bin="$root/fake-bin"
  config="$root/etc/ssh/sshd_config.d/99-signal-cli-hardening.conf"
  backup_marker="$root/backup-path"
  reload_log="$root/reload-log"
  mkdir -p "$fake_bin" "$(dirname "$config")"
  printf "#!/usr/bin/env bash\nexit 0\n" >"$fake_bin/sshd"
  chmod +x "$fake_bin/sshd"
  printf "operator-policy\n" >"$config"
  chmod 0600 "$config"

  set +e
  PATH="$fake_bin:$PATH" TEST_MODE=true INSTALL_ROOT="$root" BACKUP_MARKER="$backup_marker" RELOAD_LOG="$reload_log" bash -c '\''
    set -Eeuo pipefail
    source ./install.sh
    trap "on_lifecycle_signal TERM" TERM
    trap cleanup EXIT
    SSH_HARDENING=true
    signal_scheduled=false
    maybe_systemctl() {
      if is_true "${SSH_HARDENING_RESTORE_IN_PROGRESS:-false}"; then
        printf "restored-policy-reloaded\n" >>"$RELOAD_LOG"
        return 0
      fi
      if ! is_true "$signal_scheduled"; then
        signal_scheduled=true
        printf "%s\n" "${SSH_HARDENING_BACKUP_DIR:-}" >"$BACKUP_MARKER"
        trap "trap - RETURN; kill -TERM \$BASHPID" RETURN
      fi
      return 0
    }
    configure_ssh_hardening
  '\'' >/dev/null 2>&1
  hardening_rc=$?
  set -e

  test "$hardening_rc" -eq 143
  test "$(cat "$config")" = operator-policy
  grep -Fxq "restored-policy-reloaded" "$reload_log"
  backup_dir="$(cat "$backup_marker")"
  test -n "$backup_dir"
  test ! -e "$backup_dir"
' bash "$ROOT_DIR"

expect_success "unexpected EXIT after SSH replacement restores and cleans the prior state" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  fake_bin="$root/fake-bin"
  config="$root/etc/ssh/sshd_config.d/99-signal-cli-hardening.conf"
  backup_marker="$root/backup-path"
  mkdir -p "$fake_bin" "$(dirname "$config")"
  printf "#!/usr/bin/env bash\nexit 0\n" >"$fake_bin/sshd"
  chmod +x "$fake_bin/sshd"
  printf "operator-policy\n" >"$config"
  chmod 0600 "$config"

  set +e
  PATH="$fake_bin:$PATH" TEST_MODE=true INSTALL_ROOT="$root" BACKUP_MARKER="$backup_marker" bash -c '\''
    set -Eeuo pipefail
    source ./install.sh
    trap cleanup EXIT
    SSH_HARDENING=true
    maybe_systemctl() {
      if is_true "${SSH_HARDENING_RESTORE_IN_PROGRESS:-false}"; then
        return 0
      fi
      printf "%s\n" "${SSH_HARDENING_BACKUP_DIR:-}" >"$BACKUP_MARKER"
      exit 77
    }
    configure_ssh_hardening
  '\'' >/dev/null 2>&1
  hardening_rc=$?
  set -e

  test "$hardening_rc" -eq 77
  test "$(cat "$config")" = operator-policy
  test "$(stat -c %a "$config" 2>/dev/null || stat -f %Lp "$config")" = 600
  backup_dir="$(cat "$backup_marker")"
  test -n "$backup_dir"
  test ! -e "$backup_dir"
' bash "$ROOT_DIR"

expect_success "failed SSH restoration preserves and reports its recovery backup" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  fake_bin="$root/fake-bin"
  config="$root/etc/ssh/sshd_config.d/99-signal-cli-hardening.conf"
  backup_marker="$root/backup-path"
  output="$root/hardening-output"
  mkdir -p "$fake_bin" "$(dirname "$config")"
  printf "#!/usr/bin/env bash\nexit 0\n" >"$fake_bin/sshd"
  chmod +x "$fake_bin/sshd"
  printf "operator-policy\n" >"$config"
  chmod 0600 "$config"

  set +e
  PATH="$fake_bin:$PATH" TEST_MODE=true INSTALL_ROOT="$root" BACKUP_MARKER="$backup_marker" bash -c '\''
    set -Eeuo pipefail
    source ./install.sh
    trap "on_lifecycle_signal TERM" TERM
    trap cleanup EXIT
    SSH_HARDENING=true
    signal_sent=false
    cp() {
      if is_true "${SSH_HARDENING_RESTORE_IN_PROGRESS:-false}"; then
        return 97
      fi
      command cp "$@"
    }
    maybe_systemctl() {
      if ! is_true "$signal_sent"; then
        signal_sent=true
        printf "%s\n" "${SSH_HARDENING_BACKUP_DIR:-}" >"$BACKUP_MARKER"
        kill -TERM "$BASHPID"
      fi
      return 0
    }
    configure_ssh_hardening
  '\'' >"$output" 2>&1
  hardening_rc=$?
  set -e

  test "$hardening_rc" -eq 143
  backup_dir="$(cat "$backup_marker")"
  test -n "$backup_dir"
  test -d "$backup_dir"
  test -f "$backup_dir/ssh-hardening.conf"
  grep -Fq "$backup_dir" "$output"
' bash "$ROOT_DIR"

expect_success "SSH backup deletion failure after restore does not poison service-state recovery" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  previous_target="$root/opt/signal-cli-native-previous/signal-cli"
  active_link="$root/usr/local/bin/signal-cli"
  systemctl_log="$root/systemctl-log"
  mkdir -p "$(dirname "$previous_target")" "$(dirname "$active_link")" "$root/etc/ssh/sshd_config.d"
  cp tests/fixtures/native/signal-cli-0.0.0-Linux-native/signal-cli "$previous_target"
  chmod 0755 "$previous_target"
  ln -s "$previous_target" "$active_link"

  TEST_MODE=true INSTALL_ROOT="$root" PREVIOUS_TARGET="$previous_target" SYSTEMCTL_LOG="$systemctl_log" bash -c '\''
    set -Eeuo pipefail
    source ./install.sh
    begin_ssh_hardening_transaction
    printf "replacement-policy\n" >"$SSH_HARDENING_FILE"
    recovery_dir="$SSH_HARDENING_BACKUP_DIR"
    SIGNAL_CLI_PREVIOUS_TARGET="$PREVIOUS_TARGET"
    SIGNAL_CLI_SERVICE_WAS_ACTIVE="true"
    SIGNAL_CLI_SERVICE_STATE_MUTATED="true"
    rm() {
      if [[ "${1:-}" == -rf && "${2:-}" == -- && "${3:-}" == "$recovery_dir" ]]; then
        return 88
      fi
      command rm "$@"
    }
    maybe_systemctl() {
      printf "%s %s\n" "${1:-}" "${2:-}" >>"$SYSTEMCTL_LOG"
      return 0
    }

    restore_previous_signal_cli_state
    test "$SSH_HARDENING_TRANSACTION_ACTIVE" == false
    test -d "$recovery_dir"
  '\'' >/dev/null 2>&1

  grep -Fxq "restart signal-cli" "$systemctl_log"
  ! grep -Fxq "stop signal-cli" "$systemctl_log"
' bash "$ROOT_DIR"

expect_success "SSH commit treats post-disarm backup deletion as best-effort" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  mkdir -p "$root/etc/ssh/sshd_config.d"

  TEST_MODE=true INSTALL_ROOT="$root" bash -c '\''
    set -Eeuo pipefail
    source ./install.sh
    begin_ssh_hardening_transaction
    recovery_dir="$SSH_HARDENING_BACKUP_DIR"
    rm() {
      if [[ "${1:-}" == -rf && "${2:-}" == -- && "${3:-}" == "$recovery_dir" ]]; then
        return 89
      fi
      command rm "$@"
    }

    commit_ssh_hardening_transaction
    test "$SSH_HARDENING_TRANSACTION_ACTIVE" == false
    test -d "$recovery_dir"
  '\'' >/dev/null 2>&1
' bash "$ROOT_DIR"

expect_success "SSH hardening reload failure restores prior file state" bash -c '
  set -Eeuo pipefail
  cd "$1"
  file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

  for prior_state in absent existing; do
    root="$(mktemp -d)"
    fake_bin="$root/fake-bin"
    config="$root/etc/ssh/sshd_config.d/99-signal-cli-hardening.conf"
    mkdir -p "$fake_bin" "$(dirname "$config")"
    printf "#!/usr/bin/env bash\nexit 0\n" >"$fake_bin/sshd"
    chmod +x "$fake_bin/sshd"
    if [[ "$prior_state" == existing ]]; then
      printf "operator-policy\n" >"$config"
      chmod 0600 "$config"
    fi

    set +e
    PATH="$fake_bin:$PATH" TEST_MODE=true INSTALL_ROOT="$root" bash -c '\''
      set -Eeuo pipefail
      cd "$1"
      source ./install.sh
      SSH_HARDENING=true
      maybe_systemctl() { return 1; }
      configure_ssh_hardening
    '\'' bash "$1" >/dev/null 2>&1
    hardening_rc=$?
    set -e

    test "$hardening_rc" -ne 0
    if [[ "$prior_state" == existing ]]; then
      test "$(cat "$config")" = operator-policy
      test "$(file_mode "$config")" = 600
    else
      test ! -e "$config"
      test ! -L "$config"
    fi
  done
' bash "$ROOT_DIR"

expect_success "SSH config validation failure restores the previous hardening file" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  fake_bin="$root/fake-bin"
  config="$root/etc/ssh/sshd_config.d/99-signal-cli-hardening.conf"
  mkdir -p "$fake_bin" "$(dirname "$config")"
  printf "#!/usr/bin/env bash\nexit 37\n" >"$fake_bin/sshd"
  chmod 0755 "$fake_bin/sshd"
  printf "operator-policy\n" >"$config"
  chmod 0600 "$config"

  set +e
  PATH="$fake_bin:$PATH" TEST_MODE=false INSTALL_ROOT="$root" bash -c '\''
    set -Eeuo pipefail
    cd "$1"
    source ./install.sh
    SSH_HARDENING=true
    chown() { :; }
    configure_ssh_hardening
  '\'' bash "$1" >/dev/null 2>&1
  hardening_rc=$?
  set -e

  test "$hardening_rc" -ne 0
  test "$(cat "$config")" = operator-policy
' bash "$ROOT_DIR"

expect_success "fail2ban uses installer-specific jail file" bash -c '
  set -Eeuo pipefail
  cd "$1"
  root="$(mktemp -d)"
  mkdir -p "$root/etc/fail2ban/jail.d"
  printf "custom-policy\n" > "$root/etc/fail2ban/jail.d/sshd.local"
  TEST_MODE=true INSTALL_ROOT="$root" bash -c "source ./install.sh; configure_fail2ban" >/dev/null
  test -f "$root/etc/fail2ban/jail.d/99-signal-cli-sshd.local"
  test "$(cat "$root/etc/fail2ban/jail.d/sshd.local")" = "custom-policy"
' bash "$ROOT_DIR"

printf '\nTests passed: %d\n' "$PASS_COUNT"
if [[ "$FAIL_COUNT" -ne 0 ]]; then
  printf 'Tests failed: %d\n' "$FAIL_COUNT" >&2
  exit 1
fi
