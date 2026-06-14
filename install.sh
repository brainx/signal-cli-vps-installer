#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SERVICE_USER="signal-cli"
SERVICE_GROUP="signal-cli"
DATA_DIR="/var/lib/signal-cli"
CONFIG_FILE="/etc/default/signal-cli"
WRAPPER_FILE="/usr/local/sbin/signal-cli-daemon-start"
SERVICE_FILE="/etc/systemd/system/signal-cli.service"

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
RUN_UPGRADE="${RUN_UPGRADE:-false}"
VERSION="${VERSION:-}"

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
  --install-mode auto|native|jvm
                               Default: auto. Uses native on x86_64, JVM elsewhere.
  --native                     Same as --install-mode native.
  --jvm                        Same as --install-mode jvm.
  --version VERSION            Pin signal-cli version, for example 0.14.5. Default: latest.
  --no-link                    Install and start daemon without QR linking now.
  --ssh-hardening              Disable SSH password login and apply SSH hardening.
  --no-ssh-hardening           Do not change SSH config.
  --no-ufw                     Do not enable/configure UFW.
  --no-fail2ban                Do not enable/configure fail2ban.
  --no-sysctl-hardening        Do not install sysctl hardening profile.
  --no-unattended-upgrades     Do not enable unattended security upgrades.
  --upgrade                    Run apt-get upgrade -y before install.
  -h, --help                   Show this help.

Examples:
  sudo $0 --account +31612345678 --device-name HomeOps-Signal
  sudo RUN_LINK=false $0 --account +31612345678
  sudo $0 --install-mode jvm --account +31612345678
EOF
}

is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
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
      y|yes) return 0 ;;
      n|no) return 1 ;;
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
      --version)
        [[ $# -ge 2 ]] || die "--version requires a value"
        VERSION="$2"
        shift 2
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
      --upgrade)
        RUN_UPGRADE="true"
        shift
        ;;
      -h|--help)
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
  if [[ "${EUID}" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
  fi
}

validate_inputs() {
  if [[ -z "$DEVICE_NAME" ]]; then
    DEVICE_NAME="$(hostname -s 2>/dev/null || hostname)-signal-cli"
  fi

  if [[ -r /dev/tty ]]; then
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

  if [[ "$SSH_HARDENING" == "ask" ]]; then
    if ask_yes_no "Disable SSH password login and harden SSH config" "n"; then
      SSH_HARDENING="true"
    else
      SSH_HARDENING="false"
    fi
  fi

  if [[ ! "$HTTP_BIND" =~ :[0-9]+$ ]]; then
    die "Invalid --bind. Expected HOST:PORT, for example 127.0.0.1:8080."
  fi

  if [[ "$HTTP_BIND" != 127.0.0.1:* && "$HTTP_BIND" != localhost:* && "$HTTP_BIND" != "[::1]:"* ]]; then
    warn "HTTP daemon bind is not localhost-only: $HTTP_BIND. Do not expose signal-cli JSON-RPC directly to the internet."
  fi
}

choose_install_mode() {
  local arch
  arch="$(uname -m)"

  if [[ "$INSTALL_MODE" == "auto" ]]; then
    case "$arch" in
      x86_64|amd64) INSTALL_MODE="native" ;;
      *) INSTALL_MODE="jvm" ;;
    esac
  fi

  if [[ "$INSTALL_MODE" == "native" && ! "$arch" =~ ^(x86_64|amd64)$ ]]; then
    die "Native Linux release is expected for x86_64/amd64. Use --install-mode jvm on $arch."
  fi

  log "Install mode: $INSTALL_MODE"
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
  major="$(java_major_version || true)"
  if [[ -n "$major" && "$major" =~ ^[0-9]+$ && "$major" -ge 25 ]]; then
    log "Detected Java $major."
    return 0
  fi

  log "JVM mode needs JRE 25. Trying apt packages."
  if apt_pkg_available openjdk-25-jre-headless; then
    apt-get install -y openjdk-25-jre-headless
  elif apt_pkg_available openjdk-25-jre; then
    apt-get install -y openjdk-25-jre
  else
    die "No openjdk-25-jre package found in apt. Use --install-mode native on x86_64, or install JRE 25 manually, then rerun."
  fi
}

install_base_packages() {
  if ! command -v apt-get >/dev/null 2>&1; then
    die "This script targets Debian/Ubuntu systems with apt-get."
  fi

  export DEBIAN_FRONTEND=noninteractive

  log "Updating apt metadata."
  apt-get update

  if is_true "$RUN_UPGRADE"; then
    log "Running apt-get upgrade -y."
    apt-get upgrade -y
  fi

  local packages=(ca-certificates curl tar jq qrencode ufw fail2ban libstdc++6 coreutils)
  if is_true "$ENABLE_UNATTENDED_UPGRADES"; then
    packages+=(unattended-upgrades)
  fi

  log "Installing base packages."
  apt-get install -y "${packages[@]}"

  if [[ "$INSTALL_MODE" == "jvm" ]]; then
    install_java25_if_needed
  fi
}

latest_signal_cli_version() {
  curl -fsSL -o /dev/null -w '%{url_effective}' \
    https://github.com/AsamK/signal-cli/releases/latest | sed -e 's#^.*/v##'
}

install_signal_cli() {
  local version tmpdir asset url extract_dir candidate

  version="${VERSION:-$(latest_signal_cli_version)}"
  [[ -n "$version" ]] || die "Could not determine latest signal-cli version."

  tmpdir="$(mktemp -d)"
  extract_dir="$tmpdir/extract"
  mkdir -p "$extract_dir"

  log "Installing signal-cli $version ($INSTALL_MODE)."

  if [[ "$INSTALL_MODE" == "native" ]]; then
    asset="signal-cli-${version}-Linux-native.tar.gz"
    url="https://github.com/AsamK/signal-cli/releases/download/v${version}/${asset}"
    curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "$tmpdir/$asset" "$url"
    tar xf "$tmpdir/$asset" -C "$extract_dir"

    candidate="$(find "$extract_dir" -type f -name signal-cli -perm -111 | head -n 1 || true)"
    [[ -n "$candidate" ]] || die "Could not find native signal-cli binary in release archive."

    install -d -m 0755 "/opt/signal-cli-native-${version}"
    install -m 0755 "$candidate" "/opt/signal-cli-native-${version}/signal-cli"
    ln -sfn "/opt/signal-cli-native-${version}/signal-cli" /usr/local/bin/signal-cli
  else
    asset="signal-cli-${version}.tar.gz"
    url="https://github.com/AsamK/signal-cli/releases/download/v${version}/${asset}"
    curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "$tmpdir/$asset" "$url"
    rm -rf "/opt/signal-cli-${version}"
    tar xf "$tmpdir/$asset" -C /opt
    [[ -x "/opt/signal-cli-${version}/bin/signal-cli" ]] || die "Could not find JVM signal-cli launcher after extraction."
    ln -sfn "/opt/signal-cli-${version}/bin/signal-cli" /usr/local/bin/signal-cli
  fi

  rm -rf "$tmpdir"
  /usr/local/bin/signal-cli --version
}

create_service_user() {
  local nologin_shell
  nologin_shell="$(command -v nologin || true)"
  nologin_shell="${nologin_shell:-/usr/sbin/nologin}"

  if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
    groupadd --system "$SERVICE_GROUP"
  fi

  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system \
      --gid "$SERVICE_GROUP" \
      --home-dir "$DATA_DIR" \
      --create-home \
      --shell "$nologin_shell" \
      "$SERVICE_USER"
  fi

  install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$DATA_DIR"
  chown -R "$SERVICE_USER:$SERVICE_GROUP" "$DATA_DIR"
  chmod 0700 "$DATA_DIR"
}

detected_ssh_ports() {
  if command -v sshd >/dev/null 2>&1; then
    sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -u
  fi
}

configure_ufw() {
  is_true "$ENABLE_UFW" || return 0

  local ports=() port
  mapfile -t ports < <(detected_ssh_ports || true)
  if [[ "${#ports[@]}" -eq 0 ]]; then
    ports=(22)
  fi

  log "Configuring UFW."
  ufw default deny incoming
  ufw default allow outgoing

  for port in "${ports[@]}"; do
    ufw allow "${port}/tcp"
  done

  ufw --force enable
  ufw status verbose || true
}

configure_fail2ban() {
  is_true "$ENABLE_FAIL2BAN" || return 0

  local ports=() ports_csv
  mapfile -t ports < <(detected_ssh_ports || true)
  if [[ "${#ports[@]}" -eq 0 ]]; then
    ports=(22)
  fi
  ports_csv="$(IFS=,; printf '%s' "${ports[*]}")"

  log "Configuring fail2ban for SSH."
  install -d -m 0755 /etc/fail2ban/jail.d
  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
backend = systemd
port = ${ports_csv}
maxretry = 5
findtime = 10m
bantime = 1h
EOF

  systemctl enable --now fail2ban
  systemctl restart fail2ban
}

configure_ssh_hardening() {
  is_true "$SSH_HARDENING" || return 0

  if ! command -v sshd >/dev/null 2>&1; then
    warn "sshd not found; skipping SSH hardening."
    return 0
  fi

  log "Applying SSH hardening."
  install -d -m 0755 /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-signal-cli-hardening.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

  if ! sshd -t; then
    rm -f /etc/ssh/sshd_config.d/99-signal-cli-hardening.conf
    die "SSH config test failed. Rolled back SSH hardening file."
  fi

  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
}

configure_sysctl_hardening() {
  is_true "$ENABLE_SYSCTL_HARDENING" || return 0

  log "Applying conservative sysctl hardening."
  cat > /etc/sysctl.d/99-signal-cli-server-hardening.conf <<'EOF'
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
  sysctl --system >/dev/null || warn "Some sysctl settings could not be applied on this kernel."
}

configure_unattended_upgrades() {
  is_true "$ENABLE_UNATTENDED_UPGRADES" || return 0

  log "Enabling unattended security upgrades."
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  systemctl enable --now unattended-upgrades 2>/dev/null || true
}

write_runtime_config() {
  log "Writing signal-cli runtime config."
  cat > "$CONFIG_FILE" <<EOF
SIGNAL_CLI_DATA_DIR="$DATA_DIR"
SIGNAL_CLI_ACCOUNT="$SIGNAL_ACCOUNT"
SIGNAL_CLI_HTTP_BIND="$HTTP_BIND"
EOF
  chown "root:$SERVICE_GROUP" "$CONFIG_FILE"
  chmod 0640 "$CONFIG_FILE"
}

link_signal_device() {
  is_true "$RUN_LINK" || return 0

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
  if [[ -z "$SIGNAL_ACCOUNT" ]]; then
    warn "No account number configured. Service will run in multi-account mode. JSON-RPC calls must include the account parameter."
    return 0
  fi

  log "Running a short initial receive pass for contacts/groups sync."
  timeout 30s runuser -u "$SERVICE_USER" -- env HOME="$DATA_DIR" XDG_DATA_HOME="$DATA_DIR" \
    /usr/local/bin/signal-cli --data-dir "$DATA_DIR" -a "$SIGNAL_ACCOUNT" receive || true
}

write_systemd_service() {
  log "Writing systemd service."

  cat > "$WRAPPER_FILE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/signal-cli

args=(--data-dir "$SIGNAL_CLI_DATA_DIR")
if [[ -n "${SIGNAL_CLI_ACCOUNT:-}" ]]; then
  args+=(-a "$SIGNAL_CLI_ACCOUNT")
fi

exec /usr/local/bin/signal-cli "${args[@]}" daemon --http "$SIGNAL_CLI_HTTP_BIND"
EOF
  chown root:root "$WRAPPER_FILE"
  chmod 0755 "$WRAPPER_FILE"

  cat > "$SERVICE_FILE" <<EOF
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

  systemctl daemon-reload
  systemctl enable --now signal-cli.service
}

health_check() {
  log "Checking signal-cli daemon health."
  sleep 2
  if curl -fsS "http://${HTTP_BIND}/api/v1/check" >/dev/null; then
    printf '[+] JSON-RPC daemon is reachable at http://%s/api/v1/check\n' "$HTTP_BIND"
  else
    warn "Health check failed. Recent logs:"
    journalctl -u signal-cli -n 80 --no-pager || true
  fi
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
  parse_args "$@"
  require_root "$@"
  validate_inputs
  choose_install_mode
  install_base_packages
  configure_ufw
  configure_fail2ban
  configure_ssh_hardening
  configure_sysctl_hardening
  configure_unattended_upgrades
  install_signal_cli
  create_service_user
  write_runtime_config
  link_signal_device
  run_initial_receive
  write_systemd_service
  health_check
  print_summary
}

main "$@"
