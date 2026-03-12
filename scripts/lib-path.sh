#!/usr/bin/env bash

repo_root_from_script() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

prepend_vendor_bin() {
  local root_dir="${1:-$(repo_root_from_script)}"
  local vendor_bin="${root_dir}/vendor/bin"

  if [[ -d "${vendor_bin}" ]]; then
    PATH="${vendor_bin}:${PATH}"
    export PATH
  fi
}
