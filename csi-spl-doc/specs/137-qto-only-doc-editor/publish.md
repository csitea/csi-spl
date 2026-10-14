# Spec 137 addendum: the Qto "Publish to GitHub" button

Status: **Decided v0.3** (owner answered Q1..Q6 and the review question, §8; issue SPL-1887).
Authority: this file for the Publish button; [tasks.md](tasks.md) §7 for its
build tasks (all Planned). Docs only: it builds nothing (`../README.md` §2.4).
Source: owner HUM-10, prd t1 topic `2a2a4694-f8fb-40f1-931e-203c6635b5e6`,
ask msg `b04f0ab5`, answers poll `72d2b3da` (final msg `86c7b888`) and poll
`6f7ce1d7` (msg `af133e9c`).

`<doc_id>`, `<path>`, `<env>`, `<rev>` and `<workspace>` are placeholders.
The target repo is cnf `env.docs.repo_edit` (hub env
`SPOOL_HUB_DOCS_EDIT_GITHUB_REPO`); no estate value appears here as a literal.

## 0. The owner's ask (verbatim)

| msg | text |
|---|---|
| `b04f0ab5` | "the aim is to slowly make the master storage format of our docs to be qto and the '*.md' files to be published to the github repo , once desired via a pubblish button" |

What it binds:

- **P1**: Qto is the master copy of a doc (already spec §5.1, B1). The `.md`
  in git is its published form.
- **P2**: "slowly": publishing follows the import slice by slice (T030a..d);
  an unmapped `.md` keeps its git editing until its slice lands.
- **P3**: "once desired via a publish button": a person decides when a doc's
  current Qto text reaches the repo. Saving in Qto does NOT publish.

## 1. What exists today (measured on `d22c1fef7`, 2026-10-14)

### 1.1 The export to `.md` is a box action, not a hub feature

| piece | where | what it does |
|---|---|---|
| map | `csi-spl-doc/doc/md/qto-docs.tsv` (`wc -l` -> 4 rows) | doc id, TAB, md path, optional third column `repo` (system tenant, [unified-fs.md](unified-fs.md) §5) |
| export action | `csi-spl-orc/src/bash/run/spl-doctree-export-md.func.sh:53` | runs `spool doctree export`, then `spl-doctree-md.py compose`, and writes the file in a git worktree; a lane commits it |
| composer | `csi-spl-orc/src/bash/run/spl-doctree-md.py:173` | writes the front matter, `# <title>`, and the export stamp `` > Generated from qto doc `<id>`; edit it there. This file is its export: ... `` |
| stamp readers | `spl-doctree-md.py:44` (`STAMP`); hub `repoDocNotQto` (`csi-spl-api/src/go/spool-hub-api/internal/hub/repo_docs_edit.go:622-635`) | an import drops the old stamp; the spec 075 save answers 409 `qto_managed` for a stamped file (T024) |
| Go exporter | `csi-spl-api/src/go/spool-hub-api/cmd/spool/doctree_export.go` | the CLI's export of the item tree (package `main`: the hub cannot import it) |
| rev history | `csi-spl-rdb/src/sql/postgres/spool-hub/0157_workspace_docs.sql:71` (`workspace_doc_rev_log`: `rev`, `op` jsonb, `actor`) | an op log, not snapshots: an old rev cannot be re-exported cheaply, so §6 records each export's blob instead |

So the hub cannot produce the published file on its own today: the composer
is Python on a box.

### 1.2 The hub already commits to master under a GitHub App (spec 075 repo-edit)

Paths below are under `csi-spl-api/src/go/spool-hub-api/` unless they start
with a module directory.

| piece | where |
|---|---|
| App key slot `spool-hub-github-app-key`, env `SPOOL_GITHUB_APP_KEY` | `cmd/spool/hub_repo_edit.go:20`; cnf `csi-spl-cnf/csi-spl/all.env.yaml:704-717` (`env.docs.repo_edit`: App id and installation id are public cnf); key put and rotated by `do_put_github_app_key` (`csi-spl-iac/src/bash/run/put-github-app-key.func.sh:22`) and `do_rotate_github_app_key` (`rotate-github-app-key.func.sh:21`) |
| switch | `env.docs.repo_edit.enabled: true` in `csi-spl-cnf/csi-spl/dev.env.yaml:325` and `prd.env.yaml:310` |
| one-file commit, fast-forward only | `internal/github/repo.go:124` (`Commit`: blob -> tree -> commit -> `PATCH ref force:false`; `moveRef` :217; a moved branch = 422, the branch untouched) |
| committer = the App's bot, author = the person | `internal/github/repo.go:162` (`Committer`); `internal/repodocs/author.go:134` (`ResolveAuthor`: mapping row, else history identity, else display name + verified sign-in email); consent notice: spec 075 repo-edit §4.2 |
| commit message, no AI trailer | `internal/repodocs/author.go:242` (`CommitMessage`: `docs: edit <path>`, `docs(dev): ...` on dev) |
| text gates before a write | `internal/repodocs/gate.go:104` (`Gate`: hygiene patterns + secret scan on the new lines), called at `internal/hub/repo_docs_edit.go:677` |
| queue, 3-way merge, retry | `internal/repodocs/worker.go:281` (`attempt`), :343 (`mergeOnto`), `internal/repodocs/merge.go:27` (`Merge3`); table `csi-spl-rdb/src/sql/postgres/spool-hub/0142_repo_doc_edits.sql` |
| ruleset bypass for the App | `csi-spl-iac/src/bash/run/spl-gh-app-bypass.func.sh` (skips `master-no-force`: the App never force-pushes, so it needs no bypass there) |
| it works live | `git log --format=%H --committer='\[bot\]' origin/master \| wc -l` -> 18 commits; for the newest, `69917787`, `gh run list --commit` shows workflows 00, 15, 64 and 32 green and 10 cancelled (superseded by a newer push): an App push fires CI, unlike a `GITHUB_TOKEN` push |

The deploy workflows write no content: 20 and 30 hold `contents: write` only
to claim the release tag through the REST API
(`.github/workflows/20_hub-build-deploy.yml:364`, `30_wui-build-deploy.yml:190`,
the reason at :200-209). They are not a publish path.

### 1.3 Who may write the repo docs in Qto today

`repoDocsWriter` (`internal/hub/wsdoc_tree.go:197-207`): an agent or an `admin`
of the operator workspace; everyone else gets 403 `repo_docs_read_only` on an
`fs=repo` write (:183-187). The doc permissions are `docs.read` and
`docs.write` only (`internal/rbac/rbac.go:40-41`).

## 2. The button

### 2.1 Where

- **Doc view**: a **Publish** button in the doc header of
  `csi-spl-wui/src/components/workspace-docs/WorkspaceDocView.vue`
  (`data-test="ws-doc-publish"`), shown to any caller with `docs.write` in the
  doc's workspace. For a caller without it the button is absent, not disabled.
- **Selection**: in the Explorer (`QtoFileTree.vue`), a multi-select of docs,
  and a folder's **Publish changed** action, publish every selected doc whose
  Qto rev is newer than its last publish, as ONE commit (§3.3).
- **First publish**: a doc with no map row asks for its target `<path>` (a
  `.md` path in the repo); the publish adds the map row (§3.3).
- Phone: the doc view's overflow menu holds the one-doc action; no selection.

### 2.2 Who may press it, and which docs (Q1 B, Q2 B, msg af133e9c)

- Any member with `docs.write` in the doc's workspace presses Publish (Q1 B;
  no new permission). An agent presses it for a requester who holds
  `docs.write` (`X-Spool-Requester`, spec 075 repo-edit §4.3 rules a-e), so
  every commit has a human author.
- Any workspace doc may be published, to a path the presser picks (Q2 B).
- **Every press publishes at once.** There is no review step, no request
  queue and no reviewer role (owner msg `af133e9c`: "no additional processes ,
  just publish , no review needed ... we will add later on version history ,
  malicious attempts will be quickly spotted"). What stands between a press
  and the public repo is automatic: the public-repo guard (§2.4), the commit
  identity (§3.1) and the audit row (§5), which is how a malicious attempt is
  spotted and traced.

### 2.3 What one press does

1. **Read** the doc at its current rev (the press sends `If-Match: <rev>`; a
   newer rev answers 412 and the view reloads).
2. **Export** it on the hub with the Go composer (T061), byte-identical to
   `do_spl_doctree_export_md` for the same rev.
3. **Guard** the bytes and the path (§2.4). A hit: 422 `rejected_text`,
   nothing written to GitHub.
4. **Check the repo**: `HeadBlob(<path>)` against the doc's last recorded
   blob (`published_blob`, §4). Equal, or the file is new: go on. Equal to the
   new bytes: 200 `unchanged`, no commit. Different: the same-rev rule (§6.2),
   then the 3-way merge (§3.4).
5. **Commit** to `master`, fast-forward only (`force:false`), author = the
   presser (§3.1), committer = the App's bot; a first publish adds the map row
   in the same commit (§3.3). A 422 ref-moved re-reads the head and retries
   from step 4, up to 3 times, then `failed` (retryable).
6. **Record** the publish row and the audit event (§5), and answer
   `{commit_sha, blob, url, rev}`.

A press is synchronous (one doc: 5-8 GitHub calls, as one spec 075 push). No
queue and no coalescing: the person chose the moment.

### 2.4 The public-repo guard (automatic, on every press)

The repo is public (spec 044). The guard is not a process step but the
repo's existing rule (the hygiene sweep and secret scan every lane's push
passes), run by the hub because a publish never passes a box:

- **Whole text, not new lines**: for a first publish every line is new, so
  `repodocs.Gate` (the distribution-hygiene patterns and the secret scan,
  `internal/repodocs/gate.go:104`) runs on the whole exported text.
- **Path rules**: `.md` only; the spec 075 deny list
  (`env.docs.repo_edit.deny`: the agent-instruction files, workflows, module
  trees, test inputs, `tasks.md`); a new file only in a directory that already
  holds a published doc; never a path that holds an unmapped file or another
  doc's export (its stamp names a different doc).
- **Size**: the 1 MiB spec 075 cap.
- **On a hit**: 422 `rejected_text` naming the rule and line, to the presser
  only; nothing reaches GitHub, and the audit row is `rejected` with the rule
  name, not the text (a customer's text that tripped the guard is not copied
  anywhere). The presser fixes the doc in Qto and presses again.
- **Again after a merge**: the same guard runs on the merged bytes of §3.4
  before the Qto write-back and the commit; a hit there is `rejected` too.

## 3. The commit

### 3.1 Identity (CLAUDE.md §5.1)

- **Author**: the presser (for an agent: its requester), resolved by
  `repodocs.ResolveAuthor` exactly as a spec 075 save, with the same one-time
  public-identity notice (428 `author_notice_required`) before the press is
  accepted. A real name and address, never a placeholder author.
- **Committer**: `<app-slug>[bot]` and its noreply address (`repo.go:162`).
- **No `Co-Authored-By:`, no `Generated with ...`, no session link, no other
  AI trailer** (the leak-gate rule). The hub builds the message; nothing a
  caller sends reaches it but the doc's path and its title.

### 3.2 Message

One doc:

```
docs(qto): publish <path>

Published from qto doc <doc_id> rev <rev> (<env>). Publish <publish_id>.
Merged with <sha7>.
Published by agent <agent_id> for <author name>.

Qto-Doc: <doc_id> rev <rev>

Lay-What: <title> was published from the shared library.
Lay-Why: Its library copy is the master; this file is its export.
```

- The "Merged" and agent lines are present only when they apply.
- `Qto-Doc:` is the line T041 and the same-rev rule read (§6); a lane's
  export commit carries the same line (T066).
- The last paragraph is the release note's doc-only form (Lay-What +
  Lay-Why, `csi-spl-iac/src/bash/run/check-release-note.func.sh`).
- A selection: subject `docs(qto): publish <n> docs`, one `Qto-Doc:` line
  per doc.
- No issue key: a publish closes nothing (spec 135 closing rule).

### 3.3 One file or many

`Commit` writes ONE path (`repo.go:124`). A publish needs a tree of N paths
in one commit (T062): the doc's `.md` plus `qto-docs.tsv` on a first publish
(its row: doc id, path, and the third column `repo` for the system tenant or
the workspace id for any other workspace, T066), and N docs for a selection.
One commit = one CI run, and it lands or fails as one. Cap: 50 docs per press.

### 3.4 The repo file changed since the last publish: 3-way merge (Q3 B)

When the head blob of `<path>` is not the doc's last recorded blob and the
same-rev rule (§6.2) does not explain it, the hub merges, as spec 075 §8 does,
and then writes the result back into Qto so Qto stays the master:

1. **Merge**: `repodocs.Merge3(base, theirs, mine)` (`merge.go:27`) with
   base = the text of `published_blob` (read from GitHub by its sha), theirs
   = the head text, mine = the new export.
2. **Conflict** (a line both sides changed): 409 `merge_conflict`; nothing is
   written to GitHub or Qto. The view shows theirs and mine side by side; the
   presser copies what they keep into the doc in Qto and presses again with
   **Resolved** checked, which takes the head blob as the new base (the
   presser has seen it), so the next merge only adds Qto's changes.
3. **Clean**: the guard (§2.4) runs on the merged bytes. Then the merged text
   is **written back into Qto as a new rev**: the Go splitter (T061, the port
   of `spl-doctree-md.py split`) turns the merged `.md` into the doc's item
   tree, and the hub applies the changed items in one store transaction
   (`If-Match: <rev>`, rev log op `publish_merge` with the `publish_id`,
   actor = the presser). The hub first checks that composing the split tree
   gives the merged bytes exactly; if not (the repo change is not something a
   Qto doc can hold, e.g. a broken outline), 409 `merge_not_representable`,
   nothing written, and the presser takes the change in by hand as in step 2.
4. **Commit** the merged bytes naming the NEW rev (`Qto-Doc: <id> rev <n+1>`,
   "Merged with <sha7>"). If the commit fails after the Qto write, the doc
   simply reads "Changed since publish" (Qto holds a rev that is not published
   yet) and Retry publishes it: no state is lost and the repo never holds text
   that Qto does not.

So after every publish, merged or not, the file on master is the export of a
Qto rev, and Qto holds every line that is on master.

## 4. Status shown back in Qto

Stored per doc (T063): `published_rev`, `published_blob`, `published_sha`,
`published_at`, `published_by`. The doc header shows one chip:

| chip | when |
|---|---|
| **Not published** | no publish row |
| **Rejected** (rule, line) | the last press hit the guard (§2.4) |
| **Published** `<sha7>`, linked to the commit on GitHub | `rev == published_rev` |
| **Changed since publish** (n revs) | `rev > published_rev` |
| **Repo changed** | the head blob of `<path>` differs from `published_blob` and no recorded export explains it (read when the doc opens, cached 5 min, one `HeadBlob` call) |
| **Publish failed**, Retry | the last publish row is `failed` |

The Explorer shows a "changed since publish" dot on a doc row, so a folder's
**Publish changed** has a visible target.

## 5. Audit trail

- A publish row per press (a new rdb table, number taken at build, under RLS
  by `tenant_id`):
  `publish_id`, `tenant_id`, `doc_id`, `rev`, `path`, `kind` (`button`,
  `lane_export`), `actor_kind`, `human_id`, `agent_id`, `author_name`,
  `author_email`, `author_source`, `base_blob`, `result_blob`, `commit_sha`, `merged_with`, `status`
  (`rejected`, `published`, `unchanged`,
  `merge_conflict`, `failed`, `exported`), `error`, `created_at`. A selection:
  one row per doc, all with the same `commit_sha`.
- One hub audit event per press and per commit (`docs.publish`), readable
  with `audit.read`. This trail, the commit's real author and the git history
  are how a bad publish is spotted and undone (by publishing a fixed rev).
- The commit body names the `publish_id`, so a commit leads to its row and a
  row to its commit (`git log --grep <publish_id>`).
- `GET /v1/workspace/doctree/docs/{id}/publishes` lists a doc's publishes.

## 6. Two writers: Publish and the lane export (Q6 B), and Phase 4

### 6.1 Every mapped file is the export of a recorded rev

Both Publish and `do_spl_doctree_export_md` write mapped files (Q6 B). The
one invariant both keep, and T041 checks: **the file on master equals the
`result_blob` of a publish row of its doc, for the rev its last commit names
in `Qto-Doc:`**. Because the rev log holds ops, not snapshots (§1.1), the
blob is recorded at export time instead of re-exporting an old rev later.

- **Publish** records its row before the commit (§2.3 step 6, §3.4).
- **The lane export** (T066) reads the doc's latest recorded rev from the
  hub, exports the current rev, and records a `lane_export` row
  (`POST .../publishes` with rev, path and blob; status `exported`, no
  commit yet) before it writes the file; it prints the `Qto-Doc:` line for
  the lane's commit body. The lane then commits and pushes as usual.

### 6.2 The same-rev rule: how the two avoid racing

- **Master is the lock**: Publish moves the ref fast-forward only; a lane's
  push is refused when master moved. The loser re-reads; nothing is
  overwritten.
- **Never backwards**: the lane export refuses (FATAL, exit non-zero) to
  write a rev older than the doc's latest recorded rev, so a lane cannot
  roll back a publish. T041 reds a file whose `Qto-Doc:` rev is older than
  the doc's latest `published` row.
- **Equal rev, equal bytes**: a lane exporting the rev that Publish already
  published writes the same bytes (parity, T061), so its diff is empty and
  there is nothing to commit.
- **A newer lane export is adopted, not merged**: when Publish finds a head
  blob that is not its `published_blob` (§2.3 step 4), it first looks for a
  recorded row of the same doc with that blob and a rev >= `published_rev`.
  Found: the head is a Qto rev's export, so the hub adopts it as the new
  `published_blob` / `published_rev` and fast-forwards the current rev on top
  of it, with no merge. Only a head that no row explains (a hand edit before
  T040, or a spec 075 save before T024 covered the file) goes to the 3-way
  merge of §3.4.

### 6.3 Phase 4 (T040, T041)

- T041 (CI drift check) applies §6.1: the file's blob equals the recorded
  blob for the rev in its `Qto-Doc:` line. "Changed since publish" is a
  normal state, not drift; drift = a file that equals no recorded export.
- T040 (pre-push) runs on lanes' pushes only: a mapped `.md` in the push
  needs a `Qto-Doc:` line and a recorded `lane_export` row with its blob. A
  publish never passes a box; the hub runs the same cheap gates itself
  (§2.4), as spec 075 §6 does.
- Parity is the contract both writers rest on: the Go composer (T061) and
  `spl-doctree-md.py compose` give the same bytes for the same rev, held by a
  parity test.
- The export stamp stays as it is (Q5 A): the rev goes into the commit body
  and the publish row, so `STAMP` (`spl-doctree-md.py:44`), the T024 reader
  and every exported file stay byte-stable.
- The spec 075 save already refuses a stamped file (T024, 409 `qto_managed`),
  so the repo-edit worker is not a third writer of a published file.

## 7. Failure modes

| failure | answer | state |
|---|---|---|
| doc rev moved since the view loaded | 412 `rev_changed` | nothing written; the view reloads |
| guard hit (hygiene, secret, path rule, size) | 422 `rejected_text`, naming the rule and line, to the presser only | row `rejected` (rule name only); nothing on GitHub |
| repo file changed, merge has a conflict | 409 `merge_conflict` + theirs/mine | nothing written; §3.4 step 2 |
| merged text cannot be held by a Qto doc | 409 `merge_not_representable` | nothing written; the presser takes the change in by hand |
| commit fails after the Qto write-back | `failed`, Retry | Qto holds the merged rev; the doc reads "Changed since publish" |
| master moved between read and ref update | retried 3 times from §2.3 step 4 | then `failed`, Retry |
| lane export of an older rev than the latest publish | the export action exits non-zero | nothing written (§6.2) |
| GitHub 5xx, timeout, rate limit | 503 `github_unavailable` | row `failed`, Retry; nothing half-written (the ref moves last) |
| repo edit switched off or no App key | 503 `publish_off` | button hidden while `env.docs.repo_edit.enabled` is false or the key is absent (`repoEdit` returns nil, `cmd/spool/hub_repo_edit.go`) |
| a publish attempted on dev | 403 `publish_prd_only` | button hidden on dev (Q4 A); dev tests run against the fake GitHub |
| author unverified, no consent | 403 `email_unverified`, 428 `author_notice_required` | the spec 075 rules |
| caller lacks `docs.write` | 403 `publish_forbidden` | button absent in the WUI |
| CI red on the publish commit | the publisher's red only when a job it fired fails (spec 075 §6) | never auto-reverted; a bad publish is undone by publishing a fixed rev |
| hub restarts mid-press | the ref moves last: the commit landed or nothing did | on the next open, a recent master commit naming the `publish_id` marks the row `published` (as the worker's `landed`, `worker.go:380`) |

## 8. Owner decisions

Answered by the owner HUM-10 in poll `72d2b3da` (t1 `2a2a4694`), final msg
`86c7b888-13dc-487d-a623-e702bec98c22` (earlier partial answers `f42a86b4`,
`72fc67d8`, `091a4091`, `ee819649`, `3cadbc90`), relayed by the dispatch
holder in msg `160acbf7`. Q1/Q2 refined in poll `6f7ce1d7`, msg
`af133e9c-abaf-4236-bca1-abb0c9aea049`, verbatim: "no additional processes ,
just publish , no review needed ... we will add later on version history ,
malicious attempts will be quickly spotted".

| Q | question | decision | what it changed |
|---|---|---|---|
| Q1 | Who may press Publish? | **B**: anyone with `docs.write` (msg `86c7b888`); every press publishes at once, no review (msg `af133e9c`) | no new permission, no reviewer role; §2.2 |
| Q2 | Which docs can be published? | **B**: any workspace doc, to a path the presser picks (msg `86c7b888`); the review step of v0.2 dropped (msg `af133e9c`) | §2.2; the automatic public-repo guard §2.4 stays |
| Q3 | The repo file changed since the last publish? | **B**: 3-way merge as spec 075 (msg `86c7b888`) | §3.4: the merged text is written back into Qto as a new rev, a conflict is refused |
| Q4 | Which environment publishes? | **A**: prd only; dev tests against a fake GitHub (msg `86c7b888`) | §7 `publish_prd_only` |
| Q5 | Does the export stamp carry the rev? | **A**: no; the rev goes into the commit body (`Qto-Doc:`) and the publish row (msg `86c7b888`) | §3.2, §6.3 |
| Q6 | Who writes the mapped `.md` files? | **B**: both Publish and the lane export action (msg `86c7b888`) | §6.1, §6.2: recorded blobs and the same-rev rule |

The recommendations of v0.1 were A A A A A A; the owner chose B for Q1, Q2,
Q3 and Q6, then dropped the review step of v0.2 (msg `af133e9c`). The design
above follows his answers.

## 9. Not in scope (later)

- **Version history** of published docs in Qto (owner msg `af133e9c`: "we
  will add later on version history"): a per-doc view of the publish rows and
  their commits, and a way back to an older published rev. A later item; the
  publish rows of §5 and the git history already keep the data it needs.
- Any review or approval step before a publish (dropped, msg `af133e9c`).

## 10. Version log

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1.0 | 2026-10-14 | c-526 | Publish button addendum (SPL-1887, owner msg b04f0ab5): the measured export path and the spec 075 GitHub App commit path; button, permission, commit identity and message, conflict rule, status chip, audit, Phase 4 fit, failure modes; owner questions Q1..Q6; tasks T060..T067. |
| v0.2.0 | 2026-10-14 | c-526 | Owner decisions folded (poll 72d2b3da, msg 86c7b888): Q1 B, Q2 B, Q3 B, Q4 A, Q5 A, Q6 B. Added the admin review step and the public-repo guard, the merge write-back into Qto, recorded export blobs and the same-rev rule for the two writers; tasks T060..T067 reworked. |
| v0.3.0 | 2026-10-14 | c-526 | Owner msg af133e9c (poll 6f7ce1d7): no review, every docs.write press publishes at once; the request queue, review list, alerts notice and reviewer roles removed; the automatic guard and the audit row kept; version history noted as a later item (§9). |

<!-- version: 0.3.0 · updated: 2026-10-14 · last-edit: 2026-10-14T23:30:00Z -->
