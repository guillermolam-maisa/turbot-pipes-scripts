#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PYTHON_SRC="${REPO_ROOT}/src"

if [[ ! -d "${PYTHON_SRC}" && -d /opt/turbot-ops/src ]]; then
  PYTHON_SRC="/opt/turbot-ops/src"
fi

export PYTHONPATH="${PYTHON_SRC}${PYTHONPATH:+:${PYTHONPATH}}"
exec python3 -m turbot_ops.cli write-compose-env
