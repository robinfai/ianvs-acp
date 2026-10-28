# Shared agent package release candidates

Prepared on 2026-10-28; no packages have been uploaded by this task.

Official pub.dev API checks found chat 0.2.0 and runtime 0.1.0 as the latest
published versions. The core and Mermaid package APIs returned HTTP 404.
The published versions precede the extracted core and new host widget APIs.

| Candidate | Dependencies / order | Dry-run result |
| --- | --- | --- |
| ianvs_agent_core 0.1.0 | Publish first | 0 warnings |
| ianvs_mermaid 0.1.0 | Independent of core; optional to consumers | 0 warnings |
| ianvs_acp_runtime 0.2.0 | Requires hosted core ^0.1.0; ABI 12 / schema 5 | Blocked during dependency resolution: core is not published |
| ianvs_agent_chat 0.3.0 | Requires hosted core ^0.1.0; no native Mermaid dependency | Blocked during dependency resolution: core is not published |

`python3 tool/prepare_shared_agent_release.py --output /absolute/new/directory`
creates isolated candidates, substitutes these versions and hosted core constraints,
and removes `publish_to: none` only in those copies. It does not upload, change
workspace dependency declarations or commit anything. `manifest.json` records the
base commit, the fact that working-tree content is included, and each candidate
file's SHA256. Recreate candidates after any source change. The temporary candidates
are review material, not proof of a release or a committed release revision.

The current workspace keeps local paths for integration. Do not replace consumer
specs with nonexistent hosted versions or label old published versions as providing
new APIs. Once explicitly authorized, publish core, verify its official archive,
then rerun real (unoverridden) runtime/chat dry-runs and resolve any additional
package validation issues before uploading those candidates. Mermaid is independent.
Record final package versions, source commits/tags and official archive hashes.

After publication, create an independent consumer using only hosted dependencies,
without path/Git/dependency_overrides. Verify lockfile hashes, public imports,
shared widget tests and target-platform builds before switching production hosts.
Terminal's PTY ownership, command execution status and approval controllers remain
host responsibilities regardless of package provenance.

## Authorization and repository precedent

The [previous chat release record](../agent-chat-release-0.2.0.md#正式发布)
states that chat 0.2.0 publication and branch/tag pushes followed explicit user
authorization for that version. That historical authorization does not authorize
these new versions. The [convergence plan](../agent-chat-convergence-2026-09-23.md#6-迁移步骤与分工)
defines release, independent hosted consumption and host upgrade as separate gates,
and explicitly says the plan itself is not publication authorization.

The current instruction authorizes implementation and preparation, with publication
subject to the existing process. Actual publication still needs confirmation of the
reviewed package versions/artifacts; credentials or an authenticated pub client are
not authorization. Until then, keep the packages unpublished and report the
runtime/chat dry-run dependency blocker accurately.

## Shared host integration verification

- Chat package: 304 tests passed; 2 opt-in live-provider tests skipped.
- ACP application: 1384 tests passed after the shared frame/approval integration.
- Both package and application static analysis passed.
- Five host-widget tests cover editor identity, focus/selection/IME ownership,
  opt-in original-source copying, 320px dark layout and separate approval actions,
  suppressed output/images/diffs, and host-controlled rich-tool disclosure.
- The existing long permission context retains one vertical scrolling owner;
  expanded code previews only scroll horizontally inside that context.
- Three existing visual baselines were inspected and updated for the shared
  uniform role inset. User bubbles retain their content-fitting width.
- ACP's existing conversation uses the shared frame, permission surface and
  literal command preview. Hosted input shares its surface with managed input.

These checks do not establish Terminal persistence correctness or mobile-device
runtime behavior; those are verified by the Terminal host. Shared widgets hold no
operation receipts, restart persistence, approval restoration, or PTY input state.
No staging, commits, publication, or pushes were performed for this integration.

## Authorized release execution — 2026-10-28

The user authorized the necessary releases in the Terminal coordination chat:
“必要的都发布”. Scope: core 0.1.0, runtime 0.2.0, chat 0.3.0 and hosted
consumer verification. Mermaid 0.1.0 remains optional and will not be published.
The earlier preparation-only restrictions above describe the pre-authorization state.

Workspace pubspecs retain local paths and `publish_to: none` for monorepo
integration. Committed versions/changelogs plus the preparation script reproduce
the hosted publication manifests. Publication uses the reviewed frozen payloads,
whose manifest SHA256 is
`9a47b3a4f432e244655f43db55fa965a3f86e4047738959debe7e5b1a6a72fd6`.
No unrelated `.gitignore` edits are part of this release. Git pushes are deferred
until the Terminal host coordinates the dependency update.
