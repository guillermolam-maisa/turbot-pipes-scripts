#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

HOME_DIR="${HOME:-/home/powerpipe}"
STEAMPIPE_INSTALL_DIR="${STEAMPIPE_INSTALL_DIR:-${HOME_DIR}/.steampipe}"
STEAMPIPE_CONFIG_DIR="${STEAMPIPE_INSTALL_DIR}/config"
HOST_AWS_DIR="${HOST_AWS_DIR:-/host-aws}"
STEAMPIPE_DATABASE_PORT="${STEAMPIPE_DATABASE_PORT:-9193}"
STEAMPIPE_DATABASE_PASSWORD="${STEAMPIPE_DATABASE_PASSWORD:-steampipe}"
STEAMPIPE_SEED_DIR="${STEAMPIPE_SEED_DIR:-/opt/steampipe-seed}"
STEAMPIPE_AWS_PLUGIN_VERSION="${STEAMPIPE_AWS_PLUGIN_VERSION:-1.30.0}"
AWS_CONFIG_DIR="${HOME_DIR}/.aws"
AWS_CONFIG_FILE="${AWS_CONFIG_DIR}/config"
STEAMPIPE_GENERATED_CONFIG="${STEAMPIPE_CONFIG_DIR}/aws-profiles.spc"
HOST_STEAMPIPE_CONFIG_FILE="${HOST_STEAMPIPE_CONFIG_FILE:-/host-steampipe-config/aws.spc}"
STEAMPIPE_DEFAULT_OPTIONS_FILE="${STEAMPIPE_CONFIG_DIR}/default.spc"
STEAMPIPE_DATABASE_START_TIMEOUT="${STEAMPIPE_DATABASE_START_TIMEOUT:-180}"
STEAMPIPE_PLUGIN_START_TIMEOUT="${STEAMPIPE_PLUGIN_START_TIMEOUT:-120}"
STEAMPIPE_ALL_CONNECTION_NAME="${STEAMPIPE_ALL_CONNECTION_NAME:-aws_all}"
USED_HOST_STEAMPIPE_CONFIG="false"
STEAMPIPE_DB_ROOT="${STEAMPIPE_INSTALL_DIR}/db"

# These directories must be backed by volumes in compose.yaml to be writable
mkdir -p "${STEAMPIPE_INSTALL_DIR}" "${STEAMPIPE_CONFIG_DIR}" "${AWS_CONFIG_DIR}" /tmp

if [[ -d "${HOST_AWS_DIR}" ]]; then
  # Populate the writable volume from the read-only host mount
  cp -a "${HOST_AWS_DIR}/." "${AWS_CONFIG_DIR}/" 2>/dev/null || true
fi

if [[ -d "${STEAMPIPE_SEED_DIR}" && ! -e "${STEAMPIPE_INSTALL_DIR}/plugins" ]]; then
  cp -a "${STEAMPIPE_SEED_DIR}/." "${STEAMPIPE_INSTALL_DIR}/"
fi

slug_us() {
  local s="$1"
  s="$(printf '%s' "${s}" | tr '[:upper:]' '[:lower:]')"
  s="$(printf '%s' "${s}" | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//; s/_+/_/g')"
  [[ -n "${s}" ]] || s="aws"
  printf '%s' "${s}"
}

append_aggregator() {
  local aggregator_name="$1"
  shift
  local connections=("$@")

  [[ "${#connections[@]}" -gt 0 ]] || return 0

  {
    printf 'connection "%s" {\n' "${aggregator_name}"
    printf '  plugin      = "aws@%s"\n' "${STEAMPIPE_AWS_PLUGIN_VERSION}"
    printf '  type        = "aggregator"\n'
    printf '  connections = [\n'
    local connection_name
    for connection_name in "${connections[@]}"; do
      printf '    "%s",\n' "${connection_name}"
    done
    printf '  ]\n'
    printf '}\n\n'
  } >> "${STEAMPIPE_GENERATED_CONFIG}"
}

clear_stale_steampipe_state() {
  local stale_file

  if [[ -d "${STEAMPIPE_DB_ROOT}" ]]; then
    while IFS= read -r stale_file; do
      rm -f "${stale_file}"
    done < <(find "${STEAMPIPE_DB_ROOT}" \
      \( -name postmaster.pid -o -name postmaster.opts -o -name postmaster.log -o -name .s.PGSQL."${STEAMPIPE_DATABASE_PORT}" -o -name .s.PGSQL."${STEAMPIPE_DATABASE_PORT}".lock \) \
      -print 2>/dev/null)
  fi

  rm -f \
    "${STEAMPIPE_INSTALL_DIR}/internal/plugin_manager.json"
}

export AWS_SDK_LOAD_CONFIG=1

declare -a all_connections=()
declare -a admin_connections=()

rm -f \
  "${STEAMPIPE_CONFIG_DIR}/aws.spc" \
  "${STEAMPIPE_CONFIG_DIR}/admin_only.spc" \
  "${STEAMPIPE_CONFIG_DIR}/all.spc" \
  "${STEAMPIPE_CONFIG_DIR}/${STEAMPIPE_ALL_CONNECTION_NAME}.spc" \
  "${STEAMPIPE_GENERATED_CONFIG}"

cat > "${STEAMPIPE_DEFAULT_OPTIONS_FILE}" <<EOF
options "database" {
  start_timeout = ${STEAMPIPE_DATABASE_START_TIMEOUT}
}

options "plugin" {
  start_timeout = ${STEAMPIPE_PLUGIN_START_TIMEOUT}
}
EOF

: > "${STEAMPIPE_GENERATED_CONFIG}"

if [[ -s "${HOST_STEAMPIPE_CONFIG_FILE}" ]]; then
  USED_HOST_STEAMPIPE_CONFIG="true"
  sed -E \
    -e 's/plugin([[:space:]]*)=([[:space:]]*)"aws"/plugin\1=\2"aws@'"${STEAMPIPE_AWS_PLUGIN_VERSION}"'"/g' \
    -e 's/^connection "all"/connection "'"${STEAMPIPE_ALL_CONNECTION_NAME}"'"/' \
    "${HOST_STEAMPIPE_CONFIG_FILE}" > "${STEAMPIPE_GENERATED_CONFIG}"
  if ! grep -q '^connection "'"${STEAMPIPE_ALL_CONNECTION_NAME}"'"' "${STEAMPIPE_GENERATED_CONFIG}"; then
    echo "ERROR: Expected aggregate connection \"${STEAMPIPE_ALL_CONNECTION_NAME}\" was not generated from ${HOST_STEAMPIPE_CONFIG_FILE}." >&2
    exit 1
  fi
elif [[ -f "${AWS_CONFIG_FILE}" ]]; then
  while IFS=$'\t' read -r profile_name region_name; do
    [[ -n "${profile_name}" ]] || continue

    connection_name="$(slug_us "${profile_name}")"
    lower_profile_name="$(printf '%s' "${profile_name}" | tr '[:upper:]' '[:lower:]')"

    {
      printf 'connection "%s" {\n' "${connection_name}"
      printf '  plugin  = "aws@%s"\n' "${STEAMPIPE_AWS_PLUGIN_VERSION}"
      printf '  profile = "%s"\n' "${profile_name}"
      if [[ -n "${region_name}" ]]; then
        printf '  regions = ["%s"]\n' "${region_name}"
      fi
      printf '}\n\n'
    } >> "${STEAMPIPE_GENERATED_CONFIG}"

    all_connections+=("${connection_name}")
    if [[ "${lower_profile_name}" == *administratoraccess* || "${lower_profile_name}" == *developer-permission-set* ]]; then
      admin_connections+=("${connection_name}")
    fi
  done < <(
    awk '
      /^\[profile / {
        if (profile_name != "") {
          print profile_name "\t" profile_region
        }
        profile_name = $0
        sub(/^\[profile /, "", profile_name)
        sub(/\]$/, "", profile_name)
        profile_region = ""
        next
      }
      /^\[/ {
        if (profile_name != "") {
          print profile_name "\t" profile_region
        }
        profile_name = ""
        profile_region = ""
        next
      }
      /^[[:space:]]*region[[:space:]]*=/ && profile_name != "" {
        split($0, parts, "=")
        profile_region = parts[2]
        sub(/^[[:space:]]+/, "", profile_region)
        sub(/[[:space:]]+$/, "", profile_region)
      }
      END {
        if (profile_name != "") {
          print profile_name "\t" profile_region
        }
      }
    ' "${AWS_CONFIG_FILE}"
  )
fi

if [[ "${USED_HOST_STEAMPIPE_CONFIG}" == "true" ]]; then
  :
elif [[ "${#all_connections[@]}" -eq 0 ]]; then
  cat > "${STEAMPIPE_GENERATED_CONFIG}" <<EOF
connection "aws" {
  plugin = "aws@${STEAMPIPE_AWS_PLUGIN_VERSION}"
}

connection "admin_only" {
  plugin      = "aws@${STEAMPIPE_AWS_PLUGIN_VERSION}"
  type        = "aggregator"
  connections = ["aws"]
}

connection "${STEAMPIPE_ALL_CONNECTION_NAME}" {
  plugin      = "aws@${STEAMPIPE_AWS_PLUGIN_VERSION}"
  type        = "aggregator"
  connections = ["aws"]
}
EOF
else
  if [[ "${#admin_connections[@]}" -eq 0 ]]; then
    admin_connections=("${all_connections[@]}")
  fi
  append_aggregator "admin_only" "${admin_connections[@]}"
  append_aggregator "${STEAMPIPE_ALL_CONNECTION_NAME}" "${all_connections[@]}"
fi

# The persisted Steampipe volume can retain service metadata from a prior
# container lifecycle. Force-clear any previous service state before starting
# the foreground service for this container.
steampipe service stop --force >/dev/null 2>&1 || true
clear_stale_steampipe_state

exec steampipe service start \
  --foreground \
  --database-listen network \
  --database-port "${STEAMPIPE_DATABASE_PORT}" \
  --database-password "${STEAMPIPE_DATABASE_PASSWORD}"
