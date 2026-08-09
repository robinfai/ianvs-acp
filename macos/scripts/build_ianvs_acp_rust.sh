#!/bin/sh
set -eu

RUST_WORKSPACE="${SRCROOT}/../rust"
PROFILE="debug"
CARGO_FLAGS=""
if [ "${CONFIGURATION}" != "Debug" ]; then
  PROFILE="release"
  CARGO_FLAGS="--release"
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
