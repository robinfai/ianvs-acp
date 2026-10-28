#!/bin/sh
set -eu

[ "$#" -eq 1 ] || { printf 'usage: verify_macos_runtime.sh /path/to/runtime.dylib\n' >&2; exit 64; }

probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/ianvs-acp-load-probe.XXXXXX")
trap 'rm -rf -- "${probe_dir}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Architecture, symbol and signature checks cannot prove that dyld will accept
# a Mach-O image. Load the library on the build host before installing it.
/usr/bin/xcrun clang -x c -Wall -Wextra -Werror -o "${probe_dir}/probe" - <<'C'
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>

int main(int argc, char **argv) {
  if (argc != 2) return 64;
  void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (library == NULL) {
    fprintf(stderr, "error: cannot load ACP runtime: %s\n", dlerror());
    return 1;
  }
  uint32_t (*version)(void) = (uint32_t (*)(void))dlsym(library, "ianvs_acp_ffi_version");
  if (version == NULL) {
    fprintf(stderr, "error: cannot resolve ACP ABI version: %s\n", dlerror());
    dlclose(library);
    return 1;
  }
  uint32_t actual = version();
  dlclose(library);
  if (actual != 12) {
    fprintf(stderr, "error: ACP runtime ABI is %u, expected 12\n", actual);
    return 1;
  }
  puts("macOS runtime load verification passed (host architecture, ABI 12)");
  return 0;
}
C
"${probe_dir}/probe" "$1"
