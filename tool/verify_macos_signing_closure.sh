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
        'usage: verify_macos_signing_closure.sh [--distribution] /path/to/App.app' >&2
      exit 64
    }
    distribution=1
    app=$2
    ;;
  *)
    printf '%s\n' \
      'usage: verify_macos_signing_closure.sh [--distribution] /path/to/App.app' >&2
    exit 64
    ;;
esac

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

[ -d "${app}" ] || fail "app bundle does not exist: ${app}"
codesign_bin=${IANVS_CODESIGN_BIN:-/usr/bin/codesign}
[ -x "${codesign_bin}" ] || fail "codesign tool is not executable: ${codesign_bin}"

candidate_list=$(mktemp "${TMPDIR:-/tmp}/ianvs-acp-signing-candidates.XXXXXX")
app_signing_info=$(mktemp "${TMPDIR:-/tmp}/ianvs-acp-app-signing.XXXXXX")
nested_signing_info=$(mktemp "${TMPDIR:-/tmp}/ianvs-acp-nested-signing.XXXXXX")
cleanup() {
  rm -f -- "${candidate_list}" "${app_signing_info}" "${nested_signing_info}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"${codesign_bin}" --verify --deep --strict --verbose=2 "${app}"
"${codesign_bin}" --display --verbose=4 "${app}" 2>"${app_signing_info}"

app_is_adhoc=0
if /usr/bin/grep -q '^Signature=adhoc$' "${app_signing_info}"; then
  app_is_adhoc=1
  [ "${distribution}" -eq 0 ] \
    || fail 'distribution bundle must not use an ad-hoc signature'
  if /usr/bin/grep -Eq '^CodeDirectory .*flags=.*runtime' "${app_signing_info}"; then
    fail 'ad-hoc app must not enable Hardened Runtime without a signing team'
  fi
  app_team='not set'
else
  /usr/bin/grep -Eq '^CodeDirectory .*flags=.*runtime' "${app_signing_info}" \
    || fail 'non-ad-hoc app signature does not enable Hardened Runtime'
  app_team=$(/usr/bin/awk -F= '/^TeamIdentifier=/ {print $2; exit}' "${app_signing_info}")
  [ -n "${app_team}" ] && [ "${app_team}" != 'not set' ] \
    || fail 'non-ad-hoc app signature does not contain a signing team'
fi

if [ "${distribution}" -eq 1 ]; then
  /usr/bin/grep -q '^Authority=Developer ID Application:' "${app_signing_info}" \
    || fail 'distribution bundle is not signed with Developer ID Application'
  app_timestamp=$(/usr/bin/awk -F= '/^Timestamp=/ {print $2; exit}' "${app_signing_info}")
  [ -n "${app_timestamp}" ] && [ "${app_timestamp}" != 'none' ] \
    || fail 'distribution bundle does not contain a secure timestamp'
fi

/usr/bin/find "${app}/Contents" -type f -print0 >"${candidate_list}"
mach_o_count=0
while IFS= read -r -d '' binary; do
  if ! /usr/bin/file "${binary}" | /usr/bin/grep -q 'Mach-O'; then
    continue
  fi
  mach_o_count=$((mach_o_count + 1))
  "${codesign_bin}" --verify --strict --verbose=2 "${binary}" \
    || fail "invalid nested Mach-O signature: ${binary}"
  "${codesign_bin}" --display --verbose=4 "${binary}" 2>"${nested_signing_info}"

  if [ "${app_is_adhoc}" -eq 1 ]; then
    /usr/bin/grep -q '^Signature=adhoc$' "${nested_signing_info}" \
      || fail "ad-hoc app contains a non-ad-hoc Mach-O: ${binary}"
    if /usr/bin/grep -Eq '^CodeDirectory .*flags=.*runtime' "${nested_signing_info}"; then
      fail "ad-hoc app contains a Hardened Runtime Mach-O: ${binary}"
    fi
    nested_team=$(/usr/bin/awk -F= '/^TeamIdentifier=/ {print $2; exit}' \
      "${nested_signing_info}")
    [ "${nested_team}" = 'not set' ] \
      || fail "ad-hoc app contains a team-signed Mach-O: ${binary}"
  else
    ! /usr/bin/grep -q '^Signature=adhoc$' "${nested_signing_info}" \
      || fail "signed app contains an ad-hoc Mach-O: ${binary}"
    /usr/bin/grep -Eq '^CodeDirectory .*flags=.*runtime' "${nested_signing_info}" \
      || fail "signed app contains a Mach-O without Hardened Runtime: ${binary}"
    nested_team=$(/usr/bin/awk -F= '/^TeamIdentifier=/ {print $2; exit}' \
      "${nested_signing_info}")
    [ "${nested_team}" = "${app_team}" ] \
      || fail "app and nested Mach-O have different signing teams: ${binary}"
  fi

  if [ "${distribution}" -eq 1 ]; then
    /usr/bin/grep -q '^Authority=Developer ID Application:' "${nested_signing_info}" \
      || fail "distribution Mach-O is not signed with Developer ID Application: ${binary}"
    nested_timestamp=$(/usr/bin/awk -F= '/^Timestamp=/ {print $2; exit}' \
      "${nested_signing_info}")
    [ -n "${nested_timestamp}" ] && [ "${nested_timestamp}" != 'none' ] \
      || fail "distribution Mach-O does not contain a secure timestamp: ${binary}"
  fi
done <"${candidate_list}"

[ "${mach_o_count}" -gt 0 ] || fail 'app bundle contains no Mach-O files'
printf '%s\n' 'macOS signing closure verification passed'
