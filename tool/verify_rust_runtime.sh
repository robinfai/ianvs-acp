#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

cd "${PROJECT_ROOT}/rust"
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo build --locked -p ianvs-acp-ffi
cargo build --locked -p ianvs-acp-core --bin ianvs-acp-fixture-agent

cd "${PROJECT_ROOT}"
IANVS_ACP_RUST_LIBRARY="${PROJECT_ROOT}/rust/target/debug/libianvs_acp_ffi.dylib" \
  bash tool/flutter_test_isolated.sh \
  test/acp/rust_acp_agent_client_test.dart \
  test/rust/ianvs_acp_native_test.dart \
  test/rust/ianvs_acp_ffi_integration_test.dart
