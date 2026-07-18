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
cargo build --locked -p ianvs-acp-ffi ${CARGO_FLAGS}

SOURCE_LIBRARY="${RUST_WORKSPACE}/target/${PROFILE}/libianvs_acp_ffi.dylib"
FRAMEWORKS_DIRECTORY="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
DESTINATION_LIBRARY="${FRAMEWORKS_DIRECTORY}/libianvs_acp_ffi.dylib"

mkdir -p "${FRAMEWORKS_DIRECTORY}"
cp "${SOURCE_LIBRARY}" "${DESTINATION_LIBRARY}"
chmod 755 "${DESTINATION_LIBRARY}"
install_name_tool -id "@rpath/libianvs_acp_ffi.dylib" "${DESTINATION_LIBRARY}"
