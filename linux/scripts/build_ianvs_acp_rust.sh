#!/bin/sh
set -eu

BUILD_TYPE=$1
RUST_WORKSPACE=$2
RUST_TARGET_DIR=$3
BUNDLE_DIR=$4

case "${BUILD_TYPE}" in
  Debug)
    PROFILE=debug
    set -- build --locked
    ;;
  Profile|Release)
    PROFILE=release
    set -- build --locked --release
    ;;
  *)
    echo "unsupported CMake build type: ${BUILD_TYPE}" >&2
    exit 1
    ;;
esac

mkdir -p "${BUNDLE_DIR}"
CARGO_TARGET_DIR="${RUST_TARGET_DIR}" \
  cargo "$@" --manifest-path "${RUST_WORKSPACE}/Cargo.toml" \
    -p ianvs-acp-ffi -p ianvs-acpd
cp "${RUST_TARGET_DIR}/${PROFILE}/libianvs_acp_ffi.so" \
  "${BUNDLE_DIR}/libianvs_acp_ffi.so"
cp "${RUST_TARGET_DIR}/${PROFILE}/ianvs-acpd" \
  "${BUNDLE_DIR}/ianvs-acpd"
chmod 0755 "${BUNDLE_DIR}/ianvs-acpd"
