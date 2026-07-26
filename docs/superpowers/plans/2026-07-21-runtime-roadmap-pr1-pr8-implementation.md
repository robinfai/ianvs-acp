# Runtime roadmap PR1–PR8 implementation note

## Reviewed baseline

- Branch baseline: `main`
- Commit: `3c5d14bdf06ea138bd5de6f2db8f5ddb92aed0c8`
- Handoff: `ianvs-acp-codex-handoff-v2-2026-07-21.zip`

The work follows the handoff dependency order continuously through PR8. Each
milestone keeps Rust Core as the only durable Task, Run, scheduling, ownership,
recovery, Workflow, and coordinator authority.

## PR1 reviewed baseline finding

The current atomic path is:

```text
TaskScheduler._drainAtomicAuthority
  -> publish runtime observations
  -> Rust scheduler_claim_next
  -> persist dispatched Run, attempt, event, and workspace lease
  -> ReservableTaskWorker.tryAcquire(task)
```

The worker path is:

```text
TaskRunnerWorker.tryAcquire(task)
  -> TaskRunner.tryAcquireAgent(task)
  -> TaskAgentPool.tryAcquire(agentName)
```

If the final acquisition returns null or throws, `_failAtomicClaimWithoutWorker`
marks the already-dispatched Run failed. Capacity absence therefore consumes an
attempt even though Agent execution never started.

PR1 resolved this by changing the typed contract so the host first holds
expiring reservations for candidate Agent names, Rust selects only among those
reservations, and the claim echoes the selected reservation ID. No-capacity and
every other no-op admission leave the durable revision unchanged.

Required proof covers:

- no capacity creates no Run, attempt, event, workspace lease, or revision;
- reservation Agent identity and expiry are enforced in Rust;
- runtime observations expire in Rust rather than through host interpretation;
- priority, retry, quota, exclusion, and workspace ordering remain Rust-owned;
- unselected, exceptional, shutdown, and no-op reservations are released;
- human review may retain workspace isolation without consuming execution
  capacity.

## Completed sequence

1. PR1 reserves expiring Agent capacity before Rust claim and returns structured
   admission without mutating on a no-op.
2. PR2 persists executor lease/generation, start acknowledgement, heartbeat,
   takeover, release, and fenced mutations.
3. PR3 makes command idempotency transactional and restart recovery classified.
4. PR4 stores high-volume events append-only with sequence cursors and bounded
   checkpoints/replay.
5. PR5 adds `ianvs-acpd` as the database-locked headless execution host. Flutter
   is an IPC projection client and starts no second dispatcher.
6. PR6 adds immutable Workflow Definitions and revisioned Workflow/Step Runs for
   the eight typed v1 node kinds, with DAG and budget validation.
7. PR7 adds exact-one-JSON extraction, a bounded JSON Schema subset, durable
   validation attempts, at most two corrections, non-bypassable typed output,
   and durable human-review exhaustion.
8. PR8 adds semantic capability profiles, bounded Task/Progress Ledgers,
   provenance-bearing Plan proposals, immutable started Steps, and hard replan,
   invocation, token, cost, global/profile concurrency, node, fan-out, and depth
   limits.

SQLite is now schema v10; the foreground FFI contract is v7 and daemon IPC is
v1. Rust workspace tests, daemon/Dart integration tests, full Flutter tests,
`flutter analyze`, clippy with warnings denied, and diff whitespace checks are
the completion gates.
