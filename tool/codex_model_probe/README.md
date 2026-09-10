# Codex model entitlement probe

This demo asks the installed Codex CLI, through `@openai/codex-sdk`, to run one
minimal turn with each exact model ID. It uses the CLI's existing login and
prints the server result as JSON.

```bash
cd tool/codex_model_probe
npm ci
npm run probe
```

The script currently defaults to these historical candidate strings from
`probe.mjs`. Their presence is not evidence that any spelling is public,
current, or available to your account:

```text
gpt-5.6-sol
gpt-5.6-sol-pro
gpt-5.6-pro
```

You can probe model IDs supplied by somebody else:

```bash
npm run probe -- gpt-5.6-sol gpt-5.6-sol-pro
```

Interpretation:

- `available`: the authenticated Codex backend accepted the exact model ID and
  completed a turn.
- `rejected`: the backend returned a structured turn failure.
- `error`: the SDK/CLI process failed before a conclusive completion.
- `unknown`: the stream ended without a recognized completion or failure event.

The process exits 0 if at least one model is `available`, and 1 otherwise;
exit 0 does not mean every candidate succeeded. Each run performs real backend
model turns with the current login. It is not part of `make verify`.

This tests the current Codex login's entitlement. It does not test OpenCode's
own model aliases or a third-party OpenAI-compatible provider.
