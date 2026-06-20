# Troubleshooting

## QR Code Does Not Appear or Scans Wrong

Likely cause: `qrencode` is missing, or signal-cli did not print a `sgnl://linkdevice...` URI before the link session closed. The installer only QR-encodes that URI; status text and errors are not valid QR payloads.

Check:

```bash
command -v qrencode
sudo runuser -u signal-cli -- env HOME=/var/lib/signal-cli XDG_DATA_HOME=/var/lib/signal-cli \
  signal-cli --data-dir /var/lib/signal-cli link -n HomeOps-Signal
```

Fix:

```bash
sudo apt-get install -y qrencode
```

If the manual link command never prints a `sgnl://linkdevice...` URI, check the VPS clock and outbound connectivity, then rerun linking.

## Link Command Hangs

Likely cause: the primary phone has not scanned the QR code yet.

Check:

```bash
journalctl -u signal-cli -n 100 --no-pager
```

Fix: rerun linking and scan from Signal on the primary phone:

```bash
sudo runuser -u signal-cli -- env HOME=/var/lib/signal-cli XDG_DATA_HOME=/var/lib/signal-cli \
  signal-cli --data-dir /var/lib/signal-cli link -n HomeOps-Signal
```

## Health Check Fails

Likely cause: the service failed to start, the account is not linked, or the daemon is bound to a different address.

Check:

```bash
systemctl status signal-cli --no-pager
journalctl -u signal-cli -n 100 --no-pager
```

Fix: inspect the logs, correct the runtime config in `/etc/default/signal-cli`, then restart:

```bash
sudo systemctl restart signal-cli
```

## JRE 25 Error

Likely cause: JVM mode is selected but Java 25 is unavailable from the configured apt repositories.

Check:

```bash
java -version
apt-cache show openjdk-25-jre-headless
```

Fix: use native mode on x86_64/amd64, or install Java 25 before rerunning:

```bash
sudo ./install.sh --install-mode native --account +31612345678 --version 0.14.5 --sha256 SHA256
```

## SSH Reload Failed

Likely cause: generated SSH hardening config is invalid for the host's OpenSSH version.

Check:

```bash
sudo sshd -t
```

Fix: remove the generated drop-in and reload SSH:

```bash
sudo rm -f /etc/ssh/sshd_config.d/99-signal-cli-hardening.conf
sudo systemctl reload ssh || sudo systemctl reload sshd
```

## Cannot Connect Remotely

Likely cause: the daemon is correctly bound to localhost.

Check:

```bash
ss -ltnp | grep 8080
```

Fix: use an SSH tunnel, VPN, or authenticated reverse proxy. Do not expose the JSON-RPC daemon directly.

```bash
ssh -L 8080:127.0.0.1:8080 user@server
curl -i http://127.0.0.1:8080/api/v1/check
```

## Public Bind Refused

Likely cause: the installer now rejects non-localhost binds unless explicitly allowed.

Fix only when a separate authenticated transport protects access:

```bash
sudo ./install.sh --allow-public-bind --bind 10.0.0.5:8080 --version 0.14.5 --sha256 SHA256
```

## Artifact Verification Fails

Likely cause: the SHA256 digest does not match the downloaded release artifact, or the checksum file does not contain the selected asset.

Check:

```bash
sha256sum signal-cli-0.14.5.tar.gz
```

Fix: confirm the release version, install mode, and checksum source. Do not bypass verification unless you explicitly accept the risk:

```bash
sudo ./install.sh --verify none --allow-unverified-download --version 0.14.5
```
