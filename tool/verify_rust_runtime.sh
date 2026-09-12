#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

RUNTIME_ROOT="${PROJECT_ROOT}/packages/ianvs_acp_runtime"
CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-${RUNTIME_ROOT}/rust/target}
mkdir -p "${CARGO_TARGET_DIR}"
CARGO_TARGET_DIR=$(CDPATH= cd -- "${CARGO_TARGET_DIR}" && pwd -P)
export CARGO_TARGET_DIR
"${RUNTIME_ROOT}/tool/verify.sh"

cd "${PROJECT_ROOT}"
IANVS_ACP_RUST_LIBRARY="${CARGO_TARGET_DIR}/debug/libianvs_acp_ffi.dylib" \
  IANVS_ACP_FIXTURE_AGENT="${CARGO_TARGET_DIR}/debug/ianvs-acp-fixture-agent" \
  bash tool/flutter_test_isolated.sh \
  test/acp/rust_acp_agent_client_test.dart \
  test/rust/ianvs_acp_native_test.dart \
  test/rust/ianvs_acp_ffi_integration_test.dart
