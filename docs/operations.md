# Operations

## Install

```bash
sudo ./install.sh --account +31612345678 --device-name HomeOps-Signal --version 0.14.5 --sha256 SHA256
```

Use multi-account daemon mode by omitting `--account`:

```bash
sudo ./install.sh --no-link --version 0.14.5 --sha256 SHA256
```

In multi-account mode, JSON-RPC calls must include the `account` parameter.

## Pin a Release

```bash
sudo ./install.sh --version 0.14.5 --sha256 SHA256 --account +31612345678
```

Pinning is recommended when rebuilding production hosts because it avoids surprise changes from the latest upstream release.

## Preview Changes

Dry-run mode prints the selected install mode, package plan, files to write, bind address, verification mode, and hardening choices without requiring root or changing the system:

```bash
./install.sh --dry-run --account +31612345678 --version 0.14.5
```

## Artifact Verification

Use `--sha256` when you already have the expected release artifact digest:

```bash
sudo ./install.sh --version 0.14.5 --sha256 SHA256 --account +31612345678
```

Use `--checksum-url` when you publish or trust a checksum file containing the selected artifact name:

```bash
sudo ./install.sh --version 0.14.5 --checksum-url https://example.com/signal-cli-checksums.txt --account +31612345678
```

Unverified installs require an explicit unsafe opt-in:

```bash
sudo ./install.sh --verify none --allow-unverified-download --version 0.14.5 --account +31612345678
```

## JVM Mode

```bash
sudo ./install.sh --install-mode jvm --account +31612345678 --version 0.14.5 --sha256 SHA256
```

JVM mode requires Java 25. The installer tries to install `openjdk-25-jre-headless` or `openjdk-25-jre` from apt when Java 25 is missing.

## Service Files

The installer writes:

```text
/etc/default/signal-cli
/usr/local/sbin/signal-cli-daemon-start
/etc/systemd/system/signal-cli.service
/var/lib/signal-cli
```

The data directory contains linked-device state and should be treated as sensitive.

## Health Check

```bash
curl -i http://127.0.0.1:8080/api/v1/check
```

If the check fails:

```bash
systemctl status signal-cli --no-pager
journalctl -u signal-cli -n 100 --no-pager
```

## Restart

```bash
sudo systemctl restart signal-cli
```

## Upgrade signal-cli

Upgrade only changes the installed binary and symlink. It does not relink the Signal device or remove `/var/lib/signal-cli`.

Preview:

```bash
scripts/upgrade-signal-cli.sh --dry-run --version 0.14.6 --install-mode native --sha256 SHA256
```

Run:

```bash
sudo scripts/upgrade-signal-cli.sh --version 0.14.6 --install-mode native --sha256 SHA256
```

Skip service restart when you want to restart manually:

```bash
sudo scripts/upgrade-signal-cli.sh --version 0.14.6 --install-mode native --sha256 SHA256 --no-restart
```

## Roll Back signal-cli

Rollback switches `/usr/local/bin/signal-cli` back to an existing version under `/opt` and restarts the service. It does not delete any installed versions.

Preview:

```bash
scripts/rollback-signal-cli.sh --dry-run --to-version 0.14.5 --install-mode native
```

Run:

```bash
sudo scripts/rollback-signal-cli.sh --to-version 0.14.5 --install-mode native
```

## Reconfigure Bind Address

Edit:

```text
/etc/default/signal-cli
```

Then restart:

```bash
sudo systemctl restart signal-cli
```

Keep the bind address on localhost unless a separate authenticated transport protects access. Non-localhost binds require `--allow-public-bind` during install.

## Link Later

If installed with `--no-link`, run signal-cli linking manually as the service user:

```bash
sudo runuser -u signal-cli -- env HOME=/var/lib/signal-cli XDG_DATA_HOME=/var/lib/signal-cli \
  signal-cli --data-dir /var/lib/signal-cli link -n HomeOps-Signal
```

Then scan the QR code from Signal on the primary phone.

## Uninstall

Default uninstall removes the service, wrapper, and runtime config while preserving linked-device state and installed binaries:

```bash
sudo scripts/uninstall.sh --dry-run
sudo scripts/uninstall.sh
```

Explicit purge flags are available:

```bash
sudo scripts/uninstall.sh --purge-binaries
sudo scripts/uninstall.sh --purge-hardening
sudo scripts/uninstall.sh --purge-data --yes
```

Remove `/var/lib/signal-cli` only after confirming you no longer need the linked-device state.
