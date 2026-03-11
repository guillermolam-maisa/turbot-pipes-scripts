#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

WORKDIR="${WORKDIR:-/workspace/powerpipe}"
HOME_DIR="${HOME:-/home/powerpipe}"

mkdir -p "${WORKDIR}/results" "${WORKDIR}/vendor/bin" "${HOME_DIR}/.steampipe" /tmp

if [[ ! -x /usr/local/bin/steampipe || ! -x /usr/local/bin/powerpipe ]]; then
  echo "ERROR: expected vendored steampipe and powerpipe binaries in the image." >&2
  exit 1
fi

cd "${WORKDIR}" || exit 1
bash "${WORKDIR}/run-all-controls-safe.sh"
