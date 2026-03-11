#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Tool Versions to Pin
# -----------------------------------------------------------------------------
STEAMPIPE_VERSION="${STEAMPIPE_VERSION:-2.4.0}"
POWERPIPE_VERSION="${POWERPIPE_VERSION:-1.5.0}"
TAILPIPE_VERSION="${TAILPIPE_VERSION:-0.7.2}"
ARCH="${ARCH:-linux_amd64}"

# Output file for the Dockerfile to consume
SUMS_FILE="vendor/bin/tool_checksums.txt"

log() { printf "[\033[0;34mINFO\033[0m] %s\n" "$*"; }
error() { printf "[\033[0;31mERROR\033[0m] %s\n" "$*" >&2; exit 1; }

mkdir -p "vendor/bin"
: > "${SUMS_FILE}"

fetch_and_hash() {
  local name="$1"
  local version="$2"
  local url="$3"
  local tmp_file
  
  tmp_file="$(mktemp)"
  log "Fetching ${name} v${version}..."
  
  if ! curl -fsSL "${url}" -o "${tmp_file}"; then
    error "Failed to download ${name} from ${url}"
  fi
  
  local hash
  hash="$(sha256sum "${tmp_file}" | awk '{print $1}')"
  printf "%s  %s_v%s.tar.gz\n" "${hash}" "${name}" "${version}" >> "${SUMS_FILE}"
  log "Generated hash for ${name}: ${hash}"
  
  rm -f "${tmp_file}"
}

# Steampipe URL pattern
fetch_and_hash "steampipe" "${STEAMPIPE_VERSION}" \
  "https://github.com/turbot/steampipe/releases/download/v${STEAMPIPE_VERSION}/steampipe_${ARCH}.tar.gz"

# Powerpipe URL pattern (uses . instead of _ in some releases, normalizing here)
fetch_and_hash "powerpipe" "${POWERPIPE_VERSION}" \
  "https://github.com/turbot/powerpipe/releases/download/v${POWERPIPE_VERSION}/powerpipe.linux.amd64.tar.gz"

# Tailpipe URL pattern
fetch_and_hash "tailpipe" "${TAILPIPE_VERSION}" \
  "https://github.com/turbot/tailpipe/releases/download/v${TAILPIPE_VERSION}/tailpipe.linux.amd64.tar.gz"

log "Pinned checksums written to ${SUMS_FILE}"
cat "${SUMS_FILE}"
