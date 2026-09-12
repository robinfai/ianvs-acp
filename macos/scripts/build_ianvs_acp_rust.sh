#!/bin/sh
# Application compatibility entry point; native build logic lives in the package.
set -eu
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
IANVS_ACP_RUNTIME_ROOT=${IANVS_ACP_RUNTIME_ROOT:-${PROJECT_ROOT}/packages/ianvs_acp_runtime}
exec "${IANVS_ACP_RUNTIME_ROOT}/tool/build_macos.sh"
