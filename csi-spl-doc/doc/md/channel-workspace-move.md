# Channel workspace move: plan, run, and read the kept list

SPL-4405, [spec 169](../../specs/169-channel-workspace-move/spec.md) (row
T12; written from spec v0.17 and the code on master at `15789e9ea`). The
operator page for moving or copying a
whole channel from one workspace into another.

> **Built on master, rehearsed once on dev, never run on prd.** The hub answers the plan of a
> move, every step P1 to P7, the journal, the owner's GO check and the refusal of a post into a
> moved topic (T7), and a box re-routes that post (T7b).
>
> **The dev rehearsal (T13) moved 3650 posts in one run; it is not passed:** P7 failed
> `proof scan messages.body 1`, on a staying post that links a moved topic (n=1). So today **a channel
> stops at P7, after its rows have moved, when a row left in `<SRC>` holds a full task or msg UUID of the set, or the channel's id or name as a whole word, in a column the scan reads; the fleet topic ids are excepted** (spec R7, row T13b). P4 took 4.42 s, under the box's
> 30 s cap (n=1). P7 took about 9 s with 5 messages in `<SRC>`: on a populated `<SRC>` it is not
> measured. It did not exercise a real `<DST>` desk, Qto docs, hours rows or the old link over HTTP.
> Record:
> [dev-rehearsal.md](../../specs/169-channel-workspace-move/dev-rehearsal.md).
>
> What still waits:
>
> - **The menu entry:** there is none yet; this action is the only door (spec section 8.5).
> - **Copy:** every `op` of a copy answers 501 `not_built` (T11).
> - **The owner's exceptions:** the hub reads them from a step's `detail` (T7d), but this action does
>   not send them (section 2.4).
> - **The last date:** `KEPT_UNTIL` always prints `not read: no date for hub logs` (row T13c).
>
Every part below that waits says **[pending <row>]**, or says no row owns it.

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
| taking out seats that do not move, `DRY_RUN=0` on `prd` (section 2.1) | under the owner's GO for that move, which lists the seats by name |
| `plan` (the default, changes nothing) | the orchestrator seat or the owner |
| `MOVE_CMD=run` with `DRY_RUN=1` (the default, prints the steps) | the orchestrator seat or the owner |
| `MOVE_CMD=run DRY_RUN=0` (the move or copy itself) | the owner only: the run carries, in `MOVE_GO_MSG`, the msg id of the owner's `(GO) Go` poll answer for THAT channel and target, and the journal records it |

A `DRY_RUN=0` run without a `MOVE_GO_MSG` uuid is refused before anything
is called, exit 3 (spec case C15). The hub then checks the GO on every `step`
and `mark` and refuses with 403 `go_required` unless all of these hold:

- the message is in the operator workspace, is not a copy, and its author is
  that workspace's biz owner;
- it is a poll answer: a `Poll: <form msg id>` line and an `Answer: GO` line
  ("Chat: wants to discuss" is not a GO);
- the poll form is in the same topic, is not a copy, and its text names
  `<SRC>/<CHANNEL>` and `<DST>` as whole slugs. **Write both into the form**,
  or the answer does not open this move.

The hub does not check whether the owner answered again later. P1 stores the GO
in the journal: every later call of that move carries the same msg id, and
another one is refused with 409 `move_refused`. A journal read needs no GO. An
agent never runs `DRY_RUN=0` on its own judgement; it sends the plan's output to
the owner and waits.

The first prd move (owner, Q7, spec 11.1): `<SRC>` = csitea, `<CHANNEL>` =
the csitea channel named like the workspace `ws-hidden-17`, `<DST>` =
`ws-hidden-17`. It runs only after a dev rehearsal (spec T13) passes: on dev,
`plan` then `DRY_RUN=0` of a seeded channel between two dev test
workspaces, with the owner's GO msg id, P7 printing 0 and the journal read
back. The first one did not pass (the box above). The calendar half of case C18 comes before both the rehearsal and that
move (spec row T7c) **[pending T7c]**. The box re-route (T7b), also a prerequisite,
is on master.

## 2. Plan

### 2.1 Before the plan: seats that do not move

A move only. The action below is on master and works today. `plan` refuses every seat of the channel that has no
`<DST>` desk on its box (spec W2, case C23; the store's check is
`mpMissingDesks` in `channel_move_plan_postgres.go`). An agent that is not
meant to move leaves the channel first, or the plan stops on it.

See the change first (a dry run, it calls no cloud):

```bash
cd csi-spl-orc && ENV=<ENV> TENANT_ID=<SRC> CHANNEL=<CHANNEL> AGENT_BOX=<box> AGENTS="<agent> <agent>" ./run -a do_spl_channel_agent_remove_op
```

Then take the seats out:

```bash
cd csi-spl-orc && ENV=<ENV> TENANT_ID=<SRC> CHANNEL=<CHANNEL> AGENT_BOX=<box> AGENTS="<agent> <agent>" DRY_RUN=0 ./run -a do_spl_channel_agent_remove_op
```

- **What it does:** the seat's origin becomes `removed`, which the hub reads
  as not a member and a later announce cannot undo. The agent's desk seat and
  roster row stay, so DMs and @mentions still reach it.
- **One box per run:** `AGENT_BOX` defaults to the box's desk id; a seat on
  another box needs its own run. An agent with no live seat is reported as
  absent and changes nothing.
- **Who:** with `DRY_RUN=0` on `prd` this is a prd write. It belongs to the
  owner's GO for that move, and the question to the owner lists the seats by
  name.
- **What it does not clear:** two other sources of the same refusal. A
  channel-scope `dedicated_agents` binding is counted too; the remove action
  leaves it, and `DEDICATED_CMD=unbind` of `do_spl_dedicated_bind` removes it.
  A `REFUSE box rule` line comes from the box's `channel-rules.tsv` (spec
  case C25); a `<DST>` desk for that agent clears it.
- **A copy:** a copy moves no seat and leaves `<SRC>` unchanged, so do not take
  seats out for one. The hub answers the plan of a copy with 501 `not_built`
  today, and the store's check has no mode, so whether a copy's plan skips this
  check is open **[pending T11]**. The shell's own box rule check (section 2.3)
  already skips a copy.

### 2.2 Run the plan

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
a bad value stops with a `FATAL`, exit 1. The hub also refuses, with 400
`bad_channel`, a default channel: it never moves.

Both commands call the hub's endpoint, `POST /v1/operator/channel-moves` on
`https://<env.dns.api_fqdn>`, as the env's service account (its key
`$HOME/.gcp/.csi/key-csi-spl-<env>.json`) with a Google ID token; the account
must be on the hub's operator allow-list. With no key the action stops with a
`FATAL` before any call; it never falls back to the owner account. Any answer
but HTTP 200 is a refusal. `CHANNEL_MOVE_HUB_CMD` replaces the call in the
tests only.

The action prints a refusal of the hub as `FATAL the hub refused <op> ...` with
the hub's answer, exit 1. The plan of a copy ends there today **[pending
T11]**.

### 2.3 Read the plan

The plan prints one line per item, in this order:

| line | what |
|---|---|
| `PLAN count <table> <n>` | the set, one count per table of the move catalogue; `<table> refs` counts rows that refer to the set without being in it (spec section 4, M1-M12) |
| `PLAN seat <agent> on <box>` | an agent seated in the channel and the box of its seat, with a `<DST>` desk or without one (case C27). P2b probes these seats |
| `PLAN mention outside the set: ...` | one JSON object per post in another `<SRC>` channel, another person's DM or a staying Qto doc that links a moved topic or names the channel (spec 5.4). They are left as they are and only listed (owner, Q4 = A) |
| `PLAN member not in the target: ...` | a person of the channel who is not a member of `<DST>`. They lose access; only the members the owner adds to `<DST>` come along, with their read state, hours rows and calendar guest rows (owner, Q5 = A) |
| `PLAN shared file <file id>: ...` | a file a staying post in `<SRC>` also lists: copied, not deleted in `<SRC>` (spec case C6). It does not refuse the move |
| `PLAN kept <store> until <what ends it>` | the kept list (section 4 of this page) |
| `PLAN retention Cloud SQL backups: ...`, `PLAN retention log bucket <name>: ...` | how long those two copies live, read as the per-env service account (spec R4). A value it cannot read prints as `not read: <reason>`; it never refuses |
| `PLAN box rule: ...` | a move only: what this box's `channel-rules.tsv` says about the channel. A box reads only its own file: **run the plan on every box that works the channel**. It names each other box that holds a seat: `run this plan on box <box> too` |
| `REFUSE seat <agent> on <box> has no desk in <DST> (W2)` | the agent needs a desk in `<DST>` first (spec case C11; seat it with [spec 158](../../specs/158-new-workspace-automatic/spec.md)), or, if it is not meant to move, leaves the channel (section 2.1) |
| `REFUSE box <box> is not pinned in <DST> (R1)` | a box that posted in the channel has no pin in `<DST>`. Pinning it clears the line; it does not make that box's old rows verify there (section 5.2) |
| `REFUSE box rule: ...` | this box's rule row names a desk agent with no `<DST>` desk on this box, or the plan cannot tell (spec case C25). A `<DST>` desk for that agent clears it |
| `REFUSE shared <kind> <id>: <why>` | a Qto doc, issue, epic or spec sync row the channel uses that something staying in `<SRC>` also uses (spec 5.5). The move stops; the owner decides each one (owner, Q6 = A). Kind `table` is a row the move cannot carry: `embed_visitors` is a channel with a website-chat visitor (spec 5.1b) |
| `REFUSE hours: <member> <n> rows ...` | hours rows of a member who does not come along (Q5), or inside a frozen or approved time sheet (spec 5.1a, owner Q8 = A) |
| `REFUSE channel <name> exists in <DST>: set TO_NAME` | the name is taken in `<DST>`, an archived channel included (section 2.4) |

A clean plan can still stop at P2. Two of its checks are not in the plan's answer:
an agent with the orchestrator number on `<DST>`'s roster, and the channel's
attachment total against `<DST>`'s file quota (Qto pictures are not counted).

With no `REFUSE` line the plan ends with
`OK plan of <SRC>/<CHANNEL> -> <DST> (move): nothing changed. Run it: MOVE_CMD=run`.
With one or more it ends with `FATAL the plan ... refuses (<n> item(s) above); nothing changed`,
exit 3.

### 2.4 Clear the plan before a run

A run is ready when the plan prints no `REFUSE` line and the owner has read
the members, the mentions and the kept list.

- **Hours rows:** adding the member to `<DST>` clears the Q5 line and the rows
  move. Reopening the time sheet clears the Q8 line. Each line clears on its own.
- **Leaving hours rows in `<SRC>`:** the hub reads the owner's "leave them" from
  the `leave_hours` of a plan's or a step's `detail` (spec row T7d): the rows
  become a kept item and the stop clears. The shell does not send that detail
  yet, so from this action the stop stands **[pending: no row owns the shell
  half yet]**.
- **Channel invites:** the hub moves the invites named in `keep_emails` (T7d)
  and P4 deletes the others. The shell sends none yet, so P4 deletes every invite
  of the channel; invite the people to `<DST>` afterwards **[pending: no row owns
  the shell half yet]**.
- **The doc of the box rule row:** the hub's plan puts the `rule_doc` of the
  detail in the set (T7d). The shell does not send column 3 of the rule row yet,
  so a Qto doc reached only through it stays in `<SRC>` **[pending: no row owns
  the shell half yet]**.
- **The name:** a channel named `<CHANNEL>` that already exists in `<DST>`,
  archived or not, blocks the run. `TO_NAME=<new id>` makes the plan check that
  name instead, but a step carrying it is refused with 501 `not_built`, so a move
  keeps the channel's id: free the name in `<DST>` **[pending: a row that builds
  `TO_NAME`]**.

## 3. Run

### 3.1 See the steps first

`MOVE_CMD=run` with the default `DRY_RUN=1` reads the journal and prints
the steps a real run would do, changing nothing:

```bash
cd csi-spl-orc && ENV=<ENV> CHANNEL=<SRC>/<CHANNEL> TO=<DST> MOVE_CMD=run ./run -a do_spl_channel_workspace_move
```

It ends with `OK DRY_RUN move <move id> ... would run P1 P2 P2b P3 P4 P5 P6 P7`
(`<new>` in place of the move id before P1 has run). Before P1 it also reads the
plan, so a `REFUSE` line stops it, exit 3.

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

P2 checks `MOVE_CALLER`'s seat on `<DST>`'s roster when the step's `detail`
carries it as `caller` (spec row T7d), but the shell does not send it yet: P2
then only checks that `<DST>`'s roster has an agent with the orchestrator
number, so naming the right seat is yours **[pending: no row owns the shell
half yet]**.

### 3.3 The owner's run of a copy

A copy has no P2b and no P5, so it needs only `MOVE_GO_MSG`. Today the hub answers
the first call with 501 `not_built`, so this stops at `FATAL the hub refused
journal` **[pending T11]**:

```bash
cd csi-spl-orc && ENV=<ENV> CHANNEL=<SRC>/<CHANNEL> TO=<DST> MOVE_MODE=copy MOVE_CMD=run DRY_RUN=0 MOVE_GO_MSG=<GO msg id> ./run -a do_spl_channel_workspace_move
```

### 3.4 The steps

The run walks the steps of spec section 8.2 and marks each in the hub's
journal. A move runs P1 P2 P2b P3 P4 P5 P6 P7; a copy P1 P2 P3 P4 P7.

| step | where | what | if it fails |
|---|---|---|---|
| P1 | hub | freeze the set in the journal (kept in `<DST>`); returns the move id. A stop is P2's to refuse | nothing changed but the journal row |
| P2 | hub | refuse on the plan's stops, a name taken in `<DST>`, an attachment total over `<DST>`'s file quota, or no orchestrator seat; list the seats for P2b | 409 `move_refused` with the reason; nothing of the set moved |
| P2b | box | each seat sends one probe DM through its `<DST>` desk to `MOVE_CALLER`, on the task = the move id; a dead desk stops the run here. The hub's mark needs a stored probe per seat | nothing changed but the probe DMs, which stay in `<DST>` as part of the journal |
| P3 | hub | copy blobs and Qto objects to `<DST>` | re-run; the copy is idempotent |
| P4 | hub | one database transaction: re-read the plan under the channel lock (that is the set moved), insert it under `<DST>`, delete it in `<SRC>` (a move), recompute counters, bump change stamps, expire deliveries no box can verify. A stop found here refuses, and so does a seat with no probe | the transaction rolls back as a whole; both workspaces are as before (spec case C5) |
| P5 | box | the channel's row of the box map `$SPOOL_ROOT/channel-rules.tsv` gets `<DST>` (and `TO_NAME`) in columns 1-2; one spool note per lane whose issue key changed | re-run; it resumes at P5 and sends only the missing notes |
| P6 | hub | a move only: copy again what P4 moved (a post can land between P3 and P4), then delete the `<SRC>` blobs and Qto objects no staying row lists | re-run; it resumes from the journal |
| P7 | hub | run the database proofs and the bucket proofs (spec 5.3) and write the results into the journal; prints `proof <name> <count>` per proof | a proof that is not 0 is a `FATAL`, exit 1, and P7 stays not done (section 5.1) |

Each hub step needs the step before it done, the journal's move id and the same GO.
A refusal prints as `FATAL the hub refused step <step> ...` with the hub's answer,
exit 1. Each step done prints `OK <step> of move <move id> done`; the run ends with
`OK move <move id> of <SRC>/<CHANNEL> -> <DST> (move) done`.

P4 and P7 print each line of their `.report` (the deliveries line, section 5.2)
as `REPORT <step> <line>`, and P7 prints its kept list as `KEPT <store> until
<its date, or what ends it>` and `KEPT_UNTIL <the last date>` (section 4.1);
neither refuses. Before P7 the action prints one `RETENTION <copy>: <n> days
(<how>)` or `RETENTION <copy>: not read: <reason>` line per copy it dates. The hub answers more than the action prints:
P4's `.lost` and `.new_keys`, P6's `.counts` and `.kept_objects`. Those step
counts are in `channel_move_steps` in `<DST>`, readable with `do_spl_db_query`.

### 3.5 Resume after a stop

A re-run with the same `CHANNEL` and `TO` reads the journal and starts at
the first step not marked done. `MOVE_FROM=<step>` starts at that step
instead, but only P5, P6 or P7 once P4 has committed: a `MOVE_FROM` of P1
to P4 then is refused, exit 3 (spec case C17). The hub still wants the step before
it done, so `MOVE_FROM=P6` with P5 not done is refused with 409. A re-run of a fully
done move prints `OK move <move id> ... is done: nothing to do`.

A re-run carries the same `MOVE_GO_MSG` as the first run. Before P4, a re-run of P1
freezes the set again in the same journal row. If a re-run of P2 finds a new seat,
P4 refuses it with `seat <agent> has no probe from P2b`: run `MOVE_FROM=P2b`.

Two runs of the same channel never overlap: the second one stops with
`FATAL another move of <SRC>/<CHANNEL> runs`, exit 3 (lock
`$SPOOL_ROOT/channel-move/<SRC>.<CHANNEL>.lock`).

The box steps keep their own journal, `$SPOOL_ROOT/channel-move/<move id>/box.tsv`,
one row per probe, rule row and lane note done, so a re-run sends no second
probe DM, no second note and no second rewrite.

### 3.6 When P5 refuses the rule row

P5 rewrites only the channel's `<SRC>` row of the box map. If the map
already has a `<DST>` row for the same channel name beside it, P5 stops and
changes nothing. The box script says `FATAL <map> already has a row for <DST>
#<name> beside <SRC> #<CHANNEL>: resolve it by hand` and exits 3; the action then
says `FATAL P5: the box rule row of <SRC>/<CHANNEL> was not rewritten; a re-run
resumes at P5` and exits 1. Resolve the two rows by hand, then re-run (it resumes
at P5). A box with no map, or with no row for the channel, is not an error: P5
says so and goes on.

### 3.7 The short window after P4

Between the P4 commit and the end of P5, a lane that posts into a moved topic
through its `<SRC>` desk is refused by the hub (spec W2, case C8), and the box client
re-routes the post (T7b). P5 follows P4 at once in the same run, so the window is
short. The re-route itself lasts as long as the redirect, 30 days.

| answer | when | what the post does on a box |
|---|---|---|
| 409 `topic_moved`, detail `topic moved: tenant=<DST> link=<link>` | the redirect is live | sent once through the sending agent's own `<DST>` desk on this box, same msg id and task id, under that desk's key |
| 404 `topic_moved` | the redirect has expired | not sent, see below |
| 503 `moved_check_failed` | the hub could not read the redirect | stays pending and is retried on the next flush |

The refusal never opens a new `<SRC>` topic and never names the channel (spec case
C13). The hub does not carry the post over, because a box key is live in one workspace
only. A browser post gets the same refusal and no re-route.

**When there is no re-route:** the agent has no desk or no seat in `<DST>` on this
box (a desk of another OS user counts as none), `<DST>` cannot place the recipient,
the redirect has expired, the refusal names no destination, or `<DST>` refuses with
`topic_moved` too (one hop only). The post is not sent. It moves to the desk's
`spool/.hub/rejected/` with a `<file>.reason` beside it, and the agent's inbox gets a
`reject` naming the msg id and the reason. An answer is never queued, so its caller
gets the error instead. To recover one, send it again through the `<DST>` desk (same
`--task`: the topic id did not change).

## 4. Read the kept list

### 4.1 What it is

"Not even a trace" covers the live system. Some copies of `<SRC>` already
hold the channel and cannot be edited row by row; the move does not touch
them. The plan prints most of them as `PLAN kept <store> until <what ends it>`.
Two rows of the table below print no such line: the soft-deleted bucket objects,
and the hours rows, which the plan lists as stops (section 2.3). P7's answer carries
the same list in `.kept`, and the action prints it as `KEPT` lines (section 3.4).
Each row that ends with a retention is dated by P7: P4's `done_at` plus the days in
P7's detail `retention_days`, as `expires`, so the line reads
`KEPT daily DB dumps until 2026-12-12`. `.kept_until` is the last of those dates
(owner, Q3), printed as `KEPT_UNTIL <date>`. The action sends those days (spec row
T8c), counted to the day the last copy made before P4 is gone for good:

- the four bucket copies, from the cnf: the lifecycle age, plus the noncurrent
  days of a versioned bucket (046, 052), plus the soft delete in whole days;
- Cloud SQL's automated backups: their COUNT read as days at one backup a day
  (the `startTime` window), or the point-in-time log days when those are longer,
  read as the per-env service account.

A copy it cannot read is not sent: the hub logs always (no cnf value names their
bucket), and any value that fails to read. Its `RETENTION` line says why, its
`KEPT` line ends `not read: no retention_days in P7's detail`, and `KEPT_UNTIL`
says which rows have no date. They are kept until they expire on their own
(owner, Q3 = A).

| copy | holds | why it stays | gone by |
|---|---|---|---|
| daily DB dumps (step 045) | the whole database | one file for every workspace; editing it breaks the backup | its retention, 30 days |
| off-project backup copy (step 046) | the same dumps | its writer may add, never delete, by design; only the owner can remove an object, by hand | its retention, 30 / 90 days |
| Cloud SQL automated backups | the whole database | managed by Cloud SQL, not per row | its retention: the plan's `PLAN retention Cloud SQL backups` line (spec R4) |
| `<SRC>` Qto daily export (step 052 `backup/`) | `<SRC>`'s docs | one file per day per workspace | 30 days |
| soft-deleted bucket objects (step 052) | the moved files and Qto objects | the bucket keeps them for its soft-delete time | 7 days |
| box-state copy (step 056) | transcripts, the spool root | one nightly archive per box | 30 days |
| hub logs (Cloud Logging) | request lines with ids | append-only by design | the log bucket's retention: the plan's `PLAN retention log bucket` lines, one per bucket of the project (spec R4) |
| mail and notifications already sent | text sent to people | outside the system | never |
| git history of this repository | commit subjects, specs and dispatch notes citing a task id or an issue key | history is forward-only; no force-push | never |
| hours rows the owner said to leave (spec 5.1a; no input yet, section 2.4) | a member's time record that names the channel | it is the member's signed or kept time sheet | never, unless the owner deletes it |
| box spool archives, transcripts, worktrees | the agents' copies of the channel's posts | the agents need them to continue the work; they name no workspace | spec 167's cleanup, if the channel also leaves its box |

### 4.2 Read the dates

The plan names no dates: a `PLAN kept` line says in words what ends the
copy (`their retention`, `never`). P7's `KEPT` lines carry the date when its
detail gave the days (section 4.1); until the shell sends them, read the days
from the `PLAN retention` lines and the table above, and count them from the day
P4 committed. The longest of
them is the day after which the channel survives only in the "never" rows: mail
already sent, git history, the hours rows the owner left and the boxes' copies.

## 5. After the move

### 5.1 Read the proofs

P7 prints one `proof <name> <count>` line per proof and writes them into
the journal. Every proof runs in `<SRC>` and must print 0: the database rows of the
set (spec 5.1), and a scan of every text, jsonb, uuid and array column of every
`<SRC>` table for the channel id, its name and every task and msg UUID (spec 5.2). A
count that is not 0 stops the run with `FATAL P7: a proof of section 5 is not 0`, exit
1: the move is not done and P7 stays not done, so a re-run runs the proofs again. Send
the move id and the proof lines to the orchestrator.

The one exception to the scan's 0: when `<SRC>` holds the fleet rows, hits on
`fleet_lanes.topic` and `fleet_asks.topic` are known. They print as
`proof <name> (known <n> of <m>, kept: 5.2) 0`, never as a failure (spec 5.2).

P7 also proves the bucket objects of spec 5.3 in the buckets themselves, not
from P6's counts: for the files bucket (M4) and the Qto pictures (M8) it prints
`proof objects <kind>: left in <SRC> <n>` and `proof objects <kind>: missing in
<DST> <n>`, both 0 after a good move. A shared object that a staying `<SRC>` row
still lists (spec 5.5) stays in `<SRC>` and prints as `(known <n> of <m>, kept:
5.5) 0`. A bucket P7 cannot read stops P7 with the hub's error: it never prints
0 for an object it could not read.

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
  Cite the new key from then on. A lane filed on a moved key after P1 gets no
  note. A moved issue whose number was free keeps its key.
- **The old key map** (spec row T7g): P4 writes the 30-day map (owner, Q2 = A),
  and the closer `do_spl_issue_close_landed` reads it every run through
  `spool issue moved` (old key, `<DST>`, new key, expiry, live). For those 30
  days a commit that cites the old key closes the new one in `<DST>`. The desk
  acts there, so it needs a desk in `<DST>` on its box; without one the close
  is refused and reported `failed`, and since a failed run keeps its cursor,
  the closer re-reads that range and stays red on every run until a `<DST>`
  desk is seated or the 30 days end: seat it before the move. A commit the
  ledger already holds under the old key (it closed the issue in `<SRC>`,
  the owner reopened it, then it moved) does not close the new one. When the
  new key is not open in `<DST>` (done, diss, or moved on by a second move,
  which is not followed) the old key is a no-op that says so. After the 30 days the old key closes
  nothing (a no-op, with the new key in its reason). When the map or the
  `<DST>` open list cannot be read, the key is reported `failed` and retried
  on the next run: no no-op on a guess, no ledger row, and the cursor stays.
  P4 rewrites the key in `fleet_lanes.issue_key`, `fleet_lanes.origin_issue`
  and `fleet_asks.issue_key` of `<SRC>` (M11).
- **Links**: a moved topic's link is `https://<DST_HOST>/t/<uuid>`. For 30
  days the hub answers a read of the topic at `<SRC>` with 404 `topic_moved`
  and the new link in `moved_to`; then 404 `topic_moved` with no link (owner, Q2 =
  A). The link goes only to a reader who is a `<DST>` member: anyone else gets
  the 404 with no link, so a person the move dropped never learns the new
  workspace (spec row W5). The web app follows it (spec row T7h): an old link opens the topic at
  its new workspace. It follows only a link to a workspace of this site, and
  only once: the page it opens does not follow a link again. After the 30 days the old link shows no topic, so
  someone opening it then has to be given the new one.
- **Posts**: for those 30 days a post to a moved topic at `<SRC>` is refused
  with the new workspace and link, and the box client sends it on through the `<DST>`
  desk (section 3.7); a post from the web app names them only to a `<DST>`
  member, as a read does. Then it is refused with a 404 and reported.
- **Members**: only the people the owner added to `<DST>` keep the channel;
  the others lose access (owner, Q5 = A).
- **Open polls, claims and parked rows** travel with their rows and can be
  answered in `<DST>` right after the move.
- **Open web clients** refetch on the bumped change stamps: a `<SRC>` client
  drops the channel, a `<DST>` client shows it. A browser that is offline
  keeps its local copy until it next loads.
- **Encrypted posts** stay readable only by the boxes they were encrypted
  for; a move does not change that (spec R2).
- **Old agent posts in `<DST>`**: a moved row keeps the signature of its `<SRC>` key,
  and the same-named box in `<DST>` normally holds another key, so the row does not
  verify there, pinned or not (spec F10). Back-fill withholds such rows from a new
  seat and counts them in its summary. A box reads them only by tail, and tail shows
  it only rows it sent, was addressed by or had delivered; people read them in the
  browser. No box can edit, delete or move them, except an agent's issue comment,
  which is unsigned by design, so a same-named box there still can. Posts by people
  are not affected.
- **Queued deliveries**: P4 expires a queued or unacked delivery of a moved row when
  the sender's pin is missing or different in `<DST>`, or the addressee's box has no
  pin there. Nobody receives those. P4's report line counts them, but a row signed
  before its box re-keyed is refused by the box and lost, uncounted (spec case C28).

### 5.3 The journals

The hub's journal lives in `<DST>` on purpose: it is the record that the
channel came from somewhere, kept where the channel now is. It holds the
mode, the `<SRC>` slug, the channel id, the frozen id lists, the owner's GO
msg id, the P2b probe msg ids and one row per step with its times, counts
and proof results. `<SRC>` gets no audit row for the move.

The action reads it through the hub at the start of every run; to see where a move
stands, run section 3.1 (it prints the steps still to do). The hub's answer carries
`.move_id`, `.done`, `.steps`, `.seats` and `.lanes`, not the counts or the proofs:
those are in `channel_move_steps` (section 3.4).

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
- The hub endpoint and its steps (T7):
  `csi-spl-api/src/go/spool-hub-api/internal/hub/channel_move.go`,
  `channel_move_steps.go`, the moved refusal's wire text
  `csi-spl-api/src/go/spool-hub-api/internal/wire/topic_moved.go`.
- The transaction P4 (T5, T5b, T5c):
  `csi-spl-api/src/go/spool-hub-api/internal/store/channel_move_apply_postgres.go`.
- The box client's re-route (T7b):
  `csi-spl-api/src/go/spool-hub-api/internal/hubclient/reroute.go`.
