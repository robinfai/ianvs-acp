#!/usr/bin/env node

import { Codex } from "@openai/codex-sdk";

const DEFAULT_MODELS = [
  "gpt-5.6-sol",
  "gpt-5.6-sol-pro",
  "gpt-5.6-pro",
];

const models = process.argv.slice(2);
if (models.length === 0) models.push(...DEFAULT_MODELS);

const codex = new Codex();
const results = [];

for (const model of models) {
  process.stderr.write(`Probing ${model} ... `);

  const thread = codex.startThread({
    model,
    modelReasoningEffort: "low",
    sandboxMode: "read-only",
    approvalPolicy: "never",
    workingDirectory: process.cwd(),
    skipGitRepoCheck: true,
    networkAccessEnabled: false,
  });

  let result = { model, status: "unknown" };

  try {
    const { events } = await thread.runStreamed(
      "Reply with exactly OK. Do not use tools.",
    );

    for await (const event of events) {
      if (event.type === "turn.completed") {
        result = { model, status: "available", usage: event.usage };
      } else if (event.type === "turn.failed") {
        result = {
          model,
          status: "rejected",
          error: event.error.message,
        };
      } else if (event.type === "error") {
        result = { model, status: "error", error: event.message };
      }
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const backendMessage = message.match(/"message":"([^"]+)"/)?.[1];
    result = {
      model,
      status: backendMessage ? "rejected" : "error",
      error: backendMessage ?? message,
    };
  }

  results.push(result);
  process.stderr.write(`${result.status}\n`);
}

console.log(JSON.stringify({ checkedAt: new Date().toISOString(), results }, null, 2));

if (results.some((result) => result.status === "available")) {
  process.exitCode = 0;
} else {
  process.exitCode = 1;
}
