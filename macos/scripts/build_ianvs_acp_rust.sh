#!/bin/sh
set -eu

RUST_WORKSPACE="${SRCROOT}/../rust"
MEMORY_WORKSPACE="${SRCROOT}/../memory-core"
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
RESOURCES_DIRECTORY="${MACOS_DIRECTORY}/../Resources"
DESTINATION_MEMORY_CORE="${RESOURCES_DIRECTORY}/memory-core"

mkdir -p "${FRAMEWORKS_DIRECTORY}" "${MACOS_DIRECTORY}" "${RESOURCES_DIRECTORY}"
# Replacing an already-executed Mach-O in place can leave macOS' code-signing
# cache associated with the old vnode. Remove executable destinations before
# staging freshly built binaries so repeated Debug builds remain launchable.
rm -f "${DESTINATION_DAEMON}" "${DESTINATION_MEMORY_CORE}"
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
  cd "${MEMORY_WORKSPACE}"
  cargo build --locked --release --target "${ARM_TARGET}"
  cargo build --locked --release --target "${X86_TARGET}"
  /usr/bin/lipo -create \
    "${MEMORY_WORKSPACE}/target/${ARM_TARGET}/release/memory-core" \
    "${MEMORY_WORKSPACE}/target/${X86_TARGET}/release/memory-core" \
    -output "${DESTINATION_MEMORY_CORE}"
else
  cargo build --locked -p ianvs-acp-ffi -p ianvs-acpd ${CARGO_FLAGS}
  cp "${RUST_WORKSPACE}/target/${PROFILE}/libianvs_acp_ffi.dylib" \
    "${DESTINATION_LIBRARY}"
  cp "${RUST_WORKSPACE}/target/${PROFILE}/ianvs-acpd" \
    "${DESTINATION_DAEMON}"
  cd "${MEMORY_WORKSPACE}"
  cargo build --locked
  cp "${MEMORY_WORKSPACE}/target/${PROFILE}/memory-core" \
    "${DESTINATION_MEMORY_CORE}"
fi

chmod 755 "${DESTINATION_LIBRARY}"
install_name_tool -id "@rpath/libianvs_acp_ffi.dylib" "${DESTINATION_LIBRARY}"
chmod 755 "${DESTINATION_DAEMON}"
chmod 755 "${DESTINATION_MEMORY_CORE}"

if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
  SIGN_IDENTITY=${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}
  if [ -z "${SIGN_IDENTITY}" ]; then
    SIGN_IDENTITY=-
  fi
  if [ "${SIGN_IDENTITY}" = "-" ]; then
    /usr/bin/codesign --force --sign - --timestamp=none \
      --preserve-metadata=identifier,entitlements,flags \
      "${DESTINATION_DAEMON}"
    /usr/bin/codesign --force --sign - --timestamp=none \
      --preserve-metadata=identifier,entitlements,flags \
      "${DESTINATION_MEMORY_CORE}"
  else
    /usr/bin/codesign --force --sign "${SIGN_IDENTITY}" \
      --preserve-metadata=identifier,entitlements,flags \
      "${DESTINATION_DAEMON}"
    /usr/bin/codesign --force --sign "${SIGN_IDENTITY}" \
      --preserve-metadata=identifier,entitlements,flags \
      "${DESTINATION_MEMORY_CORE}"
  fi
fi

# Catch a staged daemon that passed the build but cannot be executed because
# of a stale or invalid code signature.
"${DESTINATION_DAEMON}" --help >/dev/null
