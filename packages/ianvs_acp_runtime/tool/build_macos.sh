#!/bin/sh
# Build and embed ABI v11 from this package, regardless of the consumer's cwd.
set -eu

PACKAGE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
RUST_WORKSPACE="${PACKAGE_ROOT}/rust"
PROFILE=debug
if [ "${CONFIGURATION:-Debug}" != Debug ]; then PROFILE=release; fi

# Prefer rustup's cross-target toolchain over Homebrew's host-only Rust.
if command -v rustup >/dev/null 2>&1; then
  RUSTUP_CARGO=$(rustup which cargo)
  RUST_TOOLCHAIN_BIN=$(dirname "${RUSTUP_CARGO}")
  PATH="${RUST_TOOLCHAIN_BIN}:/usr/bin:${PATH}"
  export PATH
fi

FRAMEWORKS_DIRECTORY=${IANVS_ACP_FRAMEWORKS_DIR:-}
if [ -z "${FRAMEWORKS_DIRECTORY}" ]; then
  : "${TARGET_BUILD_DIR:?Set TARGET_BUILD_DIR or IANVS_ACP_FRAMEWORKS_DIR}"
  : "${FRAMEWORKS_FOLDER_PATH:?Set FRAMEWORKS_FOLDER_PATH or IANVS_ACP_FRAMEWORKS_DIR}"
  FRAMEWORKS_DIRECTORY="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
fi
mkdir -p "${FRAMEWORKS_DIRECTORY}"
FRAMEWORKS_DIRECTORY=$(CDPATH= cd -- "${FRAMEWORKS_DIRECTORY}" && pwd -P)
DESTINATION_LIBRARY="${FRAMEWORKS_DIRECTORY}/libianvs_acp_ffi.dylib"

if [ -n "${IANVS_ACP_ARCHS:-}" ]; then
  BUILD_ARCHS=${IANVS_ACP_ARCHS}
elif [ "${PROFILE}" = release ]; then
  BUILD_ARCHS='arm64 x86_64'
else
  BUILD_ARCHS=${ARCHS:-$(uname -m)}
fi

# Resolve relative Cargo output paths before changing directory.
CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-${RUST_WORKSPACE}/target}
mkdir -p "${CARGO_TARGET_DIR}"
CARGO_TARGET_DIR=$(CDPATH= cd -- "${CARGO_TARGET_DIR}" && pwd -P)
export CARGO_TARGET_DIR
cd "${RUST_WORKSPACE}"

set --
for ARCH in ${BUILD_ARCHS}; do
  case "${ARCH}" in
    arm64) RUST_TARGET=aarch64-apple-darwin ;;
    x86_64) RUST_TARGET=x86_64-apple-darwin ;;
    *) printf 'error: unsupported macOS architecture: %s\n' "${ARCH}" >&2; exit 1 ;;
  esac
  if [ "${PROFILE}" = release ]; then
    cargo build --locked -p ianvs-acp-ffi --release --target "${RUST_TARGET}"
  else
    cargo build --locked -p ianvs-acp-ffi --target "${RUST_TARGET}"
  fi
  set -- "$@" "${CARGO_TARGET_DIR}/${RUST_TARGET}/${PROFILE}/libianvs_acp_ffi.dylib"
done
[ "$#" -gt 0 ] || { printf 'error: no build architectures\n' >&2; exit 1; }
if [ "$#" -eq 1 ]; then
  cp "$1" "${DESTINATION_LIBRARY}"
else
  /usr/bin/lipo -create "$@" -output "${DESTINATION_LIBRARY}"
fi
chmod 755 "${DESTINATION_LIBRARY}"
install_name_tool -id '@rpath/libianvs_acp_ffi.dylib' "${DESTINATION_LIBRARY}"
"${PACKAGE_ROOT}/tool/sign_macos.sh" "${DESTINATION_LIBRARY}"
printf 'Built %s (%s: %s)\n' "${DESTINATION_LIBRARY}" "${PROFILE}" "${BUILD_ARCHS}"
