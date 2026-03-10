#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${WORKDIR}/vendor/bin"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing command: $1" >&2
    exit 1
  }
}

copy_binary() {
  local name="$1"
  local source_path
  source_path="$(command -v "${name}")"

  install -m 0755 "${source_path}" "${VENDOR_DIR}/${name}"
  "${source_path}" --version > "${VENDOR_DIR}/${name}.manifest"
}

need_cmd install
need_cmd steampipe
need_cmd powerpipe

mkdir -p "${VENDOR_DIR}"

copy_binary steampipe
copy_binary powerpipe

printf 'Vendored binaries in %s\n' "${VENDOR_DIR}"
