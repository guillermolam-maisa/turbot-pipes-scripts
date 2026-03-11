#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]} [--profile ...]" >&2
  return 1 2>/dev/null || exit 1
fi

PROFILE="${PROFILE:-all}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

FAILED=0

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

need_cmd() {
  local cmd="$1"
  if ! have_cmd "${cmd}"; then
    echo "ERROR: missing command: ${cmd}" >&2
    FAILED=1
  fi
}

need_one_of() {
  local label="$1"
  shift
  local cmd
  for cmd in "$@"; do
    if have_cmd "${cmd}"; then
      return 0
    fi
  done
  echo "ERROR: need one of: ${label}" >&2
  FAILED=1
}

check_home() {
  if [[ -z "${HOME:-}" || ! -d "${HOME}" ]]; then
    echo "ERROR: HOME is not set to a readable directory" >&2
    FAILED=1
  fi
}

check_path() {
  local path="$1"
  local label="$2"
  if [[ ! -e "${path}" ]]; then
    echo "ERROR: missing ${label}: ${path}" >&2
    FAILED=1
  fi
}

check_profile_common() {
  need_cmd bash
  need_cmd awk
  need_cmd cat
  need_cmd cp
  need_cmd date
  need_cmd grep
  need_cmd ln
  need_cmd mkdir
  need_cmd mv
  need_cmd rm
  need_cmd sed
  need_cmd tr
}

check_profile_host() {
  need_cmd powerpipe
  need_cmd steampipe
  need_cmd timeout
  need_cmd pgrep
  need_cmd pkill
  need_one_of "lsof ss" lsof ss
}

check_profile_compose() {
  need_cmd docker
  check_home
  check_path "${HOME}/.aws" "AWS config directory"
  if [[ ! -f "${HOME}/.steampipe/config/aws.spc" ]]; then
    echo "WARN: host Steampipe config not found: ${HOME}/.steampipe/config/aws.spc" >&2
  fi
}

check_profile_tailpipe() {
  need_cmd aws
  need_cmd python3
  need_cmd tailpipe
  check_home
  check_path "${HOME}/.aws/config" "AWS shared config"
}

check_profile_task() {
  need_cmd task
}

check_profile_common

case "${PROFILE}" in
  common)
    ;;
  host)
    check_profile_host
    ;;
  compose)
    check_profile_compose
    ;;
  tailpipe)
    check_profile_tailpipe
    ;;
  task)
    check_profile_task
    ;;
  all)
    check_profile_host
    check_profile_compose
    check_profile_tailpipe
    check_profile_task
    ;;
  *)
    echo "ERROR: unsupported profile: ${PROFILE}" >&2
    exit 1
    ;;
esac

if [[ "${FAILED}" -ne 0 ]]; then
  exit 1
fi
