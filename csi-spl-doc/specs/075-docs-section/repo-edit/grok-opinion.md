# 075 repo-edit — panel opinion (grok)

**Feature ID**: `075-docs-section/repo-edit` · **Status**: Opinion (not a spec)
**Panelist**: grok · **Topic**: t1 `2e20d6d4-16b7-4be2-b7d7-45c4f1fbf56e`
**Reads**: spec 075, `internal/hub/docs.go`, `do_publish_docs` in `csi-spl-orc/src/bash/run/publish-docs.func.sh`, the WUI docs page `csi-spl-wui/src/pages/docs.vue`, and the draft `spec.md` at `6f91653fb28477d47f0dc8c294e7013c1b60b539`.

Docs only. This file proposes. It changes no code, no secret, and no environment.

User-facing text says **workspace**. The word tenant appears only as the existing column name `tenant_id`.

---

## What the code does today

- Repo docs are read-only. `docs.go` registers `GET /v1/docs/{path...}` only. A signed-in member passes `humanTenant`; an empty human is 403; `Options.Docs == nil` is 404 `docs_off`. `ValidDocsPath` allows `tree.json` or a `.md` path of at most 512 characters whose segments match `[A-Za-z0-9._-]` and do not start with a dot.
- `do_publish_docs` runs inside the WUI deploy. `spl_docs_stage` copies `git ls-files '*.md'` at the deploy sha, skips `CLAUDE.md`, `GEMINI.md`, `AGENTS.md`, `node_modules/`, `tpl-gen/`, `bin/`, and the built help copy, and writes `tree.json` as `{v, sha, files:[{path, title}]}`. `spl_docs_upload` is `gcloud storage rsync --delete-unmatched-destination-objects`. The bucket is a mirror of that commit, not a place the hub writes.
- The repo page in `docs.vue` renders `MarkdownBlock` and has no edit control. Workspace docs are the other branch (`DocsWorkspaceDoc`), `PUT`/`DELETE` on `/v1/workspace/docs/`, last save wins, a `.history/` object per write, cap `MaxWorkspaceDoc` = 1 MiB (`workspace_docs.go`). The owner already refused a lock (`15134701`).
- `docs.write` is on every default role except `demo_user`: biz owner, product owner, admin, developer, tester, pure agent, biz customer, regular user (`internal/rbac/rbac.go` `Defaults`). `demo_user` has `docs.read` only.
- Workflow 30's path allow-list includes `csi-spl-wui/**` and `publish-docs.func.sh`. A commit that only touches `csi-spl-doc/**` does not deploy the WUI and does not republish.
- Workflow 20's allow-list includes `csi-spl-api/src/go/**` (not limited to `*.go`), plus `csi-spl-rdb/src/sql/postgres/spool-hub/**` and `spool-hub-roles/**`. A `.md` file under those prefixes deploys the hub.
- Workflow 10 has no path filter: every push to the default branch runs the quality gate, including the job `distribution-hygiene` (its Sweep step). `do_check_dist_hygiene` extracts that step from the workflow and does not keep a second copy. `cancel-in-progress` on that gate is false. An API push does not run the client pre-push hook, so the hub must apply the same Sweep patterns before it commits. The CI job only reports a banned line after the commit is already on the trunk.
- Workflow 15 (gitleaks, full history) and workflow 64 (verified secret scan) run on every push to the default branch.

---

## Q1 — flow

**Answer.** Save writes an overlay object in the docs bucket and a row in a hub table `repo_doc_edits` in the same request. An in-hub worker, one per environment, claims the oldest queued row with a Postgres advisory lock and pushes. The save response does not wait for the host.

**Why.** The hub already has Postgres and always-on CPU, the bucket is what the app serves, and a second queue service is a new identity and a new failure domain for a few rows a day.

**What the user sees.** The header chip is `Saved · pushing`, then `Pushed · <sha7>`, then no chip once `tree.json` names a commit that contains the push. `Conflict · resolve` and `Not pushed · retry` are the two failures. Same-author edits of one path that are still queued fold into one commit (`superseded`). Two authors are two commits, so each author stays on their own commit.

**Risk.** A 200 means the overlay and the row both landed. If the row insert fails after the object write, the overlay is an orphan; a dated sweep deletes an overlay with no row. A worker that dies after creating the commit but before recording the sha must look for a commit that names the edit id before it creates another.

---

## Q2 — where it lands

**Answer.** Production pushes fast-forward only, straight onto the default branch, through the Git data API. Dev pushes only to a long-lived branch `docs-edit-dev` and never updates the default branch. No pull request, no force-push.

**Why.** The product rule for this repo is a direct push to the trunk. A pull request per save adds a review the owner did not ask for and makes the chip wait on the quality gate. Dev and production share one repo, so a dev proof must not move the trunk.

**Risk.** Every production doc commit still starts workflow 10 until a path skip exists, and workflow 10 does not cancel a running gate. Coalescing same-author saves bounds that, it does not remove it. The chip must not turn red because an unrelated job in that gate failed. Red on this edit means the docs-publish workflow failed, or a job that ran only because of this push failed. Inherited red is an ops note.

---

## Q3 — conflicts

**Answer.** No lock. Both saves are accepted. The worker three-way merges the editor's base blob, the current head, and the saved text. A clean merge is committed only after the merged bytes pass the same text gates as a save. A line conflict pushes nothing, keeps the overlay, and the editor saves again against the new head.

**Why.** Disjoint line edits should both land, and a silent overwrite of a lane commit on the trunk is worse than asking the editor to look. Markdown has no semantic merge; a clean diff is not a promise the two edits agree.

**Risk.** A clean merge can put back a line one editor deleted, or join two harmless halves into a banned string. Re-running the gates on the merged bytes is what stops the second case. The first case is a conflict the editor still has to notice; the chip says `merged with <sha7>` so it is visible.

---

## Q4 — author

**Answer.** The committer is always the GitHub App bot. The author is the editor's mapped name and email, else the name and email this repo's history already uses for that member's verified sign-in address, else the display name plus `<human_id>@users.noreply.<BASE_DOMAIN>`. The message is `docs: edit <path>` and a body that names the workspace and the edit id. No `Co-Authored-By:`, no generated-by line, no session URL.

**Why.** The owner asked for the editor as author and one system account as committer. The repo is public, so a private sign-in address must not become the author email. A member with no history cannot be blocked, or almost nobody could edit: the draft's count at `1f8e51a28` is one distinct author across the last 500 commits.

**Risk.** Agents hold `docs.write` today because that permission gates workspace docs. Reusing the permission alone would let an agent token push a repo doc with no human author. The repo-edit route accepts a member session only and refuses an agent token in v0.1. A later version may author an agent edit as the human who requested it.

---

## Q5 — who, which paths, abuse

**Answer.** A member whose role holds `docs.write`, and only in a workspace an operator has switched on. The switch is off by default. Editable paths are the paths `do_publish_docs` would publish, plus a new `.md` file under an already editable directory, minus the deny list below. Create is allowed. Delete and rename are not in v0.1. Cap 1 MiB. Rate 30 saves per member per hour and 300 per environment per day. Hygiene patterns and a secret scan run on the new lines before anything is written. A hit is 422 and writes neither the object nor the row.

**Deny list.**

| prefix or name | why |
|---|---|
| `CLAUDE.md`, `GEMINI.md`, `AGENTS.md` anywhere | agent instructions; the publish already skips them |
| `csi-spl-wui/**` | workflow 30: a WUI build, deploy, and version mint |
| `csi-spl-api/src/go/**` | workflow 20's glob is every file under that tree, including `.md` |
| `csi-spl-rdb/src/sql/postgres/spool-hub/**` and `spool-hub-roles/**` | workflow 20: a hub deploy |
| `.github/**` | workflow files and their docs |
| `csi-spl-doc/specs/*/tasks.md` | lane checklists with shas; not a document an end user should move |
| anything `ValidDocsPath` rejects | same door as the read route |

**Why.** "Every end user" is every `docs.write` member, and that set is already wider than admins (`regular_user` and `biz_customer` included). The docs bucket and the repo are one per environment, shared by every workspace, and the repo is public. The workspace switch is what keeps a customer or demo workspace from writing the product repo. The role table is not.

**Risk.** On a switched-on workspace, any regular member can change a public spec. That is the owner's "any md", and it is the abuse that remains after the deny list. The audit row (who, workspace, path, base blob, result sha) plus a revert-by-a-new-edit is the recovery. No force-push.

---

## Q6 — bucket and repo

**Answer.** The main object stays a mirror of the published commit. The save writes `.edits/<path>/<edit_id>.md`. `GET /v1/docs/<path>` returns the newest overlay whose row is queued, pushing, pushed, or conflict; otherwise the main object. A new workflow publishes with `do_publish_docs` and does not build or mint a version. Its path filter is the editable prefixes, not every `*.md`. When `tree.json`'s sha contains the edit's commit, the row is published and the overlay is deleted.

**Why.** `rsync --delete-unmatched` on a WUI deploy of an older sha would erase a main-key write that is not on that sha yet. An overlay whose key fails `ValidDocsPath` (a leading dot) is not a key the publish mirrors. Readers still see the saved text, which is the "bucket first" rule, without a second writer of the main keys.

**Risk.** A path filter of `**/*.md` races workflow 30 whenever a push contains both a WUI file and a markdown file, or any markdown file under `csi-spl-wui/**`: two publishes, both deleting unmatched objects. Limiting the new workflow to the editable prefixes removes that race. Until dev's publish is pointed at `docs-edit-dev`, a dev overlay stays until the dated sweep; dev readers keep seeing it through the hub, which is the point of the overlay.

---

## Q7 — secret and infra

**Answer.** One GitHub App, installed on this repo only, permission contents write and metadata read. The hub signs a short-lived JWT and exchanges it for a one-hour installation token per batch. The private key is one secret per environment, name `spool-hub-github-app-key`, read by the hub runtime service account as an environment variable from the secret store. The app id and the installation id are configuration, not secrets. Terraform adds the secret container and the accessor grant and does not store a secret version. The value is inserted out of band by a named action that shreds the local file. Dev (branch `docs-edit-dev`) is proved before production (default branch) is switched on.

**Why.** A personal access token is long-lived and belongs to a user account. A deploy key needs a clone inside the hub image and does not expire. The App token lasts one hour and is scoped to one repo. The repo rule is that a key is never in git, configuration values, terraform state, or a log.

**Risk.** A missing or revoked key fails every push as permanent until the named rotate action runs and the failed rows are retried. Both environments must not be allowed to fast-forward the default branch; the dev target is the control that prevents that.

---

## Scores

The design above, after the review changes. 1 is poor, 5 is strong.

| axis | score | why |
|---|---|---|
| simple | 4 | One table, one worker, one overlay prefix, a fast-forward push. The new publish workflow and the author tables are the extra parts, and each replaces a race or a leaked email. |
| safe | 4 | The key stays in the secret store, the workspace switch defaults off, deploy-input prefixes and agent-instruction files are denied, and the text gates run before a write. A switched-on workspace still lets every `docs.write` member edit a public spec, which is the ask. |
| robust | 4 | Fast-forward only, a three-way merge re-checked by the text gates, a stuck `pushing` row reclaimed without a second commit. A bad commit that did land is undone by a new edit, not by rewriting the branch. |
| fast | 5 | The save returns when the overlay and the row are written. The host call, the publish, and the quality gate are off that request. |

The draft at `6f91653fb`, scored as written, before the replacements below:

| axis | score | why |
|---|---|---|
| simple | 4 | Same shape. The picture in §2 is one path a reader can follow. |
| safe | 3 | §9 and the workspace switch are right. §5 does not deny the workflow 20 prefixes, and §1.1 describes `docs.write` as a shorter role list than `rbac.go`. |
| robust | 4 | §8 and §11 cover the races that matter. The merged text is not passed back through the §5 gates. |
| fast | 5 | The 200 is the bucket write plus the insert. GitHub is the worker's problem. |

---

## Review of spec.md 6f91653fb28477d47f0dc8c294e7013c1b60b539

Present on `origin/master` at `2026-10-06T09:26:57Z` (`git ls-tree` of `csi-spl-doc/specs/075-docs-section/repo-edit/spec.md`). I had started from "overwrite the main object, batch commits onto one branch, refuse every prose merge". The draft is the better design on those three points: the overlay survives a republish (§7), a direct fast-forward matches the trunk rule (§6), and a three-way merge lets disjoint edits both land (§8). The replacements below are the places I would still change a named section.

### Q1 — agree with §3

The table, the advisory lock, same-author coalesce, and the chip names are the queue. No replacement.

### Q2 — agree with the target in §6, replace two sentences

Agree: production target is the default branch, fast-forward only; dev target is `docs-edit-dev`; a pull request per edit stays the rejected alternative in §6.1.

Replace the §1.1 cell "Workflow 20 (hub) runs only on its allow-list; no `.md` path is in it". The allow-list entry is `csi-spl-api/src/go/**` (`.github/workflows/20_hub-build-deploy.yml` line 49), which matches a markdown file, and the SQL prefixes on the following lines match one too.

Replace the §11 row "CI red on the pushed doc commit → master red → editor and ops told". The editor's chip stays `Pushed` unless the failure is the docs-publish workflow or a job that this push alone caused. An inherited red on workflow 10 is an ops note. Otherwise every doc save looks failed while the trunk is already red for another reason.

### Q3 — agree with §8, add one gate

Agree: no lock, FIFO, three-way merge, conflict keeps the overlay, no conflict-copy file in the repo.

Add to the clean-merge bullet: the worker runs the §5 text gates on the merged bytes and, on a hit, stores `conflict` and does not update the ref.

### Q4 — agree with §4, name the door

Agree: mapping row, then history match on the verified sign-in address, then display name and the noreply address on `<BASE_DOMAIN>`. Agree agents do not edit repo docs in v0.1. Agree the message carries no AI trailer.

Replace the §10 API row "member, `docs.write`" with "member session, `docs.write`, agent token refused". `pure_agent` holds `docs.write` for workspace docs (`rbac.go`). The permission alone does not express §4.

### Q5 — agree with the switch, fix the role sentence and the deny list

Agree: `repo_docs_edit` off until an operator enables the workspace (§5, O1 option a). Agree: 1 MiB, 30 per member per hour, 300 per environment per day, gates before the write, no delete or rename in v0.1, `tasks.md` denied.

Replace the §1.1 cell that lists `docs.write` as "admin, product owner, developer, tester roles and to agents". `Defaults` also grants it to the biz owner, biz customer, and regular user. `demo_user` does not have it. The workspace switch is doing the real bounding; the sentence as written understates who can write once the switch is on.

Add to the §5 deny table the two workflow 20 prefixes in Q5 above (`csi-spl-api/src/go/**`, and the two `spool-hub` SQL prefixes).

Agree that the pattern list is the Sweep step of workflow 10's `distribution-hygiene` job. `do_check_dist_hygiene` reads that step out of the workflow. The hub running those patterns before the write is what keeps a banned line off the trunk; the job itself runs only after the push.

### Q6 — agree with §7, narrow the new workflow's paths

Agree: overlay under `.edits/`, GET prefers it, publish owns the main keys, workflow 30 is not the republish.

Replace §7 step 3's path filter `**/*.md` with the editable prefixes from §5. A glob of every markdown file also matches `csi-spl-wui/**/*.md`, which is a workflow 30 push, so two `do_publish_docs` runs would `rsync --delete` the same bucket.

### Q7 — agree with §9

Agree: GitHub App, one secret `spool-hub-github-app-key`, app id and installation id in configuration, no secret version in terraform, named put and rotate actions, dev branch before the production switch. No replacement.
