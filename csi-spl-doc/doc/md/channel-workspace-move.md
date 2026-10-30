# Channel workspace move: plan, run, and read the kept list

SPL-4405, [spec 169](../../specs/169-channel-workspace-move/spec.md) (row
T12; written from spec v0.3, `103f9c642`). The operator page for moving or
copying a whole channel from one workspace into another.

> **DRAFT.** Nothing of spec 169 is built yet: the action, the hub endpoint
> and the box steps are rows T1-T11 of the spec. Every part below that
> depends on an unbuilt row says so with **[pending Tn]**. The owner has not
> answered the spec's questions (section 11, Q1-Q7) yet; where an answer
> changes what the operator sees, the page names the question and shows the
> spec's recommended option as **[pending Qn]**. This page is finished last,
> after lanes L7 and L8 land.

Placeholders, because the repository is public: `<SRC>` the workspace the
channel leaves, `<DST>` the workspace it goes to, `<CHANNEL>` the channel id,
`<SRC_HOST>` / `<DST_HOST>` their web hosts.

## 1. What it does

### 1.1 Move and copy

- **Move**: the channel and everything that belongs to it (its *set*, spec
  section 4) end up in `<DST>`; afterwards `<SRC>` holds no row, object or
  index entry that names them, except the copies listed in the kept list
  (section 4 of this page).
- **Copy**: `<DST>` gets its own channel with the same set under new ids;
  `<SRC>` is only read and stays unchanged. A copy is a snapshot that lives
  on by itself **[pending Q1]**. Members, seats and lanes are not copied:
  the copy starts with the owner as its only member.

### 1.2 What it is not

- A channel's work moving to another **box** in the same workspace is
  [spec 167](../../specs/167-channel-box-move/spec.md). A move that is also a
  move between boxes runs spec 167 first, then this one (spec R5).
- A topic moving to another channel inside one workspace is
  [spec 045](../../specs/045-spool-move-by-drag/spec.md) (move by drag).

### 1.3 Who may run what

| step | who |
|---|---|
| `plan` (the default, a dry run) | the orchestrator seat or the owner |
| `DRY_RUN=0` (the move or copy itself) | the owner only: the run carries the msg id of the owner's `(GO) Go` poll answer for THAT channel and target, and the journal records it |

A `DRY_RUN=0` without that GO msg id is refused before anything changes,
exit 3 (spec case C15) **[pending T7, T9]**. An agent never runs
`DRY_RUN=0` on its own judgement; it sends the plan's output to the owner
and waits.

## 2. Plan

### 2.1 Run the plan

The plan of a move:

```bash
cd csi-spl-orc && CHANNEL=<SRC>/<CHANNEL> TO=<DST> ./run -a do_spl_channel_workspace_move
```

The plan of a copy:

```bash
cd csi-spl-orc && CHANNEL=<SRC>/<CHANNEL> TO=<DST> MOVE_MODE=copy ./run -a do_spl_channel_workspace_move
```

`MOVE_CMD=plan` is the default, so both commands above change nothing
(spec case C1: a row count of every tenant table is equal before and
after). **[pending T9 for the action, T4 for the set it prints; L8's first
landing is the plan-only stub.]**

### 2.2 Read the plan

The plan prints, in this order **[pending T4, T9; the exact layout is
filled in when they land]**:

1. **The set**, one count per item (spec section 4, M1-M12): the channel,
   its topics and posts with their threads, the posts' children (revisions,
   reactions, polls and answers, deliveries, read marks), the attachments,
   members and seats, topic state, issues, Qto docs, DM links, usage and
   budget rows, fleet references and the box state.
2. **Shared items** (spec 5.5): a file, Qto doc, issue or epic the channel
   uses that a channel staying in `<SRC>` also uses. With the recommended
   default the move refuses while any is listed, and the owner decides each
   one **[pending Q6]**.
3. **Mentions outside the set** (spec 5.4): posts in other `<SRC>` channels,
   other people's DMs and staying Qto docs that link a moved topic or name
   the channel, each with its link, author and line. With the recommended
   default they are left as they are **[pending Q4]**.
4. **Missing desks**: every agent seated in the channel needs a desk in
   `<DST>` on its box. The plan refuses and names each agent without one
   (spec case C11). Seat a desk in `<DST>` first
   ([spec 158](../../specs/158-new-workspace-automatic/spec.md)).
5. **Members who are not in `<DST>`**: they lose access to the channel; add
   to `<DST>` first whom you want to keep **[pending Q5]**.
6. **Unpinned boxes**: every box that signed a post of the set must be
   pinned in `<DST>`, or its posts are stored but cannot be re-verified
   there (spec R1) **[pending T4]**.
7. **The kept list** (section 4 of this page), with the date each copy
   expires.
8. **The proof queries** that P7 will run after the move (spec section 5).

### 2.3 Clear the plan before a run

A run is ready when the plan lists no missing desk, no unresolved shared
item and no unpinned box, and the owner has read the members list, the
mentions and the kept list. A channel named `<CHANNEL>` that already exists
in `<DST>` blocks the run; give the new channel another id with
`TO_NAME=<new id>`.

## 3. Run

### 3.1 The owner's run of a move

```bash
cd csi-spl-orc && CHANNEL=<SRC>/<CHANNEL> TO=<DST> DRY_RUN=0 ./run -a do_spl_channel_workspace_move
```

### 3.2 The owner's run of a copy

```bash
cd csi-spl-orc && CHANNEL=<SRC>/<CHANNEL> TO=<DST> MOVE_MODE=copy DRY_RUN=0 ./run -a do_spl_channel_workspace_move
```

**[pending T7, T9: the name of the variable that carries the owner's GO msg
id is fixed when the action lands.]**

### 3.3 The steps

The run walks the steps of spec section 8.2 and marks each in the journal
**[pending T5-T10]**:

| step | what | if it fails |
|---|---|---|
| P1 | freeze the set in the journal (kept in `<DST>`) | nothing changed |
| P2 | check `<DST>`, the caller, the name, quotas, desks, shared items | nothing changed |
| P2b | each seated agent sends one probe DM through its `<DST>` desk; a dead desk stops the run here | nothing changed but the probe DMs, which stay in `<DST>` as part of the journal |
| P3 | copy blobs and Qto objects to `<DST>` | re-run; the copy is idempotent |
| P4 | one database transaction: insert the set under `<DST>`, delete it in `<SRC>` (a move), recompute counters, bump change stamps | the transaction rolls back as a whole; both workspaces are as before (spec case C5) |
| P5 | box steps: the channel's rule rows point at `<DST>`, lanes get a note for each changed issue key | re-run; it resumes from the journal |
| P6 | a move only: delete the `<SRC>` blobs and Qto objects no staying row lists | re-run; it resumes from the journal |
| P7 | run every proof and write the results into the journal; print the kept list | re-run; it resumes from the journal |

P1 to P4 can be re-run from the start until P4 commits. After P4 commits, a
re-run resumes at the first step not marked done, and a re-run from P1 is
refused (spec case C17).

### 3.4 The short window after P4

Between the P4 commit and the end of P5, a lane that posts into a moved
topic through its `<SRC>` desk is refused by the hub (spec W2, case C8).
P5 follows P4 at once in the same run, so the window is short.
**[pending T10: whether the box retries such a refusal or files it as
rejected is not checked on master; T10 tests it and this paragraph then
says which, and what the operator does about a rejected post.]**

## 4. Read the kept list

### 4.1 What it is

"Not even a trace" covers the live system. Some copies of `<SRC>` already
hold the channel and cannot be edited row by row; the move does not touch
them. The run prints them, each with the date the last copy expires
(spec 5.6). With the recommended default they are kept until they expire
on their own **[pending Q3; option B purges what can be purged now and
leaves the off-project backups for the owner to remove by hand]**.

| copy | holds | why it stays | gone by |
|---|---|---|---|
| daily DB dumps (step 045) | the whole database | one file for every workspace; editing it breaks the backup | its retention, 30 days |
| off-project backup copy (step 046) | the same dumps | its writer may add, never delete, by design; only the owner can remove an object, by hand | its retention, 30 / 90 days |
| Cloud SQL automated backups | the whole database | managed by Cloud SQL, not per row | its retention, read by the plan **[pending T4; spec R4]** |
| `<SRC>` Qto daily export (step 052 `backup/`) | `<SRC>`'s docs | one file per day per workspace | 30 days |
| soft-deleted bucket objects (step 052) | the moved files and Qto objects | the bucket keeps them for its soft-delete time | 7 days, or at once under Q3 option B |
| box-state copy (step 056) | transcripts, the spool root | one nightly archive per box | 30 days |
| hub logs (Cloud Logging) | request lines with ids | append-only by design | the log bucket's retention, read by the plan **[pending T4; spec R4]** |
| mail and notifications already sent | text sent to people | outside the system | never |
| git history of this repository | commit subjects, specs and dispatch notes citing a task id or an issue key | history is forward-only; no force-push | never |
| box spool archives, transcripts, worktrees | the agents' copies of the channel's posts | the agents need them to continue the work; they name no workspace | spec 167's cleanup, if the channel also leaves its box |

### 4.2 Read the dates

Each row of the printed list ends with the date its last copy goes. The
latest of those dates is the day after which the channel survives only in
the "never" rows: mail already sent, git history and the boxes' copies.

## 5. After the move

### 5.1 Read the proofs

P7 writes one result per proof into the journal. Every proof runs in
`<SRC>` and must print 0: the database rows of the set (spec 5.1), a scan of
every text, jsonb, uuid and array column of every `<SRC>` table for the
channel id, its name and every task and msg UUID (spec 5.2), and each moved
bucket object (spec 5.3). **[pending T8.]** A proof that prints more than 0
means the move is not done; send the journal id and the proof's output to
the orchestrator.

The free-text scan proves only that those exact strings are absent. It
cannot prove that nobody described the channel in other words in a post,
and this page does not claim it (spec R6).

### 5.2 What changes for the people and the agents

- **Topic and post ids stay the same** in a move (not in a copy), so a
  lane's `--task <uuid>`, its brief and its dispatch files still work; only
  the desk its posts go through changes (P5).
- **Issue keys change**: each moved issue gets a new `<DST>` key; its first
  event holds the old key, and each lane whose issue key changed gets one
  note old -> new. Cite the new key from then on. An old key maps to the new
  one for 30 days, then closes nothing **[pending Q2]**.
- **Links**: a moved topic's link is `https://<DST_HOST>/t/<uuid>`. An old
  `https://<SRC_HOST>/t/<uuid>` link redirects for 30 days, then 404s
  **[pending Q2; option B is 404 at once]**.
- **Open polls, claims and parked rows** travel with their rows and can be
  answered in `<DST>` right after the move.
- **Open web clients** refetch on the bumped change stamps: a `<SRC>` client
  drops the channel, a `<DST>` client shows it. A browser that is offline
  keeps its local copy until it next loads.
- **Encrypted posts** stay readable only by the boxes they were encrypted
  for; a move does not change that (spec R2).

### 5.3 The journal

The journal lives in `<DST>` on purpose: it is the record that the channel
came from somewhere, kept where the channel now is. It holds the mode, the
`<SRC>` slug, the channel id, the frozen id lists, the owner's GO msg id and
one row per step with its times, counts and proof results. `<SRC>` gets no
audit row for the move. **[pending T2 for the table; how to read it is
filled in when T9 lands.]**

## 6. Where the rest is

- The design, every store the move touches and every case:
  [spec 169](../../specs/169-channel-workspace-move/spec.md).
- The action **[pending T9]**:
  `csi-spl-orc/src/bash/run/spl-channel-workspace-move.func.sh`.
- The box steps **[pending T10]**:
  `csi-spl-orc/src/bash/features/spawn-agents/scripts/channel-workspace-move-box.sh`.
