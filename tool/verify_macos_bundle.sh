#!/bin/sh
set -euf

distribution=0
case "$#" in
  1)
    app=$1
    ;;
  2)
    [ "$1" = '--distribution' ] || {
      printf '%s\n' \
        'usage: verify_macos_bundle.sh [--distribution] /path/to/App.app' >&2
      exit 64
    }
    distribution=1
    app=$2
    ;;
  *)
    printf '%s\n' \
      'usage: verify_macos_bundle.sh [--distribution] /path/to/App.app' >&2
    exit 64
    ;;
esac

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

[ -d "${app}" ] || fail "app bundle does not exist: ${app}"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
signing_verifier="${script_dir}/verify_macos_signing_closure.sh"
[ -x "${signing_verifier}" ] \
  || fail "missing macOS signing closure verifier: ${signing_verifier}"
info_plist="${app}/Contents/Info.plist"
executable="${app}/Contents/MacOS/ACP Client"
rust_runtime="${app}/Contents/Frameworks/libianvs_acp_ffi.dylib"
merman_lib="${app}/Contents/Frameworks/libmerman_ffi.dylib"
merman_framework_binary="${app}/Contents/Frameworks/merman.framework/Versions/A/merman"

[ -f "${info_plist}" ] || fail "missing Info.plist"
[ -f "${executable}" ] || fail "missing app executable"
[ -f "${rust_runtime}" ] || fail "missing ianvs ACP Rust runtime"
[ -f "${merman_lib}" ] || fail "missing merman library"
[ -f "${merman_framework_binary}" ] || fail "missing merman framework binary"

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${info_plist}")
[ "${bundle_id}" = 'com.ianvs.acp' ] \
  || fail "unexpected bundle identifier: ${bundle_id}"

url_types=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' "${info_plist}")
printf '%s\n' "${url_types}" \
  | /usr/bin/grep -Eq '^[[:space:]]*ianvs-acp[[:space:]]*$' \
  || fail 'missing ianvs-acp URL scheme'

for binary in \
  "${executable}" "${rust_runtime}" \
  "${merman_lib}" "${merman_framework_binary}"; do
  /usr/bin/lipo "${binary}" -verify_arch arm64 x86_64 \
    || fail "binary is not universal: ${binary}"
done

merman_id=$(/usr/bin/otool -D "${merman_lib}" | /usr/bin/awk 'NR == 2 {print; exit}')
[ "${merman_id}" = '@rpath/libmerman_ffi.dylib' ] \
  || fail "unexpected merman install name: ${merman_id}"
rust_runtime_id=$(/usr/bin/otool -D "${rust_runtime}" | /usr/bin/awk 'NR == 2 {print; exit}')
[ "${rust_runtime_id}" = '@rpath/libianvs_acp_ffi.dylib' ] \
  || fail "unexpected ianvs ACP runtime install name: ${rust_runtime_id}"

candidate_list=$(mktemp "${TMPDIR:-/tmp}/ianvs-acp-verify-candidates.XXXXXX")
dependency_list=$(mktemp "${TMPDIR:-/tmp}/ianvs-acp-verify-dependencies.XXXXXX")
expected_rust_symbols=$(mktemp "${TMPDIR:-/tmp}/ianvs-acp-verify-expected-symbols.XXXXXX")
actual_rust_symbols=$(mktemp "${TMPDIR:-/tmp}/ianvs-acp-verify-actual-symbols.XXXXXX")
cleanup() {
  rm -f -- \
    "${candidate_list}" "${dependency_list}" \
    "${expected_rust_symbols}" "${actual_rust_symbols}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

merman_reference_found=0
/usr/bin/find "${app}/Contents" -type f -print0 >"${candidate_list}"
while IFS= read -r -d '' binary; do
  if ! /usr/bin/file "${binary}" | /usr/bin/grep -q 'Mach-O'; then
    continue
  fi
  /usr/bin/otool -L "${binary}" \
    | /usr/bin/awk '/^[[:space:]]/ && /libmerman_ffi[.]dylib/ {print $1}' \
    | /usr/bin/sort -u \
    >"${dependency_list}"
  while IFS= read -r dependency; do
    [ -n "${dependency}" ] || continue
    if [ "${dependency}" != '@rpath/libmerman_ffi.dylib' ]; then
      fail "non-relocatable merman dependency in ${binary}: ${dependency}"
    fi
    merman_reference_found=1
  done <"${dependency_list}"
done <"${candidate_list}"
[ "${merman_reference_found}" -eq 1 ] \
  || fail 'no Mach-O references @rpath/libmerman_ffi.dylib'

# The Dart host eagerly resolves this complete product ABI when it opens the
# library. Validate the exact exported surface so a mixed incremental bundle
# cannot pass architecture/signature checks but fail at launch, and so removed
# product APIs cannot accidentally remain distributable.
LC_ALL=C /usr/bin/sort >"${expected_rust_symbols}" <<'EOF'
_ianvs_acp_authenticate
_ianvs_acp_cancel
_ianvs_acp_close_session
_ianvs_acp_create_session
_ianvs_acp_delete_session
_ianvs_acp_dispose
_ianvs_acp_ffi_version
_ianvs_acp_last_error
_ianvs_acp_list_sessions
_ianvs_acp_logout
_ianvs_acp_poll_events
_ianvs_acp_prompt
_ianvs_acp_prompt_with_attachments
_ianvs_acp_respond_permission
_ianvs_acp_restore_session
_ianvs_acp_runtime_free
_ianvs_acp_runtime_new
_ianvs_acp_set_config_option
_ianvs_acp_set_mode
_ianvs_acp_start_agent
_ianvs_acp_string_free
EOF
/usr/bin/nm -gUj "${rust_runtime}" \
  | LC_ALL=C /usr/bin/sort -u >"${actual_rust_symbols}"
if ! /usr/bin/cmp -s "${expected_rust_symbols}" "${actual_rust_symbols}"; then
  /usr/bin/diff -u "${expected_rust_symbols}" "${actual_rust_symbols}" >&2 || true
  fail 'ianvs ACP runtime exports do not match the current host ABI'
fi

if [ "${distribution}" -eq 1 ]; then
  "${signing_verifier}" --distribution "${app}"
else
  "${signing_verifier}" "${app}"
fi

printf '%s\n' 'macOS bundle verification passed'
