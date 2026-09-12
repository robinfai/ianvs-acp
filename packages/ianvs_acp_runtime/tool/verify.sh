#!/bin/sh
set -eu

PACKAGE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-${PACKAGE_ROOT}/rust/target}
mkdir -p "${CARGO_TARGET_DIR}"
CARGO_TARGET_DIR=$(CDPATH= cd -- "${CARGO_TARGET_DIR}" && pwd -P)
export CARGO_TARGET_DIR
cd "${PACKAGE_ROOT}/rust"
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo build --locked -p ianvs-acp-core --bin ianvs-acp-fixture-agent
cargo build --locked -p ianvs-acp-ffi

cd "${PACKAGE_ROOT}"
"${DART:-dart}" pub get
"${DART:-dart}" analyze
IANVS_ACP_RUST_LIBRARY="${CARGO_TARGET_DIR}/debug/libianvs_acp_ffi.dylib" \
  IANVS_ACP_FIXTURE_AGENT="${CARGO_TARGET_DIR}/debug/ianvs-acp-fixture-agent" \
  "${DART:-dart}" test
