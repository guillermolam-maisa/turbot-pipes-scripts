#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]} [args]" >&2
  return 1 2>/dev/null || exit 1
fi

PREFERRED_PORT="${PREFERRED_PORT:-9033}"
MAX_PORT="${MAX_PORT:-65535}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preferred)
      PREFERRED_PORT="$2"
      shift 2
      ;;
    --max)
      MAX_PORT="$2"
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing command: $1" >&2
    exit 1
  }
}

port_in_use() {
  local port="$1"
  local used_ports="${2:-}"

  if [[ -n "${used_ports}" ]]; then
    grep -qx "${port}" <<< "${used_ports}"
    return $?
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -tiTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi

  if command -v ss >/dev/null 2>&1; then
    ss -ltnH "( sport = :${port} )" 2>/dev/null | grep -q .
    return $?
  fi

  echo "ERROR: need either lsof or ss to detect used ports" >&2
  exit 1
}

need_cmd bash
need_cmd grep

used_ports=""
if command -v ss >/dev/null 2>&1; then
  used_ports="$(ss -ltnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | grep -E '^[0-9]+$' || true)"
fi

if ! [[ "${PREFERRED_PORT}" =~ ^[0-9]+$ && "${MAX_PORT}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: preferred and max ports must be integers" >&2
  exit 1
fi

if (( PREFERRED_PORT < 1 || PREFERRED_PORT > MAX_PORT || MAX_PORT > 65535 )); then
  echo "ERROR: invalid port range ${PREFERRED_PORT}-${MAX_PORT}" >&2
  exit 1
fi

for ((port=PREFERRED_PORT; port<=MAX_PORT; port++)); do
  if ! port_in_use "${port}" "${used_ports}"; then
    printf '%s\n' "${port}"
    exit 0
  fi
done

echo "ERROR: no free TCP ports found in range ${PREFERRED_PORT}-${MAX_PORT}" >&2
exit 1
