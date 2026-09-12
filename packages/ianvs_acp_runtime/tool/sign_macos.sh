#!/bin/sh
set -eu

[ "$#" -eq 1 ] || { printf 'Usage: %s <dylib>\n' "$0" >&2; exit 2; }
LIBRARY=$1
[ -f "${LIBRARY}" ] || { printf 'error: library missing: %s\n' "${LIBRARY}" >&2; exit 1; }
if [ "${CODE_SIGNING_ALLOWED:-YES}" = NO ]; then exit 0; fi
CODESIGN_BIN=${IANVS_CODESIGN_BIN:-/usr/bin/codesign}
[ -x "${CODESIGN_BIN}" ] || {
  printf 'error: codesign tool is not executable: %s\n' "${CODESIGN_BIN}" >&2
  exit 1
}
SIGN_IDENTITY=${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}
if [ -z "${SIGN_IDENTITY}" ]; then SIGN_IDENTITY=-; fi
if [ "${SIGN_IDENTITY}" = - ]; then
  "${CODESIGN_BIN}" --force --sign - --timestamp=none "${LIBRARY}"
else
  "${CODESIGN_BIN}" --force --sign "${SIGN_IDENTITY}" \
    --options runtime --timestamp "${LIBRARY}"
fi
