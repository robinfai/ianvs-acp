#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

cd "${PROJECT_ROOT}/rust"
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo build --locked -p ianvs-acp-ffi
cargo build --locked -p ianvs-acpd
cargo build --locked -p ianvs-acp-core --bin ianvs-acp-fixture-agent

cd "${PROJECT_ROOT}"
case "$(uname -s)" in
  Darwin) RUST_LIBRARY="libianvs_acp_ffi.dylib" ;;
  Linux) RUST_LIBRARY="libianvs_acp_ffi.so" ;;
  *)
    echo "unsupported Rust runtime host: $(uname -s)" >&2
    exit 1
    ;;
esac
bash tool/flutter_test_isolated.sh \
  test/acp/rust_acp_agent_client_test.dart \
  test/rust/ianvs_acp_native_test.dart \
  test/rust/ianvs_acp_ffi_integration_test.dart \
  test/rust/ianvs_workflow_native_test.dart \
  test/rust/ianvs_workflow_ffi_integration_test.dart \
  test/rust/ianvs_rust_task_repository_ffi_integration_test.dart \
  test/rust/ianvs_daemon_workflow_integration_test.dart

IANVS_ACP_RUST_LIBRARY="${PROJECT_ROOT}/rust/target/debug/${RUST_LIBRARY}" \
  bash tool/flutter_test_isolated.sh \
  test/ui/acp_client_app_test.dart \
  --plain-name "AcpClientApp migrates legacy tasks before enabling Inbox"
