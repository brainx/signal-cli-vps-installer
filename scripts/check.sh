#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "[check] bash syntax"
bash -n install.sh

if command -v shellcheck >/dev/null 2>&1; then
  echo "[check] shellcheck"
  shellcheck install.sh scripts/check.sh
else
  echo "[check] shellcheck not installed; skipping"
fi

echo "[check] ok"
