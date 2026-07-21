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
MACOS_DIRECTORY="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}"
DESTINATION_DAEMON="${MACOS_DIRECTORY}/ianvs-acpd"

mkdir -p "${FRAMEWORKS_DIRECTORY}" "${MACOS_DIRECTORY}"
if [ "${PROFILE}" = "release" ]; then
  ARM_TARGET="aarch64-apple-darwin"
  X86_TARGET="x86_64-apple-darwin"
  cargo build --locked -p ianvs-acp-ffi -p ianvs-acpd \
    --release --target "${ARM_TARGET}"
  cargo build --locked -p ianvs-acp-ffi -p ianvs-acpd \
    --release --target "${X86_TARGET}"
  /usr/bin/lipo -create \
    "${RUST_WORKSPACE}/target/${ARM_TARGET}/release/libianvs_acp_ffi.dylib" \
    "${RUST_WORKSPACE}/target/${X86_TARGET}/release/libianvs_acp_ffi.dylib" \
    -output "${DESTINATION_LIBRARY}"
  /usr/bin/lipo -create \
    "${RUST_WORKSPACE}/target/${ARM_TARGET}/release/ianvs-acpd" \
    "${RUST_WORKSPACE}/target/${X86_TARGET}/release/ianvs-acpd" \
    -output "${DESTINATION_DAEMON}"
else
  cargo build --locked -p ianvs-acp-ffi -p ianvs-acpd ${CARGO_FLAGS}
  cp "${RUST_WORKSPACE}/target/${PROFILE}/libianvs_acp_ffi.dylib" \
    "${DESTINATION_LIBRARY}"
  cp "${RUST_WORKSPACE}/target/${PROFILE}/ianvs-acpd" \
    "${DESTINATION_DAEMON}"
fi

chmod 755 "${DESTINATION_LIBRARY}"
install_name_tool -id "@rpath/libianvs_acp_ffi.dylib" "${DESTINATION_LIBRARY}"
chmod 755 "${DESTINATION_DAEMON}"
