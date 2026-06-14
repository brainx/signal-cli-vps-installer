#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "[check] bash syntax"
bash -n install.sh
bash -n scripts/check.sh
bash -n scripts/uninstall.sh
bash -n scripts/upgrade-signal-cli.sh
bash -n scripts/rollback-signal-cli.sh
bash -n tests/run-tests.sh

if command -v shellcheck >/dev/null 2>&1; then
  echo "[check] shellcheck"
  shellcheck install.sh scripts/check.sh scripts/uninstall.sh scripts/upgrade-signal-cli.sh scripts/rollback-signal-cli.sh tests/run-tests.sh
else
  echo "[check] shellcheck not installed; skipping"
fi

if command -v shfmt >/dev/null 2>&1; then
  echo "[check] shfmt"
  shfmt -i 2 -ci -d install.sh scripts/*.sh tests/*.sh
else
  echo "[check] shfmt not installed; skipping"
fi

echo "[check] tests"
tests/run-tests.sh

echo "[check] ok"
