#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pkill -f "powerpipe benchmark run" >/dev/null 2>&1 || true
pkill -f "powerpipe server" >/dev/null 2>&1 || true

if command -v docker >/dev/null 2>&1; then
  bash "${ROOT_DIR}/scripts/docker-compose.sh" -f "${ROOT_DIR}/compose.yaml" down --remove-orphans >/dev/null 2>&1 || true
fi
