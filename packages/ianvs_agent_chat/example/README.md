# Agent Chat example

A standalone macOS host that depends only on `ianvs_agent_chat` and Flutter.

```sh
flutter pub get
flutter run -d macos
```

Use **Demo** for a deterministic conversation with tool approval, streamed text and cancellation. Use **LLM API** for a real OpenAI-compatible service. Enter the full completion endpoint, model name and API key. Credentials remain in memory and are cleared from the form after creating the connection.

Optional endpoint/model defaults can be set with `--dart-define=LLM_ENDPOINT=...` and `--dart-define=LLM_MODEL=...`. Do not put API keys in build definitions or source code.
