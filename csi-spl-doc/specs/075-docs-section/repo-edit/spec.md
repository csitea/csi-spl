# 075 Phase 1b: editable Repo Docs, saved to the docs bucket, pushed to git asynchronously

**Feature ID**: `075-docs-section/repo-edit` · **Milestone**: M3 · **Status**: Decided (v0.3, the owner's answers O1-O9 recorded, §14); build plan in [`tasks.md`](tasks.md)
**Created**: 2026-10-06 · **Lane**: c-380 (spec author v0.1-v0.2, claude), c-388 (v0.3) · **Panel**: g-381 (grok), a-382 (agy)
**Topic**: t1 `2e20d6d4-16b7-4be2-b7d7-45c4f1fbf56e`
**Authority**: this file for the behaviour of editing Repo Docs; [`../spec.md`](../spec.md) for the Docs section as a whole. Panel record: [`consensus.md`](consensus.md); the panel's opinions: [`grok-opinion.md`](grok-opinion.md), [`agy-opinion.md`](agy-opinion.md). The owner's answers (§14) override the panel where they differ. Docs only: this spec builds nothing (`../../README.md` §2.4); [`tasks.md`](tasks.md) is the build.

Builds on, and does not repeat:
- [075 the Docs section](../spec.md): §3 Phase 1 (Repo Docs, read-only) and §4.5 (workspace docs history).
- [044 open source](../../044-spool-open-source/spec.md): the repo is public; every pushed edit, and its author line, is public.
- [025 workspace RBAC](../../025-spool-tenant-rbac/spec.md): `docs.write` is the permission reused here.

`<BASE_DOMAIN>`, `<env>`, `<human_id>`, `<workspace>`, `<app-slug>`, `<agent_id>` are placeholders. User-facing text says **workspace**; **tenant** appears only where an existing code identifier is cited.

---

## 1. Why and The Owner's Ask

Owner HUM-10, prd t1 topic `2e20d6d4`, verbatim, in order:

1. msg `100bc0a2`: "enable the editing of docs from the github repo on the workspace and pushing them to the github repo"
2. msg `6ebd86b6`: "so the end users must be able to edit any md docs and save them into the s3 , but also this will trigger asynchronos git push with the some system account to github and set the author as the user names of this repo"
3. msg `d968b50a`: "we need first a better multi-type agent , multi-agent specification on how this exactly will work"
4. msgs `e7efcb67` + `f4142409`: the answers to O1-O9 (§14).

What the asks decide:

| # | decided | from |
|---|---|---|
| D1 | WHO: every end user of every workspace, and agents on behalf of their requester | 6ebd86b6 "the end users"; O1, O4 |
| D2 | WHAT: any published `.md` doc minus the deny list of §5.2 | 6ebd86b6 "any md docs"; O9 |
| D3 | SAVE: to the docs bucket first ("s3" = GCS here, as 075 §1 resolved) | 6ebd86b6 "save them into the s3" |
| D4 | THEN: an ASYNC git push to GitHub by ONE system account (the committer), to master, from dev and prd alike | 6ebd86b6 "asynchronos git push with the some system account"; O2, O7 |
| D5 | AUTHOR: the editing person, as this repo's history names them, else their own sign-in email | 6ebd86b6 "set the author as the user names of this repo"; O3 |

This reverses 075 §10's "Direct bidirectional Git push from browser to GitHub repository" non-goal for Repo Docs only. The browser still never talks to GitHub: the hub does, as the system account.

### 1.1 What the code does today (read 2026-10-06 at `7f67bb604`)

| fact | where |
|---|---|
| Repo Docs are read-only: one route, `GET /v1/docs/{path...}`, any signed-in member | `csi-spl-api/src/go/spool-hub-api/internal/hub/docs.go` |
| A doc key must match `ValidDocsPath` (segments of `[A-Za-z0-9._-]`, no leading dot, `.md`, <= 512 chars) | `docs.go` |
| The env's docs bucket (iac step `051-gcs-docs`) is filled ONLY by `do_publish_docs`, a step of the WUI deploy (workflow 30); it mirrors `git ls-files '*.md'` at the deployed sha (deleting objects no longer in the repo) and writes `tree.json` `{v, sha, files:[{path,title}]}` | `csi-spl-orc/src/bash/run/publish-docs.func.sh` |
| Skipped by the publish: `CLAUDE.md`, `GEMINI.md`, `AGENTS.md`, `node_modules/`, `tpl-gen/`, `bin/`, the WUI's built help copy `csi-spl-wui/src/public/help-md/` | `publish-docs.func.sh` `spl_docs_stage` |
| Workflow 30 runs only on its path allow-list (`csi-spl-wui/**`, the publish script, ...): a commit touching only `csi-spl-doc/**` does NOT republish | `.github/workflows/30_wui-build-deploy.yml` |
| Workflow 20 (hub) runs only on its allow-list, but `csi-spl-api/src/go/**` and the two `csi-spl-rdb/src/sql/postgres/spool-hub*/**` prefixes match a `.md` too: a doc there deploys the hub (g-381) | `.github/workflows/20_hub-build-deploy.yml` |
| Workflow 50 (OSS standalone) runs on `csi-spl-api/**`, `csi-spl-wui/**`, `csi-spl-rdb/**`; 65 and 70 on `csi-spl-iac/src/terraform/**`; 85 on `.github/workflows/**` | `.github/workflows/50_*.yml`, `65_*`, `70_*`, `85_*` |
| Workflows 10 (CI quality), 15 (gitleaks) and 64 (trufflehog) run on EVERY push to master, no path filter | `.github/workflows/10_ci-quality.yml`, `15_*`, `64_*` |
| `csi-spl-doc/doc/help/` is the SOURCE of the WUI's `/help`; `csi-spl-wui/src/public/help-md/` is its copy, and `tests/unit/help-sync.test.mjs` (workflow 10) fails while the two differ | `csi-spl-wui/src/node/help/sync-help.mjs` |
| Workspace Docs (075 Phase 2) are editable: `PUT/DELETE /v1/workspace/docs/{path}`, `docs.write`, 1 MiB cap, no lock, last save wins, every write also kept under `.history/` (owner `15134701`: "no need for ultra high level ACID Like doc locking mechanisms"); agents write them with a box upload token (owner `b60bf417`: "people and agents, or people via agents") | `internal/hub/workspace_docs.go` |
| `docs.write` is on every default role except `demo_user`, and on `pure_agent` (g-381) | `internal/rbac/rbac.go` `Defaults` |
| The hub does not record which member an agent works for: `agent_join_tokens.for_human` (rdb 0119) is the only seat-to-member link, and no Go code reads it | `grep -rn 'for_human\|ForHuman' csi-spl-api/src/go --include='*.go' \| grep -v _test` -> 0 |
| The publish upload is `gcloud storage rsync --delete-unmatched-destination-objects`: today it deletes EVERY bucket object the stage lacks, a dot-prefixed one included | `publish-docs.func.sh` `spl_docs_upload` |
| The hub reads secrets as env vars from Secret Manager (`secret_environment_variables` -> `secret_key_ref`), and its CPU is always allocated (`cpu_idle = false`), so a background worker in the hub runs between requests | `csi-spl-iac/src/terraform/030-cloud-run-hub/04-cloud-run-service.tf` |
| The repo holds 580 tracked `.md`; 542 of them pass the publish filter; the largest is ~96 KB | `git ls-files '*.md' \| wc -l` -> 580; the `spl_docs_stage` filter over that list -> 542 |
| The last 500 commits carry ONE author identity | `git log -500 --format='%an <%ae>' \| sort -u \| wc -l` -> 1 |
| `do_put_github_app_key` does not exist yet | `grep -rn do_put_github_app_key --include='*.sh' .` -> 0 |

---

## 2. The design in one picture

```
 WUI /docs/repo/<path>  [Edit] -> editor -> (first save only: author notice §4.2) -> [Save]
 or an agent:  the same PUT + X-Spool-Requester: <human_id>
        │  PUT /v1/docs/<path>   body = markdown, If-Match: <base blob sha>
        ▼
 HUB of <env> (dev or prd; member session or agent token, docs.write)
   1. validate: path = published .md minus deny list (§5.2), size, rate, hygiene + secret scan
   2. write gs://<docs bucket>/.edits/<path>/<edit_id>.md        (D3: saved)
   3. INSERT repo_doc_edits row, status = queued                  (same request)
   4. 200 {edit_id, status:"queued"}  -> the doc shows "Saved · pushing"
        │
        ▼  (async, in-hub worker, one per env, after the coalescing window §3)
 WORKER  claim oldest due queued row (FOR UPDATE SKIP LOCKED)
   5. GitHub App installation token (secret: Secret Manager, §9)
   6. read <path> at master -> head blob sha
        same as base  -> commit as is
        moved         -> 3-way merge (base, head, edit): clean -> commit merged
                                                       conflict -> status conflict, stop
   7. Git Data API: blob -> tree -> commit (author = §4, committer = the App,
      subject "docs: edit <path>" on prd, "docs(dev): edit <path>" on dev)
      -> update master, fast-forward only (never force): the ref is the lock
         between the dev and the prd worker (§6.2)
   8. status = pushed, commit sha recorded  -> the doc shows "Pushed · <sha7>"
        │
        ▼
 CI: workflow 32_docs-publish (new, **/*.md minus csi-spl-wui/**, no build, no version)
   9. do_publish_docs for dev then prd -> each env's main keys + tree.json now hold master
  10. each env's worker drops its .edits overlay once its tree.json.sha contains the commit
```

Readers always see the newest saved text: `GET /v1/docs/<path>` serves the newest unlanded overlay (`.edits/<path>/...`) when one exists, else the published object.

---

## 3. Q1: the flow, the queue, and the cost control

**Decided**: a hub Postgres table `repo_doc_edits` is the queue; an in-hub worker goroutine drains it.

- **Queue**: one row per save (data model §10). Written in the same request as the bucket write, so a 200 means both the text is in the bucket and the push is owed.
- **Who pushes**: the hub, in a worker goroutine started with the server. Only one worker per env runs at a time: it takes `pg_try_advisory_lock(<repo_edit lock id>)`; a second hub instance of the same env idles. Cloud Run keeps CPU between requests (`cpu_idle = false`), so the goroutine runs. Wake-up: a `NOTIFY repo_doc_edits` on insert, the moment the earliest queued row falls due, plus a 30 s poll (5 s while a pushed edit waits for the publish, §7 step 4). Dev and prd have separate databases, so the two envs' workers never share this lock; master itself serialises them (§6.2).
- **Ordering**: FIFO by `created_at` per path; paths in parallel are not needed (volume is tiny). A `pushing` row is frozen: a save during it is a new `queued` row (a-382). Different authors are never coalesced: each gets its own commit and its own authorship.
- **Coalescing is one cost control; the express docs lane of workflow 10 is the other.** O6 ("no `.md` fast path, coalescing is enough") is REVERSED by the newer owner order (owner, t1 `a477c187`, msgs `50a349f4` "could we have a bypass lane for those purely doc changes as they should not brake anything in the code" and `31e00aee` "some kind of express docs edit lane for them , also integrated in the CICD"): a push whose every changed path is a `.md` outside `csi-spl-wui/**` and `.github/**` skips workflow 10's code jobs (classifier `csi-spl-orc/src/bash/scripts/ci-doc-only.sh`, by files, never by author; it fails safe to the full gate). Every pushed commit still costs a run of workflow 10's classify + hygiene jobs plus 15, 64 and 32 (§6), so the number of commits still matters:
  - A row becomes due `coalesce_after` (cnf, default **15 s**; 120 s before 2026-10-07) after it was saved: `next_try_at = created_at + coalesce_after`. A further save of the SAME path by the SAME author (and, for an agent, the same agent and requester) before that moment folds into it: the newest text wins, the earlier rows go `superseded`, and the window restarts from the newest save, capped at `coalesce_max` (cnf, default **10 min**) after the first save of the run, so a member typing for an hour still lands.
  - So a member who saves ten times within 15 s of each other costs one commit and one CI run.
  - The daily caps of §5.1 bound the worst case: at most 300 commits a day on prd, 50 on dev.
  - **No `[skip ci]`** in the commit message: it would skip every workflow, the docs-publish and the secret scans included.
- **Retries**: transient errors (GitHub 5xx, 429, network, ref moved during update) retry with backoff 30 s, 1 m, 2 m, 5 m, 10 m, 30 m, 1 h (7 tries, ~2 h); then `failed`. Permanent errors (403 permission, 422 validation, path now denied) go `failed` at once. The editor, the agent's requester, or an admin may `retry` a `failed` row.
- **What the user sees**: a status chip on the doc header and in "My edits" (a requester sees the edits their agents made there too):

| status | chip | meaning |
|---|---|---|
| `queued` | Saved · pushing | in the bucket, push owed (inside the coalescing window or waiting) |
| `pushing` | Saved · pushing | worker holds it |
| `pushed` | Pushed · `<sha7>` (link to the commit) | on master |
| `published` | (no chip) | `tree.json` holds a sha containing the commit; overlay gone |
| `conflict` | Conflict · resolve | master changed the same lines; nothing pushed |
| `failed` | Not pushed · retry | after the retries, with the reason |
| `superseded` | (no chip) | folded into a later edit's commit |

**Rejected**:
- *Cloud Tasks / Pub/Sub*: a new GCP service, IAM and terraform step for a queue of a few rows a day; the DB is already there.
- *A GitHub Actions workflow per save* (`repository_dispatch` carrying the text): moves user text through workflow logs and inputs, and the Actions token cannot set the per-user author cleanly.
- *Synchronous push in the save request*: violates D4 ("asynchronos"), and a GitHub outage would fail saves.
- *A journal file in the bucket*: no atomic claim; two instances would double-push.
- *A `.md`-only fast path in workflow 10*: first rejected by the owner (O6, "coalescing is enough"), then ORDERED by the owner (owner, t1 `a477c187`, msgs `50a349f4` "could we have a bypass lane for those purely doc changes as they should not brake anything in the code" and `31e00aee` "some kind of express docs edit lane for them , also integrated in the CICD"); built as the express docs lane of workflow 10 (§3).

---

## 4. Q4: author mapping

**Decided**: author = the editing person (for an agent: its requester), resolved in this order; committer = the GitHub App's bot identity.

### 4.1 The resolution order

1. **A mapping row** in `repo_doc_authors` (`human_id -> git_name, git_email`), set by a workspace admin, or by the member themself after verifying the email. This is how a member who already appears in this repo's history gets EXACTLY that identity (D5: "the user names of this repo"), and how a member who does not want their sign-in email in public history picks another verified address.
2. **The member's verified sign-in email matches an author email in this repo's history** (the worker reads `.mailmap` + `git log` authors once a day into `repo_doc_known_authors`): that name and email, as the history has them.
3. **Otherwise** (no history: today every member but one): the member's **display name and their own sign-in email** (owner O3). A member whose sign-in email is not verified cannot save (403 `email_unverified`): an unverified address must never be published as someone's authorship.

The author is resolved at save and stored on the row (`author_name`, `author_email`, `author_source`), so a later mapping change never rewrites who wrote a queued edit.

### 4.2 The sign-in email becomes public: the one-time notice

The repo is public (044). An author email in a pushed commit is readable by anyone, forever: a later edit cannot remove it from history, and history is never rewritten (repo rule). The author line lives in commit METADATA, not in a file, so the distribution-hygiene sweep (`do_check_dist_hygiene`, file content only) neither sees nor blocks it; this is the carve-out the repo's own rules make for real authorship.

So the editor MUST show the member, **before their first save**, the exact identity that will be published, and the save waits for their consent:

- The hub answers a save from a member with no matching consent row `428 author_notice_required` with `{git_name, git_email, author_source}`; the WUI shows the notice, and on **I understand, save** it calls `POST /v1/docs/author-notice` (records `repo_doc_author_notices`) and repeats the save. Nothing is written to the bucket or the queue before the consent.
- The consent is per member and per published identity: if the resolved name or email later changes (a mapping row, a changed sign-in email), the notice is shown again.
- The notice text (i18n key `docs.repoEdit.authorNotice`, all 19 locales):

> **Your edit will be public, with your name and email**
>
> Saved edits are pushed to this product's public GitHub repository. Git records you as the author:
>
> **{git_name} &lt;{git_email}&gt;**
>
> Anyone can read this name and email address in the repository history, and it cannot be removed later.
> To publish under a different verified address, ask a workspace admin to set your author identity before you save.
>
> [Cancel] [I understand, save]

- For an agent's edit, the notice is the REQUESTER's: an agent's save for a requester without a consent row gets `428 author_notice_required`, and the requester gives consent once in the WUI (Docs -> My edits shows the notice); the agent's error names that step.

### 4.3 Agents (owner O4: "yes, authored as the agent's requester")

- An agent edits Repo Docs with its token (a box upload token, as for Workspace Docs), because `pure_agent` holds `docs.write`, and it names its requester: `X-Spool-Requester: <human_id>`.
- The hub accepts the requester only if (a) they are an active member of the agent's workspace, (b) their role holds `docs.write`, (c) their sign-in email is verified, (d) they have not switched agent edits off (`repo_doc_authors.allow_agents`, default true), and (e) when the agent's seat was made by a join token with `for_human` set (rdb 0119), the header equals it. Otherwise 403 `requester_invalid`; no header: 403 `requester_required`.
- Author = the requester (§4.1 applied to them). The commit body names the agent: `Edited by agent <agent_id> for <git_name>.` The row stores `actor_kind = 'agent'`, `agent_id`, and the requester as `human_id`.
- Rate limits count against the requester AND the agent (§5.1). The requester sees the edit in "My edits" and is the one who may retry it or resolve its conflict.
- Known limit: for a seat made WITHOUT a join token's `for_human`, the hub cannot prove the requester asked; it proves only that the requester could have made the edit themself. Every agent edit is therefore audited with the agent id, the seat and the requester, and the requester can switch agent edits off for themself.

### 4.4 Committer and message

- **Committer**: `<app-slug>[bot]` and its noreply address, fixed. GitHub shows "<author> committed with <app-slug>[bot]".
- **Subject**: `docs: edit <path>` on prd; `docs(dev): edit <path>` on dev (§6.2). **Body**: `Edited in the Docs section of workspace <workspace> (<env>). Edit <edit_id>.`, plus the agent line of §4.3 when an agent made it. **No `Co-Authored-By:`, no `Generated with`, no session URL, no other AI trailer** (the repo's leak-gate rule).
- The repo's CLAUDE.md rule that commits carry one canonical address governs lanes' own commits, not members' edits through this feature: members are a different person each.

**Rejected**:
- *Every commit authored by the system account, the user named in the message*: loses D5 outright.
- *A noreply address of the product domain for members with no history*: the owner chose the sign-in email (O3); the notice of §4.2 is the safeguard instead.
- *Only members already in history may edit*: contradicts D1 (one author today).
- *Agents author their own commits*: the owner chose the requester (O4).

---

## 5. Q5: permissions, editable paths, abuse

### 5.1 Who, and the abuse limits

**Decided** (owner O1, "every workspace"): any member of ANY workspace on the env whose role holds `docs.write` (every default role but `demo_user`), from a session, and any agent of such a workspace for a valid requester (§4.3). There is no per-workspace switch. The env-wide switch `env.docs.repo_edit.enabled` (cnf) stays: it is the kill switch, not an access list.

Because every workspace can now write the product's public repo, the abuse limits carry the safety the switch used to:

- **Verified sign-in email** required for the author (§4.1); a member cannot save in their first `min_member_age` (cnf, default 24 h) in the workspace.
- **Rate**: 30 saves per member per hour (agent edits count to the requester), 60 per agent per hour, 100 per workspace per day, 300 per env per day on prd and 50 on dev; over any: 429 `rate_limited`, nothing written. Coalescing (§3) makes the commit count lower than the save count.
- **Size**: 1 MiB per doc (the workspace docs cap, 10x the largest repo doc).
- **Text gates in the hub, before the bucket write** (the push bypasses the developer pre-push hook, so the hub runs the cheap gates itself):
  - the distribution-hygiene sweep's patterns (the same list `do_check_dist_hygiene` reads, baked into the hub image at build) on the NEW lines only;
  - a secret scan: PEM private-key blocks, cloud key JSON (`"private_key"`), common token prefixes. A hit: 422 `rejected_text` naming the rule and line, nothing written.
- **Operator brake**: cnf `env.docs.repo_edit.blocked_workspaces` (empty by default) refuses saves from a listed workspace with 403 `workspace_blocked`; ops adds a workspace there after abuse.
- **Audit**: the `repo_doc_edits` row (who, agent, workspace, path, base, result sha) plus one hub audit event per save and per push (`audit.read` shows them); the bucket overlay object is kept 30 days after publish.
- **Undo**: any member with the permission opens the doc's git history link; a bad edit is reverted by a new edit, never by a force-push.

### 5.2 What: the editable set and the deny list (owner O9)

**Decided**: the editable set = **every published `.md`** (the env's `tree.json`; 542 at `7f67bb604`) **minus the deny list below**, plus a NEW `.md` in a directory that already holds an editable doc. Measured on `7f67bb604`: 173 tracked `.md` match the deny list and **407 are editable**: 393 under `csi-spl-doc/`, the five root docs, and nine READMEs and runbooks under `csi-spl-orc/`, `csi-spl-iac/`, `csi-spl-dat/` and `csi-spl-utl/`.

How each count was measured (repo root; `$D` = the alternation of every row's regex):

```
git ls-files '*.md' | grep -cE '<row regex>'
git ls-files '*.md' | grep -vcE "$D"
git ls-files '*.md' | grep -vE "$D" | grep -c '^csi-spl-doc/'
```

The last two print 407 and 393.

| # | denied (glob) | regex | n | why |
|---|---|---|---|---|
| 1 | `**/CLAUDE.md`, `**/GEMINI.md`, `**/AGENTS.md` | `(^\|/)(CLAUDE\|GEMINI\|AGENTS)\.md$` | 1 | agent instructions: a prompt-injection door into every agent of the fleet; not published |
| 2 | any path with a segment starting with a dot (`.github/**`, `csi-spl-doc/.specify/**`, `.edits/`, `.history/`) | `(^\|/)\.` | 15 | `ValidDocsPath` refuses them; `.github/workflows/**` fires workflow 85 and holds CI |
| 3 | `csi-spl-wui/**` | `^csi-spl-wui/` | 24 | fires workflows 30 (a full WUI build, deploy and version mint) and 50; `src/public/help-md/` is a generated copy |
| 4 | `csi-spl-api/**` | `^csi-spl-api/` | 1 | `src/go/**` fires workflow 20 (a hub deploy); the whole tree fires 50 |
| 5 | `csi-spl-rdb/**` | `^csi-spl-rdb/` | 1 | `spool-hub*/**` fires workflow 20; the whole tree fires 50 |
| 6 | `csi-spl-cnf/**` | `^csi-spl-cnf/` | 2 | the cnf tree: the env's single source of truth and the home of the secret ids; its env files fire 20 and 30 |
| 7 | `csi-spl-iac/src/terraform/**` | `^csi-spl-iac/src/terraform/` | 1 | fires workflows 65 (checkov) and 70 (supply chain); infra is owner-governed |
| 8 | `csi-spl-orc/src/bash/features/*/assets/**`, `**/*.tpl.md` | `^csi-spl-orc/src/bash/features/[^/]+/assets/\|\.tpl\.md$` | 23 | agent skills, slash commands, CLAUDE.md fragments and brief templates installed into every agent: the same door as row 1 |
| 9 | `csi-spl-doc/doc/md/lane-integration-rules.md` | `^csi-spl-doc/doc/md/lane-integration-rules\.md$` | 1 | named in every agent's seed prompt (`spawn-core.inc.sh`): agent instructions |
| 10 | `csi-spl-doc/doc/help/**` | `^csi-spl-doc/doc/help/` | 22 | the SOURCE of the WUI `/help` copy: an edit here reds `help-sync.test.mjs` on master until a lane regenerates the copy in `csi-spl-wui/`; `how-to-post.md` is also the agents' posting rule |
| 11 | `csi-spl-doc/specs/**/tasks.md` | `^csi-spl-doc/specs/.+/tasks\.md$` | 73 | build authority with shas and checks; edited by lanes |
| 12 | `**/tests/**`, `**/fixtures/**`, `**/testdata/**`, `**/*.fixture.md` | `/(tests\|fixtures\|testdata)/\|\.fixture\.md$` | 9 | test inputs: an edit reds a suite |
| 13 | `**/node_modules/**`, `tpl-gen/**`, `**/bin/**`, `**/secrets/**` | `(^\|/)(node_modules\|tpl-gen\|bin\|secrets)/` | 0 | generated or vendored trees, and any secrets dir: never published; denied in case one is ever tracked |
| 14 | anything `ValidDocsPath` refuses; anything not in the env's `tree.json` that is not a new file in an editable dir | - | - | the same rule as the read route |

Rows overlap (a `csi-spl-wui/**/tests/**` file counts in rows 3 and 12); the union is 173.

- The deny list lives in cnf (`env.docs.repo_edit.deny`, the globs above), read by the hub, so a change is a config change; a hub unit test pins one sample path per row.
- A doc that a test only reads by path, not by content (find them with `grep -rlF '<path>' --include='*.tst.sh' --include='*.test.mjs' --include='*_test.go'`; e.g. `csi-spl-doc/doc/md/csi-spl.feature.md` as a sample of the read route), stays editable. A red caused by an edit is handled as in §11.
- **New files and deletes**: create allowed in a directory that already holds an editable doc; delete and rename NOT in v0.1 (owner O5).

**Rejected**:
- *A per-workspace switch, default off*: the owner chose every workspace (O1); the limits above carry the safety.
- *Admins only*: contradicts D1.
- *An allow-list of `csi-spl-doc/**` + the root docs*: the owner chose the wider set (O9).

---

## 6. Q2: where the commit lands

**Decided** (owner O2 and O7): **master, directly, fast-forward only**, via the GitHub Git Data API, **from both envs**.

| env | target ref | subject |
|---|---|---|
| `prd` | `master` | `docs: edit <path>` |
| `dev` | `master` | `docs(dev): edit <path>` |

- **Pre-push hook**: client-side, so it never runs for an API push. Its cheap part that matters for a `.md` (dist hygiene) and a secret scan run in the hub (§5.1). CI (workflows 10, 15, 64) still runs on master for every pushed commit. The chip turns red only when the docs-publish workflow fails, or a job fails that ran because of this push; a red inherited from another push is an ops note, not the editor's failure (g-381). Never auto-reverted.
- **Deploy triggers**: with rows 2-7 of the deny list (§5.2), a doc commit fires workflows 10, 15, 64 and the new 32 only: no hub or WUI deploy, no version tag minted.
- **CI load**: workflow 10 per doc commit is the cost; coalescing (§3) and the express docs lane of workflow 10 (code jobs skipped for a doc-only push, newer owner order reversing O6, §3) are the controls.
- **Branch protection**: if master later requires PRs or status checks, the App is added as a bypass actor; if the owner prefers PRs, §6.1 is the switch.

### 6.1 Rejected alternatives
- *Branch + PR per edit, auto-merge on green*: adds 5-15 min per edit (CI) and a PR per save; contradicts the owner's "push directly to trunk, no PR" rule. Kept as cnf `mode: pr` for a future corporate install whose master is protected.
- *A `docs-edit-dev` branch for dev*: rejected by the owner (O7).
- *Force-push or ref update without fast-forward*: forbidden by the repo rules.

### 6.2 Dev writes master too: the risks and the mitigation

Dev and prd are two hubs with two databases, two buckets and two workers, writing ONE ref. What that creates, and what the design does about it:

| risk | what would happen | mitigation in this design |
|---|---|---|
| dev and prd race on master | both workers read head H, both build a commit on H, the second ref update is refused | the ref update is fast-forward only (`force: false`), so master is the lock: the loser gets 422, counts it transient, re-reads head and 3-way merges onto the winner (§8). Nothing is overwritten. A shared advisory lock is impossible (two databases) and not needed |
| the same doc edited on dev and prd at once | two commits on the same lines | the second merges cleanly or goes `conflict` for its editor (§8), exactly like two prd members |
| dev test edits land on trunk | a proof, an e2e or a demo edit reaches the public repo and every env | (a) automated tests never reach GitHub: e2e and CI run with `enabled=false` or with `env.docs.repo_edit.github_api` pointed at a fake GitHub; (b) every dev commit's subject is `docs(dev): ...`, so `git log --grep '^docs(dev):'` lists them, and a bad one is reverted by a new edit; (c) dev's env cap is 50 commits a day; (d) `demo_user` has no `docs.write`, so demo workspaces cannot write |
| dev runs newer, less proven hub code than prd | a dev bug writes bad bytes to master | fast-forward only, never force; the text gates run on the final bytes; one commit touches one file; `enabled=false` on dev stops dev alone |
| one env's publish overwrites the other's bucket | none: each env publishes its own bucket | workflow 32 publishes dev then prd from the same master sha; each worker reads its own `tree.json` |
| one person edits the same doc on dev and on prd | two commits, both theirs | intended: each is that env's own save |

---

## 7. Q6: the bucket <-> repo loop

**Decided**: the bucket's main keys stay a mirror of master; an edit lives in an **overlay** until master holds it and the publish has run.

1. Save writes `.edits/<path>/<edit_id>.md` (D3: the edit IS in the bucket). The overlay prefix starts with a dot, so the read route never serves it by key. **The publish deletes it today** (`rsync --delete-unmatched-destination-objects`, §1.1): the publish task adds an exclude of `^\.edits/` to `spl_docs_upload` (and the same skip to `do_docs_publish_none`) with a test, and the overlay does not ship before it.
2. `GET /v1/docs/<path>` serves the newest overlay of `<path>` whose row is `queued`, `pushing` or `pushed`, else the main key. A `conflict` is never served, not even to its editor: its base is a blob master moved past, so a save of that text conflicts again, for good (dev, 2026-10-07: one conflict born racing the other env's save pinned its editor's `X-Spool-Doc-Base`). The editor reads master's text and blob; their text is in the conflict view (§8). `tree.json` is merged with overlay-only (new) paths in the hub's answer.
3. After the push, a NEW workflow `32_docs-publish.yml` runs `do_publish_docs` for dev then prd: no build, no version mint, no new secret (the env project SA already publishes). Its `paths`: `'**/*.md'`, then `'!csi-spl-wui/**'` and `'!.github/**'` (a `csi-spl-wui/**` push is published by workflow 30). Two `rsync --delete` runs on one bucket must not overlap (g-381): workflow 32 and workflow 30's publish step share one concurrency group per env (`docs-publish-<env>`, `cancel-in-progress: false`).
4. The worker, on its poll, reads its env's `tree.json.sha`; equal to the edit's commit, or containing it (GitHub compare API: `ahead` or `identical`), the row goes `published` and the overlay is deleted. One compare call per NEW `tree.json.sha`, cached, never one per poll (a-382); `sha == commit` alone would miss a commit landing on top.
5. Dev and prd both publish master (§6), so both envs' overlays drop the same way.

Why overlay, not overwrite: a WUI deploy of an older sha in flight republishes and would silently overwrite a just-saved edit; the overlay cannot be clobbered.

**Rejected**:
- *Write the main key directly*: the race above; and the main key would disagree with master for an unbounded time after a `conflict`/`failed`.
- *Hub promotes the overlay into the main key itself*: two writers of the main keys (hub and publish), and the hub SA would need write on the whole bucket.
- *Rely on workflow 30 to republish*: it does not run for `csi-spl-doc/**`.

---

## 8. Q3: conflicts

**Decided**: optimistic, with a 3-way merge; refuse only a real line conflict.

- The editor opens a doc at `base` = the git blob sha of the text it shows (the publish adds `blob` per file to `tree.json`; an overlay records its own `base`). Save sends `If-Match: <base>`.
- **Two users, one file, in the app** (one env or both): both saves succeed (owner `15134701`: no heavy locking); each is its own row with its own base, pushed in strict FIFO order per env: B never uses A's unpushed overlay as its base; once A lands, B merges onto A's commit (a-382).
- **Master moved** (a lane pushed the same file, the other env's worker pushed, or the first user's edit landed): the worker 3-way merges `base`, `head`, `edit` (line diff3).
  - clean -> the §5.1 text gates run again on the MERGED bytes (two clean halves can join into a banned string; g-381): a hit is `conflict`, no ref update; else commit the merged text, author = the editor; the status says "merged with <sha7>".
  - conflict -> `conflict`; nothing pushed; the overlay stays; the editor gets a side-by-side (theirs / mine) view (`GET /v1/docs/edits/{id}/conflict`), edits, and saves again with `base = head`. Their text is never lost (overlay + row); the doc's own GET serves master meanwhile (§7 step 2).
- **Ref moved between read and update** (a push in the same second, often the other env): the fast-forward update fails 422; the worker re-reads and retries (counts as transient).

**Rejected**:
- *Last save wins on master* (overwrite head): silently reverts a lane's commit.
- *Conflict copy file* (`<doc>.conflict-<user>.md` committed): litters the public repo; nobody resolves them.
- *Lock a doc while one user edits*: contradicts owner `15134701`.

---

## 9. Q7: the GitHub identity, the secret, infra

**Decided**: a **GitHub App** installed on this one repo, permission `contents: write` (and `metadata: read`), nothing else. The owner said go (O8).

- **Tokens**: the hub signs a JWT with the App private key and exchanges it for a 1 h installation token, cached in memory for 50 min and never written to disk or a log (a-382). Nothing long-lived reaches GitHub.
- **Secret**: the App private key, one Secret Manager secret per env project, named `spool-hub-github-app-key`, exposed to the hub as env var `SPOOL_GITHUB_APP_KEY` through the existing `secret_environment_variables` map. App id and installation id are not secret: cnf `env.docs.repo_edit.github_app_id` / `installation_id`. The key never enters git, cnf, terraform state or a log. Dev and prd hold the SAME key (one App, one repo).
- **Terraform**: step `030-cloud-run-hub` gains the secret container and the accessor grant to the hub runtime SA (no secret version: the value is put out of band). As the env's project SA, never the owner account.
- **Out of band, named actions** (repo rule: nothing ad hoc): `do_put_github_app_key` (adds a secret version from the file the owner downloaded from GitHub; `ENV=dev` then `ENV=prd`; shreds the file only after the prd version is in) and `do_rotate_github_app_key` (new key in GitHub, new versions, hub roll, old key deleted in GitHub). Rotation yearly or on suspicion. **Neither exists yet** (`grep -rn do_put_github_app_key --include='*.sh' .` -> 0 on `7f67bb604`): they are build task T04 of [`tasks.md`](tasks.md).
- **Proof order**: dev first, then prd, each behind cnf `env.docs.repo_edit.enabled`; both target master.

### 9.1 The owner's steps on GitHub (O8)

Done once, by the owner, signed in to GitHub as an owner of the organisation that owns the repo. Nothing here is a secret until step 6.

1. Organisation **Settings** -> **Developer settings** -> **GitHub Apps** -> **New GitHub App**.
2. Fill in:
   - **GitHub App name**: the product name plus ` Docs` (its slug becomes `<app-slug>`, the committer `<app-slug>[bot]`).
   - **Homepage URL**: `https://<BASE_DOMAIN>`.
   - **Webhook**: untick **Active** (the hub never receives webhooks).
   - **Repository permissions**: **Contents: Read and write**; **Metadata: Read-only** (GitHub sets it). Every other permission: **No access**. No organisation or account permissions. No events.
   - **Where can this GitHub App be installed?**: **Only on this account**.
3. **Create GitHub App**. Note the **App ID** shown at the top of the App's page.
4. **Install App** (left menu) -> the organisation -> **Only select repositories** -> this repo only -> **Install**. Note the **installation id**: the number at the end of the page's URL (`.../installations/<id>`).
5. If master has a branch protection rule or ruleset, add the App to its bypass list (repo **Settings** -> **Rules**); with no protection, skip.
6. App page -> **Private keys** -> **Generate a private key**. GitHub downloads one `.pem` file. Leave it in the box user's `~/Downloads/`, and do NOT paste it anywhere else (no chat, no spool post, no git).
7. Tell the orchestrator in one spool post: "GitHub App done, App ID `<n>`, installation id `<n>`, key at `<path>`". The orchestrator then runs, as each env's project SA, `ENV=dev KEY_FILE=<path> ./run -a do_put_github_app_key` and `ENV=prd KEY_FILE=<path> ./run -a do_put_github_app_key` (the second shreds the file), and commits the two ids into cnf. The owner types no command (owner rule: an agreed infra step is run by the orchestrator).

**Rejected**:
- *A bot user account + fine-grained PAT*: a paid seat, a human-style account to guard, long-lived token, password + 2FA to own.
- *A deploy key (SSH)*: needs a git binary and a clone in the hub image; the key is long-lived and grants the whole repo; no API for merge/compare.
- *A GitHub Actions `GITHUB_TOKEN`*: lives only inside a workflow run (see §3 rejection).

---

## 10. Data model

```sql
-- hub DB (spool_hub owner migrates; spool_hub_rt does DML). Tenant column for RLS + audit.
CREATE TABLE repo_doc_edits (
  edit_id        uuid PRIMARY KEY,
  tenant_id      text NOT NULL,               -- the editor's workspace (RLS)
  human_id       text NOT NULL,               -- the member, or the agent's requester (§4.3)
  actor_kind     text NOT NULL CHECK (actor_kind IN ('member','agent')),
  agent_id       text,                        -- set iff actor_kind = 'agent'
  path           text NOT NULL,               -- ValidDocsPath, editable (§5.2)
  base_blob      text NOT NULL,               -- git blob sha the editor started from
  overlay_key    text NOT NULL,               -- .edits/<path>/<edit_id>.md
  text_sha256    text NOT NULL,
  author_name    text NOT NULL,               -- resolved at save (§4.1)
  author_email   text NOT NULL,
  author_source  text NOT NULL CHECK (author_source IN ('mapping','history','signin')),
  target_ref     text NOT NULL DEFAULT 'master',
  status         text NOT NULL CHECK (status IN
                 ('queued','pushing','pushed','published','conflict','failed','superseded')),
  tries          int  NOT NULL DEFAULT 0,
  next_try_at    timestamptz NOT NULL,        -- created_at + coalesce_after (§3)
  first_saved_at timestamptz NOT NULL,        -- start of the coalescing run, for coalesce_max
  last_error     text,
  commit_sha     text,
  merged_with    text,                        -- head sha when a 3-way merge was needed
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CHECK ((actor_kind = 'agent') = (agent_id IS NOT NULL))
);
CREATE INDEX ON repo_doc_edits (status, next_try_at);
CREATE INDEX ON repo_doc_edits (path, created_at);
CREATE INDEX ON repo_doc_edits (tenant_id, human_id, created_at);  -- rate limits, "My edits"

CREATE TABLE repo_doc_authors (            -- §4.1 rule 1, §4.3 opt-out
  tenant_id text NOT NULL, human_id text NOT NULL,
  git_name text NOT NULL, git_email text NOT NULL, verified_at timestamptz,
  allow_agents boolean NOT NULL DEFAULT true,
  PRIMARY KEY (tenant_id, human_id)
);
CREATE TABLE repo_doc_author_notices (     -- §4.2 consent, one per published identity
  tenant_id text NOT NULL, human_id text NOT NULL,
  git_name text NOT NULL, git_email text NOT NULL,
  acked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, human_id, git_email, git_name)
);
CREATE TABLE repo_doc_known_authors (      -- §4.1 rule 2, refreshed daily from history
  git_email text PRIMARY KEY, git_name text NOT NULL, seen_at timestamptz NOT NULL
);
```

The env is not a column: each env has its own database. The worker reads the queue across workspaces (it is the env's one pusher): it runs `asOperator`; the tenant tables carry the RLS `NULLIF` policy like every tenant table, and each new tenant table gets its tenant-isolation test and its `seedTenantAll` seed.

API:

| route | who | answer |
|---|---|---|
| `PUT /v1/docs/{path}` (`If-Match: <base>`; agent: `X-Spool-Requester`) | member with `docs.write`, or an agent for a valid requester (§4.3) | 200 `{edit_id, status}`; 403 (`email_unverified`, `requester_required`, `requester_invalid`, `workspace_blocked`, path denied) / 409 base unknown / 413 / 422 rejected text / 428 `author_notice_required` / 429 |
| `POST /v1/docs/author-notice` (`{git_name, git_email}`) | the member (session only) | 204; records the consent of §4.2 |
| `GET /v1/docs/{path}` | member | overlay or main; headers `X-Spool-Doc-Base`, `X-Spool-Doc-Edit` |
| `GET /v1/docs/edits?mine=1\|path=` | member | rows, newest first; `mine` includes their agents' edits |
| `POST /v1/docs/edits/{id}/retry` | the editor, the requester, or an admin | 202 |
| `GET /v1/docs/edits/{id}/conflict` | the editor or the requester | `{base, theirs, mine}` |

---

## 11. Failure modes

| failure | effect | recovery |
|---|---|---|
| bucket write fails | 503, no row, nothing owed | user saves again |
| row insert fails after the bucket write | 503; an orphan overlay | 30-day sweep deletes overlays with no row |
| GitHub down / 5xx / 429 | stays `queued`, backoff | automatic, then `failed` + retry button |
| App key missing or revoked | every push 401 -> `failed` (permanent) | ops alert; `do_put_github_app_key`; bulk retry |
| master moved, clean merge | pushed as merged | none |
| master moved, real conflict | `conflict`, nothing pushed | editor resolves (§8) |
| dev and prd push in the same second | the second ref update 422 | transient retry, merge onto the winner (§6.2) |
| a dev test edit reaches master | a `docs(dev):` commit on trunk | revert by a new edit; automated tests use a fake GitHub (§6.2) |
| member never saw the author notice | 428, nothing written | the WUI shows §4.2 and repeats the save |
| agent names no or a wrong requester | 403, nothing written | the agent asks its requester; the requester may need to give consent once |
| CI red caused by the pushed doc commit | master red | chip red, editor and ops told; fixed by a new edit or a lane |
| CI red inherited from another push | master red already | ops note only; the chip stays `pushed` |
| publish run without the `.edits/` exclude | every overlay deleted | the publish task ships before the overlay; its test is the gate |
| hub instance dies mid-push | row stuck `pushing` | a `pushing` row older than 10 min returns to `queued`; before a new commit the worker checks whether head already holds a commit naming this `edit_id`, so a repeat never double-commits |
| docs-publish workflow fails | overlay keeps serving the new text | workflow rerun; row stays `pushed` |
| two hub instances of one env | one holds the advisory lock | none |
| abuse from one workspace | many edits | rate limits; ops lists it in `blocked_workspaces`; edits reverted by new edits |
| hygiene/secret false positive | 422 at save | the member rewords; a rule tuned in cnf |

---

## 12. Test plan

Unit / module (`bash csi-spl-api/src/bash/tests/run-all-tests.sh`, store tests on Postgres):
- paths: one sample path per deny row of §5.2, a published editable doc, a new file in an editable dir, a new file in a denied dir, traversal; the cnf deny list equals the §5.2 globs.
- size, rate (member, agent, workspace, env; dev's lower env cap), `min_member_age`, `blocked_workspaces`.
- hygiene + secret gate: each rule hits; clean text passes; only new lines scanned.
- author resolution: mapping row, history match, sign-in email fallback, unverified email -> 403; message has no AI trailer (anchored grep `^(Co-Authored-By:|Claude-Session:)` = 0); dev subject `docs(dev):`, prd `docs:`.
- author notice: no consent -> 428 and nothing written; consent -> 200; a changed identity -> 428 again.
- agents: an agent token with a valid requester -> 200, author = requester, body names the agent; no header -> 403; requester not a member / no `docs.write` / unverified / not the seat's `for_human` / `allow_agents = false` -> 403.
- door: a `demo_user` session gets 403.
- worker against a fake GitHub (httptest): unchanged base -> commit; moved + clean -> merged; moved + conflict -> `conflict`, no ref update; 5xx -> backoff; 401 -> `failed`; coalescing inside `coalesce_after`, capped by `coalesce_max`; never coalesce two authors; ref-moved 422 -> retry (two workers on one fake repo = the dev/prd race); stuck `pushing` reclaim without a double commit.
- overlay read: overlay wins until `published`; publish never deletes `.edits/` (bash tests on `do_publish_docs` provider none and on the `spl_docs_upload` rsync argument list).
- merged text: a clean merge that forms a banned string goes `conflict`, no ref update.
- RLS: a workspace reads only its own rows, for each new table.

Dev proof (live, `enabled` on dev):
1. Edit an editable doc in the WUI: the author notice shows the member's name and sign-in email; after consent, chip "Saved · pushing" -> "Pushed · <sha7>"; `git log -1 --format='%an <%ae> | %cn | %s' origin/master` shows the editor, the App bot and `docs(dev): edit <path>`.
2. Two browsers edit one doc on different lines -> both land, the second "merged with".
3. Same lines -> `conflict`, resolve, lands.
4. A denied path and a planted fake key -> refused, nothing in the bucket, no row.
5. An agent edit with its requester -> author = the requester, body names the agent.
6. Disable the App key's secret version -> `failed`; restore -> retry lands.

Prd proof: one real edit to a doc under `csi-spl-doc/`, author shown, workflow 32 publishes both envs, both overlays drop, no WUI/hub deploy ran (`gh run list --commit <sha>` shows 10, 15, 32 and 64 only).

---

## 13. Effort: lanes

The build is [`tasks.md`](tasks.md): small tasks, one agent each. The lanes, for readers of v0.2:

| lane | scope | size | tasks |
|---|---|---|---|
| L1 | rdb migration: 4 tables, RLS policies, isolation tests | S | T02 |
| L2 | hub: `PUT /v1/docs`, gates (paths, size, rate, hygiene, secrets), author resolution + notice, agent requester, overlay write/read, `tree.json` merge, edits API | M | T05, T06, T07, T08 |
| L3 | publish: `blob` per file in `tree.json`, rsync exclude of `^\.edits/` + its test, workflow `32_docs-publish.yml` | S | T03 |
| L4 | hub worker: queue claim, coalescing window, GitHub App client (JWT, Git Data API, compare), 3-way merge, retries, published sweep | L | T09, T10 |
| L5 | WUI: Edit button, editor, author notice, status chip, "My edits", conflict view, i18n x19 | M | T11, T12 |
| L6 | iac: secret container + accessor in 030, cnf keys, `do_put_github_app_key`, `do_rotate_github_app_key`; GitHub App creation is the owner's step (§9.1) | S | T01, T04 |
| L8 | dev proof, then prd proof (§12) | S | T13, T14 |

L7 (a `.md` fast path in workflow 10) was removed when the owner answered O6 "no, coalescing is enough", then built outside this plan as the express docs lane once the owner reversed O6 (msgs `50a349f4`, `31e00aee`, §3). The lane ids are kept stable so the panel files still read.

---

## 14. Owner decisions

Owner HUM-10 answered all nine questions of v0.2 in prd t1 topic `2e20d6d4`, msgs `e7efcb67` and `f4142409`. Decided; not reopened.

| # | question | owner's answer | v0.2 recommendation | where it lands |
|---|---|---|---|---|
| O1 | which workspaces may edit | **b) every workspace** | a) operator-enabled only | §5.1 |
| O2 | where a prd edit lands | a) master directly, fast-forward | same | §6 |
| O3 | author for a member with no history in the repo | **b) the member's own sign-in email** | a) display name + noreply | §4.1, §4.2 |
| O4 | may agents edit | **b) yes, authored as the agent's requester** | a) no, members only | §4.3, §5.1, §10 |
| O5 | delete and rename from the app | a) not in v0.1 | same | §5.2 |
| O6 | `.md`-only fast path in workflow 10 before prd | **b) no, coalescing is enough** - REVERSED 2026-10-07 by msgs `50a349f4` + `31e00aee`: an express docs lane in workflow 10 | a) yes, lane L7 | §3, §6, §13 |
| O7 | dev target | **b) master from dev as well** | a) a `docs-edit-dev` branch | §6, §6.2, §7 |
| O8 | create the GitHub App | **go - yes** (owner step on GitHub) | - | §9.1, `tasks.md` T00 |
| O9 | how wide is the editable set | **b) any published .md minus the deny list of §5** | a) `csi-spl-doc/**` + root docs | §5.2 |

---

## 15. Not in scope

- Real-time co-editing (CRDT/OT).
- Editing anything but `.md`.
- Pushing to any repo but this one.
- Branch protection changes on GitHub (beyond adding the App as a bypass actor, §9.1 step 5).
- Delete and rename (O5).

## 16. Version log

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1 | 2026-10-06 | c-380 | First draft for the panel (g-381, a-382): Q1-Q7 each with one recommendation and rejected alternatives, data model, sequence, failure modes, test plan, lanes, owner questions O1-O8. |
| v0.2 | 2026-10-06 | c-380 | Panel consensus (`consensus.md`): queued-only coalescing; FIFO chaining; text gates re-run on merged bytes; member session only, agent token 403; corrected `docs.write` role fact and workflow 20 globs (deny-listed); v1 allow-list `csi-spl-doc/**` + root docs (O9 widening); workflow 32 on editable prefixes; one compare per new tree sha; rsync exclude of `.edits/` (found in consolidation: today's publish deletes it); `.md` fast path in workflow 10 before prd, no `[skip ci]`; inherited CI red is not the editor's failure; token cached in memory. |
| v0.3 | 2026-10-06 | c-388 | The owner's answers O1-O9 (msgs `e7efcb67`, `f4142409`) recorded in §14 and folded in as one design: every workspace edits, the per-workspace switch replaced by abuse limits and an operator brake (O1); author fallback = the sign-in email, with a one-time public-email notice and its text (O3); agents edit as their requester (O4); no workflow 10 fast path, a coalescing window is the only cost control, lane L7 removed (O6); dev writes master too, its risks and mitigations in §6.2 (O7); the GitHub App owner steps (O8, §9.1); editable set = published `.md` minus a measured 14-row deny list, 407 editable at `7f67bb604` (O9). Build plan: `tasks.md`. |
| v0.4 | 2026-10-07 | c-469 | O6 reversed by the newer owner order (t1 `a477c187`, msgs `50a349f4`, `31e00aee`): workflow 10 gets an express docs lane, code jobs skipped for a push whose every path is a `.md` outside `csi-spl-wui/**` and `.github/**` (§3, §6, §13, §14). |

<!-- version: 0.4 · updated: 2026-10-07 -->
