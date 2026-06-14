# Operations

## Install

```bash
sudo ./install.sh --account +31612345678 --device-name HomeOps-Signal
```

Use multi-account daemon mode by omitting `--account`:

```bash
sudo ./install.sh --no-link
```

In multi-account mode, JSON-RPC calls must include the `account` parameter.

## Pin a Release

```bash
sudo ./install.sh --version 0.14.5 --account +31612345678
```

Pinning is recommended when rebuilding production hosts because it avoids surprise changes from the latest upstream release.

## JVM Mode

```bash
sudo ./install.sh --install-mode jvm --account +31612345678
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

## Reconfigure Bind Address

Edit:

```text
/etc/default/signal-cli
```

Then restart:

```bash
sudo systemctl restart signal-cli
```

Keep the bind address on localhost unless a separate authenticated transport protects access.

## Link Later

If installed with `--no-link`, run signal-cli linking manually as the service user:

```bash
sudo runuser -u signal-cli -- env HOME=/var/lib/signal-cli XDG_DATA_HOME=/var/lib/signal-cli \
  signal-cli --data-dir /var/lib/signal-cli link -n HomeOps-Signal
```

Then scan the QR code from Signal on the primary phone.

## Uninstall

This repo does not ship an automated destructive uninstall. A manual cleanup typically involves:

```bash
sudo systemctl disable --now signal-cli
sudo rm -f /etc/systemd/system/signal-cli.service
sudo rm -f /usr/local/sbin/signal-cli-daemon-start
sudo rm -f /etc/default/signal-cli
sudo systemctl daemon-reload
```

Remove `/var/lib/signal-cli` only after confirming you no longer need the linked-device state.
