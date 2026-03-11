#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${RUNTIME_DIR:-/tmp/turbot-runtime}"
ENV_FILE="${RUNTIME_DIR}/compose.env"
PREFERRED_POWERPIPE_HOST_PORT="${PREFERRED_POWERPIPE_HOST_PORT:-${POWERPIPE_HOST_PORT:-9033}}"
# Resolve the host user's identity correctly, even when run via sudo
if [[ -n "${SUDO_USER:-}" ]]; then
  HOST_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
  HOST_UID="$(id -u "${SUDO_USER}")"
  HOST_GID="$(id -g "${SUDO_USER}")"
else
  HOST_HOME="${HOME:-}"
  HOST_UID="$(id -u)"
  HOST_GID="$(id -g)"
fi

mkdir -p "${RUNTIME_DIR}"

POWERPIPE_HOST_PORT="$(bash "${ROOT_DIR}/scripts/select-port.sh" --preferred "${PREFERRED_POWERPIPE_HOST_PORT}")"

cat > "${ENV_FILE}" <<EOF
HOST_HOME=${HOST_HOME}
HOST_UID=${HOST_UID}
HOST_GID=${HOST_GID}
POWERPIPE_HOST_PORT=${POWERPIPE_HOST_PORT}
EOF

printf '%s\n' "${ENV_FILE}"
