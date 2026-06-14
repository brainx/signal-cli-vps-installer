# Security Model

This installer is intentionally small, but it performs privileged actions. Review the threat model before running or modifying it.

## Assets

- Signal linked-device credentials in `/var/lib/signal-cli`
- Signal messages accessible through the JSON-RPC daemon
- Root-owned systemd service and wrapper files
- SSH access to the VPS
- Firewall and fail2ban configuration

## Trust Boundaries

- The installer runs as root and writes to `/etc`, `/opt`, `/usr/local`, and `/var/lib`.
- signal-cli release artifacts are downloaded from GitHub over HTTPS.
- Release artifacts are verified with SHA256 material when `--sha256` or `--checksum-url` is provided.
- Local artifacts supplied with `--artifact-file` still pass through the same SHA256 verification path.
- The JSON-RPC daemon accepts local HTTP requests by default.
- Any automation calling JSON-RPC becomes part of the trusted local system.

## Main Abuse Cases

- Public exposure of the JSON-RPC daemon lets an attacker send or inspect Signal traffic.
- A tampered release artifact can compromise the host because installation runs as root.
- A compromised local process can call the localhost JSON-RPC endpoint.
- Weak SSH configuration can expose the VPS before or after installation.
- Running an unreviewed modified installer as root can compromise the host.
- Leaked `/var/lib/signal-cli` data can compromise the linked Signal device state.

## Chosen Mitigations

- Default bind is `127.0.0.1:8080`.
- Non-localhost bind addresses are rejected unless `--allow-public-bind` is set.
- Unverified release artifact installation requires `--verify none --allow-unverified-download`.
- The service runs as an unprivileged `signal-cli` system user.
- signal-cli data is stored under a `0700` data directory.
- The systemd unit uses strict filesystem protection, no new privileges, no capabilities, private temporary storage, and a reduced syscall/address-family surface.
- UFW denies inbound traffic by default while preserving detected SSH ports.
- fail2ban is configured for SSH.
- Optional SSH hardening disables password and keyboard-interactive authentication.
- QR-code PNG output is written to a private temporary directory instead of a predictable shared `/tmp` path.

## Operational Requirements

- Do not bind JSON-RPC to a public interface unless it is behind a separate authenticated control plane.
- Prefer pinned `--version` plus `--sha256` for production rebuilds.
- Keep checksum material from a trusted source and match it to the selected install mode.
- Keep the VPS patched.
- Rotate access and rebuild the linked device if the data directory is exposed.
- Confirm SSH key login before enabling `--ssh-hardening`.
- Pin `--version` for reproducible installs, or accept latest release behavior for convenience.

## Not Provided

- JSON-RPC authentication
- End-to-end API authorization for downstream callers
- Upstream cryptographic signature verification beyond SHA256 checks supplied by the operator
- Automated backup scheduling for Signal state
- A reverse proxy, VPN, or tunnel configuration

Add those controls in the deployment environment when the server is part of a larger automation stack.
