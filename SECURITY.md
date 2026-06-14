# Security Policy

## Supported Versions

Security fixes are handled on the default branch until formal releases are introduced.

## Reporting a Vulnerability

Open a private security advisory or contact the maintainer through the repository's published security contact.

Please include:

- affected commit or release,
- host OS and version,
- installer command used,
- expected behavior,
- observed behavior,
- relevant logs with secrets removed,
- impact assessment.

Do not include Signal account secrets, linked-device state, API tokens, private keys, or full message contents in reports.

## Scope

In scope:

- unsafe root-run installer behavior,
- insecure service permissions,
- JSON-RPC exposure risks caused by this installer,
- unsafe SSH/firewall/fail2ban configuration,
- secret leakage through generated files or logs.

Out of scope:

- vulnerabilities in upstream signal-cli,
- vulnerabilities in Signal itself,
- attacks requiring prior root access with no installer-specific weakness,
- public exposure caused by deployment changes outside this repo.
