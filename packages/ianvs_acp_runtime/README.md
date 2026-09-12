# ianvs_acp_runtime

Shared, UI-independent local ACP runtime for macOS desktop hosts. This package
owns the Dart bindings, complete Rust core and C FFI, locked Cargo dependencies,
fixture agent, and native build/signing scripts. It has no Flutter dependency.
`ianvs_agent_chat` is a separate UI package; consumers supply their own adapter.

## Stable entry points

| Entry | Path / contract |
| --- | --- |
| Dart import | `package:ianvs_acp_runtime/ianvs_acp_runtime.dart` |
| Public API | `IanvsRustRuntime`, `IanvsAcpNativeApi`, `FfiIanvsAcpNativeApi`, `IanvsRuntimeEvent`, `IanvsRuntimeEventType` |
| Rust workspace | `rust/Cargo.toml` (core and FFI crates; `Cargo.lock` included) |
| Native build | `tool/build_macos.sh` |
| Hosted package build | `dart run ianvs_acp_runtime:build_macos` |
| Native signing | `tool/sign_macos.sh` |
| Full package verification | `tool/verify.sh` |
| C header | `include/ianvs_acp.h` |
| CLI example | `example/local_chat.dart` |
| C ABI | **11**, `libianvs_acp_ffi.dylib`; incompatible versions are rejected |
| Event schema | **4**, independent of the ABI and ACP wire version |
| ACP dependency | `agent-client-protocol = 1.2.0`, unchanged; Rust negotiates the wire protocol |

The package directory can be copied or archived as a whole and built outside this
repository. No source, fixture, or build script depends on files above this
directory. The app's root `rust` symlink and `lib/rust` re-exports are compatibility
entry points only; the implementation lives here.

## Consumer integration

Add the hosted dependency, then run `flutter pub get` / `dart pub get`:

```yaml
dependencies:
  ianvs_acp_runtime: ^0.1.0
```

For local development a path dependency on the complete package directory also
works. Dart >= 3.12 and Rust >= 1.90 are required. This release supports macOS;
the Rust library must be built and embedded using the steps below.

Import the public library above. Subscribe to `runtime.events` **before** calling
`startAgent`. The broadcast stream does not replay events. Start one runtime per
agent process, then create sessions after the `ready` event. Command methods
enqueue work synchronously; their return is not an asynchronous success signal.
Use unique request IDs and correlate completion/error events as described below.

```dart
final runtime = IanvsRustRuntime();
final subscription = runtime.events.listen(
  handleEvent,
  onError: handleStreamError,
);
runtime.startAgent(
  agentName: 'Document assistant',
  command: '/absolute/path/to/agent',
  args: ['--acp'],
  environment: {'EXAMPLE_SETTING': 'value'},
  processCwd: '/absolute/workspace',
);
// After status_changed: ready:
runtime.createSession(requestId: 'new-1', cwd: '/absolute/workspace');
// After session_update: session_created, use update['sessionId']:
runtime.prompt(requestId: 'prompt-1', sessionId: sessionId, text: 'Summarize');
// When the host is closing, cancel its subscription before awaiting disposal:
await subscription.cancel();
await runtime.dispose();
```

A runnable example is `dart run example/local_chat.dart /path/to/agent --acp`;
it prints text/tool events and declines permissions by default.

The launch environment inherits the host environment with explicit overrides;
`command` and `args` are passed directly, without a shell. GUI apps may need an
absolute executable path and an explicit `PATH` for the agent's child tools.
`processCwd` controls process launch; session `cwd` controls the session workspace.
Persistence is opt-in via `sessionStorePath`; use a consumer-owned location.

`enableFilesystemReadTextFile`, `enableFilesystemWriteTextFile`,
`allowFilesystemReadOutsideWorkspace`, and `enableTerminalProvider` all default
to **false**. These are client ACP providers; they do not restrict an agent's own
process or tools. Permission requests from the agent are still surfaced. Local
ACP is for the macOS host with App Sandbox disabled, matching ianvs-acp. Do not
load or start this runtime on iOS or web.

## ABI v11 event contract

Every event is a flattened JSON envelope: `schemaVersion: 4`, positive strictly
increasing `sequence` (per runtime), and snake_case `type`. Field names are
camelCase. `IanvsRuntimeEvent.data` exposes the full envelope. Native polling
returns `{ "events": [...], "hasMore": bool }`, or null when empty. Dart validates
schema/order, drains bounded batches, and yields between expensive dispatches.
Sequence gaps are allowed; regressing/repeated sequences are stream errors.

| Type | Payload and consumer behavior |
| --- | --- |
| `status_changed` | `status`: `stopped`, `starting`, `ready`, `recovering`, `failed`, `disposed`; optional `detail`, `capabilities`. Wait for `ready` before session commands. |
| `session_update` | `update: {sessionId, kind, requestId?, text?, payload?}`. Kinds: `session_created`, `session_restored`, `session_closed`, `session_deleted`, `mode_changed`, `config_changed`, `commands_changed`, `permission_invalidated`. Creation completion carries the caller's request ID inside `update`, not at the envelope level. |
| `render_update` | `update: {sessionId, kind, text?, metadata?}`. Kinds: `user_message`, `assistant_text`, `thought`, `tool_call`, `plan`, `turn_completed`. Text is streamed incrementally; append deltas. Merge tool fields by `metadata.toolCallId`; updates can be partial. `turn_completed.metadata` includes `requestId` and `stopReason` (including `cancelled`). |
| `render_snapshot_chunk` | `requestId`, `sessionId`, `chunkIndex`, `isLast`, `updates`. Stage replay chunks; commit only after the matching `session_restored`. Discard staged data on failure. |
| `permission_request` | `request: {requestId, sessionId, toolCallId, title, toolKind, rawInput, options}`. Options contain `optionId`, `label`, `kind`. Respond using this nested request ID and an offered option. |
| `runtime_error` | `requestId?`, `code`, `message`, `recoverable`. Correlate request failures; connection failures may have no request ID. Fail pending host operations on terminal failure and clear pending permissions. |
| `session_catalog` | `requestId`, `sessions` with `sessionId`, `cwd`, optional additional directories/title/update metadata. |
| `authentication_changed` | `requestId`, `authenticated`, optional `methodId`. |
| `stderr_log` | `line`, separate from conversation text. |
| `terminal_attached`, `terminal_output`, `terminal_exited`, `terminal_released` | `sessionId`, `terminalId`, plus command/cwd, data, or exit respectively; only relevant when the terminal provider is enabled. |

Permission responses are `{'decision': 'selected', 'optionId': offeredId}` or
`{'decision': 'cancelled'}`. Call `respondPermission(requestId: ..., decision: ...)`.
Treat `permission_invalidated` as removal of a pending prompt; cancellation,
timeout, session closure, and disconnect can invalidate it. Do not auto-approve
an option simply because it is first in the list.

Call `cancel(requestId: cancelId, sessionId: sessionId)` to cancel a turn; wait for
`turn_completed` before considering the prompt finished. It correlates with the
original prompt request ID. Listen to both `runtime_error` events and stream
`onError` (Dart decoding/sequence failures). Native rejection throws `StateError`
synchronously. A recoverable error does not automatically mean a host request
will be retried. Dispose the runtime after terminal disconnect/failure; a new
runtime may be used for reconnect. Await `dispose()` to stop polling, shut down
the process/providers, drain pending events, release the native handle, and close
the stream. Disposal is idempotent; subsequent commands throw.

Canonical DTO definitions are in `rust/crates/ianvs-acp-core/src/model.rs`; the
FFI signatures and ownership rules are in `rust/crates/ianvs-acp-ffi/src/lib.rs`.
ACP JSON-RPC is owned entirely by Rust and never needs to be copied into a host.

## macOS Xcode build and signing

Install Rust >= 1.90 and the Apple targets needed by your build:

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

Add a Runner Run Script phase after Flutter assembly and before final application
signing. Run the package command from the consuming project so it resolves the
same version as your Dart imports, including when installed in the pub cache:

```sh
export PATH="${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
cd "${SRCROOT}/.."
"${FLUTTER_ROOT}/bin/dart" run ianvs_acp_runtime:build_macos
```

The command writes Cargo outputs into
`${DERIVED_FILE_DIR}/ianvs_acp_runtime/cargo` in Xcode or the consumer's
`build/ianvs_acp_runtime/cargo` otherwise. The downloaded package remains
unchanged. `CARGO_TARGET_DIR` can override this cache location.

If you already resolve the package directory in a native build wrapper, you can
call the underlying script directly:

```sh
"${IANVS_ACP_RUNTIME_ROOT}/tool/build_macos.sh"
```

Disable Xcode user script sandboxing for this phase (`ENABLE_USER_SCRIPT_SANDBOXING=NO`)
so Cargo can read its toolchain/cache and write its build directory. Disable
"Based on dependency analysis" unless your project declares the complete Rust
source and lockfile inputs. Embed into `Contents/Frameworks` before signing the
outer app. Hardened runtime releases should sign the dylib with the app's same
Developer ID identity, then sign/verify/notarize the containing app as usual.

| Environment | Meaning |
| --- | --- |
| `CONFIGURATION` | `Debug` uses debug; other values use release. Defaults to `Debug`. |
| `TARGET_BUILD_DIR`, `FRAMEWORKS_FOLDER_PATH` | Standard Xcode destination, typically `App.app/Contents/Frameworks`. |
| `IANVS_ACP_FRAMEWORKS_DIR` | Explicit destination instead of the two Xcode variables; useful for standalone builds. |
| `IANVS_ACP_ARCHS` | Space-separated `arm64 x86_64` override. Debug defaults to Xcode `ARCHS` or host architecture; release defaults to universal. |
| `CARGO_TARGET_DIR` | Optional build/cache directory; default is this package's `rust/target`. Use an absolute writable path when source is read-only. |
| `CODE_SIGNING_ALLOWED` | `NO` skips signing; default `YES`. |
| `EXPANDED_CODE_SIGN_IDENTITY`, `CODE_SIGN_IDENTITY` | Signing identity in priority order; defaults to ad hoc `-`. |
| `IANVS_CODESIGN_BIN` | Optional codesign executable (default `/usr/bin/codesign`). |
| `IANVS_ACP_RUST_LIBRARY` | Runtime-only explicit dylib path, useful for tests/CLI consumers. |

The script selects rustup's toolchain when available, builds with `--locked`,
combines architectures with `lipo`, sets `@rpath/libianvs_acp_ffi.dylib`, and signs
the result. Ad hoc builds use no timestamp; identity builds enable hardened
runtime and timestamping. Standalone example:

```sh
IANVS_ACP_FRAMEWORKS_DIR="$PWD/build/native" CONFIGURATION=Release \
  ./tool/build_macos.sh
```

The loader first honors `FfiIanvsAcpNativeApi.open(libraryPath: ...)`, then
`IANVS_ACP_RUST_LIBRARY`, then the app's `../Frameworks` directory and local Cargo
debug/release outputs. Bundled consumers need no runtime path override.

Native subprocess ownership must stay with Rust. In Dart 3.12.2 on macOS,
`dart:io`'s process exit thread uses `wait()` for any child, so overlapping Dart
`Process` operations can steal native child exit statuses. This was reproduced
as PTY `ECHILD` in the default kernel test runner; the package uses executable
test hosts to isolate the compiler process. Avoid overlapping host `Process`
operations with native child lifetimes. This extraction retains the existing
runtime behavior. See the [Dart SDK process implementation](https://github.com/dart-lang/sdk/blob/3.12.2/runtime/bin/process_macos.cc#L170-L218).

## Verification

From this package directory, `./tool/verify.sh` runs Rust tests, clippy, the
fixture/dylib builds, Dart analysis and pure Dart unit/real FFI tests. Rust fixture
tests need no real agent, credentials, or network service. Cargo/pub dependency
resolution requires downloaded dependencies or network access on first use.
Use `dart test test/ianvs_acp_native_test.dart` for the binding-only unit tests.
`IANVS_ACP_FIXTURE_AGENT` can point integration tests at a separately built fixture.

From the containing repository, `./tool/verify_rust_runtime.sh` remains the
application + runtime verification entry point, and the prior `test/rust/*`
entry points still run the shared suites through compatibility wrappers.

## License

Apache-2.0. Source provenance is recorded in `SOURCE.md`.
