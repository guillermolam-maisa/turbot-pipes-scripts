#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]} [--install-dir DIR]" >&2
  return 1 2>/dev/null || exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib-path.sh
source "${ROOT_DIR}/scripts/lib-path.sh"
prepend_vendor_bin "${ROOT_DIR}"

INSTALL_DIR="${INSTALL_DIR:-${ROOT_DIR}/vendor/bin}"
STEAMPIPE_VERSION="${STEAMPIPE_VERSION:-2.4.0}"
POWERPIPE_VERSION="${POWERPIPE_VERSION:-1.5.0}"
TAILPIPE_VERSION="${TAILPIPE_VERSION:-0.7.2}"
CHECKSUM_FILE="${ROOT_DIR}/vendor/bin/tool_checksums.txt"
ARCHIVE_ARCH="${ARCHIVE_ARCH:-linux_amd64}"
OS_NAME="${OS_NAME:-$(uname -s)}"
MACHINE_ARCH="${MACHINE_ARCH:-$(uname -m)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

log() { printf '%s\n' "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "ERROR: missing command: $1"
    exit 1
  }
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
    return
  fi

  log "ERROR: need sha256sum or shasum"
  exit 1
}

expected_checksum() {
  local archive_name="$1"
  awk -v archive_name="${archive_name}" '$2 == archive_name { print $1 }' "${CHECKSUM_FILE}"
}

archive_url() {
  local tool_name="$1"
  local version="$2"

  case "${tool_name}" in
    steampipe)
      printf 'https://github.com/turbot/steampipe/releases/download/v%s/steampipe_%s.tar.gz\n' "${version}" "${ARCHIVE_ARCH}"
      ;;
    powerpipe)
      printf 'https://github.com/turbot/powerpipe/releases/download/v%s/powerpipe.linux.amd64.tar.gz\n' "${version}"
      ;;
    tailpipe)
      printf 'https://github.com/turbot/tailpipe/releases/download/v%s/tailpipe.linux.amd64.tar.gz\n' "${version}"
      ;;
  esac
}

install_tool() {
  local tool_name="$1"
  local version="$2"
  local archive_name="${tool_name}_v${version}.tar.gz"
  local expected_sum
  local current_path
  local current_version
  local tmp_file

  current_path="${INSTALL_DIR}/${tool_name}"
  if [[ -x "${current_path}" ]]; then
    current_version="$("${current_path}" --version 2>/dev/null || true)"
    if [[ "${current_version}" == *"${version}"* ]]; then
      log "${tool_name} ${version} already present in ${INSTALL_DIR}; skipping."
      return 0
    fi
  fi

  expected_sum="$(expected_checksum "${archive_name}")"
  if [[ -z "${expected_sum}" ]]; then
    log "ERROR: missing checksum for ${archive_name} in ${CHECKSUM_FILE}"
    exit 1
  fi

  tmp_file="$(mktemp)"
  log "Downloading ${tool_name} ${version}..."
  curl -fsSL "$(archive_url "${tool_name}" "${version}")" -o "${tmp_file}"

  if [[ "$(sha256_file "${tmp_file}")" != "${expected_sum}" ]]; then
    rm -f "${tmp_file}"
    log "ERROR: checksum mismatch for ${tool_name} ${version}"
    exit 1
  fi

  tar -xzf "${tmp_file}" -C "${INSTALL_DIR}"
  rm -f "${tmp_file}"
  "${INSTALL_DIR}/${tool_name}" --version >/dev/null
}

case "${OS_NAME}:${MACHINE_ARCH}:${ARCHIVE_ARCH}" in
  Linux:x86_64:linux_amd64|Linux:amd64:linux_amd64)
    ;;
  *)
    log "ERROR: this bootstrap currently supports Linux x86_64/amd64 only."
    log "Set up the host prerequisites manually on ${OS_NAME}/${MACHINE_ARCH}, then rerun bootstrap."
    exit 1
    ;;
esac

need_cmd awk
need_cmd curl
need_cmd tar
need_cmd install

mkdir -p "${INSTALL_DIR}"

install_tool steampipe "${STEAMPIPE_VERSION}"
install_tool powerpipe "${POWERPIPE_VERSION}"
install_tool tailpipe "${TAILPIPE_VERSION}"

log "Installed pinned Turbot binaries into ${INSTALL_DIR}"
