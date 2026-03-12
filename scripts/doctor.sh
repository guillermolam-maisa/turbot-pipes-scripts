#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib-path.sh
source "${ROOT_DIR}/scripts/lib-path.sh"
prepend_vendor_bin "${ROOT_DIR}"

FAILED=0

pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

check_cmd() {
  local cmd="$1"
  if command -v "${cmd}" >/dev/null 2>&1; then
    pass "found ${cmd} at $(command -v "${cmd}")"
  else
    fail "missing command ${cmd}"
  fi
}

check_file() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    pass "found ${path}"
  else
    fail "missing ${path}"
  fi
}

check_cmd bash
check_cmd awk
check_cmd curl
check_cmd docker
check_cmd aws
check_cmd task
check_cmd steampipe
check_cmd powerpipe
check_cmd tailpipe

if command -v docker >/dev/null 2>&1; then
  if docker ps >/dev/null 2>&1; then
    pass "docker daemon is reachable without sudo"
  else
    warn "docker is installed but daemon access requires sudo or extra group membership"
  fi
fi

check_file "${HOME}/.aws"
check_file "${HOME}/.aws/config"

if command -v steampipe >/dev/null 2>&1; then
  if steampipe plugin list 2>/dev/null | grep -q ' aws '; then
    pass "Steampipe AWS plugin is installed"
  else
    fail "Steampipe AWS plugin is not installed"
  fi
fi

if command -v tailpipe >/dev/null 2>&1; then
  if tailpipe plugin list 2>/dev/null | grep -q ' aws '; then
    pass "Tailpipe AWS plugin is installed"
  else
    fail "Tailpipe AWS plugin is not installed"
  fi
fi

if command -v powerpipe >/dev/null 2>&1; then
  if (cd "${ROOT_DIR}/powerpipe" && powerpipe mod list >/dev/null 2>&1); then
    pass "Powerpipe workspace mods are installed"
  else
    fail "Powerpipe workspace mods are not installed"
  fi
fi

if ! bash "${ROOT_DIR}/scripts/check-dependencies.sh" --profile common >/dev/null 2>&1; then
  fail "common dependency checks failed"
else
  pass "common dependency checks passed"
fi

if [[ "${FAILED}" -ne 0 ]]; then
  exit 1
fi
