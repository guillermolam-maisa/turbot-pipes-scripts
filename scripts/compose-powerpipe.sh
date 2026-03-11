#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

WORKDIR="${WORKDIR:-/tmp/powerpipe-runtime-workspace}"
SOURCE_WORKDIR="${SOURCE_WORKDIR:-/workspace-src/powerpipe}"
RESULTS_DIR="${RESULTS_DIR:-/workspace-results}"
HOME_DIR="${HOME:-/home/powerpipe}"
HOST_AWS_DIR="${HOST_AWS_DIR:-/host-aws}"
# These directories must be backed by volumes in compose.yaml to be writable
CONFIG_DIR="${HOME_DIR}/.powerpipe/config"
AWS_CONFIG_DIR="${HOME_DIR}/.aws"
CONNECTIONS_FILE="${CONFIG_DIR}/connections.ppc"
WORKSPACES_FILE="${CONFIG_DIR}/workspaces.ppc"
WORKSPACE_NAME="${POWERPIPE_WORKSPACE:-compose}"
PORT="${PORT:-9033}"
POWERPIPE_LISTEN="${POWERPIPE_LISTEN:-network}"
MAX_PARALLEL="${MAX_PARALLEL:-1}"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-90}"
BENCHMARK_TIMEOUT="${BENCHMARK_TIMEOUT:-2700}"
POWERPIPE_INSTALL_MODS="${POWERPIPE_INSTALL_MODS:-true}"
POWERPIPE_MOD_PULL="${POWERPIPE_MOD_PULL:-latest}"
POWERPIPE_DATABASE_HOST="${POWERPIPE_DATABASE_HOST:-steampipe}"
STEAMPIPE_DATABASE_PORT="${STEAMPIPE_DATABASE_PORT:-9193}"
STEAMPIPE_DATABASE_PASSWORD="${STEAMPIPE_DATABASE_PASSWORD:-steampipe}"

mkdir -p "${CONFIG_DIR}" "${AWS_CONFIG_DIR}" /tmp

if [[ -d "${HOST_AWS_DIR}" ]]; then
  # Populate the writable volume from the read-only host mount
  cp -a "${HOST_AWS_DIR}/." "${AWS_CONFIG_DIR}/" 2>/dev/null || true
fi

prepare_runtime_workspace() {
  rm -rf "${WORKDIR}"
  mkdir -p "${WORKDIR}"

  if [[ ! -f "${SOURCE_WORKDIR}/mod.pp" ]]; then
    echo "ERROR: Missing source workspace file: ${SOURCE_WORKDIR}/mod.pp" >&2
    exit 1
  fi

  cp -a "${SOURCE_WORKDIR}/." "${WORKDIR}/"
  rm -rf "${WORKDIR}/.powerpipe" "${WORKDIR}/results"
}
prepare_runtime_workspace
mkdir -p "${RESULTS_DIR}"
ln -s "${RESULTS_DIR}" "${WORKDIR}/results"

cat > "${CONNECTIONS_FILE}" <<EOF
connection "steampipe" "default" {
  host     = "${POWERPIPE_DATABASE_HOST}"
  port     = ${STEAMPIPE_DATABASE_PORT}
  password = "${STEAMPIPE_DATABASE_PASSWORD}"
}
EOF

cat > "${WORKSPACES_FILE}" <<EOF
workspace "${WORKSPACE_NAME}" {
  listen            = "${POWERPIPE_LISTEN}"
  port              = ${PORT}
  watch             = false
  query_timeout     = ${QUERY_TIMEOUT}
  max_parallel      = ${MAX_PARALLEL}
  benchmark_timeout = ${BENCHMARK_TIMEOUT}
}
EOF

cd "${WORKDIR}" || exit 1

if [[ "${POWERPIPE_INSTALL_MODS}" == "true" ]]; then
  powerpipe mod install --pull "${POWERPIPE_MOD_PULL}" >/tmp/powerpipe-mod-install.log 2>&1
fi

exec powerpipe server \
  --workspace "${WORKSPACE_NAME}" \
  --listen "${POWERPIPE_LISTEN}" \
  --port "${PORT}" \
  --mod-location "${WORKDIR}"
