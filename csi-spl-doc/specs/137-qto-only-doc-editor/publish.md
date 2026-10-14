# Spec 137 addendum: the Qto "Publish to GitHub" button

Status: **Draft v0.1** (addendum to [spec.md](spec.md) §5; issue SPL-1887).
Authority: this file for the Publish button; [tasks.md](tasks.md) §7 for its
build tasks (all Planned). Docs only: it builds nothing (`../README.md` §2.4).
Source: owner HUM-10, prd t1 topic `2a2a4694-f8fb-40f1-931e-203c6635b5e6`,
msg `b04f0ab5`.

`<doc_id>`, `<path>`, `<env>` and `<rev>` are placeholders. The target repo is
cnf `env.docs.repo_edit` (hub env `SPOOL_HUB_DOCS_EDIT_GITHUB_REPO`); no estate
value appears here as a literal.

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

So the hub cannot produce the published bytes on its own today: the composer
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
| queue, 3-way merge, retry | `internal/repodocs/worker.go:281` (`attempt`), :343 (`mergeOnto`); table `csi-spl-rdb/src/sql/postgres/spool-hub/0142_repo_doc_edits.sql` |
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
`docs.write` only (`internal/rbac/rbac.go:40-41`); no `docs.publish` exists.

## 2. The button

### 2.1 Where

- **Doc view**: a **Publish** button in the doc header of
  `csi-spl-wui/src/components/workspace-docs/WorkspaceDocView.vue`
  (`data-test="ws-doc-publish"`), shown only for a publishable doc (§2.2,
  Q2) and only to a caller who may publish. For everyone else it is absent,
  not disabled.
- **Selection**: in the Explorer (`QtoFileTree.vue`), a multi-select of docs,
  and a folder's **Publish changed** action, publish every selected doc whose
  Qto rev is newer than its last publish, as ONE commit (§3.3).
- Phone: the doc view's overflow menu holds the one-doc action; no selection.

### 2.2 Who may press it, and which docs

Recommended (Q1 A, Q2 A):

- a new permission `docs.publish` in `internal/rbac`, held by default by
  `admin` and `product_owner` of the operator workspace only, so it can be
  granted apart from editing later;
- an agent of the operator workspace may publish only for a requester who
  holds `docs.publish` (`X-Spool-Requester`, spec 075 repo-edit §4.3 rules
  a-e), so every commit has a human author;
- publishable docs: repo docs (system tenant) and docs mapped in
  `qto-docs.tsv`. A customer workspace's doc never reaches the public repo by
  one click.

### 2.3 What one press does

1. **Read** the doc at its current rev (the press sends `If-Match: <rev>`; a
   newer rev answers 412 and the view reloads).
2. **Export** it on the hub with the Go composer (T061), byte-identical to
   `do_spl_doctree_export_md` for the same rev.
3. **Gate** the bytes: `repodocs.Gate` (hygiene + secret scan) on the new
   lines, the deny list (`env.docs.repo_edit.deny`), the size cap. A hit: 422
   `rejected_text`, nothing written.
4. **Check the repo**: `HeadBlob(<path>)` against the blob this doc last
   published (`published_blob`, §4). Equal, or the file is new: go on.
   Different: 409 `repo_changed` (§3.4). Equal to the new bytes: 200
   `unchanged`, no commit.
5. **Commit** to `master`, fast-forward only (`force:false`), author = the
   presser (§3.1), committer = the App's bot. A 422 ref-moved re-reads the
   head and retries from step 4, up to 3 times, then `failed` (retryable).
6. **Record** the publish row and the audit event (§5), and answer
   `{commit_sha, blob, url, rev}`.

The press is synchronous (one doc: 5-8 GitHub calls, as one spec 075 push).
No queue and no coalescing: the person chose the moment.

## 3. The commit

### 3.1 Identity (CLAUDE.md §5.1)

- **Author**: the presser (for an agent: its requester), resolved by
  `repodocs.ResolveAuthor` exactly as a spec 075 save, with the same one-time
  public-identity notice (428 `author_notice_required`). A real name and
  address, never a placeholder author.
- **Committer**: `<app-slug>[bot]` and its noreply address (`repo.go:162`).
- **No `Co-Authored-By:`, no `Generated with ...`, no session link, no other
  AI trailer** (the leak-gate rule). The hub builds the message; nothing a
  caller sends reaches it but the doc's path and title.

### 3.2 Message

One doc:

```
docs(qto): publish <path>

Published from qto doc <doc_id> rev <rev> (<env>). Publish <publish_id>.
Published by agent <agent_id> for <author name>.

Lay-What: <title> was published from the shared library.
Lay-Why: Its library copy is the master; this file is its export.
```

- The agent line is present only for an agent's press.
- The last paragraph is the release note's doc-only form (Lay-What +
  Lay-Why, `csi-spl-iac/src/bash/run/check-release-note.func.sh`), so these
  commits meet the same rule as the lanes' commits.
- A selection: subject `docs(qto): publish <n> docs`, one body line per doc
  (`<path>: qto doc <doc_id> rev <rev>`).
- No issue key: a publish closes nothing (spec 135 closing rule).

### 3.3 One file or many

`Commit` writes ONE path (`repo.go:124`). A selection needs a tree of N paths
in one commit (T062): one commit = one CI run instead of N, and the selection
lands or fails as one. Cap: 50 docs per press.

### 3.4 The repo file changed since the last publish

Qto is the master, so the hub does NOT 3-way merge (unlike spec 075 §8): a
merge would put text into the repo that no Qto rev holds, and the next publish
would silently drop it. Recommended (Q3 A):

- 409 `repo_changed` with the repo's text and the diff against the last
  published text; the view shows them side by side.
- **Take it into Qto**: the presser copies what they want into the doc (a
  normal Qto edit, a new rev), then presses Publish again.
- **Publish over it**: one more confirmation ("the repo change will be
  replaced"); it is a NEW commit on top of the head, never a force-push, so
  the replaced change stays in history.
- After Phase 4 (T040, T041 live) a hand edit of a mapped file cannot land, so
  `repo_changed` can only mean another env's publish (Q4) or a lane's
  `do_spl_doctree_export_md` of another rev; the diff shows which (its stamp
  names the doc).

## 4. Status shown back in Qto

Stored per doc (T063): `published_rev`, `published_blob`, `published_sha`,
`published_at`, `published_by`. The doc header shows one chip:

| chip | when |
|---|---|
| **Not published** | no publish row (exported only by a lane's action, or new) |
| **Published** `<sha7>`, linked to the commit on GitHub | `rev == published_rev` |
| **Changed since publish** (n revs) | `rev > published_rev` |
| **Repo changed** | the head blob of `<path>` differs from `published_blob` (read when the doc opens, cached 5 min, one `HeadBlob` call) |
| **Publish failed**, Retry | the last publish row is `failed` |

The Explorer shows a "changed since publish" dot on a doc row, so a folder's
**Publish changed** has a visible target. The first publish of a doc a lane
already exported takes the head blob as its base (no false `repo_changed`).

## 5. Audit trail

- A publish row per press (a new rdb table, number taken at build, under RLS
  by `tenant_id`): `publish_id`, `tenant_id`, `doc_id`, `rev`, `path`,
  `actor_kind`, `human_id`, `agent_id`, `author_name`, `author_email`,
  `author_source`, `base_blob`, `result_blob`, `commit_sha`, `status`
  (`published`, `unchanged`, `rejected`, `repo_changed`, `failed`), `error`,
  `created_at`. A selection: one row per doc, all with the same `commit_sha`.
- One hub audit event per press (`docs.publish`), readable with `audit.read`.
- The commit body names the `publish_id`, so a commit leads to its row and a
  row to its commit (`git log --grep <publish_id>`).
- `GET /v1/workspace/doctree/docs/{id}/publishes` lists a doc's publishes for
  the view.

## 6. How it fits Phase 4 (T040, T041)

- A published file IS the export of `published_rev`. T041 (CI drift check)
  compares a mapped file with the export of the rev it was published from
  (the publish row; for a lane's export, the rev named in its commit), NOT
  with the doc's latest rev: "changed since publish" is a normal state, not
  drift. Drift = a file that equals no export of its doc.
- T040 (pre-push) runs on lanes' pushes only; a publish never passes a box.
  The hub runs the same cheap gates itself (§2.3 step 3), as spec 075 §6 does.
- Parity is the contract both gates rest on: the Go composer (T061) and
  `spl-doctree-md.py compose` give the same bytes for the same rev, held by a
  parity test. With parity, a lane running `do_spl_doctree_export_md` on a
  published rev changes nothing.
- The export stamp stays as it is (Q5 A): the rev goes into the commit body
  and the publish row, so `STAMP` (`spl-doctree-md.py:44`), the T024 reader
  and every exported file stay byte-stable.
- The spec 075 save already refuses a stamped file (T024, 409 `qto_managed`),
  so the repo-edit worker and Publish never write the same file.

## 7. Failure modes

| failure | answer | state |
|---|---|---|
| doc rev moved since the view loaded | 412 `rev_changed` | nothing written; the view reloads |
| gate hit (hygiene, secret, deny list, size) | 422 `rejected_text`, naming the rule and line | row `rejected`; nothing on GitHub |
| repo file changed since the last publish | 409 `repo_changed` + diff | row `repo_changed`; the §3.4 choices |
| master moved between read and ref update | retried 3 times from §2.3 step 4 | then `failed`, Retry |
| GitHub 5xx, timeout, rate limit | 503 `github_unavailable` | row `failed`, Retry; nothing half-written (the ref moves last) |
| repo edit switched off or no App key | 503 `publish_off` | button hidden while `env.docs.repo_edit.enabled` is false or the key is absent (`repoEdit` returns nil, `cmd/spool/hub_repo_edit.go`) |
| author unverified, no consent | 403 `email_unverified`, 428 `author_notice_required` | the spec 075 rules |
| caller lacks `docs.publish`, or doc not publishable | 403 `publish_forbidden` | button absent in the WUI |
| CI red on the publish commit | the publisher's red only when a job it fired fails (spec 075 §6) | never auto-reverted; a bad publish is undone by publishing a fixed rev |
| hub restarts mid-press | the ref moves last: the commit landed or nothing did | on the next open, a recent master commit naming the `publish_id` marks the row `published` (as the worker's `landed`, `worker.go:380`) |

## 8. Owner questions (poll-ready)

**Q1. Who may press Publish?**
- **A (recommended)**: a new `docs.publish` permission, held by `admin` and `product_owner` of the operator workspace; agents only for a requester who holds it. The same circle that writes the repo docs today (`wsdoc_tree.go:197`).
- **B**: anyone with `docs.write` in the operator workspace.

**Q2. Which docs can be published?**
- **A (recommended)**: only repo docs (system tenant) and docs mapped in `qto-docs.tsv`; a customer workspace's doc never reaches the public repo.
- **B**: any workspace doc, to a path the presser picks (needs the deny list and an admin review step).

**Q3. The repo file changed since the last publish: what then?**
- **A (recommended)**: refuse with a diff; the presser takes the change into Qto, or publishes over it as a new commit (never a force-push).
- **B**: 3-way merge as spec 075 does (the merged text then exists in no Qto rev).

**Q4. Which environment publishes?**
- **A (recommended)**: prd only. The map ids are prd's ([unified-fs.md](unified-fs.md) §5); a dev publish would write dev doc ids into the stamp. Dev tests run against a fake GitHub.
- **B**: both; dev commits as `docs(qto, dev): ...` (as spec 075 §6.2).

**Q5. Does the export stamp carry the rev?**
- **A (recommended)**: no; the rev goes into the commit body and the publish row, so every exported file and the T024 stamp reader stay byte-stable.
- **B**: yes, `Generated from qto doc <id> rev <n>`: every mapped file changes once, and both stamp readers change.

**Q6. After Publish ships, who writes the mapped `.md` files?**
- **A (recommended)**: Publish only; `do_spl_doctree_export_md` keeps a check mode (export and compare, no write) for T041 and for lanes.
- **B**: both Publish and the lane export action.

## 9. Version log

| Version | Date | Author | Description |
|---|---|---|---|
| v0.1.0 | 2026-10-14 | c-526 | Publish button addendum (SPL-1887, owner msg b04f0ab5): the measured export path and the spec 075 GitHub App commit path; button, permission, commit identity and message, conflict rule, status chip, audit, Phase 4 fit, failure modes; owner questions Q1..Q6; tasks T060..T067. |

<!-- version: 0.1.0 · updated: 2026-10-14 · last-edit: 2026-10-14T21:30:00Z -->
