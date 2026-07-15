# Changelog

## 0.2.0

This vendored release intentionally includes security-driven API changes and is
not published as the upstream `dart_acp` package.

### Migration

- Replace nullable `AcpTimeouts.prompt` and `AcpTimeouts.permission` values with
  finite, positive `Duration` values. Prompt, permission, ordinary request, and
  cancellation-grace deadlines can no longer be disabled.
- Update custom `PermissionProvider` implementations and `PermissionCallback`
  callbacks to return `PermissionDecision` instead of `PermissionOutcome`.
  Use `PermissionDecision.allow`, `PermissionDecision.deny`, or
  `PermissionDecision.cancelled`; pass an ACP option id through `optionId` when
  selecting a structured permission choice.
- Replace `AcpClient.cancel(sessionId: ...)` according to the prompt API in use.
  For typed prompt streams, cancel the `StreamSubscription`. For raw prompts,
  retain the `AcpSessionInputBudgetOwner` returned by `beginPromptTurn` and call
  `cancelPromptTurn(owner)` so cancellation cannot target a replacement turn.
- Existing `TerminalProvider.create` implementations and
  `TerminalProcessHandle(terminalId:, process:)` calls remain source compatible.
  Handles retain at most 1 MiB by default. Providers that support a smaller
  caller-selected cap may implement `OutputBoundedTerminalProvider` and handle
  `createWithOutputByteLimit`; `DefaultTerminalProvider` implements this
  optional capability. Legacy providers are host-trusted and remain responsible
  for bounding their own internal retention; the session manager still enforces
  the effective byte cap on every protocol output and wait response.

### Security and reliability

- Added bounded transport, parsing, retained-state, filesystem, terminal, and UI
  budgets.
- Added owner-bound prompt cancellation, finite deadlines, first-wins terminal
  settlement, and deterministic cleanup across close, reconnect, and disposal.
- Added payload-free failures and bounded permission audit handling for
  untrusted ACP data.
