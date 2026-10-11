# 129: Private git specs (a customer's spec repo, the crossing rule, the leak gate)

**Feature ID**: `129-private-git-specs` · **Milestone**: M3 · **Status**: Draft (v0.1), waits for the owner's yes on section 9
**Created**: 2026-10-11 · **Lane**: c-998 (claude) · **Topic**: `dispatch-6556594d`
**Authority**: this file. Docs only: this spec builds nothing (`../README.md` §2.4); nothing is built from it before the owner's yes.

Builds on, and does not repeat:
- [044 open source](../044-spool-open-source/spec.md): this repository is PUBLIC; everything pushed here is published.
- [075 the Docs section](../075-docs-section/spec.md) and its [repo-edit](../075-docs-section/repo-edit/spec.md) phase: Repo Docs, Workspace Docs (one GCS bucket per workspace), the GitHub App that pushes edits.
- [114 workspace document privacy](../114-workspace-doc-privacy-sharing/spec.md): Workspace Docs are private to their workspace; sharing is a grant.
- [058 multi-machine fleet](../058-multi-machine-fleet/spec.md): the lane map (`lane-map.sh`) with every live lane's repo, branch, topic and files.

Placeholders: `<PRIVATE_REPO>` (a customer's private git repository, `<gh-org>/<repo>`),
`<CUSTOMER_WORKSPACE>` (that customer's Spool Hub workspace), `<PUBLIC_REPO>` (this
repository), `<env>`, `<NNN>`. No customer name, host or business term appears in this
file, by design: this file is itself subject to the gate it specifies.

---

## 1. Why and the owner's ask

Owner HUM-10, customer workspace topic `6556594d`, msg `c0f209c5`, verbatim, with the
customer's repository name replaced by `<PRIVATE_REPO>`:

> "We need support in the Spool Hub to create private Git specs. In this case, the Git
> spec should be in the `<PRIVATE_REPO>` project. The `<PRIVATE_REPO>` project should have
> its own Git spec, and that Git spec should be replicated between the two projects
> whenever some kind of architectural Spool Hub decision is taken."

"The two projects" = `<PRIVATE_REPO>` and `<PUBLIC_REPO>`.

Rulings already given in the same topic, which this spec takes as fixed:

| # | ruling | consequence here |
|---|---|---|
| R1 | Nothing about the customer's business is stored in the Spool Hub database. | The private spec text never enters Postgres: not a row, not a message body copy, not a search index (section 6). |
| R2 | Secrets are set only by the customer's business owner, as GitHub secrets of the customer's repository. | Every credential the private repo's CI uses is a GitHub secret of `<PRIVATE_REPO>`, set by that owner (section 3.2). |
| R3 | Spec files go to the workspace's private Docs (msg `a4d65b56`). | The WUI shows a private spec from `<CUSTOMER_WORKSPACE>`'s Docs bucket (section 6). |

### 1.1 The incident this spec must make impossible

On 2026-10-11 a customer's architecture panel spec was written to
`csi-spl-doc/specs/<NNN>-…/` of `<PUBLIC_REPO>` by a fleet lane, because its brief named
that path, and pushed to master 16 times before a dispatcher stopped it; it is being cut
out by a history rewrite under a push freeze. Every gate that existed passed it:

| gate | why it passed |
|---|---|
| `do_check_dist_hygiene` (ban list) | It finds only the literals someone listed in advance; the spec used names and terms nobody had listed. A ban list cannot prove absence (global rule "make claims that carry their own check", corollary). |
| gitleaks / trufflehog (workflows 15, 64) | They look for credentials, not for confidential prose. |
| the pre-push gate | It checks that the tree is correct, not that it is public-safe. |
| the brief | It named a public path for private content; the lane followed it. |

So the design below does not rely on anyone remembering a rule or a word. Its gates key
on WHERE content came from (provenance), not on WHAT it says.

### 1.2 What the code does today (read 2026-10-11 at `1b0bb48ae`)

| fact | check |
|---|---|
| Repo-edit pushes to ONE repository, from cnf `env.docs.repo_edit` (one `github_app_id`, one `installation_id`, one deny list) | `grep -c 'installation_id' csi-spl-cnf/csi-spl/all.env.yaml` -> 1 |
| Workspace Docs: `GET/PUT/DELETE /v1/workspace/docs/{path...}`; a member with `docs.write`, or an agent with a box upload token | `grep -c 'HandleFunc' csi-spl-api/src/go/spool-hub-api/internal/hub/workspace_docs.go` -> 4 (the fourth is `OPTIONS`) |
| The lane map records per lane: repo, branch, topic, files, scope | `lane-map.sh --help` |
| The fleet pre-push hook runs `do_check_pre_push` per worktree; no part of it reads a lane's topic or workspace | `grep -c topic csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push` -> 0 |
| `do_check_dist_hygiene` runs the Sweep step of workflow 10 over the tracked tree: a fixed pattern list plus an allow-list | `csi-spl-iac/src/bash/run/check-dist-hygiene.func.sh` |

---

## 2. Terms

| term | meaning |
|---|---|
| **private spec** | A spec about one customer's use of Spool Hub. Lives ONLY in `<PRIVATE_REPO>`. |
| **public spec** | A spec in `<PUBLIC_REPO>` (`csi-spl-doc/specs/<NNN>-*`). Org-neutral by construction. |
| **Spool Hub decision** | A decision that changes Spool Hub itself: its code, API, schema, cnf shape, deploy or fleet rules. Anything that needs a commit to `<PUBLIC_REPO>` to be built. |
| **customer decision** | Everything else: the customer's systems, data, hosts, people, business, weaknesses, and how they use Spool Hub. |
| **crossing** | One Spool Hub decision written into `<PUBLIC_REPO>` because a private spec needed it. |
| **private lane** | A fleet lane whose brief comes from a topic of `<CUSTOMER_WORKSPACE>`, or whose worktree is a checkout of `<PRIVATE_REPO>`. |
| **private marker** | The line `spool-private: <id>` that every file of a private spec carries (section 5, G2). |

---

## 3. Where a private spec lives, and who writes it

### 3.1 Location

- Repository: `<PRIVATE_REPO>`, which MUST be private. Every action that writes to it
  first reads `gh api repos/<PRIVATE_REPO> --jq .private` and refuses on anything but
  `true` (G4; test: a stub `gh` answering `false` -> refusal, exit non-zero).
- Path: `spool-specs/p<NNN>-<slug>/spec.md` (+ `plan.md`, `tasks.md`, reviews).
  - The `p` prefix keeps a private number from ever being read as a public spec number:
    075's auto-linker turns `spec <NNN>` into a link to the PUBLIC spec, so `spec 012` in a
    customer topic must never resolve into the public tree. `p012` links to the
    workspace's own Docs copy (section 6) or to nothing.
  - Numbering is per private repo, `p001` upward, no relation to public numbers.
- `spool-specs/public/<NNN>-<slug>/`: read-only mirrors of the public specs this customer
  relies on (section 4.1), each with a `SOURCE` file naming the public path and sha.
- `spool-specs/crossings.md`: the crossing log (section 4.2), private.

### 3.2 Who writes it, and with which identity

| writer | how | identity |
|---|---|---|
| a fleet agent (private lane) | `git` in a checkout of `<PRIVATE_REPO>` on its box, push to its trunk | a deploy key with write access to `<PRIVATE_REPO>` ONLY, added by the customer's business owner (R2: they control the repo's keys). It is a separate key from the one that pushes `<PUBLIC_REPO>`, so a private lane's seat holds no credential that can push public (G1). Commit author: the owner's real identity, as in every fleet repo (Q6). |
| a member, from the WUI | 075 repo-edit, extended to a second target (section 7, phase B) | the GitHub App, installed by the customer's business owner on `<PRIVATE_REPO>` only; installation id per workspace (where it is stored: Q2, Q3). |
| the private repo's CI | GitHub Actions in `<PRIVATE_REPO>` | GitHub secrets of `<PRIVATE_REPO>` set by the business owner (R2), e.g. the workspace upload token of section 6. |

A private lane works in a checkout of `<PRIVATE_REPO>`, never in a worktree of
`<PUBLIC_REPO>`. The spawn harness enforces it (G1).

---

## 4. The sync rule

The owner asked for replication "whenever some kind of architectural Spool Hub decision is
taken". The two directions are not symmetric, because one side is public.

### 4.1 Public to private: automatic, a copy

- A public spec is public already, so copying it into a private repo leaks nothing.
- A scheduled workflow of `<PRIVATE_REPO>` (and an action a lane can run) copies each
  public spec listed in `spool-specs/public/LIST` from `<PUBLIC_REPO>` master into
  `spool-specs/public/<NNN>-<slug>/`, and writes `SOURCE` = `<path> <sha>`.
- The copy is read-only: the private CI fails when a file there differs from the public
  file at the recorded sha. A Spool Hub decision is edited in the public spec only.
- `LIST` holds the public specs a private spec cites; the new-spec and lint actions add a
  public spec to it when a private spec links to one.

### 4.2 Private to public: never a copy; a crossing, approved one by one

- Only a **Spool Hub decision** crosses (section 2). A customer decision never does,
  whatever it says.
- A crossing is a NEW text, written for the public repo, never a copy, an excerpt or an
  edit of a private file. It states the decision as Spool Hub behaviour, in the public
  spec it belongs to (an existing one, or a new public number), with no reference to the
  customer: not its name, not its workspace, not "a customer asked".
- Steps, each one a named action with a test:
  1. A private lane writes a **crossing request** in the private crossing log: the
     decision in at most ~10 lines, already in neutral words, and the public spec it
     targets.
  2. The owner says yes to that request, in the customer topic, by message id. One yes
     per crossing; a yes is never a standing approval (Q4: whether the customer's
     business owner approves too).
  3. A **public lane** (a different lane, spawned for it, with a `<PUBLIC_REPO>` worktree
     and no `<PRIVATE_REPO>` checkout) receives ONLY the approved request text, writes the
     public spec change, and pushes it through every public gate (section 5).
  4. The crossing log records the request, the yes (msg id) and the public commit sha.
     The public commit names nothing private: no crossing id, no workspace, no topic.
- Authority after a crossing: the public spec is the source of that decision; section
  4.1 copies it back into the private repo, where the private spec links to it instead of
  restating it.

### 4.3 Until this is built

The interim rule stays: a customer-private spec is kept in the dispatch store of its
topic on the boxes (group-only, never in git), and never in `<PUBLIC_REPO>`.

---

## 5. The leak gate

Goal: customer content cannot reach `<PUBLIC_REPO>` through a lane following a brief, a
copy, or a paste of a private file. Paraphrase is the residual risk; section 5.2 says
what bounds it.

Each layer is mechanical and has a test that plants the thing it refuses. A control that
must turn trunk red runs on a throwaway branch, never on master.

| layer | what it refuses | where it runs | why it is not a ban list |
|---|---|---|---|
| **G1 lane realm** | a push to `<PUBLIC_REPO>` from a private lane | spawn harness + fleet pre-push hook + the seat's keys | It keys on the lane's origin (topic workspace, repo), recorded at spawn in the lane map as `realm=private:<workspace_id>`. The content is never read. |
| **G2 private marker** | any tracked file in `<PUBLIC_REPO>` containing the marker | `<PRIVATE_REPO>` CI requires the marker on every `spool-specs/p*/**` file; `<PUBLIC_REPO>` workflow 10 and pre-push refuse it | The marker is stamped on every private file by construction, so a copy carrying the header is caught without anyone guessing a word. |
| **G3 fingerprint** | a diff that shares an 8-word shingle with a file of a private repo checked out on the box | fleet pre-push hook, against every private checkout in the box-local list | It compares with the actual private text, not a guessed list: a copied paragraph matches even with the header stripped. |
| **G4 private repo visibility** | a sync into a repo that is not private | every action that writes `<PRIVATE_REPO>` (section 3.1) | A fact read from GitHub. |
| **G5 owner yes per crossing** | a crossing without a yes msg id | the crossing action | Human judgement, one decision at a time. |
| G6 hygiene sweep (exists) | listed literals | workflow 10, `do_check_dist_hygiene` | It IS a ban list: kept as the last layer, never cited as proof. |

### 5.1 Layer detail

**G1, lane realm.**
- At spawn, a brief whose source topic belongs to a workspace on the box-local private
  list (Q2) makes a private lane: its lane map row gets `realm=private:<workspace_id>`.
  The list names customers, so it never lives in a tracked file.
- The spawn harness refuses a `<PUBLIC_REPO>` worktree for a private lane, whatever path
  the brief names, and refuses a `<PRIVATE_REPO>` checkout to a lane that already holds a
  `<PUBLIC_REPO>` worktree.
- The fleet pre-push hook of `<PUBLIC_REPO>` reads the pushing agent's lane map row and
  refuses (exit 1) when the realm is private. `SPL_PREPUSH_OVERRIDE` does not skip it.
- A private lane's seat holds no key that can push `<PUBLIC_REPO>` (section 3.2).
- This is the layer that would have stopped the incident of section 1.1, brief or not.
- Tests: hook test with a lane row `realm=private:x` -> refusal; spawn test with a
  private-topic brief naming `csi-spl-doc/specs/...` -> refusal; control: the same with
  `realm=public` -> allowed.

**G2, private marker.**
- Every file under `spool-specs/p*/` carries `<!-- spool-private: <id> -->` on line 1,
  `<id>` = 16 random hex chars per file. `<PRIVATE_REPO>`'s CI fails on a file without
  it; its new-spec action writes it.
- `<PUBLIC_REPO>`: workflow 10's Sweep (and with it the pre-push hygiene part, which runs
  the same step) refuses the marker token anywhere, this spec's own mentions excepted by
  the Sweep's existing allow-line mechanism.
- Tests: plant a file with the marker on a throwaway branch -> workflow 10 red; the
  pre-push hygiene part red locally.

**G3, fingerprint.**
- The box keeps a list of private checkouts (box-local, Q2). The pre-push hook builds the
  normalised 8-word shingles (lower case, punctuation stripped) of the added lines of the
  outgoing diff and of every text file of each listed private checkout, and refuses on a
  common shingle that is not also present in `<PUBLIC_REPO>` master (so shared
  boilerplate does not trip it).
- Nothing private is written anywhere public: the comparison is local, and its refusal
  prints the public file:line and the placeholder name of the private checkout, never the
  private text.
- Public CI cannot run G3 (it has no private text, by design). Instead `<PRIVATE_REPO>`'s
  CI runs the comparison nightly the other way: it reads `<PUBLIC_REPO>` master (public)
  and raises a blocker to the dispatcher on any match. That is detection after the fact,
  stated as such.
- Measure before it may refuse: run G3 over the last 500 public commits against one
  private checkout and report false matches with n, tree and k.
- Tests: a diff with one copied private paragraph minus its marker -> refusal; a diff
  sharing only a public boilerplate sentence -> pass.

### 5.2 What the gate does not prove

- A lane or a human who restates a customer decision in new words, in a public lane, is
  not stopped by G1-G3. G5 bounds it: the only input a public lane gets for a crossing is
  a request text the owner approved.
- A paste by a human outside the fleet (their own git client) is caught only by G2 (when
  the marker came along) and by the nightly G3 detection. Q5 asks for a GitHub-side rule.

---

## 6. Relation to the workspace Docs store

- Source of truth: git, `<PRIVATE_REPO>` `spool-specs/` (the owner: "the Git spec should be
  in the `<PRIVATE_REPO>` project").
- Reading in the WUI: `<CUSTOMER_WORKSPACE>`'s Docs (R3, 075 Phase 2), folder
  `git-specs/`, private to that workspace (spec 114).
- How it gets there: `<PRIVATE_REPO>`'s CI, on a push touching `spool-specs/**`, mirrors
  that tree into the workspace Docs with `PUT /v1/workspace/docs/git-specs/<path>` (and
  `DELETE` for removed files), using an agent upload token of `<CUSTOMER_WORKSPACE>` held
  as a GitHub secret of `<PRIVATE_REPO>`, set by the business owner (R2). No new hub
  route, no hub-side credential for the private repo.
- R1: the text lands in the workspace's GCS Docs bucket, not in Postgres. Whether that
  bucket is acceptable under R1 is Q1.
- `git-specs/` is read-only in the WUI in phase A (an edit there would split the source of
  truth); editing from the WUI is phase B (section 7).
- Messages: `p<NNN>` in a topic of `<CUSTOMER_WORKSPACE>` links to `git-specs/p<NNN>-*` in
  that workspace's Docs; in any other workspace it links to nothing.

---

## 7. Phases

| phase | builds | where |
|---|---|---|
| A0 | G1 (lane realm in the lane map, spawn refusal, pre-push refusal) and G2 (marker refusal in workflow 10 + pre-push) | `<PUBLIC_REPO>` orc, workflow 10 |
| A1 | private repo skeleton action: `spool-specs/`, marker on new files, marker CI check, visibility check (G4), public mirror workflow (4.1) | an orc action run by a private lane against the private repo |
| A2 | Docs mirror workflow (section 6), `p<NNN>` auto-link | private repo CI; WUI id-links |
| A3 | G3 fingerprint in pre-push, after its measurement; the nightly reverse check | `<PUBLIC_REPO>` orc; private repo CI |
| A4 | crossing actions (request, approve by msg id, hand to a public lane, log) | `<PUBLIC_REPO>` orc |
| B | WUI editing of `git-specs/` through 075 repo-edit with a per-workspace target | hub, WUI; only after Q3 |

A0 comes first: it closes the incident's path before any private repo exists.

---

## 8. Acceptance

1. A lane spawned from a `<CUSTOMER_WORKSPACE>` topic whose brief names
   `csi-spl-doc/specs/...` gets no `<PUBLIC_REPO>` worktree, and a push from such a
   lane's seat is refused by the hook (G1 test + control).
2. A file carrying the private marker cannot land on `<PUBLIC_REPO>` master: workflow 10
   is red on a throwaway branch carrying it (G2 control).
3. A private spec pushed to `<PRIVATE_REPO>` appears in `<CUSTOMER_WORKSPACE>`'s Docs
   under `git-specs/` within one CI run, and in no other workspace (114 isolation test).
4. A public spec cited by a private spec appears read-only in `spool-specs/public/` with
   its sha; an edit there fails the private CI.
5. A crossing without an owner yes msg id is refused by the crossing action.
6. No Postgres row holds private spec text: a unique sentence of a test private spec,
   searched in a dump of the dev database -> 0 rows, with a control that plants it and
   finds it.

---

## 9. Open questions for HUM-10

- **Q1. Docs bucket and R1.** The private spec text is stored in the workspace's Docs
  bucket (GCS, not Postgres). Does R1 allow that?
  (a) yes, the bucket is fine (recommended); (b) no, the WUI reads it live from GitHub
  through the customer's App installation, and Spool Hub stores nothing.
- **Q2. Where the list of private workspaces and their repos lives.** It names customers,
  so never in this public repo.
  (a) a box-local file on each fleet box, synced like the dispatch store (recommended);
  (b) a workspace setting in the hub database (a repo name only, no business content).
- **Q3. WUI editing (phase B).** Should members edit private specs from the WUI? That
  needs the customer's business owner to install the GitHub App on `<PRIVATE_REPO>`.
  (a) not now, read-only (recommended); (b) yes.
- **Q4. Who approves a crossing.** (a) the owner, per crossing, by msg id (as written);
  (b) the customer's business owner too, since the request derives from their spec.
- **Q5. Server-side refusal.** Add a GitHub-side rule on `<PUBLIC_REPO>` that refuses the
  private marker at push time, also for pushes made outside the fleet?
  (a) yes, if GitHub offers it for this repo (unchecked; to be checked first);
  (b) no, the fleet gates plus the nightly check are enough.
- **Q6. The agents' key for `<PRIVATE_REPO>`.** (a) a deploy key for that repo only,
  added by the business owner (recommended, as written); (b) the fleet's existing git
  identity added as a collaborator: simpler, but then one seat can push both repos,
  which weakens G1.

---

## 10. Not in scope

- Removing the incident's spec from history (the dispatcher's rewrite).
- Any change to a customer's repository before the owner's yes.
- Credentials of the customer's own systems: they stay GitHub secrets of the customer's
  repository (R2) and are never named here.

## 11. Version log

- v0.1 (2026-10-11, c-998): first draft.
