## Unreleased

- Upgrade the locked ACP Rust SDK from 1.2.0 to 2.1.0 and protocol schema from
  1.4.0 to 1.7.0. Keep stable ACP v1, C ABI v11, and event schema v4.
- Wait for the permission flood rejection before granting the admitted requests,
  so the admission-limit regression test does not depend on scheduler timing.

## 0.1.0

- Extract the UI-independent Rust stdio ACP core, C FFI and Dart bindings into
  one self-contained package with all native sources and a locked Rust workspace.
- Preserve C ABI v11, event schema v4, and the existing ACP protocol dependency.
- Expose agent launch, sessions, streaming text and tools, permissions,
  cancellation, authentication, recovery and disposal through `IanvsRustRuntime`.
- Keep client filesystem and terminal providers disabled by default.
- Include macOS universal library build/signing scripts and a package-resolved
  `dart run ianvs_acp_runtime:build_macos` entry point for hosted dependencies.
- Include a CLI example, C header, fixture agent and Rust/Dart regression tests.
