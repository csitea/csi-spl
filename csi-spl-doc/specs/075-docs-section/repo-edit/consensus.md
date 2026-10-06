# 075 repo-edit: panel consensus

**Topic**: t1 `2e20d6d4-16b7-4be2-b7d7-45c4f1fbf56e` · **Written by**: c-380 (claude, spec author) · **Date**: 2026-10-06
**Inputs**: [`spec.md`](spec.md) v0.1 at `6f91653fb` (claude, c-380), [`grok-opinion.md`](grok-opinion.md) (grok, g-381), [`agy-opinion.md`](agy-opinion.md) (agy, a-382). Both reviewed v0.1 at `6f91653fb`, and both landed within the 90-minute window.
**Result**: folded into [`spec.md`](spec.md) v0.2. Docs only: this file builds nothing.

## 1. The table

| Q | claude (c-380) | grok (g-381) | agy (a-382) | agreed answer, or left for the owner |
|---|---|---|---|---|
| Q1 flow | Postgres `repo_doc_edits` queue; in-hub worker under an advisory lock; `.edits/` overlay; status chip | same | same, plus: coalesce only `queued` rows | **Agreed**: as v0.1, plus coalescing touches `queued` rows only (a `pushing` row is frozen), and a reclaimed `pushing` row first looks for a commit naming its edit id. Retries as v0.1. |
| Q2 target | prd: master, fast-forward via the Git Data API; dev: `docs-edit-dev` | same; a red inherited from another push must not turn the edit's chip red | same; the workflow 10 skip for .md-only pushes is a P0 prerequisite; `[skip ci]` in the message | **Agreed**: the target as v0.1. The chip shows red only when the docs-publish workflow fails or a job fails because of this push. The .md fast path in workflow 10 is a **prerequisite before prd** (claude and agy; grok: a risk, not a blocker). **Rejected**: `[skip ci]`, because it skips every workflow, the docs-publish and hygiene runs included. Instead the fast path keeps hygiene and link checks and skips the builds. Whether to build it is still O6. |
| Q3 conflicts | no lock; 3-way merge; a line conflict pushes nothing; the editor resolves | same; re-run the text gates on the merged bytes | same; apply in-app edits in order (B merges onto A's landed commit) | **Agreed**: v0.1 plus both additions: the gates run again on merged text (a hit = `conflict`, no ref update), and in-app edits are applied in strict FIFO order. |
| Q4 author | mapping row > history match > display name + `<human_id>@users.noreply.<BASE_DOMAIN>`; committer = the App bot; no AI trailer; no agents | same; the route refuses agent tokens, not just "agents not allowed" | same | **Agreed**: as v0.1, and the route accepts a member session only (an agent token gets 403). The message stays `docs: edit <path>` with no `[skip ci]`. |
| Q5 who / paths | `docs.write` member in an operator-enabled workspace; deny list (agent files, `csi-spl-wui/**`, `.github/**`, `tasks.md`); 30/h, 300/day | same switch; corrects the role list (every role but `demo_user`); adds the workflow 20 prefixes to the deny list | strict allow-list: `csi-spl-doc/**` + root docs only; deny every module root; 20/h, 200/day | **Agreed**: the workspace switch (default off), the corrected role fact, member-only access, the gates before the write, 1 MiB, 30/h and 300/day (2 of 3), no delete or rename. **v1 editable set = agy's allow-list** (`csi-spl-doc/**` + `README.md`, `CONTRIBUTING.md`, `DEPLOY.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`), minus `tasks.md` and the agent files (claude moved to it; ~500 of 574 docs). **Left for the owner (O9)**: widen to grok's form ("any published .md minus a deny list of deploy prefixes"), which is closer to "any md docs". |
| Q6 loop | overlay; workflow `32_docs-publish` on `**/*.md`; drop the overlay when tree.json's sha contains the commit (compare API) | trigger on the editable prefixes only (`**/*.md` would also match WUI pushes, giving two `rsync --delete` runs) | same overlay; avoid a compare call every cycle | **Agreed**: workflow 32 triggers on the editable prefixes only. The `published` check makes one compare call per NEW tree.json sha, cached (`tree.json.sha == commit_sha` alone misses a commit landing on top). **New, found in consolidation**: today `spl_docs_upload` runs `gcloud storage rsync --delete-unmatched-destination-objects`, so the publish WOULD delete `.edits/`. v0.1 and both opinions assumed it would not. Lane L3 must add an exclude for `^\.edits/` and its test before the overlay ships. |
| Q7 secret | GitHub App, contents:write + metadata:read, this repo only; key `spool-hub-github-app-key` in each env's Secret Manager; terraform adds only the container and the accessor; named put/rotate actions | same | same; cache the token for 50 min | **Agreed**: as v0.1, plus the installation token is cached in memory and never written to disk. |

## 2. Scores the panel gave v0.1 (1-5)

| axis | grok on v0.1 | agy on v0.1 | after v0.2 (claude's read) |
|---|---|---|---|
| simple | 4 | 4 | 4 |
| safe | 3 | 4 | 4 (deploy prefixes denied, member-only, merged text gated, allow-list) |
| robust | 4 | 3 | 4 (FIFO, frozen `pushing`, rsync exclude, cached compare) |
| fast | 5 | 5 | 5 |

## 3. Left for the owner

The owner questions are in [`spec.md`](spec.md) §14, O1-O9. The panel recommends the same option on every one. Only O9 (how wide the editable set is) carries a split: grok favours the wider form, claude and agy the allow-list for v1.

<!-- consensus: 075 repo-edit · c-380 · 2026-10-06 -->
