#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

WORKDIR="${WORKDIR:-/workspace/powerpipe}"
SOURCE_WORKDIR="${SOURCE_WORKDIR:-/workspace-src/powerpipe}"
RESULTS_DIR="${RESULTS_DIR:-${WORKDIR}/results}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${RESULTS_DIR}/${STAMP}"
LATEST_LINK="${RESULTS_DIR}/latest"
HOME_DIR="${HOME:-/home/powerpipe}"
HOST_AWS_DIR="${HOST_AWS_DIR:-/host-aws}"
CONFIG_DIR="${HOME_DIR}/.powerpipe/config"
CONNECTIONS_FILE="${CONFIG_DIR}/connections.ppc"
WORKSPACES_FILE="${CONFIG_DIR}/workspaces.ppc"
WORKSPACE_NAME="${POWERPIPE_WORKSPACE:-compose}"
POWERPIPE_DATABASE_URL="${POWERPIPE_DATABASE_URL:-postgres://steampipe:${STEAMPIPE_DATABASE_PASSWORD:-steampipe}@steampipe:${STEAMPIPE_DATABASE_PORT:-9193}/steampipe?sslmode=disable}"
POWERPIPE_DATABASE_HOST="${POWERPIPE_DATABASE_HOST:-steampipe}"
PORT="${PORT:-9033}"
POWERPIPE_HOST_PORT="${POWERPIPE_HOST_PORT:-${PORT}}"
SEARCH_PATH="${SEARCH_PATH:-admin_only}"
BENCHMARK="${BENCHMARK:-aws_compliance.benchmark.all_controls}"
MAX_PARALLEL="${MAX_PARALLEL:-0}"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-90}"
BENCHMARK_TIMEOUT="${BENCHMARK_TIMEOUT:-0}"
POWERPIPE_INSTALL_MODS="${POWERPIPE_INSTALL_MODS:-true}"

if [[ "${MAX_PARALLEL}" -eq 0 ]]; then
  if command -v nproc >/dev/null 2>&1; then
    MAX_PARALLEL="$(nproc)"
  else
    MAX_PARALLEL=2
  fi
fi
POWERPIPE_MOD_PULL="${POWERPIPE_MOD_PULL:-latest}"
BENCHMARK_ACCEPT_FINDINGS="${BENCHMARK_ACCEPT_FINDINGS:-false}"
STEAMPIPE_DATABASE_PORT="${STEAMPIPE_DATABASE_PORT:-9193}"
STEAMPIPE_DATABASE_PASSWORD="${STEAMPIPE_DATABASE_PASSWORD:-steampipe}"
RUN_RC=0
FINAL_RC=0

log() { printf '%s\n' "$*" >&2; }

prepare_runtime_workspace() {
  rm -rf "${WORKDIR}"
  mkdir -p "${WORKDIR}" /tmp

  if [[ ! -f "${SOURCE_WORKDIR}/mod.pp" ]]; then
    log "ERROR: Missing source workspace file: ${SOURCE_WORKDIR}/mod.pp"
    exit 1
  fi

  cp -a "${SOURCE_WORKDIR}/." "${WORKDIR}/"
  rm -rf "${WORKDIR}/.powerpipe" "${WORKDIR}/results"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "ERROR: Missing command: $1"
    exit 1
  }
}

wait_for_tcp() {
  local host="$1"
  local port="$2"
  local timeout_seconds="$3"
  local started_at
  started_at="$(date +%s)"

  while true; do
    if bash -lc "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1; then
      return 0
    fi

    if (( $(date +%s) - started_at >= timeout_seconds )); then
      return 1
    fi

    sleep 2
  done
}

wait_for_relation() {
  local database_url="$1"
  local relation_name="$2"
  local timeout_seconds="$3"
  local started_at
  local result
  started_at="$(date +%s)"

  while true; do
    result="$(psql "${database_url}" -Atqc "select count(*) from information_schema.tables where table_name = '${relation_name}';" 2>/dev/null || true)"
    if [[ "${result}" =~ ^[1-9][0-9]*$ ]]; then
      return 0
    fi

    if (( $(date +%s) - started_at >= timeout_seconds )); then
      return 1
    fi

    sleep 2
  done
}

write_run_metadata() {
  cat > "${RUN_DIR}/run.env" <<EOF
WORKDIR=${WORKDIR}
RUN_DIR=${RUN_DIR}
BENCHMARK=${BENCHMARK}
SEARCH_PATH=${SEARCH_PATH}
MAX_PARALLEL=${MAX_PARALLEL}
QUERY_TIMEOUT=${QUERY_TIMEOUT}
BENCHMARK_TIMEOUT=${BENCHMARK_TIMEOUT}
PORT=${PORT}
POWERPIPE_DATABASE_URL=${POWERPIPE_DATABASE_URL}
EOF
}

have_primary_exports() {
  [[ -s "${RUN_DIR}/benchmark.json" ]] || [[ -s "${RUN_DIR}/benchmark.html" ]] || [[ -s "${RUN_DIR}/benchmark.md" ]] || [[ -s "${RUN_DIR}/benchmark.pps" ]]
}

should_promote_latest() {
  [[ "${RUN_RC}" -eq 0 || "${RUN_RC}" -eq 2 ]] || have_primary_exports
}

update_latest_link() {
  local tmp_link="${RESULTS_DIR}/latest.tmp"
  rm -f "${tmp_link}"
  ln -s "${RUN_DIR}" "${tmp_link}" || return 1

  if [[ -L "${LATEST_LINK}" || -f "${LATEST_LINK}" ]]; then
    rm -f "${LATEST_LINK}" || return 1
  elif [[ -d "${LATEST_LINK}" ]]; then
    if ! rmdir "${LATEST_LINK}" 2>/dev/null; then
      log "ERROR: ${LATEST_LINK} exists as a non-empty directory; refusing to replace it."
      rm -f "${tmp_link}" || true
      return 1
    fi
  fi

  mv "${tmp_link}" "${LATEST_LINK}" || return 1
}

write_partial_marker() {
  cat > "${RUN_DIR}/partial-artifacts.txt" <<EOF
Benchmark did not complete cleanly.
Exit code: ${RUN_RC}
Benchmark: ${BENCHMARK}
Search path: ${SEARCH_PATH}

Available diagnostics:
- ${RUN_DIR}/benchmark.stdout.log
- ${RUN_DIR}/run.env
EOF
}

benchmark_stdout_has_runtime_errors() {
  [[ -s "${RUN_DIR}/benchmark.stdout.log" ]] || return 1
  rg -q '(^ERROR:|^\|([[:space:]]+\|)?[[:space:]]+ERROR:)' "${RUN_DIR}/benchmark.stdout.log"
}

need_cmd bash
need_cmd mkdir
need_cmd powerpipe
need_cmd psql
need_cmd rm
need_cmd ln
need_cmd mv
need_cmd rg
need_cmd timeout

mkdir -p "${CONFIG_DIR}" "${HOME_DIR}/.aws" /tmp
if [[ -d "${HOST_AWS_DIR}" ]]; then
  cp -a "${HOST_AWS_DIR}/." "${HOME_DIR}/.aws/"
fi
prepare_runtime_workspace
mkdir -p "${RESULTS_DIR}" "${RUN_DIR}"
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
  listen            = "network"
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

write_run_metadata

log "[1/5] Waiting for Steampipe on steampipe:${STEAMPIPE_DATABASE_PORT:-9193}..."
if ! wait_for_tcp "steampipe" "${STEAMPIPE_DATABASE_PORT:-9193}" 60; then
  log "ERROR: Steampipe is not reachable on steampipe:${STEAMPIPE_DATABASE_PORT:-9193}."
  exit 1
fi

log "[2/5] Waiting for Steampipe AWS schema..."
if ! wait_for_relation "${POWERPIPE_DATABASE_URL}" "aws_account" 60; then
  log "ERROR: Steampipe backend did not expose aws_account within 60 seconds."
  exit 1
fi

log "[3/5] Validating benchmark..."
if ! powerpipe benchmark show "${BENCHMARK}" --workspace "${WORKSPACE_NAME}" --mod-location "${WORKDIR}" >/dev/null 2>&1; then
  log "ERROR: Benchmark not found: ${BENCHMARK}"
  exit 1
fi

log "[4/5] Running benchmark..."
: > "${RUN_DIR}/benchmark.stdout.log"
EXPORT_DIR="results/${STAMP}"
timeout --foreground --signal=INT --kill-after=30 "${BENCHMARK_TIMEOUT}" \
  powerpipe benchmark run "${BENCHMARK}" \
    --workspace "${WORKSPACE_NAME}" \
    --mod-location "${WORKDIR}" \
    --search-path "${SEARCH_PATH}" \
    --max-parallel "${MAX_PARALLEL}" \
    --query-timeout "${QUERY_TIMEOUT}" \
    --benchmark-timeout "${BENCHMARK_TIMEOUT}" \
    --progress=true \
    --output brief \
    --export "${EXPORT_DIR}/benchmark.json" \
    --export "${EXPORT_DIR}/benchmark.html" \
    --export "${EXPORT_DIR}/benchmark.md" \
    --export "${EXPORT_DIR}/benchmark.pps" \
    > "${RUN_DIR}/benchmark.stdout.log" 2>&1
RUN_RC="$?"
FINAL_RC="${RUN_RC}"

if [[ "${BENCHMARK_ACCEPT_FINDINGS}" == "true" && "${RUN_RC}" -ne 0 && -s "${RUN_DIR}/benchmark.stdout.log" ]] \
  && have_primary_exports && ! benchmark_stdout_has_runtime_errors; then
  log "Benchmark completed with findings only; treating this run as success for smoke validation."
  FINAL_RC=0
fi

log "[5/5] Finalizing results..."
if ! have_primary_exports; then
  write_partial_marker
fi

if should_promote_latest; then
  update_latest_link
else
  log "Skipping latest update because the run did not produce exported artifacts."
fi

printf '\nExit code: %s\n' "${RUN_RC}"
printf 'Results: %s\n' "${RUN_DIR}"
printf 'Latest:  %s\n' "${LATEST_LINK}"
printf 'Dashboard: http://localhost:%s\n' "${POWERPIPE_HOST_PORT}"

exit "${FINAL_RC}"
