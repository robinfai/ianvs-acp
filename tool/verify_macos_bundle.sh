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
info_plist="${app}/Contents/Info.plist"
executable="${app}/Contents/MacOS/ACP Client"
merman_lib="${app}/Contents/Frameworks/libmerman_ffi.dylib"
merman_framework_binary="${app}/Contents/Frameworks/merman.framework/Versions/A/merman"

[ -f "${info_plist}" ] || fail "missing Info.plist"
[ -f "${executable}" ] || fail "missing app executable"
[ -f "${merman_lib}" ] || fail "missing merman library"
[ -f "${merman_framework_binary}" ] || fail "missing merman framework binary"

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${info_plist}")
[ "${bundle_id}" = 'com.ianvs.acp' ] \
  || fail "unexpected bundle identifier: ${bundle_id}"

url_types=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' "${info_plist}")
printf '%s\n' "${url_types}" \
  | /usr/bin/grep -Eq '^[[:space:]]*ianvs-acp[[:space:]]*$' \
  || fail 'missing ianvs-acp URL scheme'

for binary in "${executable}" "${merman_lib}" "${merman_framework_binary}"; do
  /usr/bin/lipo "${binary}" -verify_arch arm64 x86_64 \
    || fail "binary is not universal: ${binary}"
done

merman_id=$(/usr/bin/otool -D "${merman_lib}" | /usr/bin/awk 'NR == 2 {print; exit}')
[ "${merman_id}" = '@rpath/libmerman_ffi.dylib' ] \
  || fail "unexpected merman install name: ${merman_id}"

candidate_list=$(mktemp "${TMPDIR:-/tmp}/ianvs-acp-verify-candidates.XXXXXX")
dependency_list=$(mktemp "${TMPDIR:-/tmp}/ianvs-acp-verify-dependencies.XXXXXX")
signing_info=$(mktemp "${TMPDIR:-/tmp}/ianvs-acp-verify-signing.XXXXXX")
cleanup() {
  rm -f -- "${candidate_list}" "${dependency_list}" "${signing_info}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

merman_reference_found=0
/usr/bin/find "${app}/Contents" -type f \
  \( -path '*/MacOS/*' -o -path '*/Frameworks/*' \) -print0 \
  >"${candidate_list}"
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

/usr/bin/codesign --verify --deep --strict --verbose=2 "${app}"
/usr/bin/codesign --display --verbose=4 "${app}" 2>"${signing_info}"
if /usr/bin/grep -q '^Signature=adhoc$' "${signing_info}"; then
  [ "${distribution}" -eq 0 ] \
    || fail 'distribution bundle must not use an ad-hoc signature'
else
  /usr/bin/grep -Eq '^flags=.*\(.*runtime.*\)' "${signing_info}" \
    || fail 'non-ad-hoc app signature does not enable Hardened Runtime'
fi

if [ "${distribution}" -eq 1 ]; then
  /usr/bin/grep -q '^Authority=Developer ID Application:' "${signing_info}" \
    || fail 'distribution bundle is not signed with Developer ID Application'
  timestamp=$(/usr/bin/awk '
    /^Timestamp=/ {
      sub(/^Timestamp=/, "")
      print
      exit
    }
  ' "${signing_info}")
  [ -n "${timestamp}" ] && [ "${timestamp}" != 'none' ] \
    || fail 'distribution bundle does not contain a secure timestamp'
fi

printf '%s\n' 'macOS bundle verification passed'
