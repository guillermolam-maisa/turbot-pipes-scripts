#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

set -euo pipefail

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib-path.sh
source "${WORKDIR}/scripts/lib-path.sh"
prepend_vendor_bin "${WORKDIR}"
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

run_black_check() {
  local black_cmd="$1"
  shift
  local path
  for path in "$@"; do
    if ! "${black_cmd}" --check --quiet "${WORKDIR}/${path}" >/dev/null; then
      FAILED=1
    fi
  done
}

check_file "Taskfile.yml"
check_file "pyproject.toml"
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
check_file "scripts/install-host-deps.sh"
check_file "scripts/bootstrap-workspace.sh"
check_file "scripts/doctor.sh"
check_file "scripts/lib-path.sh"
check_file "src/turbot_ops/cli.py"
check_file "src/turbot_ops/benchmark.py"
check_file "src/turbot_ops/bootstrap.py"
check_file "src/turbot_ops/doctor.py"
check_file "src/turbot_ops/logging_utils.py"
check_file "src/turbot_ops/steampipe.py"
check_file "src/turbot_ops/tailpipe.py"
check_file "src/turbot_ops/aws_helpers.py"
check_file "src/turbot_ops/utilities.py"
check_file "src/turbot_ops/benchmark_common.py"
check_file "src/turbot_ops/benchmark_host.py"
check_file "src/turbot_ops/benchmark_compose.py"
check_file "src/turbot_ops/utility_support.py"
check_file "src/turbot_ops/utility_install.py"
check_file "src/turbot_ops/utility_checks.py"
check_file "tests/test_config.py"
check_file "tests/test_aws_helpers.py"
check_file "tests/test_utilities.py"
check_file "tests/test_benchmark_common.py"
check_file "tests/test_benchmark_host.py"
check_file "tests/test_utility_support.py"
check_file "tests/test_utility_install.py"

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
run_bash_syntax "scripts/install-host-deps.sh"
run_bash_syntax "scripts/bootstrap-workspace.sh"
run_bash_syntax "scripts/doctor.sh"
run_bash_syntax "scripts/lib-path.sh"

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

if command -v python3 >/dev/null 2>&1; then
  if ! python3 -m compileall "${WORKDIR}/src" >/dev/null; then
    FAILED=1
  fi
else
  echo "WARN: python3 not installed; skipped Python compilation validation." >&2
fi

if command -v poetry >/dev/null 2>&1; then
  run_black_check "poetry run black" \
    "src/turbot_ops/__init__.py" \
    "src/turbot_ops/aws_helpers.py" \
    "src/turbot_ops/benchmark.py" \
    "src/turbot_ops/benchmark_common.py" \
    "src/turbot_ops/benchmark_compose.py" \
    "src/turbot_ops/benchmark_host.py" \
    "src/turbot_ops/bootstrap.py" \
    "src/turbot_ops/cli.py" \
    "src/turbot_ops/config.py" \
    "src/turbot_ops/doctor.py" \
    "src/turbot_ops/logging_utils.py" \
    "src/turbot_ops/runtime.py" \
    "src/turbot_ops/steampipe.py" \
    "src/turbot_ops/tailpipe.py" \
    "src/turbot_ops/utilities.py" \
    "src/turbot_ops/utility_checks.py" \
    "src/turbot_ops/utility_install.py" \
    "src/turbot_ops/utility_support.py" \
    "tests/test_aws_helpers.py" \
    "tests/test_benchmark_common.py" \
    "tests/test_benchmark_host.py" \
    "tests/test_cli.py" \
    "tests/test_config.py" \
    "tests/test_utility_install.py" \
    "tests/test_utilities.py" \
    "tests/test_utility_support.py"
  if ! poetry run ruff check "${WORKDIR}/src" "${WORKDIR}/tests" >/dev/null; then
    FAILED=1
  fi
  if ! poetry run pytest -q "${WORKDIR}/tests" >/dev/null; then
    FAILED=1
  fi
elif command -v pytest >/dev/null 2>&1; then
  if command -v black >/dev/null 2>&1; then
    run_black_check "black" \
      "src/turbot_ops/__init__.py" \
      "src/turbot_ops/aws_helpers.py" \
      "src/turbot_ops/benchmark.py" \
      "src/turbot_ops/benchmark_common.py" \
      "src/turbot_ops/benchmark_compose.py" \
      "src/turbot_ops/benchmark_host.py" \
      "src/turbot_ops/bootstrap.py" \
      "src/turbot_ops/cli.py" \
      "src/turbot_ops/config.py" \
      "src/turbot_ops/doctor.py" \
      "src/turbot_ops/logging_utils.py" \
      "src/turbot_ops/runtime.py" \
      "src/turbot_ops/steampipe.py" \
      "src/turbot_ops/tailpipe.py" \
      "src/turbot_ops/utilities.py" \
      "src/turbot_ops/utility_checks.py" \
      "src/turbot_ops/utility_install.py" \
      "src/turbot_ops/utility_support.py" \
      "tests/test_aws_helpers.py" \
      "tests/test_benchmark_common.py" \
      "tests/test_benchmark_host.py" \
      "tests/test_cli.py" \
      "tests/test_config.py" \
      "tests/test_utility_install.py" \
      "tests/test_utilities.py" \
      "tests/test_utility_support.py"
  else
    echo "WARN: black not installed; skipped Python formatting validation." >&2
  fi
  if command -v ruff >/dev/null 2>&1; then
    if ! ruff check "${WORKDIR}/src" "${WORKDIR}/tests" >/dev/null; then
      FAILED=1
    fi
  else
    echo "WARN: ruff not installed; skipped Python lint validation." >&2
  fi
  if ! pytest -q "${WORKDIR}/tests" >/dev/null; then
    FAILED=1
  fi
else
  echo "WARN: pytest not installed; skipped Python test validation." >&2
fi

if [[ "${FAILED}" -ne 0 ]]; then
  echo "Validation failed." >&2
  exit 1
fi

echo "Validation passed."
