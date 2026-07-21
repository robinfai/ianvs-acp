# Codex model entitlement probe

This demo asks the installed Codex CLI, through `@openai/codex-sdk`, to run one
minimal turn with each exact model ID. It uses the CLI's existing login and
prints the server result as JSON.

```bash
cd tool/codex_model_probe
npm install
npm run probe
```

The defaults compare the public Sol ID with the two plausible Pro spellings:

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

This tests the current Codex login's entitlement. It does not test OpenCode's
own model aliases or a third-party OpenAI-compatible provider.
