#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib-path.sh
source "${WORKDIR}/../scripts/lib-path.sh"
prepend_vendor_bin "${WORKDIR}/.."
RESULTS_DIR="${WORKDIR}/results"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${RESULTS_DIR}/${STAMP}"
LATEST_LINK="${RESULTS_DIR}/latest"
PORT="${PORT:-9033}"

SEARCH_PATH="${SEARCH_PATH:-admin_only}"
BENCHMARK="${BENCHMARK:-aws_compliance.benchmark.all_controls}"
MAX_PARALLEL="${MAX_PARALLEL:-0}"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-90}"
BENCHMARK_TIMEOUT="${BENCHMARK_TIMEOUT:-0}"
SERVICE_TIMEOUT="${SERVICE_TIMEOUT:-30}"

if [[ "${MAX_PARALLEL}" -eq 0 ]]; then
  if command -v nproc >/dev/null 2>&1; then
    MAX_PARALLEL="$(nproc)"
  else
    MAX_PARALLEL=2
  fi
fi
POWERPIPE_SERVER_WAIT="${POWERPIPE_SERVER_WAIT:-5}"
STEAMPIPE_READY_TIMEOUT="${STEAMPIPE_READY_TIMEOUT:-60}"

POWERPIPE_PID=""
RUN_RC=0

log() { printf '%s\n' "$*" >&2; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: Missing command: $1"; exit 1; }; }

need_cmd steampipe
need_cmd powerpipe
need_cmd pgrep
need_cmd pkill
need_cmd mkdir
need_cmd ps
need_cmd lsof
need_cmd timeout
need_cmd sed
need_cmd tee

select_powerpipe_port() {
  PORT="$(bash "${WORKDIR}/../scripts/select-port.sh" --preferred "${PORT}")"
}

wait_for_port() {
  local host="$1"
  local port="$2"
  local timeout_secs="$3"
  local started_at
  started_at="$(date +%s)"

  while true; do
    if bash -lc "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1; then
      return 0
    fi

    if (( $(date +%s) - started_at >= timeout_secs )); then
      return 1
    fi

    sleep 1
  done
}

mkdir -p "${RESULTS_DIR}" "${RUN_DIR}"
cd "${WORKDIR}" || exit 1

write_run_metadata() {
  # Persist only the run contract, not the ambient shell environment.
  cat > "${RUN_DIR}/run.env" <<EOF
WORKDIR=${WORKDIR}
RUN_DIR=${RUN_DIR}
BENCHMARK=${BENCHMARK}
SEARCH_PATH=${SEARCH_PATH}
MAX_PARALLEL=${MAX_PARALLEL}
QUERY_TIMEOUT=${QUERY_TIMEOUT}
BENCHMARK_TIMEOUT=${BENCHMARK_TIMEOUT}
PORT=${PORT}
EOF
}

capture_query() {
  local output_file="$1"
  shift
  if ! steampipe query "$@" > "${output_file}" 2>&1; then
    return 1
  fi
}

capture_diagnostics() {
  local prefix="$1"
  local resolved_search_path
  resolved_search_path="$(resolve_search_path)"
  capture_query "${RUN_DIR}/${prefix}-pg-activity.txt" \
    "select pid, application_name, state, wait_event_type, wait_event, left(query, 160) as query from pg_stat_activity where datname = 'steampipe' order by pid;"
  capture_query "${RUN_DIR}/${prefix}-pg-summary.txt" \
    "select application_name, state, wait_event_type, wait_event, count(*) as sessions from pg_stat_activity where datname = 'steampipe' group by 1,2,3,4 order by sessions desc, application_name;"
  capture_query "${RUN_DIR}/${prefix}-caller-identity.json" --search-path "${resolved_search_path}" --output json \
    "select * from aws_caller_identity;"
  sed -n '1,200p' "${HOME}/.steampipe/logs/steampipe-$(date +%Y-%m-%d).log" > "${RUN_DIR}/${prefix}-steampipe.log" 2>/dev/null || true
  sed -n '1,240p' "${HOME}/.steampipe/logs/plugin-$(date +%Y-%m-%d).log" > "${RUN_DIR}/${prefix}-plugin.log" 2>/dev/null || true
}

terminate_steampipe_clients() {
  timeout 15 steampipe query \
    "select pid, application_name, pg_terminate_backend(pid) as terminated from pg_stat_activity where datname = 'steampipe' and pid <> pg_backend_pid() and application_name not like 'steampipe_service_%';" \
    > "${RUN_DIR}/cleanup-terminate-backends.txt" 2>&1 || true
}

force_reset_steampipe_processes() {
  pkill -9 -f "${HOME}/.steampipe/db/.*/postgres" >/dev/null 2>&1 || true
  pkill -9 -f 'steampipe plugin-manager' >/dev/null 2>&1 || true
  pkill -9 -f 'steampipe-plugin-aws.plugin' >/dev/null 2>&1 || true
  sleep 2
}

wait_for_steampipe() {
  local started_at
  started_at="$(date +%s)"

  while true; do
    if timeout 15 steampipe query "select 1 as ok;" >/dev/null 2>&1; then
      return 0
    fi

    if (( $(date +%s) - started_at >= STEAMPIPE_READY_TIMEOUT )); then
      return 1
    fi

    sleep 2
  done
}

restart_steampipe_cleanly() {
  log "[2/8] Restarting Steampipe service..."
  terminate_steampipe_clients

  timeout "${SERVICE_TIMEOUT}" steampipe service restart >/dev/null 2>&1 || true

  if ! timeout 15 steampipe service status >/dev/null 2>&1; then
    timeout "${SERVICE_TIMEOUT}" steampipe service start >/dev/null 2>&1 || true
  fi

  if wait_for_steampipe; then
    return 0
  fi

  log "Steampipe was not queryable after restart/start; forcing a clean reset."
  capture_diagnostics "pre-reset"

  timeout 20 steampipe service stop --force >/dev/null 2>&1 || true
  force_reset_steampipe_processes

  if ! timeout "${SERVICE_TIMEOUT}" steampipe service start >/dev/null 2>&1; then
    capture_diagnostics "failed-reset"
    log "ERROR: unable to restart Steampipe cleanly."
    exit 1
  fi

  if ! wait_for_steampipe; then
    capture_diagnostics "failed-reset"
    log "ERROR: unable to restart Steampipe cleanly."
    exit 1
  fi
}

expand_named_search_path() {
  local name="$1"
  local config_file="${HOME}/.steampipe/config/aws.spc"

  [[ -f "${config_file}" ]] || return 1

  awk -v name="${name}" '
    $0 ~ "^[[:space:]]*connection \"" name "\"[[:space:]]*\\{" { in_block = 1; next }
    in_block && /^[[:space:]]*}/ { exit }
    in_block && /^[[:space:]]*connections[[:space:]]*=[[:space:]]*\[/ { in_list = 1; next }
    in_list {
      if ($0 ~ /\]/) {
        in_list = 0
      }
      while (match($0, /"[^"]+"/)) {
        value = substr($0, RSTART + 1, RLENGTH - 2)
        out = (out == "" ? value : out "," value)
        $0 = substr($0, RSTART + RLENGTH)
      }
    }
    END {
      if (out != "") {
        print out
      } else {
        exit 1
      }
    }
  ' "${config_file}"
}

resolve_search_path() {
  local expanded

  if [[ "${SEARCH_PATH}" == *,* ]]; then
    printf '%s' "${SEARCH_PATH}"
    return
  fi

  if expanded="$(expand_named_search_path "${SEARCH_PATH}")"; then
    printf '%s' "${expanded}"
    return
  fi

  printf '%s' "${SEARCH_PATH}"
}

port_owner_pid() {
  lsof -tiTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null | head -n 1
}

ensure_powerpipe_server() {
  local pid command
  pid="$(port_owner_pid)"

  log "[4/8] Ensuring dashboard server on port ${PORT}..."
  if [[ -n "${pid}" ]]; then
    command="$(ps -p "${pid}" -o command= 2>/dev/null)"
    if [[ "${command}" == *"powerpipe server"* ]]; then
      log "Reusing existing Powerpipe server on port ${PORT} (pid ${pid})."
      return 0
    fi
    log "ERROR: port ${PORT} is in use by another process: ${command}"
    exit 1
  fi

  nohup powerpipe server --port "${PORT}" > "${RUN_DIR}/powerpipe-server.log" 2>&1 &
  POWERPIPE_PID="$!"
  if ! wait_for_port "127.0.0.1" "${PORT}" "${POWERPIPE_SERVER_WAIT}"; then
    log "ERROR: powerpipe server did not start on port ${PORT}."
    exit 1
  fi

  pid="$(port_owner_pid)"
  if [[ -z "${pid}" ]]; then
    log "ERROR: powerpipe server did not expose a listener on port ${PORT}."
    exit 1
  fi
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

run_benchmark() {
  local resolved_search_path benchmark_timeout_rc
  resolved_search_path="$(resolve_search_path)"

  log "[5/8] Running benchmark..."
  log "      Dashboard: http://localhost:${PORT}/${BENCHMARK}"
  log "      Search path: ${SEARCH_PATH}"
  log "      Resolved search path: ${resolved_search_path}"
  log "      Max parallel: ${MAX_PARALLEL}"
  log "      Query timeout: ${QUERY_TIMEOUT}s"
  log "      Benchmark timeout: ${BENCHMARK_TIMEOUT}s"

  : > "${RUN_DIR}/benchmark.stdout.log"

  timeout --foreground --signal=INT --kill-after=30 "${BENCHMARK_TIMEOUT}" \
    powerpipe benchmark run "${BENCHMARK}" \
      --search-path "${resolved_search_path}" \
      --max-parallel "${MAX_PARALLEL}" \
      --query-timeout "${QUERY_TIMEOUT}" \
      --benchmark-timeout "${BENCHMARK_TIMEOUT}" \
      --progress=true \
      --output brief \
      --export "${RUN_DIR}/benchmark.json" \
      --export "${RUN_DIR}/benchmark.html" \
      --export "${RUN_DIR}/benchmark.md" \
      --export "${RUN_DIR}/benchmark.pps" \
      > "${RUN_DIR}/benchmark.stdout.log" 2>&1
  benchmark_timeout_rc="$?"
  RUN_RC="${benchmark_timeout_rc}"

  if [[ "${RUN_RC}" -eq 124 ]]; then
    log "Benchmark hit the external timeout after ${BENCHMARK_TIMEOUT}s."
  fi
}

have_primary_exports() {
  [[ -s "${RUN_DIR}/benchmark.json" ]] || [[ -s "${RUN_DIR}/benchmark.html" ]] || [[ -s "${RUN_DIR}/benchmark.md" ]] || [[ -s "${RUN_DIR}/benchmark.pps" ]]
}

should_promote_latest() {
  [[ "${RUN_RC}" -eq 0 ]] || have_primary_exports
}

write_partial_marker() {
  cat > "${RUN_DIR}/partial-artifacts.txt" <<EOF
Benchmark did not complete cleanly.
Exit code: ${RUN_RC}
Benchmark: ${BENCHMARK}
Search path: ${SEARCH_PATH}

Available diagnostics:
- ${RUN_DIR}/benchmark.stdout.log
- ${RUN_DIR}/post-run-pg-activity.txt
- ${RUN_DIR}/post-run-pg-summary.txt
- ${RUN_DIR}/post-run-caller-identity.json
- ${RUN_DIR}/post-run-steampipe.log
- ${RUN_DIR}/post-run-plugin.log
EOF
}

log "[1/8] Cleaning up stale Powerpipe processes..."
pkill -f "powerpipe benchmark run" >/dev/null 2>&1 || true
pkill -f "powerpipe server" >/dev/null 2>&1 || true
select_powerpipe_port

write_run_metadata
restart_steampipe_cleanly

log "[3/8] Validating benchmark..."
if ! powerpipe benchmark show "${BENCHMARK}" >/dev/null 2>&1; then
  log "ERROR: Benchmark not found: ${BENCHMARK}"
  exit 1
fi

ensure_powerpipe_server
capture_diagnostics "pre-run"
run_benchmark
capture_diagnostics "post-run"

log "[6/8] Checking exported artifacts..."
if ! have_primary_exports; then
  write_partial_marker
fi

log "[7/8] Updating latest pointer..."
if should_promote_latest; then
  if ! update_latest_link; then
    exit 1
  fi
else
  log "Skipping latest update because the run did not produce exported artifacts."
fi

log "[8/8] Finished."
printf '\nExit code: %s\n' "${RUN_RC}"
printf 'Results: %s\n' "${RUN_DIR}"
printf 'Latest:  %s\n' "${LATEST_LINK}"
printf 'Dashboard: http://localhost:%s/%s\n' "${PORT}" "${BENCHMARK}"

exit "${RUN_RC}"
