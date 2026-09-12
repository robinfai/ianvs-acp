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
