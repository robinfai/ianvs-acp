import { spawnSync } from "node:child_process";

const checks = [
  ["Design token contrast", "node", ["scripts/check-contrast.mjs"]],
  ["Automated interaction acceptance", "npm", ["test"]],
  ["Production build", "npm", ["run", "build"]],
];

for (const [label, command, args] of checks) {
  console.log(`\n▶ ${label}`);
  const result = spawnSync(command, args, { stdio: "inherit" });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

console.log("\n✓ Inbox autopilot acceptance passed");
