# 075 Phase 1b: editable Repo Docs, saved to the docs bucket, pushed to git asynchronously

**Feature ID**: `075-docs-section/repo-edit` · **Milestone**: M3 · **Status**: Draft (v0.1)
**Created**: 2026-10-06 · **Lane**: c-380 (spec author, claude) · **Panel**: g-381 (grok), a-382 (agy)
**Topic**: t1 `2e20d6d4-16b7-4be2-b7d7-45c4f1fbf56e`
**Authority**: this file for the behaviour of editing Repo Docs; [`../spec.md`](../spec.md) for the Docs section as a whole. Panel record: `consensus.md` in this dir (written once both panel opinions land). Docs only: this spec builds nothing (`../../README.md` §2.4).

Builds on, and does not repeat:
- [075 the Docs section](../spec.md): §3 Phase 1 (Repo Docs, read-only) and §4.5 (workspace docs history).
- [044 open source](../../044-spool-open-source/spec.md): the repo is public; every pushed edit is public.
- [025 workspace RBAC](../../025-spool-tenant-rbac/spec.md): `docs.write` is the permission reused here.

`<BASE_DOMAIN>`, `<env>`, `<human_id>`, `<workspace>`, `<app-slug>` are placeholders. User-facing text says **workspace**; **tenant** appears only where an existing code identifier is cited.

---

## 1. Why and The Owner's Ask

Owner HUM-10, prd t1 topic `2e20d6d4`, verbatim, in order:

1. msg `100bc0a2`: "enable the editing of docs from the github repo on the workspace and pushing them to the github repo"
2. msg `6ebd86b6`: "so the end users must be able to edit any md docs and save them into the s3 , but also this will trigger asynchronos git push with the some system account to github and set the author as the user names of this repo"
3. msg `d968b50a`: "we need first a better multi-type agent , multi-agent specification on how this exactly will work"

What the asks decide (the dispatcher's reading, adopted here):

| # | decided | from |
|---|---|---|
| D1 | WHO: every end user, not only admins | 6ebd86b6 "the end users" |
| D2 | WHAT: any `.md` doc, the repo docs included | 6ebd86b6 "any md docs" |
| D3 | SAVE: to the docs bucket first ("s3" = GCS here, as 075 §1 resolved) | 6ebd86b6 "save them into the s3" |
| D4 | THEN: an ASYNC git push to GitHub by ONE system account (the committer) | 6ebd86b6 "asynchronos git push with the some system account" |
| D5 | AUTHOR: the editing user, as this repo's history names people | 6ebd86b6 "set the author as the user names of this repo" |

This reverses 075 §10's "Direct bidirectional Git push from browser to GitHub repository" non-goal for Repo Docs only. The browser still never talks to GitHub: the hub does, as the system account.

### 1.1 What the code does today (read 2026-10-06 at `1f8e51a28`)

| fact | where |
|---|---|
| Repo Docs are read-only: one route, `GET /v1/docs/{path...}`, any signed-in member | `csi-spl-api/src/go/spool-hub-api/internal/hub/docs.go` |
| A doc key must match `ValidDocsPath` (segments of `[A-Za-z0-9._-]`, no leading dot, `.md`, <= 512 chars) | `docs.go` |
| The env's docs bucket (iac step `051-gcs-docs`) is filled ONLY by `do_publish_docs`, a step of the WUI deploy (workflow 30); it mirrors `git ls-files '*.md'` at the deployed sha (deleting objects no longer in the repo) and writes `tree.json` `{v, sha, files:[{path,title}]}` | `csi-spl-orc/src/bash/run/publish-docs.func.sh` |
| Skipped by the publish: `CLAUDE.md`, `GEMINI.md`, `AGENTS.md`, `node_modules/`, `tpl-gen/`, `bin/`, the WUI's built help copy | `publish-docs.func.sh` `spl_docs_stage` |
| Workflow 30 runs only on its path allow-list (`csi-spl-wui/**`, the publish script, ...): a commit touching only `csi-spl-doc/**` does NOT republish | `.github/workflows/30_wui-build-deploy.yml` |
| Workflow 20 (hub) runs only on its allow-list; no `.md` path is in it | `.github/workflows/20_hub-build-deploy.yml` |
| Workflow 10 (CI quality) runs on EVERY push to master, no path filter | `.github/workflows/10_ci-quality.yml` |
| Workspace Docs (075 Phase 2) are editable: `PUT/DELETE /v1/workspace/docs/{path}`, `docs.write`, 1 MiB cap, no lock, last save wins, every write also kept under `.history/` (owner `15134701`: "no need for ultra high level ACID Like doc locking mechanisms") | `internal/hub/workspace_docs.go` |
| `docs.write` is granted to admin, product owner, developer, tester roles and to agents | `internal/rbac/rbac.go` |
| The hub reads secrets as env vars from Secret Manager (`secret_environment_variables` -> `secret_key_ref`), and its CPU is always allocated (`cpu_idle = false`), so a background worker in the hub runs between requests | `csi-spl-iac/src/terraform/030-cloud-run-hub/04-cloud-run-service.tf` |
| The repo holds 574 tracked `.md` (495 under `csi-spl-doc/`, 38 `csi-spl-orc/`, 24 `csi-spl-wui/`); the largest is ~96 KB | `git ls-files '*.md' \| wc -l` -> 574 |
| The last 500 commits carry ONE author identity | `git log -500 --format='%an <%ae>' \| sort -u \| wc -l` -> 1 |

---

## 2. The design in one picture

```
 WUI /docs/repo/<path>  [Edit] -> editor -> [Save]
        │  PUT /v1/docs/<path>   body = markdown, If-Match: <base blob sha>
        ▼
 HUB (member session, docs.write, repo_edit on for this workspace)
   1. validate: path allow-list (§5), size, rate, hygiene + secret scan
   2. write gs://<docs bucket>/.edits/<path>/<edit_id>.md        (D3: saved)
   3. INSERT repo_doc_edits row, status = queued                  (same request)
   4. 200 {edit_id, status:"queued"}  -> the doc shows "Saved · pushing"
        │
        ▼  (async, in-hub worker, one at a time per env)
 WORKER  claim oldest queued row (FOR UPDATE SKIP LOCKED)
   5. GitHub App installation token (secret: Secret Manager, §9)
   6. read <path> at the target ref -> head blob sha
        same as base  -> commit as is
        moved         -> 3-way merge (base, head, edit): clean -> commit merged
                                                       conflict -> status conflict, stop
   7. Git Data API: blob -> tree -> commit (author = editor §4, committer = the App)
      -> update ref, fast-forward only (never force)
   8. status = pushed, commit sha recorded  -> the doc shows "Pushed · <sha7>"
        │
        ▼
 CI: workflow 32_docs-publish (new, *.md allow-list, no build, no version)
   9. do_publish_docs for dev then prd -> the main key + tree.json now hold master
  10. the worker drops the .edits overlay once tree.json.sha contains the commit
```

Readers always see the newest saved text: `GET /v1/docs/<path>` serves the newest unlanded overlay (`.edits/<path>/...`) when one exists, else the published object.

---

## 3. Q1: the flow and the queue

**Recommended**: a hub Postgres table `repo_doc_edits` is the queue; an in-hub worker goroutine drains it.

- **Queue**: one row per save (data model §10). Written in the same request as the bucket write, so a 200 means both the text is in the bucket and the push is owed.
- **Who pushes**: the hub, in a worker goroutine started with the server. Only one worker per env runs at a time: it takes `pg_try_advisory_lock(<repo_edit lock id>)`; a second hub instance idles. Cloud Run keeps CPU between requests (`cpu_idle = false`), so the goroutine runs. Wake-up: a `NOTIFY repo_doc_edits` on insert plus a 30 s poll.
- **Ordering**: FIFO by `created_at` per path; paths in parallel are not needed (volume is tiny). Consecutive queued edits of the SAME path by the SAME author are coalesced into one commit (the newest text wins, the earlier rows go `superseded`). Different authors are never coalesced: each gets its own commit and its own authorship.
- **Retries**: transient errors (GitHub 5xx, 429, network, ref moved during update) retry with backoff 30 s, 1 m, 2 m, 5 m, 10 m, 30 m, 1 h (7 tries, ~2 h); then `failed`. Permanent errors (403 permission, 422 validation, path now denied) go `failed` at once. A user (or an admin) may `retry` a `failed` row.
- **What the user sees**: a status chip on the doc header and in "My edits":

| status | chip | meaning |
|---|---|---|
| `queued` | Saved · pushing | in the bucket, push owed |
| `pushing` | Saved · pushing | worker holds it |
| `pushed` | Pushed · `<sha7>` (link to the commit) | on the target ref |
| `published` | (no chip) | `tree.json` holds a sha containing the commit; overlay gone |
| `conflict` | Conflict · resolve | master changed the same lines; nothing pushed |
| `failed` | Not pushed · retry | after the retries, with the reason |
| `superseded` | (no chip) | folded into a later edit's commit |

**Rejected**:
- *Cloud Tasks / Pub/Sub*: a new GCP service, IAM and terraform step for a queue of a few rows a day; the DB is already there.
- *A GitHub Actions workflow per save* (`repository_dispatch` carrying the text): moves user text through workflow logs and inputs, and the Actions token cannot set the per-user author cleanly.
- *Synchronous push in the save request*: violates D4 ("asynchronos"), and a GitHub outage would fail saves.
- *A journal file in the bucket*: no atomic claim; two instances would double-push.

---

## 4. Q4: author mapping

**Recommended**: author = the editor, resolved in this order; committer = the GitHub App's bot identity.

1. **A mapping row** in `repo_doc_authors` (`human_id -> git_name, git_email`), set by a workspace admin or by the member themself after verifying the email. This is how a member who already appears in this repo's history gets EXACTLY that identity (owner D5: "the user names of this repo").
2. **The member's verified sign-in email matches an author email in this repo's history** (the worker reads `.mailmap` + `git log` authors once a day into `repo_doc_known_authors`): that name and email, as the history has them.
3. **Otherwise** (no history: today every member but one): the member's display name, and the email `<human_id>@users.noreply.<BASE_DOMAIN>` (never the member's private email, because the repo is public). A member who links a GitHub login gets GitHub's noreply form instead, so GitHub shows their avatar.

- **Committer**: `<app-slug>[bot]` and its noreply address, fixed. The author/committer split is git's own: GitHub shows "<author> committed with <app-slug>[bot]".
- **Message**: `docs: edit <path>` then a body `Edited in the Docs section of workspace <workspace>. Edit <edit_id>.` **No `Co-Authored-By:`, no `Generated with`, no session URL, no other AI trailer** (the repo's leak-gate rule).
- **Agents** (they hold `docs.write`): NOT allowed to edit Repo Docs in v0.1 (owner question O4): an agent's edit has no human author by D5.
- The repo's own CLAUDE.md rule that commits carry one canonical address governs agents' commits, not members' edits through this feature; the two do not collide because members are a different person each.

**Rejected**:
- *Every commit authored by the system account, the user named in the message*: loses D5 outright.
- *The member's private sign-in email as author*: publishes it in a public repo.
- *Only members already in history may edit*: contradicts D1 (one author today).

---

## 5. Q5: permissions, editable paths, abuse

**Recommended**:

- **Who** (D1): every member whose role holds `docs.write`, in a workspace where the setting `repo_docs_edit` is on. The setting is off by default and switched on per workspace by an operator (cnf `env.docs.repo_edit.workspaces`), because the docs bucket and the repo are SHARED by every workspace of the env: a member of a customer or demo workspace would otherwise write into the product's public repo. Owner question O1.
- **Editable paths** (D2 "any md", bounded by what the publish serves): every path the publish puts in `tree.json`, plus new files under an editable dir, EXCEPT a deny list:

| denied | why |
|---|---|
| `CLAUDE.md`, `GEMINI.md`, `AGENTS.md` anywhere | agent instructions; not published; a prompt-injection door into every agent of the fleet |
| `csi-spl-wui/**` | a commit there fires workflow 30: a full WUI build, deploy and version mint per save |
| `.github/**` | workflow docs; owner-governed |
| `csi-spl-doc/specs/*/tasks.md` | build authority with shas and checks; edited by lanes |
| anything `ValidDocsPath` refuses | same rule as the read route |

  The allow and deny lists live in cnf (`env.docs.repo_edit.deny`), read by the hub, so changing them is a config change.
- **New files and deletes**: create allowed under an existing editable dir; delete and rename NOT in v0.1 (O5).
- **Size**: 1 MiB per doc (the workspace docs cap, 10x the largest repo doc).
- **Rate**: 30 saves per member per hour, 300 per env per day; over it: 429 `rate_limited`, nothing written.
- **Text gates in the hub, before the bucket write** (the push bypasses the developer pre-push hook, so the hub runs the cheap gates itself):
  - the distribution-hygiene sweep's patterns (the same list `do_check_dist_hygiene` reads from workflow 10, baked into the hub image at build) on the NEW lines only;
  - a secret scan: PEM private-key blocks, cloud key JSON (`"private_key"`), common token prefixes. A hit: 422 `rejected_text` naming the rule and line, nothing written.
- **Audit**: the `repo_doc_edits` row (who, workspace, path, base, result sha) plus one hub audit event per save and per push (`audit.read` shows them); the bucket overlay object is kept 30 days after publish.
- **Undo**: any member with the permission can open the doc's git history link; a bad edit is reverted by a new edit, never by a force-push.

**Rejected**:
- *Every member of every workspace, no switch*: the product repo becomes writable from a demo workspace.
- *Admins only*: contradicts D1.
- *Only `csi-spl-doc/doc/**`*: contradicts D2 ("any md").

---

## 6. Q2: where the commit lands

**Recommended**: **directly on the target ref, fast-forward only**, via the GitHub Git Data API; the target ref is per env in cnf:

| env | target ref | why |
|---|---|---|
| `prd` | `master` | the owner's trunk rule: direct to trunk, no PR |
| `dev` | `docs-edit-dev` (a long-lived branch) | dev and prd share ONE repo; a dev proof must not write to master |

- **Pre-push hook**: client-side, so it never runs for an API push. Its cheap part that matters for a `.md` (dist hygiene) and a secret scan run in the hub (§5). The full CI (workflow 10) still runs on master for every pushed commit: a red there is reported to the editor's status (`pushed`, CI red) and to the ops channel, never auto-reverted.
- **Deploy triggers**: with `csi-spl-wui/**` denied (§5), a doc commit fires workflow 10 and the new docs-publish workflow (§7) only: no hub or WUI deploy, no version tag minted.
- **CI load**: workflow 10 per doc commit is the cost; coalescing (§3) bounds it. Lane L7 adds a `paths` skip of the heavy jobs when a push changes only `*.md` (O6).
- **Branch protection**: if master later requires PRs or status checks, the App is added as a bypass actor; if the owner prefers PRs, §6.1 is the switch.

### 6.1 Rejected alternatives
- *Branch + PR per edit, auto-merge on green*: adds 5-15 min per edit (CI) and a PR per save; contradicts the owner's "push directly to trunk, no PR" rule. Kept as cnf `mode: pr` for a future corporate install whose master is protected.
- *One rolling `docs-edits` branch merged daily by a lane*: edits invisible on master for a day; someone must own the merge.
- *Force-push or ref update without fast-forward*: forbidden by the repo rules.

---

## 7. Q6: the bucket <-> repo loop

**Recommended**: the bucket's main keys stay a mirror of master; an edit lives in an **overlay** until master holds it and the publish has run.

1. Save writes `.edits/<path>/<edit_id>.md` (D3: the edit IS in the bucket). The overlay prefix starts with a dot, so the read route never serves it by key and the publish never deletes it (it mirrors only `ValidDocsPath` keys; lane L3 makes that explicit and tested).
2. `GET /v1/docs/<path>` serves the newest overlay of `<path>` whose row is `queued`, `pushing`, `pushed` or `conflict` (the editor's own text), else the main key. `tree.json` is merged with overlay-only (new) paths in the hub's answer.
3. After the push, a NEW workflow `32_docs-publish.yml` (paths: `**/*.md`, minus the deny list) runs `do_publish_docs` for dev then prd: no build, no version mint. It needs no new secret (the env project SA already publishes).
4. The worker, on its poll, reads `tree.json.sha`; when that sha contains the edit's commit (GitHub compare API: `ahead` or `identical`), the row goes `published` and the overlay is deleted.
5. The dev target ref is not master, so on dev step 3 publishes `docs-edit-dev` only when lane L6 points dev's publish there; until then dev overlays stay until the 30-day sweep (O7).

Why overlay, not overwrite: a WUI deploy of an older sha in flight republishes and would silently overwrite a just-saved edit; the overlay cannot be clobbered.

**Rejected**:
- *Write the main key directly*: the race above; and the main key would disagree with master for an unbounded time after a `conflict`/`failed`.
- *Hub promotes the overlay into the main key itself*: two writers of the main keys (hub and publish), and the hub SA would need write on the whole bucket.
- *Rely on workflow 30 to republish*: it does not run for `csi-spl-doc/**`.

---

## 8. Q3: conflicts

**Recommended**: optimistic, with a 3-way merge; refuse only a real line conflict.

- The editor opens a doc at `base` = the git blob sha of the text it shows (the publish adds `blob` per file to `tree.json`; an overlay records its own `base`). Save sends `If-Match: <base>`.
- **Two users, one file, in the app**: both saves succeed (owner `15134701`: no heavy locking); each is its own row with its own base, pushed in FIFO order. The second push sees master moved and merges.
- **Master moved** (a lane pushed the same file, or the first user's edit landed): the worker 3-way merges `base`, `head`, `edit` (line diff3).
  - clean -> commit the merged text, author = the editor; the status says "merged with <sha7>".
  - conflict -> `conflict`; nothing pushed; the overlay stays; the editor gets a side-by-side (theirs / mine) view, edits, and saves again with `base = head`. Their text is never lost (overlay + row).
- **Ref moved between read and update** (a push in the same second): the fast-forward update fails 422; the worker re-reads and retries (counts as transient).

**Rejected**:
- *Last save wins on master* (overwrite head): silently reverts a lane's commit.
- *Conflict copy file* (`<doc>.conflict-<user>.md` committed): litters the public repo; nobody resolves them.
- *Lock a doc while one user edits*: contradicts owner `15134701`.

---

## 9. Q7: the GitHub identity, the secret, infra

**Recommended**: a **GitHub App** installed on this one repo, permission `contents: write` (and `metadata: read`), nothing else.

- **Tokens**: the hub signs a JWT with the App private key and exchanges it for a 1 h installation token per push batch. Nothing long-lived reaches GitHub.
- **Secret**: the App private key, one Secret Manager secret per env project, named `spool-hub-github-app-key`, exposed to the hub as env var `SPOOL_GITHUB_APP_KEY` through the existing `secret_environment_variables` map. App id and installation id are not secret: cnf `env.docs.repo_edit.github_app_id` / `installation_id`. The key never enters git, cnf, terraform state or a log.
- **Terraform**: step `030-cloud-run-hub` gains the secret container and the accessor grant to the hub runtime SA (no secret version: the value is put out of band). As the env's project SA, never the owner account.
- **Out of band, named actions** (repo rule: nothing ad hoc): `do_put_github_app_key` (adds a secret version from a file the owner downloaded from GitHub, then shreds the file) and `do_rotate_github_app_key` (new key in GitHub, new version, hub roll, old key deleted in GitHub). Rotation yearly or on suspicion.
- **Proof order**: dev first (target `docs-edit-dev`), then prd (target `master`), each behind cnf `env.docs.repo_edit.enabled`.

**Rejected**:
- *A bot user account + fine-grained PAT*: a paid seat, a human-style account to guard, long-lived token, password + 2FA to own.
- *A deploy key (SSH)*: needs a git binary and a clone in the hub image; the key is long-lived and grants the whole repo; no API for merge/compare.
- *A GitHub Actions `GITHUB_TOKEN`*: lives only inside a workflow run (see §3 rejection).

---

## 10. Data model

```sql
-- hub DB (spool_hub owner migrates; spool_hub_rt does DML). Tenant column for RLS + audit.
CREATE TABLE repo_doc_edits (
  edit_id       uuid PRIMARY KEY,
  tenant_id     text NOT NULL,               -- the editor's workspace (RLS)
  human_id      text NOT NULL,
  path          text NOT NULL,               -- ValidDocsPath, editable (§5)
  base_blob     text NOT NULL,               -- git blob sha the editor started from
  overlay_key   text NOT NULL,               -- .edits/<path>/<edit_id>.md
  text_sha256   text NOT NULL,
  author_name   text NOT NULL,               -- resolved at save (§4)
  author_email  text NOT NULL,
  target_ref    text NOT NULL,               -- cnf per env (§6)
  status        text NOT NULL CHECK (status IN
                ('queued','pushing','pushed','published','conflict','failed','superseded')),
  tries         int  NOT NULL DEFAULT 0,
  next_try_at   timestamptz NOT NULL DEFAULT now(),
  last_error    text,
  commit_sha    text,
  merged_with   text,                        -- head sha when a 3-way merge was needed
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON repo_doc_edits (status, next_try_at);
CREATE INDEX ON repo_doc_edits (path, created_at);

CREATE TABLE repo_doc_authors (            -- §4 rule 1
  tenant_id text NOT NULL, human_id text NOT NULL,
  git_name text NOT NULL, git_email text NOT NULL, verified_at timestamptz,
  PRIMARY KEY (tenant_id, human_id)
);
CREATE TABLE repo_doc_known_authors (      -- §4 rule 2, refreshed daily from history
  git_email text PRIMARY KEY, git_name text NOT NULL, seen_at timestamptz NOT NULL
);
```

The worker reads the queue across workspaces (it is the env's one pusher): it runs `asOperator`, the tenant tables carry the RLS `NULLIF` policy like every tenant table, and each new tenant table gets its tenant-isolation test.

API:

| route | who | answer |
|---|---|---|
| `PUT /v1/docs/{path}` (`If-Match: <base>`) | member, `docs.write`, workspace switch on | 200 `{edit_id, status}`; 403 / 409 path denied / 413 / 422 rejected text / 429 |
| `GET /v1/docs/{path}` | member | overlay or main; headers `X-Spool-Doc-Base`, `X-Spool-Doc-Edit` |
| `GET /v1/docs/edits?mine=1\|path=` | member | rows, newest first |
| `POST /v1/docs/edits/{id}/retry` | the editor or an admin | 202 |
| `GET /v1/docs/edits/{id}/conflict` | the editor | `{base, theirs, mine}` |

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
| CI red on the pushed doc commit | master red | editor and ops told; fixed by a new edit or a lane |
| hub instance dies mid-push | row stuck `pushing` | a `pushing` row older than 10 min returns to `queued`; before a new commit the worker checks whether head already holds a commit naming this `edit_id`, so a repeat never double-commits |
| docs-publish workflow fails | overlay keeps serving the new text | workflow rerun; row stays `pushed` |
| two hub instances | one holds the advisory lock | none |
| hygiene/secret false positive | 422 at save | the member rewords; a deny rule tuned in cnf |

---

## 12. Test plan

Unit / module (`bash csi-spl-api/src/bash/tests/run-all-tests.sh`, store tests on Postgres):
- path allow/deny (each deny row, new file, traversal), size, rate.
- hygiene + secret gate: each rule hits; clean text passes; only new lines scanned.
- author resolution: mapping row, history match, noreply fallback; message has no AI trailer (anchored grep `^(Co-Authored-By:|Claude-Session:)` = 0).
- worker against a fake GitHub (httptest): unchanged base -> commit; moved + clean -> merged; moved + conflict -> `conflict`, no ref update; 5xx -> backoff; 401 -> `failed`; coalescing same author; never coalesce two authors; ref-moved 422 -> retry; stuck `pushing` reclaim without a double commit.
- overlay read: overlay wins until `published`; publish never deletes `.edits/` (bash test on `do_publish_docs` provider none).
- RLS: a workspace reads only its own rows.

Dev proof (live, `enabled` on dev only, target `docs-edit-dev`):
1. Edit an allowed doc in the WUI -> chip "Saved · pushing" -> "Pushed · <sha7>"; `git log -1 --format='%an <%ae> | %cn' origin/docs-edit-dev` shows the editor and the App bot.
2. Two browsers edit one doc on different lines -> both land, the second "merged with".
3. Same lines -> `conflict`, resolve, lands.
4. A denied path and a planted fake key -> refused, nothing in the bucket, no row.
5. Disable the App key's secret version -> `failed`; restore -> retry lands.

Prd proof (after the owner's go): one real edit to a doc under `csi-spl-doc/`, author shown, workflow 32 publishes, the overlay drops, no WUI/hub deploy ran (`gh run list --commit <sha>` shows 10 and 32 only).

---

## 13. Effort: lanes

| lane | scope | size |
|---|---|---|
| L1 | rdb migration: 3 tables, RLS policies, isolation tests | S |
| L2 | hub: `PUT /v1/docs`, gates (paths, size, rate, hygiene, secrets), overlay write/read, `tree.json` merge, edits API | M |
| L3 | publish: `blob` per file in `tree.json`, `.edits/` never mirrored, workflow `32_docs-publish.yml` | S |
| L4 | hub worker: queue claim, GitHub App client (JWT, Git Data API, compare), 3-way merge, retries, coalescing, published sweep | L |
| L5 | WUI: Edit button, editor, status chip, "My edits", conflict view, i18n x19 | M |
| L6 | iac: secret container + accessor in 030, cnf keys, `do_put_github_app_key`, `do_rotate_github_app_key`; GitHub App creation is an owner step | S |
| L7 | CI: skip heavy jobs of workflow 10 for `*.md`-only pushes (if O6 = yes) | S |
| L8 | dev proof, then prd proof (§12) | S |

L1 -> L2 -> L4; L3, L5, L6 in parallel after L1; L8 last.

---

## 14. Numbered questions for the owner

- **O1. Which workspaces may edit Repo Docs?** a) only workspaces an operator switches on (recommended: the repo and the docs bucket are shared by every workspace of the env, and the repo is public) · b) every workspace.
- **O2. Where does a prd edit land?** a) master directly, fast-forward (recommended: the trunk rule) · b) a PR per edit with auto-merge on green.
- **O3. Author for a member with no history in this repo?** a) display name + a noreply address of the product domain (recommended: the repo is public) · b) the member's own sign-in email.
- **O4. May agents edit Repo Docs?** a) no, members only in v0.1 (recommended: D5 needs a human author) · b) yes, authored as the agent's requester.
- **O5. Delete and rename of repo docs from the app?** a) not in v0.1 (recommended) · b) yes.
- **O6. Skip the heavy CI jobs for a `.md`-only push?** a) yes, lane L7 (recommended: one doc save would otherwise cost a full CI run) · b) no.
- **O7. Dev target**: a) a `docs-edit-dev` branch (recommended: dev never writes master) · b) master from dev as well.
- **O8. Create the GitHub App** (an owner step on GitHub; the spool then stores its key with `do_put_github_app_key`): go?

---

## 15. Not in scope

- Real-time co-editing (CRDT/OT).
- Editing anything but `.md`.
- Pushing to any repo but this one.
- Branch protection changes on GitHub.

## 16. Version log

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1 | 2026-10-06 | c-380 | First draft for the panel (g-381, a-382): Q1-Q7 each with one recommendation and rejected alternatives, data model, sequence, failure modes, test plan, lanes, owner questions O1-O8. |

<!-- version: 0.1 · updated: 2026-10-06 -->
