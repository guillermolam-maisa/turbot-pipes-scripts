#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

HOME_DIR="${HOME:-/home/powerpipe}"
HOST_AWS_DIR="${HOST_AWS_DIR:-/host-aws}"
TAILPIPE_MODE="${TAILPIPE_MODE:-idle}"
TAILPIPE_CONFIG_DIR="${HOME_DIR}/.tailpipe/config"
TAILPIPE_GENERATED_CONFIG="${TAILPIPE_CONFIG_DIR}/aws.tpc"
TAILPIPE_QUERY_FILE="${TAILPIPE_QUERY_FILE:-/workspace/tailpipe/queries/cloudtrail_summary.sql}"
TAILPIPE_COLLECT_FROM="${TAILPIPE_COLLECT_FROM:-7d}"
TAILPIPE_SEED_DIR="${TAILPIPE_SEED_DIR:-/opt/tailpipe-seed/home}"
TAILPIPE_PIPES_SEED_DIR="${TAILPIPE_PIPES_SEED_DIR:-/opt/tailpipe-seed/pipes}"
PIPES_INSTALL_DIR="${PIPES_INSTALL_DIR:-${HOME_DIR}/.pipes}"
TAILPIPE_DISCOVERY_DIR="${TAILPIPE_DISCOVERY_DIR:-/workspace/powerpipe/results/discovery/latest}"
TAILPIPE_CLOUDTRAIL_DISCOVERY_FILE="${TAILPIPE_CLOUDTRAIL_DISCOVERY_FILE:-${TAILPIPE_DISCOVERY_DIR}/cloudtrail.tsv}"

log() { printf '%s\n' "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "ERROR: Missing command: $1"
    exit 1
  }
}

slug_us() {
  local s="$1"
  s="$(printf '%s' "${s}" | tr '[:upper:]' '[:lower:]')"
  s="$(printf '%s' "${s}" | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//; s/_+/_/g')"
  [[ -n "${s}" ]] || s="aws"
  printf '%s' "${s}"
}

seed_tailpipe_home() {
  if [[ -d "${TAILPIPE_SEED_DIR}" && ! -e "${HOME_DIR}/.tailpipe/plugins" ]]; then
    mkdir -p "${HOME_DIR}/.tailpipe"
    cp -a "${TAILPIPE_SEED_DIR}/." "${HOME_DIR}/.tailpipe/"
  fi

  if [[ -d "${TAILPIPE_PIPES_SEED_DIR}" && ! -e "${PIPES_INSTALL_DIR}/plugins" ]]; then
    mkdir -p "${PIPES_INSTALL_DIR}"
    cp -a "${TAILPIPE_PIPES_SEED_DIR}/." "${PIPES_INSTALL_DIR}/"
  fi
}

write_connection_block() {
  local profile_name="$1"
  local connection_name="$2"

  {
    printf 'connection "aws" "%s" {\n' "${connection_name}"
    printf '  profile = "%s"\n' "${profile_name}"
    printf '}\n\n'
  } >> "${TAILPIPE_GENERATED_CONFIG}"
}

write_partition_block() {
  local partition_name="$1"
  local connection_name="$2"
  local bucket_name="$3"
  local bucket_prefix="$4"
  local account_id="$5"
  local effective_prefix="${bucket_prefix}"
  local file_layout=""

  if [[ -n "${account_id}" ]]; then
    file_layout="AWSLogs/(%{DATA:org_id}/)?${account_id}/CloudTrail/%{DATA:region}/%{YEAR:year}/%{MONTHNUM:month}/%{MONTHDAY:day}/%{DATA}.json.gz"
    effective_prefix=""
  fi

  {
    printf 'partition "aws_cloudtrail_log" "%s" {\n' "${partition_name}"
    printf '  source "aws_s3_bucket" {\n'
    printf '    connection = connection.aws.%s\n' "${connection_name}"
    printf '    bucket     = "%s"\n' "${bucket_name}"
    if [[ -n "${file_layout}" ]]; then
      printf '    file_layout = `%s`\n' "${file_layout}"
    fi
    if [[ -n "${effective_prefix}" ]]; then
      printf '    prefix     = "%s"\n' "${effective_prefix}"
    fi
    printf '  }\n'
    printf '}\n\n'
  } >> "${TAILPIPE_GENERATED_CONFIG}"
}

build_tailpipe_config() {
  local profile_name account_id connection_name trail_name bucket_name bucket_prefix partition_name
  local current_connection=""
  local partitions_added=0
  local discovery_rows

  [[ -s "${TAILPIPE_CLOUDTRAIL_DISCOVERY_FILE}" ]] || {
    log "ERROR: CloudTrail discovery file not found: ${TAILPIPE_CLOUDTRAIL_DISCOVERY_FILE}"
    exit 1
  }

  : > "${TAILPIPE_GENERATED_CONFIG}"

  discovery_rows="$(tail -n +2 "${TAILPIPE_CLOUDTRAIL_DISCOVERY_FILE}" 2>/dev/null || true)"
  [[ -n "${discovery_rows}" ]] || {
    log "ERROR: No discovered CloudTrail sources found in ${TAILPIPE_CLOUDTRAIL_DISCOVERY_FILE}"
    exit 1
  }

  while IFS=$'\t' read -r profile_name account_id trail_name bucket_name bucket_prefix _trail_region _is_multi_region; do
    [[ -n "${profile_name}" && -n "${bucket_name}" && -n "${trail_name}" ]] || continue
    connection_name="$(slug_us "${profile_name}")"
    if [[ "${connection_name}" != "${current_connection}" ]]; then
      write_connection_block "${profile_name}" "${connection_name}"
      current_connection="${connection_name}"
    fi
    partition_name="$(slug_us "${profile_name}_${trail_name}")"
    write_partition_block "${partition_name}" "${connection_name}" "${bucket_name}" "${bucket_prefix}" "${account_id}"
    partitions_added=$((partitions_added + 1))
  done <<< "${discovery_rows}"

  [[ "${partitions_added}" -gt 0 ]] || {
    log "ERROR: No CloudTrail-backed Tailpipe partitions were generated from ${TAILPIPE_CLOUDTRAIL_DISCOVERY_FILE}."
    exit 1
  }
}

run_query_file() {
  local query

  [[ -r "${TAILPIPE_QUERY_FILE}" ]] || {
    log "ERROR: Tailpipe query file not found: ${TAILPIPE_QUERY_FILE}"
    exit 1
  }

  query="$(tr '\n' ' ' < "${TAILPIPE_QUERY_FILE}")"
  tailpipe query "${query}"
}

resolve_collect_from() {
  local value="$1"

  case "${value}" in
    *[!0-9smhdw-:TZ]*)
      printf '%s' "${value}"
      ;;
    *[0-9][smhdw])
      python3 - "${value}" <<'PY'
import re
import sys
from datetime import datetime, timedelta, timezone

value = sys.argv[1]
match = re.fullmatch(r"(\d+)([smhdw])", value)
if not match:
    print(value, end="")
    raise SystemExit(0)

amount = int(match.group(1))
unit = match.group(2)
delta_map = {
    "s": timedelta(seconds=amount),
    "m": timedelta(minutes=amount),
    "h": timedelta(hours=amount),
    "d": timedelta(days=amount),
    "w": timedelta(weeks=amount),
}
print((datetime.now(timezone.utc) - delta_map[unit]).strftime("%Y-%m-%dT%H:%M:%SZ"), end="")
PY
      ;;
    *)
      printf '%s' "${value}"
      ;;
  esac
}

need_cmd cp
need_cmd tailpipe
need_cmd tail
need_cmd tr
need_cmd python3

export AWS_SDK_LOAD_CONFIG=1

mkdir -p "${HOME_DIR}/.tailpipe" "${TAILPIPE_CONFIG_DIR}" "${HOME_DIR}/.aws" "${PIPES_INSTALL_DIR}/extensions/duckdb" /tmp
if [[ -d "${HOST_AWS_DIR}" ]]; then
  cp -a "${HOST_AWS_DIR}/." "${HOME_DIR}/.aws/"
fi
seed_tailpipe_home
build_tailpipe_config

case "${TAILPIPE_MODE}" in
  smoke)
    TAILPIPE_COLLECT_FROM_RESOLVED="$(resolve_collect_from "${TAILPIPE_COLLECT_FROM}")"
    log "Collecting CloudTrail data with Tailpipe from ${TAILPIPE_COLLECT_FROM_RESOLVED}..."
    tailpipe collect aws_cloudtrail_log --from "${TAILPIPE_COLLECT_FROM_RESOLVED}" --progress=false
    log "Querying collected CloudTrail data..."
    run_query_file
    ;;
  query-file)
    run_query_file
    ;;
  idle)
    log "Tailpipe AWS toolbox ready. Use TAILPIPE_MODE=smoke to run a real collect/query cycle."
    trap 'exit 0' INT TERM
    while true; do
      sleep 3600 &
      wait "$!"
    done
    ;;
  *)
    log "ERROR: Unsupported TAILPIPE_MODE=${TAILPIPE_MODE}"
    exit 1
    ;;
esac
