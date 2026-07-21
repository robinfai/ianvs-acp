#!/bin/sh
set -euf

if [ "$#" -ne 2 ]; then
  printf '%s\n' 'usage: sign_macos_bundle.sh /path/to/App.app developer-id' >&2
  exit 64
fi

app=$1
identity=$2

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

[ -d "${app}" ] || fail "app bundle does not exist: ${app}"
[ -n "${identity}" ] || fail 'Developer ID identity is required'
[ "${identity}" != '-' ] || fail 'ad-hoc signing is not allowed for distribution'

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "${script_dir}/.." && pwd)
entitlements="${project_root}/macos/Runner/Release.entitlements"
[ -f "${entitlements}" ] || fail "missing release entitlements: ${entitlements}"
codesign_bin=${IANVS_CODESIGN_BIN:-/usr/bin/codesign}
[ -x "${codesign_bin}" ] || fail "codesign tool is not executable: ${codesign_bin}"

mach_o_list=$(mktemp "${TMPDIR:-/tmp}/ianvs-acp-sign-mach-o.XXXXXX")
bundle_list=$(mktemp "${TMPDIR:-/tmp}/ianvs-acp-sign-bundles.XXXXXX")
cleanup() {
  rm -f -- "${mach_o_list}" "${bundle_list}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sign_nested_item() {
  item=$1
  "${codesign_bin}" --force --sign "${identity}" \
    --options runtime --timestamp \
    --preserve-metadata=identifier,entitlements "${item}"
}

sign_nested_root() {
  root=$1
  [ -d "${root}" ] || return 0

  /usr/bin/find "${root}" -depth -type f -print0 >"${mach_o_list}"
  while IFS= read -r -d '' candidate; do
    if /usr/bin/file "${candidate}" | /usr/bin/grep -q 'Mach-O'; then
      sign_nested_item "${candidate}"
    fi
  done <"${mach_o_list}"

  /usr/bin/find "${root}" -depth -type d \
    \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' \
    -o -name '*.appex' -o -name '*.bundle' \) -print0 >"${bundle_list}"
  while IFS= read -r -d '' bundle; do
    sign_nested_item "${bundle}"
  done <"${bundle_list}"
}

sign_nested_root "${app}/Contents/Frameworks"
sign_nested_root "${app}/Contents/MacOS"
sign_nested_root "${app}/Contents/PlugIns"
sign_nested_root "${app}/Contents/XPCServices"
sign_nested_root "${app}/Contents/Helpers"
sign_nested_root "${app}/Contents/Library/LoginItems"

"${codesign_bin}" --force --sign "${identity}" \
  --options runtime --timestamp --entitlements "${entitlements}" "${app}"
