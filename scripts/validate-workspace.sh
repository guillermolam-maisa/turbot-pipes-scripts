#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

check_file() {
  local path="$1"
  if [[ ! -f "${WORKDIR}/${path}" ]]; then
    echo "ERROR: missing file: ${path}" >&2
    FAILED=1
  fi
}

check_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "WARN: command not installed: ${cmd}" >&2
  fi
}

run_bash_syntax() {
  local path="$1"
  if ! bash -n "${WORKDIR}/${path}"; then
    FAILED=1
  fi
}

check_file "Taskfile.yml"
check_file "compose.yaml"
check_file "Dockerfile"
check_file "powerpipe/mod.pp"
check_file "powerpipe/run-all-controls-safe.sh"
check_file "scripts/compose-steampipe.sh"
check_file "scripts/compose-powerpipe.sh"
check_file "scripts/compose-benchmark-runner.sh"
check_file "scripts/compose-tailpipe.sh"
check_file "tailpipe/queries/cloudtrail_summary.sql"
check_file "scripts/vendor-local-binaries.sh"
check_file "scripts/select-port.sh"
check_file "scripts/write-compose-env.sh"
check_file "scripts/check-dependencies.sh"
check_file "scripts/docker-compose.sh"

run_bash_syntax "powerpipe/run-all-controls-safe.sh"
run_bash_syntax "scripts/compose-steampipe.sh"
run_bash_syntax "scripts/compose-powerpipe.sh"
run_bash_syntax "scripts/compose-benchmark-runner.sh"
run_bash_syntax "scripts/compose-tailpipe.sh"
run_bash_syntax "scripts/vendor-local-binaries.sh"
run_bash_syntax "scripts/select-port.sh"
run_bash_syntax "scripts/write-compose-env.sh"
run_bash_syntax "scripts/check-dependencies.sh"
run_bash_syntax "scripts/docker-compose.sh"
run_bash_syntax "scripts/validate-workspace.sh"

if ! bash "${WORKDIR}/scripts/check-dependencies.sh" --profile common; then
  FAILED=1
fi

check_cmd docker
check_cmd task
check_cmd steampipe
check_cmd powerpipe

if command -v docker >/dev/null 2>&1; then
  if ! bash "${WORKDIR}/scripts/write-compose-env.sh" >/dev/null; then
    FAILED=1
  elif ! bash "${WORKDIR}/scripts/docker-compose.sh" --env-file /tmp/turbot-runtime/compose.env -f "${WORKDIR}/compose.yaml" config >/dev/null; then
    FAILED=1
  fi
else
  echo "WARN: docker not installed; skipped compose validation." >&2
fi

if command -v task >/dev/null 2>&1; then
  if ! task --taskfile "${WORKDIR}/Taskfile.yml" --list >/dev/null; then
    FAILED=1
  fi
else
  echo "WARN: task not installed; skipped Taskfile validation." >&2
fi

if [[ "${FAILED}" -ne 0 ]]; then
  echo "Validation failed." >&2
  exit 1
fi

echo "Validation passed."
