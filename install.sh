#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SERVICE_USER="signal-cli"
SERVICE_GROUP="signal-cli"
DATA_DIR="/var/lib/signal-cli"
CONFIG_FILE="/etc/default/signal-cli"
WRAPPER_FILE="/usr/local/sbin/signal-cli-daemon-start"
SERVICE_FILE="/etc/systemd/system/signal-cli.service"
FAIL2BAN_FILE="/etc/fail2ban/jail.d/sshd.local"
SYSCTL_FILE="/etc/sysctl.d/99-signal-cli-server-hardening.conf"
SSH_HARDENING_FILE="/etc/ssh/sshd_config.d/99-signal-cli-hardening.conf"

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

VERIFY_MODE="${VERIFY_MODE:-auto}" # auto | sha256 | none
ALLOW_UNVERIFIED_DOWNLOAD="${ALLOW_UNVERIFIED_DOWNLOAD:-false}"
EXPECTED_SHA256="${EXPECTED_SHA256:-}"
CHECKSUM_URL="${CHECKSUM_URL:-}"
ALLOW_PUBLIC_BIND="${ALLOW_PUBLIC_BIND:-false}"
DRY_RUN="${DRY_RUN:-false}"
TEST_MODE="${TEST_MODE:-false}"

RESOLVED_VERSION=""
SIGNAL_CLI_ASSET=""
SIGNAL_CLI_URL=""
SIGNAL_CLI_TMPDIR=""
SIGNAL_CLI_ARTIFACT=""
BASE_PACKAGES=()
CURRENT_STAGE="startup"

log() { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

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
  is_true "$DRY_RUN" || is_true "$TEST_MODE"
}

set_stage() {
  CURRENT_STAGE="$1"
}

on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-unknown}
  warn "Installer failed during stage '$CURRENT_STAGE' with exit code $exit_code near line $line_no."
  if ! is_dry_run && command -v journalctl >/dev/null 2>&1; then
    warn "Recent signal-cli service logs, if available:"
    journalctl -u signal-cli -n 40 --no-pager 2>/dev/null || true
  fi
  exit "$exit_code"
}

cleanup() {
  if [[ -n "$SIGNAL_CLI_TMPDIR" && -d "$SIGNAL_CLI_TMPDIR" ]]; then
    rm -rf "$SIGNAL_CLI_TMPDIR"
  fi
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

write_rendered_file() {
  local target="$1"
  shift

  if is_dry_run; then
    printf '[dry-run] write %s\n' "$target"
  else
    "$@" > "$target"
  fi
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

  if [[ ! -r /dev/tty ]]; then
    [[ "$default" == "y" ]]
    return $?
  fi

  while true; do
    read -r -p "$prompt [$label]: " answer < /dev/tty || true
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
  if is_dry_run; then
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

validate_bind() {
  local port
  port="$(bind_port "$HTTP_BIND" || true)"
  if [[ -z "$port" ]] || ! validate_port "$port"; then
    die "Invalid --bind. Expected HOST:PORT with port 1-65535, for example 127.0.0.1:8080."
  fi

  if is_local_bind "$HTTP_BIND"; then
    return 0
  fi

  if ! is_true "$ALLOW_PUBLIC_BIND"; then
    die "Refusing non-localhost bind '$HTTP_BIND'. Use --allow-public-bind only behind VPN, reverse proxy, or authenticated transport."
  fi

  warn "Public/non-localhost bind enabled: $HTTP_BIND. Do not expose signal-cli JSON-RPC directly to the internet."
}

validate_inputs() {
  if [[ -z "$DEVICE_NAME" ]]; then
    DEVICE_NAME="$(hostname -s 2>/dev/null || hostname)-signal-cli"
  fi

  if [[ -r /dev/tty ]] && ! is_dry_run; then
    if [[ -z "$SIGNAL_ACCOUNT" ]]; then
      read -r -p "Signal account number, e.g. +31612345678. Leave blank for multi-account mode: " SIGNAL_ACCOUNT < /dev/tty || true
    fi

    local input_device=""
    read -r -p "Linked device name [$DEVICE_NAME]: " input_device < /dev/tty || true
    DEVICE_NAME="${input_device:-$DEVICE_NAME}"
  fi

  if [[ -n "$SIGNAL_ACCOUNT" && ! "$SIGNAL_ACCOUNT" =~ ^\+[1-9][0-9]{6,14}$ ]]; then
    die "Invalid --account. Use international E.164 format, for example +31612345678."
  fi

  if [[ ! "$INSTALL_MODE" =~ ^(auto|native|jvm)$ ]]; then
    die "Invalid install mode: $INSTALL_MODE"
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
      if (base == asset && $1 ~ /^[A-Fa-f0-9]{64}$/) {
        print $1
        exit
      }
    }
  ' "$checksum_file"
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

install_signal_cli_from_artifact() {
  set_stage "signal-cli install"
  local extract_dir candidate
  extract_dir="$SIGNAL_CLI_TMPDIR/extract"
  run_cmd mkdir -p "$extract_dir"

  log "Installing signal-cli $RESOLVED_VERSION ($INSTALL_MODE)."

  if [[ "$INSTALL_MODE" == "native" ]]; then
    run_cmd tar xf "$SIGNAL_CLI_ARTIFACT" -C "$extract_dir"

    candidate="$(find "$extract_dir" -type f -name signal-cli -perm -111 | head -n 1 || true)"
    [[ -n "$candidate" ]] || die "Could not find native signal-cli binary in release archive."

    run_cmd install -d -m 0755 "/opt/signal-cli-native-${RESOLVED_VERSION}"
    run_cmd install -m 0755 "$candidate" "/opt/signal-cli-native-${RESOLVED_VERSION}/signal-cli"
    run_cmd ln -sfn "/opt/signal-cli-native-${RESOLVED_VERSION}/signal-cli" /usr/local/bin/signal-cli
  else
    run_cmd rm -rf "/opt/signal-cli-${RESOLVED_VERSION}"
    run_cmd tar xf "$SIGNAL_CLI_ARTIFACT" -C /opt
    [[ -x "/opt/signal-cli-${RESOLVED_VERSION}/bin/signal-cli" ]] || die "Could not find JVM signal-cli launcher after extraction."
    run_cmd ln -sfn "/opt/signal-cli-${RESOLVED_VERSION}/bin/signal-cli" /usr/local/bin/signal-cli
  fi

  run_cmd /usr/local/bin/signal-cli --version
}

create_service_user() {
  set_stage "service user"
  local nologin_shell
  nologin_shell="$(command -v nologin || true)"
  nologin_shell="${nologin_shell:-/usr/sbin/nologin}"

  if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
    run_cmd groupadd --system "$SERVICE_GROUP"
  fi

  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
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
  fi
}

configure_ufw() {
  is_true "$ENABLE_UFW" || return 0
  set_stage "ufw configuration"

  local ports=() port
  mapfile -t ports < <(detected_ssh_ports || true)
  if [[ "${#ports[@]}" -eq 0 ]]; then
    ports=(22)
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
  mapfile -t ports < <(detected_ssh_ports || true)
  if [[ "${#ports[@]}" -eq 0 ]]; then
    ports=(22)
  fi
  ports_csv="$(IFS=,; printf '%s' "${ports[*]}")"

  log "Configuring fail2ban for SSH."
  run_cmd install -d -m 0755 /etc/fail2ban/jail.d
  write_rendered_file "$FAIL2BAN_FILE" render_fail2ban_jail "$ports_csv"

  run_cmd systemctl enable --now fail2ban
  run_cmd systemctl restart fail2ban
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

configure_ssh_hardening() {
  is_true "$SSH_HARDENING" || return 0
  set_stage "ssh hardening"

  if ! command -v sshd >/dev/null 2>&1; then
    warn "sshd not found; skipping SSH hardening."
    return 0
  fi

  log "Applying SSH hardening."
  run_cmd install -d -m 0755 /etc/ssh/sshd_config.d
  write_rendered_file "$SSH_HARDENING_FILE" render_ssh_hardening_config

  if ! is_dry_run && ! sshd -t; then
    rm -f "$SSH_HARDENING_FILE"
    die "SSH config test failed. Rolled back SSH hardening file."
  fi

  run_cmd systemctl reload ssh || run_cmd systemctl reload sshd || run_cmd systemctl restart ssh || run_cmd systemctl restart sshd || true
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
  write_rendered_file "$SYSCTL_FILE" render_sysctl_config
  if is_dry_run; then
    run_cmd sysctl --system
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
  write_rendered_file /etc/apt/apt.conf.d/20auto-upgrades render_unattended_upgrades_config
  run_cmd systemctl enable --now unattended-upgrades || true
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
  write_rendered_file "$CONFIG_FILE" render_runtime_config
  run_cmd chown "root:$SERVICE_GROUP" "$CONFIG_FILE"
  run_cmd chmod 0640 "$CONFIG_FILE"
}

render_wrapper() {
  cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/signal-cli

args=(--data-dir "$SIGNAL_CLI_DATA_DIR")
if [[ -n "${SIGNAL_CLI_ACCOUNT:-}" ]]; then
  args+=(-a "$SIGNAL_CLI_ACCOUNT")
fi

exec /usr/local/bin/signal-cli "${args[@]}" daemon --http "$SIGNAL_CLI_HTTP_BIND"
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
ReadOnlyPaths=/opt /usr/local/bin /usr/local/sbin
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

link_signal_device() {
  is_true "$RUN_LINK" || return 0
  set_stage "device linking"

  if is_dry_run; then
    printf '[dry-run] link Signal device as %s with device name %s\n' "$SERVICE_USER" "$DEVICE_NAME"
    return 0
  fi

  local qr_dir qr_file
  qr_dir="$(mktemp -d)"
  qr_file="$qr_dir/signal-cli-link.png"
  chmod 0700 "$qr_dir"

  log "Starting Signal linked-device provisioning."
  cat <<EOF

Open Signal on your phone:
  Settings -> Linked devices -> Link new device

Scan the QR code below. Keep this terminal open until signal-cli reports linking is finished.
A PNG copy is also written to: $qr_file

EOF

  runuser -u "$SERVICE_USER" -- env HOME="$DATA_DIR" XDG_DATA_HOME="$DATA_DIR" \
    /usr/local/bin/signal-cli --data-dir "$DATA_DIR" link -n "$DEVICE_NAME" \
    | tee >(xargs -r -L 1 qrencode -t utf8) >(xargs -r -L 1 qrencode -o "$qr_file" --level=H)

  chmod 0600 "$qr_file" 2>/dev/null || true
  log "Linking command finished."
}

run_initial_receive() {
  set_stage "initial receive"
  if [[ -z "$SIGNAL_ACCOUNT" ]]; then
    warn "No account number configured. Service will run in multi-account mode. JSON-RPC calls must include the account parameter."
    return 0
  fi

  log "Running a short initial receive pass for contacts/groups sync."
  run_cmd timeout 30s runuser -u "$SERVICE_USER" -- env HOME="$DATA_DIR" XDG_DATA_HOME="$DATA_DIR" \
    /usr/local/bin/signal-cli --data-dir "$DATA_DIR" -a "$SIGNAL_ACCOUNT" receive || true
}

write_systemd_service() {
  set_stage "systemd service"
  log "Writing systemd service."

  write_rendered_file "$WRAPPER_FILE" render_wrapper
  run_cmd chown root:root "$WRAPPER_FILE"
  run_cmd chmod 0755 "$WRAPPER_FILE"

  write_rendered_file "$SERVICE_FILE" render_systemd_service

  run_cmd systemctl daemon-reload
  run_cmd systemctl enable --now signal-cli.service
}

health_check() {
  set_stage "health check"
  log "Checking signal-cli daemon health."

  if is_dry_run; then
    printf '[dry-run] curl -fsS http://%s/api/v1/check\n' "$HTTP_BIND"
    return 0
  fi

  sleep 2
  if curl -fsS "http://${HTTP_BIND}/api/v1/check" >/dev/null; then
    printf '[+] JSON-RPC daemon is reachable at http://%s/api/v1/check\n' "$HTTP_BIND"
  else
    warn "Health check failed. Recent logs:"
    journalctl -u signal-cli -n 80 --no-pager || true
  fi
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
  trap on_error ERR
  trap cleanup EXIT

  parse_args "$@"
  require_root "$@"
  validate_inputs
  choose_install_mode
  preflight_checks
  resolve_signal_cli_version
  build_signal_cli_asset_url
  build_base_packages
  print_install_plan

  if is_dry_run; then
    return 0
  fi

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
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
