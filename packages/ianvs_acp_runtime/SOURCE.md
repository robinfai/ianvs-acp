# Source provenance

- Package: `ianvs_acp_runtime` version `0.1.0`.
- Source repository: https://github.com/robinfai/ianvs-acp
- Extraction base commit: `8e59e1bd4a57d0903da1d1ed62ce713ee350580f`.
- Extraction date: 2026-09-12.
- Native C ABI: 11; event envelope schema: 4.
- Rust `Cargo.lock` and all Rust sources retain the base commit's `rust/`
  implementation. The two Dart binding/event implementation files retain the
  base commit's `lib/rust/` implementation.
- This package adds public exports, a C header, macOS build/signing commands,
  a CLI example, portable tests, documentation and publication metadata.
- All runtime source is distributed inside this package. No source file from
  the containing application repository is required to build or use it.
- License: Apache-2.0, matching the native workspace and Ianvs package family.
