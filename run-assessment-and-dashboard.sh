#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config
# -----------------------------
TURBOT_HOME="${HOME}/turbot"
WORKSPACE_DIR="${TURBOT_HOME}/powerpipe"
RESULTS_DIR="${WORKSPACE_DIR}/results"
SERVER_PORT="${SERVER_PORT:-9033}"

# Use your clean admin aggregator by default
STEAMPIPE_SEARCH_PATH_VALUE="${STEAMPIPE_SEARCH_PATH_VALUE:-admin_only}"

# Pick a benchmark from the installed aws_compliance mod
BENCHMARK_NAME="${BENCHMARK_NAME:-aws_compliance.benchmark.cis_v150}"

# Install mods if missing
AWS_COMPLIANCE_MOD="github.com/turbot/steampipe-mod-aws-compliance"
AWS_INSIGHTS_MOD="github.com/turbot/steampipe-mod-aws-insights"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${RESULTS_DIR}/${TIMESTAMP}"

# -----------------------------
# Helpers
# -----------------------------
log() {
  printf '%s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

ensure_dir() {
  mkdir -p "$1"
}

service_running() {
  steampipe service status >/dev/null 2>&1
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

# -----------------------------
# Checks
# -----------------------------
need_cmd aws
need_cmd jq
need_cmd steampipe
need_cmd powerpipe

ensure_dir "$WORKSPACE_DIR"
ensure_dir "$RESULTS_DIR"
ensure_dir "$RUN_DIR"

# -----------------------------
# Workspace setup
# -----------------------------
cd "$WORKSPACE_DIR"

if [[ ! -f "mod.pp" ]]; then
  log "[1/8] Initializing Powerpipe workspace..."
  powerpipe mod init >/dev/null
else
  log "[1/8] Powerpipe workspace already initialized."
fi

log "[2/8] Installing/updating required Powerpipe mods..."
powerpipe mod install "$AWS_COMPLIANCE_MOD"
powerpipe mod install "$AWS_INSIGHTS_MOD"

# -----------------------------
# Validate benchmark exists
# -----------------------------
log "[3/8] Validating benchmark name..."
if ! powerpipe benchmark show "$BENCHMARK_NAME" >/dev/null 2>&1; then
  log "Available benchmarks that match 'cis':"
  powerpipe benchmark list | grep cis || true
  die "Benchmark not found: $BENCHMARK_NAME"
fi

# -----------------------------
# Ensure Steampipe DB is up
# -----------------------------
log "[4/8] Ensuring Steampipe service is running..."
if ! service_running; then
  steampipe service start >/dev/null
fi

# -----------------------------
# Run assessment
# -----------------------------
log "[5/8] Running benchmark: $BENCHMARK_NAME"
log "      Search path: $STEAMPIPE_SEARCH_PATH_VALUE"
export STEAMPIPE_SEARCH_PATH="$STEAMPIPE_SEARCH_PATH_VALUE"

# Powerpipe exit codes are meaningful:
# 0 = no alarms/errors
# 1 = alarms
# 2 = control errors
# We'll capture the exit code but still continue to save artifacts and start dashboard.
BENCHMARK_EXIT=0
set +e
powerpipe benchmark run "$BENCHMARK_NAME" \
  --output html > "${RUN_DIR}/benchmark.html"
BENCHMARK_EXIT=$?
set -e

# Also save machine-readable and readable outputs
powerpipe benchmark run "$BENCHMARK_NAME" --output json > "${RUN_DIR}/benchmark.json" || true
powerpipe benchmark run "$BENCHMARK_NAME" --output md > "${RUN_DIR}/benchmark.md" || true
powerpipe benchmark run "$BENCHMARK_NAME" --output pps > "${RUN_DIR}/benchmark.pps" || true

# -----------------------------
# Helpful inventory snapshots
# -----------------------------
log "[6/8] Saving a few AWS inventory snapshots..."
steampipe query --search-path "$STEAMPIPE_SEARCH_PATH_VALUE" \
  "select account_id, arn from aws_sts_caller_identity;" \
  --output json > "${RUN_DIR}/caller_identity.json" || true

steampipe query --search-path "$STEAMPIPE_SEARCH_PATH_VALUE" \
  "select account_id, region, instance_id, title from aws_ec2_instance limit 200;" \
  --output json > "${RUN_DIR}/ec2_instances.json" || true

steampipe query --search-path "$STEAMPIPE_SEARCH_PATH_VALUE" \
  "select account_id, name, arn from aws_iam_role limit 500;" \
  --output json > "${RUN_DIR}/iam_roles.json" || true

# -----------------------------
# Start dashboard server
# -----------------------------
log "[7/8] Starting Powerpipe dashboard server on port ${SERVER_PORT}..."

# Stop any prior background server we started in this shell session
if [[ -n "${POWERPIPE_SERVER_PID:-}" ]]; then
  kill "${POWERPIPE_SERVER_PID}" >/dev/null 2>&1 || true
fi

# Start in background and save logs
nohup powerpipe server --port "$SERVER_PORT" > "${RUN_DIR}/powerpipe-server.log" 2>&1 &
POWERPIPE_SERVER_PID=$!
if ! wait_for_port "127.0.0.1" "${SERVER_PORT}" 30; then
  die "Powerpipe server did not start on port ${SERVER_PORT}"
fi

# -----------------------------
# Summary
# -----------------------------
log "[8/8] Done."
echo
echo "Assessment results saved to:"
echo "  ${RUN_DIR}"
echo
echo "Files:"
echo "  ${RUN_DIR}/benchmark.html"
echo "  ${RUN_DIR}/benchmark.json"
echo "  ${RUN_DIR}/benchmark.md"
echo "  ${RUN_DIR}/benchmark.pps"
echo "  ${RUN_DIR}/caller_identity.json"
echo "  ${RUN_DIR}/ec2_instances.json"
echo "  ${RUN_DIR}/iam_roles.json"
echo "  ${RUN_DIR}/powerpipe-server.log"
echo
echo "Dashboard server:"
echo "  http://localhost:${SERVER_PORT}"
echo
echo "Benchmark run:"
echo "  ${BENCHMARK_NAME}"
echo
echo "Search path:"
echo "  ${STEAMPIPE_SEARCH_PATH_VALUE}"
echo
echo "Powerpipe exit code:"
echo "  ${BENCHMARK_EXIT}"

case "$BENCHMARK_EXIT" in
  0)
    echo "Result: no alarms or control errors."
    ;;
  1)
    echo "Result: completed with one or more ALARMs."
    ;;
  2)
    echo "Result: completed with one or more control ERRORS."
    ;;
  *)
    echo "Result: unexpected/non-standard exit code."
    ;;
esac
