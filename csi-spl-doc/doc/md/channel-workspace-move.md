# Channel workspace move: plan, run, and read the kept list

SPL-4405, [spec 169](../../specs/169-channel-workspace-move/spec.md) (row
T12; written from spec v0.6, `d159577f1`, and the action as landed in
`29afb52c4` and `8e72f1d7c`). The operator page for moving or copying a
whole channel from one workspace into another.

> **Not wired yet.** The shell action (T9) and the box steps (T10) are on
> master. The hub's operator endpoint (T7, with the store rows T4, T5 and
> T8 behind it) is not. Until it lands, the action stops with
> `FATAL the hub's channel move endpoint (spec 169 T7) is not wired yet`,
> exit 2. Every part below that waits for it says **[pending T7]**.

The `OK` and `FATAL` lines quoted below are the action's log text; `./run`
shows them with its own level prefix (`[OK]`, `[FATAL]`).

Placeholders, because the repository is public: `<SRC>` the workspace the
channel leaves, `<DST>` the workspace it goes to, `<CHANNEL>` the channel id,
`<SRC_HOST>` / `<DST_HOST>` their web hosts, `<ENV>` is `dev` or `prd`.

## 1. What it does

### 1.1 Move and copy

- **Move**: the channel and everything that belongs to it (its *set*, spec
  section 4) end up in `<DST>`; afterwards `<SRC>` holds no row, object or
  index entry that names them, except the copies in the kept list (section
  4 of this page).
- **Copy**: `<DST>` gets its own channel with the same set under new ids;
  `<SRC>` is only read and stays unchanged. A copy is a snapshot that lives
  on by itself (owner, spec Q1 = A). Members, seats and lanes are not
  copied: the copy starts with the owner as its only member.

### 1.2 What it is not

- A channel's work moving to another **box** in the same workspace is
  [spec 167](../../specs/167-channel-box-move/spec.md). A move that is also a
  move between boxes runs spec 167 first, then this one (spec R5).
- A topic moving to another channel inside one workspace is
  [spec 045](../../specs/045-spool-move-by-drag/spec.md) (move by drag).

### 1.3 Who may run what

| step | who |
|---|---|
| `plan` (the default, changes nothing) | the orchestrator seat or the owner |
| `MOVE_CMD=run` with `DRY_RUN=1` (the default, prints the steps) | the orchestrator seat or the owner |
| `MOVE_CMD=run DRY_RUN=0` (the move or copy itself) | the owner only: the run carries, in `MOVE_GO_MSG`, the msg id of the owner's `(GO) Go` poll answer for THAT channel and target, and the journal records it |

A `DRY_RUN=0` run without a `MOVE_GO_MSG` uuid is refused before anything
is called, exit 3 (spec case C15). An agent never runs `DRY_RUN=0` on its
own judgement; it sends the plan's output to the owner and waits.

The first prd move (owner, Q7, spec 11.1): `<SRC>` = csitea, `<CHANNEL>` =
the csitea channel named like the workspace `ws-hidden-17`, `<DST>` =
`ws-hidden-17`. It runs only after the dev rehearsal (spec T13): on dev,
`plan` then `DRY_RUN=0` of a seeded channel between two dev test
workspaces, with the owner's GO msg id, P7 printing 0 and the journal read
back.

## 2. Plan

### 2.1 Run the plan

The plan of a move:

```bash
cd csi-spl-orc && ENV=<ENV> CHANNEL=<SRC>/<CHANNEL> TO=<DST> ./run -a do_spl_channel_workspace_move
```

The plan of a copy:

```bash
cd csi-spl-orc && ENV=<ENV> CHANNEL=<SRC>/<CHANNEL> TO=<DST> MOVE_MODE=copy ./run -a do_spl_channel_workspace_move
```

`MOVE_CMD=plan` is the default, so both commands change nothing (spec case
C1). The input is checked before the hub is called: `ENV` is `dev` or
`prd`, `CHANNEL` is `<SRC>/<channel id>`, `TO` is another workspace's slug;
a bad value stops with a `FATAL`, exit 1. **[pending T7: the hub answers
the plan.]**

### 2.2 Read the plan

The plan prints one line per item, in this order:

| line | what |
|---|---|
| `PLAN count <item> <n>` | the set, one count per item (spec section 4, M1-M12) |
| `PLAN seat <agent> on <box>` | an agent seated in the channel and the box of its desk |
| `PLAN mention outside the set: ...` | a post in another `<SRC>` channel, another person's DM or a staying Qto doc that links a moved topic or names the channel (spec 5.4). They are left as they are and only listed (owner, Q4 = A) |
| `PLAN member not in the target: ...` | a person of the channel who is not a member of `<DST>`. They lose access; only the members the owner adds to `<DST>` come along, with their read state, hours rows and calendar guest rows (owner, Q5 = A) |
| `PLAN kept <store> until <date>` | the kept list (section 4 of this page) |
| `REFUSE seat <agent> on <box> has no desk in <DST>` | the agent needs a desk in `<DST>` first (spec case C11; seat it with [spec 158](../../specs/158-new-workspace-automatic/spec.md)) |
| `REFUSE shared item ...` | a file, Qto doc, issue, epic or spec sync row the channel uses that something staying in `<SRC>` also uses (spec 5.5). The move stops; the owner decides each one (owner, Q6 = A) |
| `REFUSE ...` | any other refusal of the hub, for example a channel with a website-chat visitor (spec 5.1b), hours rows of a member who does not come along or inside a frozen or approved time sheet (spec 5.1a, owner Q8 = A), or a `<DST>` with no orchestrator seat |

With no `REFUSE` line the plan ends with
`OK plan of <SRC>/<CHANNEL> -> <DST> (move): nothing changed. Run it: MOVE_CMD=run`.
With one or more it ends with `FATAL the plan ... refuses (<n> item(s) above); nothing changed`,
exit 3.

### 2.3 Clear the plan before a run

A run is ready when the plan prints no `REFUSE` line and the owner has read
the members, the mentions and the kept list. For hours rows the owner
either reopens the time sheet or adds the member to `<DST>` (the rows then
move), or says to leave the rows in `<SRC>` (they become a kept item). A
channel named `<CHANNEL>` that already exists in `<DST>` blocks the run;
give the new channel another id with `TO_NAME=<new id>`.

## 3. Run

### 3.1 See the steps first

`MOVE_CMD=run` with the default `DRY_RUN=1` reads the journal and prints
the steps a real run would do, changing nothing:

```bash
cd csi-spl-orc && ENV=<ENV> CHANNEL=<SRC>/<CHANNEL> TO=<DST> MOVE_CMD=run ./run -a do_spl_channel_workspace_move
```

It ends with `OK DRY_RUN move <move id> ... would run P1 P2 P2b P3 P4 P5 P6 P7`
(`<new>` in place of the move id before P1 has run).

### 3.2 The owner's run of a move

A move needs three values besides the owner's GO: `MOVE_GO_MSG` (the msg
id of the owner's `(GO) Go` poll answer), `MOVE_CALLER` (the `<DST>`
orchestrator seat, `<agent id>[@<box>]`, which receives the P2b probe DMs;
never a `HUM-` id, the hub refuses a probe DM to a person) and `AGENT_ID`
(the agent the P5 lane notes come from):

```bash
cd csi-spl-orc && ENV=<ENV> CHANNEL=<SRC>/<CHANNEL> TO=<DST> MOVE_CMD=run DRY_RUN=0 MOVE_GO_MSG=<GO msg id> MOVE_CALLER=<orchestrator seat> AGENT_ID=<agent id> ./run -a do_spl_channel_workspace_move
```

Run it on the machine that holds the desks of the channel's seats: P2b
probes only the desks on the machine that runs the move, and a seat whose
`<DST>` desk is elsewhere fails its probe, which stops the move before P3.

### 3.3 The owner's run of a copy

A copy has no P2b and no P5, so it needs only `MOVE_GO_MSG`:

```bash
cd csi-spl-orc && ENV=<ENV> CHANNEL=<SRC>/<CHANNEL> TO=<DST> MOVE_MODE=copy MOVE_CMD=run DRY_RUN=0 MOVE_GO_MSG=<GO msg id> ./run -a do_spl_channel_workspace_move
```

### 3.4 The steps

The run walks the steps of spec section 8.2 and marks each in the hub's
journal. A move runs P1 P2 P2b P3 P4 P5 P6 P7; a copy P1 P2 P3 P4 P7.

| step | where | what | if it fails |
|---|---|---|---|
| P1 | hub | freeze the set in the journal (kept in `<DST>`); returns the move id | nothing changed |
| P2 | hub | check `<DST>`, the caller, the name, quotas, desks, the orchestrator seat, shared items, hours | nothing changed |
| P2b | box | each seat sends one probe DM through its `<DST>` desk to `MOVE_CALLER`, on the task = the move id; a dead desk stops the run here | nothing changed but the probe DMs, which stay in `<DST>` as part of the journal |
| P3 | hub | copy blobs and Qto objects to `<DST>` | re-run; the copy is idempotent |
| P4 | hub | one database transaction: insert the set under `<DST>`, delete it in `<SRC>` (a move), recompute counters, bump change stamps | the transaction rolls back as a whole; both workspaces are as before (spec case C5) |
| P5 | box | the channel's row of the box map `$SPOOL_ROOT/channel-rules.tsv` gets `<DST>` (and `TO_NAME`) in columns 1-2; one spool note per lane whose issue key changed | re-run; it resumes at P5 and sends only the missing notes |
| P6 | hub | a move only: delete the `<SRC>` blobs and Qto objects no staying row lists | re-run; it resumes from the journal |
| P7 | hub | run every proof and write the results into the journal; prints `proof <name> <count>` per proof | a proof that is not 0 is a `FATAL`, exit 1 (section 5.1) |

Every hub step is **[pending T7]**. Each step done prints `OK <step> of move <move id> done`;
the run ends with `OK move <move id> of <SRC>/<CHANNEL> -> <DST> (move) done`.

### 3.5 Resume after a stop

A re-run with the same `CHANNEL` and `TO` reads the journal and starts at
the first step not marked done. `MOVE_FROM=<step>` starts at that step
instead, but only P5, P6 or P7 once P4 has committed: a `MOVE_FROM` of P1
to P4 then is refused, exit 3 (spec case C17). A re-run of a fully done
move prints `OK move <move id> ... is done: nothing to do`.

Two runs of the same channel never overlap: the second one stops with
`FATAL another move of <SRC>/<CHANNEL> runs`, exit 3 (lock
`$SPOOL_ROOT/channel-move/<SRC>.<CHANNEL>.lock`).

The box steps keep their own journal, `$SPOOL_ROOT/channel-move/<move id>/box.tsv`,
one row per probe, rule row and lane note done, so a re-run sends no second
probe DM, no second note and no second rewrite.

### 3.6 When P5 refuses the rule row

P5 rewrites only the channel's `<SRC>` row of the box map. If the map
already has a `<DST>` row for the same channel name beside it, P5 stops,
exit 3, and changes nothing: resolve the two rows by hand, then re-run (it
resumes at P5). A box with no map, or with no row for the channel, is not
an error: P5 says so and goes on.

### 3.7 The short window after P4

Between the P4 commit and the end of P5, a lane that posts into a moved
topic through its `<SRC>` desk is refused by the hub (spec W2, case C8).
P5 follows P4 at once in the same run, so the window is short.

T10 did not test what the box does with that refusal. What the desk does
on master today with any refusal (`hubclient/flush.go`, `sendPending`): a
4xx answer is not retried; the post moves to the desk's
`spool/.hub/rejected/` with a `<file>.reason` beside it (the hub's status,
token and detail) and one `ERROR` log line; a 5xx stays pending and is
retried on the next flush. Which status the hub gives a post into a moved
task is fixed by T7 **[pending T7]**. After the run, look in the `<SRC>`
desks' `rejected/` for posts of that window and send them again through the
`<DST>` desk (same `--task`: the topic id did not change).

## 4. Read the kept list

### 4.1 What it is

"Not even a trace" covers the live system. Some copies of `<SRC>` already
hold the channel and cannot be edited row by row; the move does not touch
them. The plan prints them as `PLAN kept <store> until <date>`, and P7
prints the date the last one goes (spec 5.6). They are kept until they
expire on their own (owner, Q3 = A).

| copy | holds | why it stays | gone by |
|---|---|---|---|
| daily DB dumps (step 045) | the whole database | one file for every workspace; editing it breaks the backup | its retention, 30 days |
| off-project backup copy (step 046) | the same dumps | its writer may add, never delete, by design; only the owner can remove an object, by hand | its retention, 30 / 90 days |
| Cloud SQL automated backups | the whole database | managed by Cloud SQL, not per row | its retention, read by the plan (spec R4) **[pending T7]** |
| `<SRC>` Qto daily export (step 052 `backup/`) | `<SRC>`'s docs | one file per day per workspace | 30 days |
| soft-deleted bucket objects (step 052) | the moved files and Qto objects | the bucket keeps them for its soft-delete time | 7 days |
| box-state copy (step 056) | transcripts, the spool root | one nightly archive per box | 30 days |
| hub logs (Cloud Logging) | request lines with ids | append-only by design | the log bucket's retention, read by the plan (spec R4) **[pending T7]** |
| mail and notifications already sent | text sent to people | outside the system | never |
| git history of this repository | commit subjects, specs and dispatch notes citing a task id or an issue key | history is forward-only; no force-push | never |
| hours rows the owner said to leave (spec 5.1a) | a member's time record that names the channel | it is the member's signed or kept time sheet | never, unless the owner deletes it |
| box spool archives, transcripts, worktrees | the agents' copies of the channel's posts | the agents need them to continue the work; they name no workspace | spec 167's cleanup, if the channel also leaves its box |

### 4.2 Read the dates

Each kept line ends with the date its last copy goes. The latest of those
dates is the day after which the channel survives only in the "never"
rows: mail already sent, git history, the hours rows the owner left and the
boxes' copies.

## 5. After the move

### 5.1 Read the proofs

P7 prints one `proof <name> <count>` line per proof and writes them into
the journal. Every proof runs in `<SRC>` and must print 0: the database
rows of the set (spec 5.1), a scan of every text, jsonb, uuid and array
column of every `<SRC>` table for the channel id, its name and every task
and msg UUID (spec 5.2), and each moved bucket object (spec 5.3). A count
that is not 0 stops the run with `FATAL P7: a proof of section 5 is not 0`,
exit 1: the move is not done; send the move id and the proof lines to the
orchestrator. **[pending T7, T8.]**

The free-text scan proves only that those exact strings are absent. It
cannot prove that nobody described the channel in other words in a post,
and this page does not claim it (spec R6).

### 5.2 What changes for the people and the agents

- **Topic and post ids stay the same** in a move (not in a copy), so a
  lane's `--task <uuid>`, its brief and its dispatch files still work; only
  the desk its posts go through changes (P5).
- **Issue keys change**: each moved issue gets a new `<DST>` key; its first
  event holds the old key, and each lane whose issue key changed gets one
  note: `Channel move <move id>: your issue key changed, <old> -> <new>`.
  Cite the new key from then on. For 30 days an old key maps to the new one,
  then it closes nothing (owner, Q2 = A).
- **Links**: a moved topic's link is `https://<DST_HOST>/t/<uuid>`. For 30
  days an old `https://<SRC_HOST>/t/<uuid>` link redirects and a post to a
  moved topic at `<SRC>` is re-routed; then both are a 404 (owner, Q2 = A).
- **Members**: only the people the owner added to `<DST>` keep the channel;
  the others lose access (owner, Q5 = A).
- **Open polls, claims and parked rows** travel with their rows and can be
  answered in `<DST>` right after the move.
- **Open web clients** refetch on the bumped change stamps: a `<SRC>` client
  drops the channel, a `<DST>` client shows it. A browser that is offline
  keeps its local copy until it next loads.
- **Encrypted posts** stay readable only by the boxes they were encrypted
  for; a move does not change that (spec R2).

### 5.3 The journals

The hub's journal lives in `<DST>` on purpose: it is the record that the
channel came from somewhere, kept where the channel now is. It holds the
mode, the `<SRC>` slug, the channel id, the frozen id lists, the owner's GO
msg id, the P2b probe msg ids and one row per step with its times, counts
and proof results. `<SRC>` gets no audit row for the move. The action reads
it through the hub at the start of every run; to see where a move stands,
run section 3.1 (it prints the steps still to do). **[pending T7: the
table (T2) and the endpoint that reads it.]**

The box journal is `$SPOOL_ROOT/channel-move/<move id>/box.tsv`, one row
per step done on this box: `<kind> TAB <key> TAB <value> TAB <utc>`, with
kind `probe` (agent, msg id), `rule-row` (`<SRC>/<CHANNEL>`,
`<DST>/<name>`) or `note` (`<agent>:<old key>`, new key).

## 6. Where the rest is

- The design, every store the move touches and every case:
  [spec 169](../../specs/169-channel-workspace-move/spec.md).
- The action (T9): `csi-spl-orc/src/bash/run/spl-channel-workspace-move.func.sh`,
  its test `csi-spl-orc/src/bash/tests/spl-channel-workspace-move.tst.sh`.
- The box steps (T10):
  `csi-spl-orc/src/bash/features/spawn-agents/scripts/channel-workspace-move-box.sh`,
  its test `csi-spl-orc/src/bash/features/spawn-agents/tests/test-channel-workspace-move-box.sh`.
- The hub endpoint (T7) **[pending T7]**: `csi-spl-api/src/go/spool-hub-api/internal/hub/channel_move.go`.
