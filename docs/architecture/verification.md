# Shared agent refactor verification

Verified locally on 2026-10-28. Original unrelated working-tree changes were
retained. No commit, push, release, installation or deployment was performed.

| Check | Result |
| --- | --- |
| ACP application `flutter test --no-pub` with final sibling core | 1384 passed |
| Application controller/ACP bridge/shell after shared mutation extraction | 355 passed |
| Shared chat full suite | 299 passed; 2 opt-in live-provider tests skipped |
| Runtime Dart binding + real native FFI suite | 26 passed |
| Rust workspace tests | 75 passed |
| Rust clippy, all targets, warnings denied | Passed |
| Optional Mermaid package | 14 passed |
| Core content/replay/generation plus partial fields/atomic mutation | 5 passed |
| Release-script contracts, including ABI 12 loader | Passed |
| ACP macOS Debug build and deep/strict signature verification | Passed |

The runtime fixtures cover environment replacement across a real subprocess,
agent identity and prompt metadata, cancellation, permissions, terminal and
filesystem providers, and an agent that never answers initialize. The adapter
checks include staged restore turn boundaries, partial tool fields, prompt cancel
completion, and pending-operation failure when the runtime stream closes.

The Terminal partner independently reports 696 AI tests, 12 Apple build-contract
tests, macOS Debug build/signature verification, and real ACP + native PTY consumer
tests including cancellation during initialize/new/config/load. These results are
reported by the Terminal chat; this repository does not contain its test logs.

## Reproduce

```sh
make bootstrap
make analyze
make test
make test-rust
make test-release-scripts
flutter build macos --debug
codesign --verify --deep --strict build/macos/Build/Products/Debug/Shift.app
```

The initial hosted `ianvs_terminal_core 0.1.0` dependency failed in its native
build hook with malformed release proc-macro dylibs. Final verification uses the
maintained sibling source with its no-strip configuration, not the temporary
copy used to diagnose that failure. Both checkouts are required during development.

No live provider credentials were used. GitHub Actions, release notarization,
and actual mobile OS builds were not run. Desktop build warnings about optional
Swift Package Manager adoption and a missing Metal Swift search directory remain;
the produced Debug app builds and passes code-signature verification.
