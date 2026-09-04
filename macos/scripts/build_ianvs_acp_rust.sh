#!/bin/sh
set -eu

RUST_WORKSPACE="${SRCROOT}/../rust"
PROFILE="debug"
CARGO_FLAGS=""
if [ "${CONFIGURATION}" != "Debug" ]; then
  PROFILE="release"
  CARGO_FLAGS="--release"
fi

# Xcode puts Homebrew's standalone Rust ahead of rustup in PATH. The
# standalone toolchain only contains its host standard library, so universal
# release builds fail for x86_64 even when rustup has that target installed.
if command -v rustup >/dev/null 2>&1; then
  RUSTUP_CARGO=$(rustup which cargo)
  RUST_TOOLCHAIN_BIN=$(dirname "${RUSTUP_CARGO}")
  PATH="${RUST_TOOLCHAIN_BIN}:/usr/bin:${PATH}"
  export PATH
fi

cd "${RUST_WORKSPACE}"
FRAMEWORKS_DIRECTORY="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
DESTINATION_LIBRARY="${FRAMEWORKS_DIRECTORY}/libianvs_acp_ffi.dylib"

mkdir -p "${FRAMEWORKS_DIRECTORY}"
if [ "${PROFILE}" = "release" ]; then
  ARM_TARGET="aarch64-apple-darwin"
  X86_TARGET="x86_64-apple-darwin"
  cargo build --locked -p ianvs-acp-ffi \
    --release --target "${ARM_TARGET}"
  cargo build --locked -p ianvs-acp-ffi \
    --release --target "${X86_TARGET}"
  /usr/bin/lipo -create \
    "${RUST_WORKSPACE}/target/${ARM_TARGET}/release/libianvs_acp_ffi.dylib" \
    "${RUST_WORKSPACE}/target/${X86_TARGET}/release/libianvs_acp_ffi.dylib" \
    -output "${DESTINATION_LIBRARY}"
else
  cargo build --locked -p ianvs-acp-ffi ${CARGO_FLAGS}
  cp "${RUST_WORKSPACE}/target/${PROFILE}/libianvs_acp_ffi.dylib" \
    "${DESTINATION_LIBRARY}"
fi

chmod 755 "${DESTINATION_LIBRARY}"
install_name_tool -id "@rpath/libianvs_acp_ffi.dylib" "${DESTINATION_LIBRARY}"

if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
  CODESIGN_BIN=${IANVS_CODESIGN_BIN:-/usr/bin/codesign}
  [ -x "${CODESIGN_BIN}" ] || {
    printf 'error: codesign tool is not executable: %s\n' "${CODESIGN_BIN}" >&2
    exit 1
  }
  SIGN_IDENTITY=${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}
  if [ -z "${SIGN_IDENTITY}" ]; then
    SIGN_IDENTITY=-
  fi
  if [ "${SIGN_IDENTITY}" = "-" ]; then
    "${CODESIGN_BIN}" --force --sign - --timestamp=none \
      "${DESTINATION_LIBRARY}"
  else
    "${CODESIGN_BIN}" --force --sign "${SIGN_IDENTITY}" \
      --options runtime --timestamp \
      "${DESTINATION_LIBRARY}"
  fi
fi
