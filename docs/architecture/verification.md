# Shared agent refactor verification

Verified locally on 2026-10-28. Original unrelated working-tree changes were
retained. At that verification checkpoint, no commit, push, release, installation
or deployment had been performed. The refactor was subsequently committed as
`4b1aa54a`; the follow-up below covers the reproducibility fixes.

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


## Reproducibility follow-up (2026-10-28)

The follow-up includes the previously uncommitted macOS loader and build fixes.
It keeps the unrelated `.fastembed_cache/` ignore-rule deletion out of the commit.
CI and local sibling-source reproduction use Terminal revision
`2fbf85aae1c4db45231d675b251925e1edf0f9ad`. That commit must be pushed to the
Terminal remote before remote ACP CI can fetch it; this task does not push either
repository.

Flutter 3.44.8's arm64 archive, SHA256
`c3d6fe95078f7001d947a31d42527de91d5bfe62e4cf444a1493a2e8f1fb199d`, and framework
revision `058e0af2c2b57e369d905a03ac9748b0ebf543c6` were checked against the
[official release manifest](https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json).
The installed toolchain reports the same framework revision.

The runtime loader tests reject invalid dynamic libraries, missing ABI symbols,
and ABI 11, and accept ABI 12. The actual Debug application's dylib also passes.
The app's locked CocoaPods install passes. Both application and example Podfiles
preserve Rust build macros; the example lockfile now removes its obsolete Mermaid
plugin dependency.

A fresh temporary directory contains only the proposed committed ACP sources and
a Git archive of the fixed Terminal commit, without either repository's existing
`build`, `.dart_tool`, or Rust target output. This checks the source dependency
boundary while still using installed SDKs and shared package download caches.

Fresh-source results: `make bootstrap`, `make analyze`, release-script contracts,
application macOS Release build, and the complete `verify_macos_bundle.sh` check
all pass. The bundle check covers universal architecture checks, native symbols
and linkage, entitlements, signing closure, and actual ACP ABI 12 loading.
The standalone chat example Debug build and deep/strict signature verification
also pass after removing its obsolete Mermaid normalization build phase/script.

Flutter emits a Terminal code-asset framework-name warning across architectures;
the produced `ianvs_core.framework` was checked with `lipo` and contains both
x86_64 and arm64, and its signature passes the bundle signing-closure check.
Remote GitHub Actions and notarization remain untested. No application was
installed or launched, and no commits were pushed.

CI explicitly installs the locally verified Rust 1.90.0 toolchain with Clippy
and both `aarch64-apple-darwin` and `x86_64-apple-darwin` targets. It sets the
runner default before Flutter/native hooks execute, so consumer working
directories do not select an older toolchain.
