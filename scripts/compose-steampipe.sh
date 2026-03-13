#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

set -euo pipefail

export PYTHONPATH="/opt/turbot-ops/src${PYTHONPATH:+:${PYTHONPATH}}"
exec python3 -m turbot_ops.cli compose-steampipe
