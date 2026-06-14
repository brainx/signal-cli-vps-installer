# Checksum Guidance

The installer can verify release artifacts with either a direct SHA256 value or a checksum file URL.

## Direct SHA256

Use `--sha256` when you already have the expected digest for the exact artifact being installed:

```bash
sudo ./install.sh --version 0.14.5 --install-mode native --sha256 SHA256 --account +31612345678
```

The digest must match the selected artifact:

- native: `signal-cli-VERSION-Linux-native.tar.gz`
- JVM: `signal-cli-VERSION.tar.gz`

## Checksum File

Use `--checksum-url` when you publish or trust a checksum file containing the artifact name and digest:

```bash
sudo ./install.sh \
  --version 0.14.5 \
  --checksum-url https://example.com/signal-cli-checksums.txt \
  --account +31612345678
```

Supported checksum-file lines look like:

```text
SHA256  signal-cli-0.14.5-Linux-native.tar.gz
SHA256  signal-cli-0.14.5.tar.gz
```

The URL must use HTTPS. Local `file://` checksum URLs are accepted only in test mode.

## Unverified Installs

Unverified installs are blocked unless explicitly requested:

```bash
sudo ./install.sh --verify none --allow-unverified-download --version 0.14.5
```

Use this only when you have accepted the supply-chain risk through another control, such as a trusted internal artifact mirror.

## Local Artifacts

Advanced operators can install a local artifact while still verifying it:

```bash
sudo ./install.sh \
  --version 0.14.5 \
  --install-mode native \
  --artifact-file ./signal-cli-0.14.5-Linux-native.tar.gz \
  --sha256 SHA256
```
