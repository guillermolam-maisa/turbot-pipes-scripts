#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib-path.sh
source "${ROOT_DIR}/scripts/lib-path.sh"
prepend_vendor_bin "${ROOT_DIR}"

log() { printf '%s\n' "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "ERROR: missing command: $1"
    exit 1
  }
}

steampipe_plugin_installed() {
  steampipe plugin list 2>/dev/null | awk '$1 == "aws" || $2 == "aws" { found = 1 } END { exit(found ? 0 : 1) }'
}

tailpipe_plugin_installed() {
  tailpipe plugin list 2>/dev/null | awk '$1 == "aws" || $2 == "aws" { found = 1 } END { exit(found ? 0 : 1) }'
}

powerpipe_mods_installed() {
  (
    cd "${ROOT_DIR}/powerpipe" || exit 1
    powerpipe mod list 2>/dev/null | grep -q 'github.com/turbot/'
  )
}

log "[1/6] Installing pinned Turbot binaries into vendor/bin..."
bash "${ROOT_DIR}/scripts/install-host-deps.sh"
prepend_vendor_bin "${ROOT_DIR}"

need_cmd steampipe
need_cmd powerpipe
need_cmd tailpipe

log "[2/6] Ensuring Steampipe AWS plugin is installed on the host..."
if steampipe_plugin_installed; then
  log "Steampipe AWS plugin already installed; skipping."
else
  steampipe plugin install aws >/tmp/turbot-bootstrap-steampipe-plugin.log 2>&1
fi

log "[3/6] Ensuring Powerpipe mods are installed in the local workspace..."
if powerpipe_mods_installed; then
  log "Powerpipe mods already installed; skipping."
else
  (
    cd "${ROOT_DIR}/powerpipe" || exit 1
    powerpipe mod install >/tmp/turbot-bootstrap-powerpipe-mods.log 2>&1
  )
fi

log "[4/6] Ensuring Tailpipe AWS plugin is installed on the host..."
if tailpipe_plugin_installed; then
  log "Tailpipe AWS plugin already installed; skipping."
else
  tailpipe plugin install aws >/tmp/turbot-bootstrap-tailpipe-plugin.log 2>&1
fi

log "[5/6] Vendoring local binaries and Steampipe plugin seed..."
bash "${ROOT_DIR}/scripts/vendor-local-binaries.sh"

log "[6/6] Validating workspace wiring..."
bash "${ROOT_DIR}/scripts/validate-workspace.sh"

printf '\nBootstrap completed.\n'
printf 'Vendored tools: %s\n' "${ROOT_DIR}/vendor/bin"
