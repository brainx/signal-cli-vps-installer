# signal-cli VPS Installer

[![CI](https://github.com/brainx/signal-cli-vps-installer/actions/workflows/ci.yml/badge.svg)](https://github.com/brainx/signal-cli-vps-installer/actions/workflows/ci.yml)

Install and run [signal-cli](https://github.com/AsamK/signal-cli) as a locked-down JSON-RPC systemd service on a fresh Debian or Ubuntu VPS.

This repo packages a single root-run installer for people who want Signal automation without hand-assembling Java/native binaries, system users, firewall defaults, fail2ban, sysctl hardening, and a hardened systemd unit.

## What It Sets Up

- Installs the latest or pinned `signal-cli` release.
- Uses the native Linux build on `x86_64` by default, or JVM mode when requested.
- Creates a dedicated `signal-cli` system user and private data directory.
- Starts a localhost-only JSON-RPC daemon at `127.0.0.1:8080` by default.
- Optionally links a phone via QR code during setup.
- Enables UFW, fail2ban, unattended security upgrades, and conservative sysctl hardening by default.
- Writes a systemd service with `NoNewPrivileges`, strict filesystem protection, no ambient capabilities, and a narrow address-family allowlist.

## Target Systems

- Debian or Ubuntu server
- `systemd`
- `apt-get`
- Root or sudo access
- Signal installed on a primary phone for linked-device provisioning

## Quick Start

Clone the repo, inspect the installer, then run it:

```bash
git clone https://github.com/brainx/signal-cli-vps-installer.git
cd signal-cli-vps-installer
less install.sh
sudo ./install.sh --account +31612345678 --device-name HomeOps-Signal
```

For a dry install without immediate QR linking:

```bash
sudo ./install.sh --account +31612345678 --no-link
```

The daemon binds to localhost by default:

```bash
curl -i http://127.0.0.1:8080/api/v1/check
```

## Common Options

```text
--account +31612345678       Signal account number in E.164 format.
--device-name NAME           Linked device name shown in Signal.
--bind HOST:PORT             JSON-RPC HTTP bind address.
--install-mode auto|native|jvm
--version VERSION            Pin a signal-cli release.
--no-link                    Install without QR linking now.
--ssh-hardening              Disable SSH password auth and harden SSH.
--no-ssh-hardening           Do not change SSH config.
--no-ufw                     Do not enable/configure UFW.
--no-fail2ban                Do not enable/configure fail2ban.
--no-sysctl-hardening        Do not install sysctl hardening profile.
--no-unattended-upgrades     Do not enable unattended security upgrades.
--upgrade                    Run apt-get upgrade -y before install.
```

Run `./install.sh --help` for the full option list.

## After Install

Useful service commands:

```bash
systemctl status signal-cli --no-pager
journalctl -u signal-cli -f
systemctl restart signal-cli
```

Send-test template:

```bash
curl -sS -X POST http://127.0.0.1:8080/api/v1/rpc \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "method": "send",
    "params": {
      "account": "+YOUR_ACCOUNT_NUMBER",
      "recipient": ["+RECIPIENT_NUMBER"],
      "message": "test from signal-cli"
    },
    "id": 1
  }'
```

## Security Notes

Treat the JSON-RPC daemon as privileged automation infrastructure. It can send and receive Signal messages for the linked account.

- Keep the default localhost bind unless you have a separate authenticated transport such as a VPN, SSH tunnel, or private reverse proxy.
- Do not expose the signal-cli JSON-RPC port directly to the public internet.
- Read `install.sh` before running it as root.
- Use `--ssh-hardening` only after confirming you have working SSH key access.
- Store VPS credentials, Signal account access, and any downstream automation secrets outside this repo.

More detail is in [docs/security-model.md](docs/security-model.md) and [docs/operations.md](docs/operations.md).

## Development Checks

```bash
./scripts/check.sh
```

The check script always runs Bash syntax validation. It also runs ShellCheck when `shellcheck` is installed.

## License

MIT. See [LICENSE](LICENSE).
