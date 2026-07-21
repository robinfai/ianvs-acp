#!/bin/sh
set -euf

MERMAN_NAME=libmerman_ffi.dylib
MERMAN_ID="@rpath/${MERMAN_NAME}"
candidate_list=
dependency_list=

cleanup() {
  if [ -n "${candidate_list}" ]; then
    rm -f -- "${candidate_list}"
  fi
  if [ -n "${dependency_list}" ]; then
    rm -f -- "${dependency_list}"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

normalize_binary() {
  binary=$1
  [ -f "${binary}" ] || fail "missing Mach-O candidate: ${binary}"
  if ! /usr/bin/file "${binary}" | /usr/bin/grep -q 'Mach-O'; then
    return 0
  fi

  /usr/bin/otool -L "${binary}" \
    | /usr/bin/awk '/^[[:space:]]/ && /libmerman_ffi[.]dylib/ {print $1}' \
    | /usr/bin/sort -u \
    >"${dependency_list}"
  while IFS= read -r dependency; do
    if [ -n "${dependency}" ] && [ "${dependency}" != "${MERMAN_ID}" ]; then
      /usr/bin/install_name_tool \
        -change "${dependency}" "${MERMAN_ID}" "${binary}"
    fi
  done <"${dependency_list}"
}

if [ "${PRODUCT_TYPE:-}" = "com.apple.product-type.bundle.unit-test" ]; then
  test_binary="${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}/${EXECUTABLE_PATH:?EXECUTABLE_PATH is required}"
  temp_root=${TEMP_FILES_DIR:-${TMPDIR:-/tmp}}
  dependency_list=$(mktemp "${temp_root%/}/merman_dependencies.XXXXXX")
  normalize_binary "${test_binary}"
  exit 0
fi

app_contents="${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}/${CONTENTS_FOLDER_PATH:?CONTENTS_FOLDER_PATH is required}"
[ -d "${app_contents}" ] || fail "missing app contents: ${app_contents}"

merman_lib="${app_contents}/Frameworks/${MERMAN_NAME}"
merman_framework="${app_contents}/Frameworks/merman.framework"
[ -f "${merman_lib}" ] || fail "missing merman library: ${merman_lib}"
[ -d "${merman_framework}" ] || fail "missing merman framework: ${merman_framework}"

temp_root=${TEMP_FILES_DIR:-${TMPDIR:-/tmp}}
candidate_list=$(mktemp "${temp_root%/}/merman_candidates.XXXXXX")
dependency_list=$(mktemp "${temp_root%/}/merman_dependencies.XXXXXX")

/usr/bin/install_name_tool -id "${MERMAN_ID}" "${merman_lib}"

/usr/bin/find "${app_contents}" -type f \
  \( -path '*/MacOS/*' -o -path '*/Frameworks/*' \) -print0 \
  >"${candidate_list}"
while IFS= read -r -d '' binary; do
  normalize_binary "${binary}"
done <"${candidate_list}"

if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
  exit 0
fi

sign_identity=${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}
if [ -z "${sign_identity}" ]; then
  sign_identity=-
fi

if [ "${sign_identity}" = "-" ]; then
  /usr/bin/codesign --force --sign - --timestamp=none \
    --preserve-metadata=identifier,entitlements,flags "${merman_lib}"
  /usr/bin/codesign --force --sign - --timestamp=none \
    --preserve-metadata=identifier,entitlements,flags "${merman_framework}"
else
  /usr/bin/codesign --force --sign "${sign_identity}" \
    --preserve-metadata=identifier,entitlements,flags "${merman_lib}"
  /usr/bin/codesign --force --sign "${sign_identity}" \
    --preserve-metadata=identifier,entitlements,flags "${merman_framework}"
fi
