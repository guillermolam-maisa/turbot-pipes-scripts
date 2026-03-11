#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${WORKDIR}/vendor/bin"
STEAMPIPE_PLUGIN_SOURCE_ROOT="${HOME}/.steampipe/plugins"
STEAMPIPE_PLUGIN_VENDOR_ROOT="${WORKDIR}/vendor/steampipe-plugins"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing command: $1" >&2
    exit 1
  }
}

copy_binary() {
  local name="$1"
  local source_path
  local current_version
  local manifest_path="${VENDOR_DIR}/${name}.manifest"
  local target_path="${VENDOR_DIR}/${name}"
  source_path="$(command -v "${name}")"
  current_version="$("${source_path}" --version)"

  if [[ -x "${target_path}" && -f "${manifest_path}" ]] && [[ "$(cat "${manifest_path}")" == "${current_version}" ]]; then
    printf 'Vendored %s already matches installed version; skipping copy.\n' "${name}"
    return 0
  fi

  if ! install -m 0755 "${source_path}" "${target_path}"; then
    echo "ERROR: failed to copy ${name} into ${VENDOR_DIR}" >&2
    exit 1
  fi

  if ! printf '%s\n' "${current_version}" > "${manifest_path}"; then
    echo "ERROR: failed to write ${name} manifest" >&2
    exit 1
  fi
}

sync_steampipe_plugin_seed() {
  local source_plugin_dir="${STEAMPIPE_PLUGIN_SOURCE_ROOT}/hub.steampipe.io/plugins/turbot/aws@latest"
  local source_versions_file="${STEAMPIPE_PLUGIN_SOURCE_ROOT}/versions.json"
  local version_file="${source_plugin_dir}/version.json"
  local vendored_manifest="${STEAMPIPE_PLUGIN_VENDOR_ROOT}/aws-plugin.manifest"
  local vendored_latest_dir="${STEAMPIPE_PLUGIN_VENDOR_ROOT}/hub.steampipe.io/plugins/turbot/aws@latest"
  local versioned_name
  local vendored_versioned_dir
  local installed_from
  local image_digest
  local binary_digest

  if [[ ! -d "${source_plugin_dir}" || ! -f "${version_file}" || ! -f "${source_versions_file}" ]]; then
    if [[ -d "${vendored_latest_dir}" && -f "${vendored_manifest}" ]]; then
      printf 'Vendored Steampipe AWS plugin seed already present; skipping host sync.\n'
      return 0
    fi

    echo "ERROR: host Steampipe AWS plugin seed not found under ${source_plugin_dir}" >&2
    exit 1
  fi

  versioned_name="$(sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "${version_file}" | head -n 1)"
  installed_from="$(sed -n 's/.*"installed_from":[[:space:]]*"\([^"]*\)".*/\1/p' "${version_file}" | head -n 1)"
  image_digest="$(sed -n 's/.*"image_digest":[[:space:]]*"\([^"]*\)".*/\1/p' "${version_file}" | head -n 1)"
  binary_digest="$(sed -n 's/.*"binary_digest":[[:space:]]*"\([^"]*\)".*/\1/p' "${version_file}" | head -n 1)"

  if [[ -z "${versioned_name}" ]]; then
    echo "ERROR: failed to parse Steampipe AWS plugin version from ${version_file}" >&2
    exit 1
  fi

  vendored_versioned_dir="${STEAMPIPE_PLUGIN_VENDOR_ROOT}/hub.steampipe.io/plugins/turbot/aws@${versioned_name}"

  rm -rf "${STEAMPIPE_PLUGIN_VENDOR_ROOT}"
  mkdir -p "$(dirname "${vendored_latest_dir}")"
  cp -a "${source_plugin_dir}" "${vendored_latest_dir}"
  cp -a "${source_plugin_dir}" "${vendored_versioned_dir}"
  cp -a "${source_versions_file}" "${STEAMPIPE_PLUGIN_VENDOR_ROOT}/versions.json"

  cat > "${vendored_manifest}" <<EOF
version=${versioned_name}
installed_from=${installed_from}
image_digest=${image_digest}
binary_digest=${binary_digest}
EOF
}

need_cmd install
need_cmd steampipe
need_cmd powerpipe
need_cmd tailpipe

mkdir -p "${VENDOR_DIR}"

copy_binary steampipe
copy_binary powerpipe
copy_binary tailpipe
sync_steampipe_plugin_seed

printf 'Vendored binaries in %s\n' "${VENDOR_DIR}"
