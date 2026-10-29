# 167 Channel Box Move: move ALL the work of one channel to another box in one action

Version: v0.1 (2026-10-29). Status: **Draft, for R7 review**. Nothing below is built.
Issue SPL-4227 · Epic SPL-2398 · Class feature · Kind specs_and_docs ·
Placement slug `c002-channel-box-move-spec` · Lead c-873.

Source: owner HUM-10, csitea topic `0941c5c2-807e-4088-b089-c6de331bfa72`.
Related: [spec 164 channel box pin](../164-channel-box-pin/spec.md) (the hub
gate), [spec 069 section 8.4](../069-ysg-box-out/spec.md) (moving desks between
users, `do_spl_desk_move`), [spec 060](../060-role-rotation/spec.md) (rotation:
QUIESCE, HANDOFF, SPAWN, ACK, RETIRE), [spec 058](../058-multi-machine-fleet/spec.md)
(`<ID>@<box>`), [spec 064](../064-fleet-without-the-pc/spec.md) (box drain,
`do_spl_box_leave`), [fleet rules index](../../doc/md/fleet-rules-index.md).

Placeholders, because the repo is public: `<BOX_A>` the box the channel's work
is on, `<BOX_B>` the box it moves to, `<TENANT>` and `<CHANNEL>` the channel,
`<REPO>` a source repository the channel works in. Paths: `orc/` =
`csi-spl-orc/src/bash/`, `sa/` = `orc/features/spawn-agents/`. Every file
named was read on origin/master `26838cdd1` (2026-10-29).

## 1. The owner's words (verbatim, box names replaced)

Topic 0941c5c2, 2026-10-29:

- 015097e6 (12:18Z): "I want to be able to switch as quickly as possible all
  of the work of a specific channel from [<BOX_A>] box to the [<BOX_B>] box
  and vice versa"
- d64c1781 (12:18Z): "both configs , data , binaries , src EVERYTHING"
- c3024892 (12:19Z): "and there should be a ball pass on the ai side as well ,
  so tha the new ai's working on the new box will KNOW what to do and how-to
  continue , once the tranfser has completed the sending agents should be
  killed"
- c0b1208c (12:19Z): "I want that as a single shell action , which could be
  called wither by me or by the adminsitrator whenever I tell so"

Earlier the same day, in another topic of the same channel, the owner asked
for the same move by hand: "move all of th ework on this ... NOW", "this is a
temporary measure", "only for the next 2 hours", then the move back, then
"delete anything after the move which was related to this discussion from the
[<BOX_B>] box".

## 2. The worked example: the move by hand, 2026-10-29

One channel's work went `<BOX_A>` -> `<BOX_B>` at about 11:1x-11:23Z and back
at about 11:33-11:42Z, by two agents, by hand. From their two handoff files
(box-local, not in git) and the lane brief:

| # | what happened | lesson for the action |
|---|---|---|
| W1 | An rsync of the 219 MB `<REPO>` checkout over a 0.3-0.9 Mbit/s uplink broke at 82 MB; a `--partial` resume was started. At 0.6 Mbit/s, 219 MB is about 49 min. | Never copy a checkout. Ship git objects only. |
| W2 | A git bundle of the work branch was 101,956 B; the way-back bundle was 10,320 B (`git bundle verify` rc 0, its prerequisite commit named). Applied with `git fetch <bundle> <branch> && git merge --ff-only FETCH_HEAD`. | A bundle on top of a commit both boxes have is the fast path: seconds, not an hour. |
| W3 | The target seat had no desk in the workspace and could not post (blocker a3e4c74f); another agent posted for it. | Seat the target agent on the target desk and prove a post BEFORE the switch. |
| W4 | Keys the channel uses could not move: secret, the owner's call; the owner's poll answer was read two ways. | Secrets never move by default; a secret moves only on the owner's GO for that move, asked as one button. |
| W5 | Each handoff listed the open owner asks with permalinks, branch and sha, tests run and not run, and "every path ... created ... on this box (delete after you verify)". | That list is the ball pass AND the cleanup list. Make it mechanical. |
| W6 | The cleanup on the target was a hand `find` over the listed paths -> 0 hits; the agent's session transcript, which quotes the channel's code, was left for the owner to decide. | Cleanup = delete the recorded paths, then a find proof; the transcript is in the list. |

## 3. Today: what exists on master

| # | fact | where |
|---|---|---|
| T1 | A channel's seat is box-local: `$SPOOL_ROOT/channel-rules.tsv`, one row `<tenant> <channel> <doc id> <env> <desk agent> [<sole seat id@box>]`, never in git. Column 6 is the only seat that may post unasked. | `sa/lib/channel-rules.inc.sh` (`cr_sole_seat`) |
| T2 | A seat brief names its channel with a header line `Channel: <tenant> #<channel>`. | same file, header |
| T3 | Every agent has a composed handoff, `<spool root>/<id>/handoff.md` (9 sections: brief, done, in flight, next step, open questions, owned topics, notes, lessons), written only by `do_spl_agent_handoff`; the agent adds its own part with `do_spl_agent_handoff_note`. | `orc/run/spl-agent-handoff.func.sh`, `spl-agent-handoff-note.func.sh` (spec 102) |
| T4 | The rotation flow QUIESCE -> HANDOFF -> SPAWN (seeded with the brief, the handoff, an ACK command) -> ACK (no ack = the new session is closed and the old one keeps the lane) -> RETIRE. One box only. | `orc/run/spl-lane-rotate.func.sh`, spec 060 4.4 and 5 |
| T5 | A spawn on another box rides a hub message: `spawn-remote.sh --box <box> ...`; the target's serve tick (every minute) runs its own `spawn-window.sh`. Only the orch lease holder is obeyed. | `sa/scripts/spawn-remote.sh` |
| T6 | Retiring an id moves its spool dir to `.retired/`, drops its desk seats, closes its hub lane row and writes an alias row `<id> -> <successor>`. | `sa/scripts/agent-id-retire.sh` (`--successor`), `do_spl_agent_id_retire` |
| T7 | A box can drain all its lanes before it goes off (`do_spl_box_leave`); there is no drain of ONE channel. | `orc/run/spl-box-leave.func.sh` |
| T8 | Seats join and leave a channel through the operator path. | `do_spl_channel_agent_add_op`, `do_spl_channel_agent_remove_op` |
| T9 | A desk is seated and proven with `do_spl_desk_up`, `do_spl_desk_check`, `do_spl_desk_probe`. | `orc/run/spl-desk-{up,check,probe}.func.sh` |
| T10 | Box-to-box files: an ssh alias through IAP exists in one direction only; the cloud box cannot ssh to a box behind NAT ("Could not resolve hostname", `spawn-remote.sh` header). The box state bucket takes files both ways but refuses any secret (exit 3). | `do_satellite_ssh_config`, `do_spl_box_state_sync` |
| T11 | Channel -> box pinning in the hub is specified (spec 164), not built: `git grep -c channel_box_pins origin/master -- csi-spl-rdb` -> 0. | spec 164 section 8 |
| T12 | Nothing knows which files on a box belong to a channel. | `git grep -n 'channel-move' origin/master` -> 0 (before this spec) |

## 4. The action

### 4.1 One command

```
cd csi-spl-orc && CHANNEL=<TENANT>/<CHANNEL> TO=<BOX_B> ./run -a do_spl_channel_move
```

- Dry run unless `DRY_RUN=0`. The dry run is `MOVE_CMD=plan`; it prints the
  whole plan (4.3) and changes nothing.
- Runs from either box, by the owner or the administrator (the owner's
  "wither by me or by the adminsitrator"; who exactly: Q1). The box that runs
  it is the **driver**; the driver reaches the other box over ssh where it
  can, else through the hub (4.6).
- Commands: `plan` (default), `move`, `status`, `resume` (re-runs a broken
  move from its last finished step), `back` (the same move in the other
  direction, from the journal), `clean` (the source cleanup, 4.8), `ack` (run
  by a target seat, 4.7).
- One journal per move, `$SPOOL_ROOT/channel-move/<move id>/journal.tsv` on
  BOTH boxes (one line per step: step, state, start, end, bytes, sha256),
  box-local, 0600, never in git: it names customer paths.
- One move per channel at a time (a lock in the journal dir); two channels
  may move at once.
- `move` asks no question. The owner's GO, where needed, is asked once with
  the plan (4.5) and recorded in the journal by its message id.

### 4.2 What a channel's work is: the manifest

The action moves what the channel's **manifest** lists, and nothing else. A
manifest is one box-local file per channel,
`$SPOOL_ROOT/channel-move/<tenant>-<channel>.manifest` (0600, never in git),
with these kinds of line:

| kind | example | how it is found | how it moves |
|---|---|---|---|
| `seat` | `seat <id>` | the channel's rows in `channel-rules.tsv` (T1) + every live registry row whose brief has `Channel: <tenant> #<channel>` (T2) | ball pass, 4.7 |
| `repo` | `repo <path> <remote name>` | each seat's worktree: its main checkout and its branches | git bundle, 4.4 |
| `uncommitted` | (derived) | `git status --porcelain` of each worktree | a patch + the untracked files as a tar, 4.4 |
| `data` | `data <path>` | declared by the seat with a manifest line (row B1) | resumable copy, 4.6 |
| `config` | `config <path>` | declared | resumable copy |
| `binary` | `binary <path> <build command>` | declared | rebuilt on the target from the moved source; copied only when no build command is given |
| `secret` | `secret <path>` | declared, or found by the existing secret scan (`spl_box_state_upload_scan`) under any other line | never by default, 4.5 |
| `marker` | `marker <string>` | declared: a word only this channel's files hold (a repo name, a project code) | not moved; used by the cleanup report, 4.8 |
| `scratch` | (derived) | each seat's CLI scratch dir and `/var/tmp/<seat id>/` | not moved; listed for cleanup |
| `transcript` | (derived) | each seat's CLI session files | not moved; the handoff carries the state (Q3) |
| `spool` | (derived) | each seat's `<spool root>/<id>/` (inbox, outbox, handoff) | unread inbox items travel in the handoff; the dir is retired with the id |

Rules:

- **Seats declare, the action derives.** A seat that writes a file outside
  its worktree adds a manifest line (`do_spl_channel_manifest_add`, row B1).
  The derived lines come from code, never from a model.
- **An undeclared path is not found.** A `plan` lists what the manifest holds;
  it cannot prove nothing else exists (the fleet rule: a control that only
  sees what was named cannot prove absence). 4.8 says what the cleanup proof
  does cover.
- A manifest path outside the box's allowed roots (`/opt/<org>`, `/var/tmp`,
  `$SPOOL_ROOT`, the agent user's home) is refused in `plan`.

### 4.3 The order, and how long it takes

Smallest first, so the part that unblocks the target arrives first and a
broken link loses the least. `plan` prints each step with its size and an
estimate at the measured uplink (`MOVE_UPLINK_KBPS`, default: measured by
`plan` with a 1 MB probe; the worked example's 0.3-0.9 Mbit/s = 37-112 kB/s).

| step | what | who changes | size (worked example) | time at 0.6 Mbit/s |
|---|---|---|---|---|
| S0 | **plan**: manifest, sizes, target checks (target has each `repo`'s base commit? a desk in `<TENANT>`? below the 40-agent ceiling? vendor not on its limit?), secrets found, the GO needed | nothing | - | < 30 s |
| S1 | **quiesce** the source seats (spec 060 QUIESCE: Escape, 60 s grace) and **hold** them (`do_spl_wd_hold`): they stop editing, so the snapshot is final | source seats pause | - | <= 60 s |
| S2 | **handoff**: `do_spl_agent_handoff` per seat + the move block (4.7) | source spool | ~10 kB | < 2 s |
| S3 | **git**: per repo, a bundle of every branch the seats touched, on top of a base the target has (`git bundle create ... ^<base>`); uncommitted work as `git diff --binary` + a tar of untracked files | - | 10-102 kB | 1-14 s |
| S4 | **config, data**: resumable copy with checksums (4.6), smallest file first | - | per manifest | per manifest |
| S5 | **build** each `binary` on the target from the moved source | target | - | per build |
| S6 | **seat the target**: spawn one agent per source seat on `<BOX_B>` (T5), seat it on the `<TENANT>` desk there (T9), add it to `<CHANNEL>` (T8), prove one post read back (`do_spl_desk_probe`) | target | - | 1-5 min (the remote spawn serve tick is 1 min) |
| S7 | **ack**: each target agent reads its handoff, checks out its bundles, runs its first check, and acks (4.7) | target | - | <= `MOVE_ACK_TIMEOUT` (900 s) |
| S8 | **switch**: channel-rules row (sole seat) to the new `<id>@<BOX_B>` on both boxes; old seats out of `<CHANNEL>` (T8); with spec 164 served, the channel's box pin to `[<BOX_B>]`; one post in each open topic of the channel naming the new seat | both, hub | - | < 30 s |
| S9 | **retire** the source seats: `/exit-clean` typed, then `do_spl_agent_id_retire` with the new `<id>@<BOX_B>` as successor (T6) | source | - | <= 5 min |
| S10 | **clean** the source (4.8), at once or later (Q2) | source | - | < 1 min |

Done means S9 finished and the journal says every step `ok`; `status` prints
it. With the worked example's sizes, S0-S9 is about **8-10 minutes**, almost
all of it the remote spawn and the ack, not the copy (**estimate, not
measured**: row B6 measures it in a dev drill).

The source keeps the channel until S8. A failure before S8 releases the hold
(S1) and the source seats go on as if nothing happened; a target agent that
never acks is closed (the spec 060 FR-014 rule). After S8 the way back is
`back`.

### 4.4 Git, uncommitted work, data

- **A checkout is never copied** (W1). For each `repo` line, `plan` asks the
  target for the base: the newest commit of the branch that the target's
  clone of `<REPO>` already has. The bundle carries only the commits after it.
  No clone on the target: the target clones from the repo's own remote when it
  can reach it; else a full bundle (`git bundle create --all`) is shipped as a
  data file (4.6), and `plan` prints its size and time so the owner sees it.
- The bundle is verified on the target (`git bundle verify`, rc 0) and fetched
  into a NEW worktree for the target seat; the source branch's head sha must
  equal the target's after the fetch.
- Uncommitted work: `git diff --binary HEAD` and a tar of `git ls-files -o
  --exclude-standard`; applied with `git apply --index` and untar; the target's
  `git status --porcelain` must list the same paths.
- A repo's own commit identity and push rules do not change: a repo that must
  never push from a box is not pushed by the move.

### 4.5 Secrets: never without the owner's GO for that move

- The `plan` lists every `secret` line and every secret the scan finds under
  another line: path, mode, size, and a sha256 yes/no match on the target.
  **Never the content, never in a log or a post.**
- Default: secrets do **not** move. The target uses its own copy where it has
  one (sha256 match = nothing to do); where it has none, the plan says so, and
  the step that needs it waits.
- With the owner's GO for this move (`MOVE_SECRET_GO=<owner msg id>`; the GO is
  asked as one `(GO) Go` poll listing the secrets by count and kind), a
  secret moves over ssh only, never through the hub or the bucket (the bucket
  refuses it anyway, T10), lands 0600 owned by the box user, and is checked by
  sha256 yes/no. Without a direct ssh path the move of a secret is refused, and
  the owner is told which box has to drive it.
- The fleet data rule holds: a brief for a target seat that will handle a
  secret goes only to a claude or grok seat, and names no key path.
- The journal, the handoff and the posts carry secrets by kind and count
  only (`2 keys, 0600`).

### 4.6 Slow or broken links

- **Transport**, in this order: ssh from the driver when it reaches the other
  box (T10); else the box state bucket (`do_spl_box_state_sync` writes a
  move prefix, the other box reads it; never a secret); else nothing, and
  `plan` says which box must drive.
- **Resumable**: every file goes in chunks with a sha256 per file in the
  journal; `resume` re-sends only files whose target sha256 differs; ssh
  copies use `rsync --partial --checksum`. A broken copy is never a failed
  move: it is a step in state `partial`, and `resume` continues it.
- **Smallest first** (4.3): the bundles and the handoff are on the target in
  seconds, so the target seat can start while a large data file is still
  arriving; a `data` line can be marked `after-switch` to move after S8.
- **The source keeps working until the target proves it runs** (S6 probe, S7
  ack). If the source box dies mid-move (the owner's earlier note: its battery
  may die), `status` on the target lists what arrived, and the owner decides:
  `resume` from another source, or wait.

### 4.7 The AI ball pass (owner c3024892)

Reuses spec 060 and spec 102; nothing new for the agents to learn.

1. **Handoff** (S2): `do_spl_agent_handoff` for each source seat, plus a
   **move block** the action writes from code: move id, `<BOX_A>` -> `<BOX_B>`,
   the channel, the seat's open owner asks with their permalinks (from the
   handoff's open questions and owned topics), each repo's branch and head
   sha and the bundle path on the target, uncommitted paths, manifest paths
   moved and NOT moved (secrets, scratch), and the next step.
2. **Seed** (S6): the target agent is spawned with the source seat's brief,
   the handoff and one ACK command:
   `MOVE_CMD=ack MOVE_ID=<id> SEAT=<new id> ./run -a do_spl_channel_move`.
   It runs the ack only after it has (a) checked out every bundle at the
   named sha, (b) read its unread inbox items from the handoff, (c) run the
   first check the handoff names. The ack records what it checked, and the
   action re-checks (a) itself before it accepts the ack.
3. **No ack, no kill.** The source seat is closed only after its successor's
   ack (S9). No ack within `MOVE_ACK_TIMEOUT`: the target agent is closed,
   the hold on the source seat is released, `FAIL ack` goes to the
   orchestrator and the owner's topic gets one line. This is spec 060 D2.
4. **Kill and retire** (owner: "the sending agents should be killed"): the
   source seat gets `/exit-clean`, then its id is retired with the new
   `<id>@<BOX_B>` as successor, so an @mention of the old id reaches the
   new seat and the old number is not reused for 24 h.
5. A seat whose vendor is on its usage limit at S6 is placed on the per-kind
   backup vendor (the spawn table); the handoff is vendor-neutral.

### 4.8 Nothing left behind, and the way back

- **`clean`** deletes, on the source, every manifest path that moved, each
  source seat's worktree and branch (after S9 these are on the target; the
  24 h disk guard is skipped for this move only, by the owner's order), the
  seats' scratch dirs, the move's bundles and chunks, and the retired spool
  dirs of the seats. Transcripts: per Q3.
- **Proof**, printed and kept in the journal: (1) `find` of every deleted path
  -> 0; (2) a `find` over the allowed roots (4.2) for files owned by the moved
  seats or newer than the move's start that hold a `marker` string -> listed
  with a count. (1) proves the listed paths are gone. (2) finds only what a
  marker names; it cannot prove nothing else is left, and the report says so.
- **Secrets on the source** are not deleted unless the owner's GO says so
  (Q4).
- **The way back** is `MOVE_CMD=back MOVE_ID=<id>`: the same steps from
  `<BOX_B>` to `<BOX_A>`, with the base commits the old box still has (before
  its clean, the bundle is a few kB, W2). A temporary move
  (`MOVE_BACK_AFTER=2h`) does not move back by itself: at that time the action
  posts one `(GO) Go` poll in the channel's topic asking to move back.

## 5. Cases (each lands with a red control)

| # | case | expected | red control (must fail without the feature) |
|---|---|---|---|
| C1 | `plan` on a channel with 1 seat, 1 repo, 1 data file, 1 secret | prints every manifest line with size and time, the secret by kind only; changes nothing (before/after `find -newer` on both sandbox boxes -> 0) | a plan that writes the journal before `DRY_RUN=0` |
| C2 | `move` with a 220 MB checkout whose base the target has | ships a bundle < 1 MB, not the checkout | the same move with the base check off copies the tree (bytes in the journal > 200 MB) |
| C3 | the link drops at 40% of a data file, then `resume` | the file finishes, sha256 equal, the earlier files are not sent again | a resume without the journal re-sends all |
| C4 | target has no desk seat in `<TENANT>` (W3) | S6 seats it and the probe post reads back before S8 | skip S6: the switch happens and the first target post is "Not sent" |
| C5 | target agent never acks | target closed, source unheld and still the channel's seat, `FAIL ack` sent | the source seat is closed before the ack |
| C6 | secret, no GO | not copied; plan names it by kind; the target step waits | a move without the GO copies the key (sha256 present on target) |
| C7 | secret with GO but only the bucket path | refused, nothing sent | the secret reaches the bucket |
| C8 | `clean` | `find` of each moved path -> 0; marker report printed | a planted file under a moved path survives `clean` |
| C9 | `back` before the clean | the channel is on `<BOX_A>` again; commits made on `<BOX_B>` come back by bundle | the back move loses a commit made on `<BOX_B>` |
| C10 | two moves of the same channel at once | the second refuses (lock) | both run |
| C11 | the source seat has uncommitted and untracked files | the target's `git status --porcelain` lists the same paths | the target worktree is clean |
| C12 | an @mention of the old id after the move | reaches the new seat (alias row) | the mention bounces |
| C13 | the journal, the handoff and the posts | 0 key bytes and no secret path beyond kind and count (`grep` of the planted key bytes over the journal dir -> 0) | a planted key path in a `data` line is printed |

Tests run on a private `SPOOL_ROOT` with two sandbox boxes (two dirs, a stub
ssh and a stub hub), never the live spool (`SPOOL_TEST=1`).

## 6. Build rows

Disjoint files. Batch 1 first, batch 2 in parallel, batch 3 last.

| row | what | files (only these) | red control | vendor (main / backup) | batch |
|---|---|---|---|---|---|
| B1 | manifest: derive + declare + `plan` | new `orc/run/spl-channel-move.func.sh` (plan only), `orc/run/spl-channel-manifest-add.func.sh`, `sa/lib/channel-move.inc.sh`, `orc/tests/channel-move-plan.tst.sh` | C1 | claude / grok | 1 |
| B2 | git and uncommitted transfer | `sa/lib/channel-move-git.inc.sh`, `orc/tests/channel-move-git.tst.sh` | C2, C11 | claude / grok | 2 |
| B3 | resumable transport, checksums, secret refusal | `sa/lib/channel-move-ship.inc.sh`, `orc/tests/channel-move-ship.tst.sh` | C3, C6, C7, C13 | claude / grok (secret kind) | 2 |
| B4 | ball pass: move block, seed, ack, retire | `sa/lib/channel-move-seat.inc.sh`, `orc/tests/channel-move-seat.tst.sh`; calls `spl-agent-handoff.func.sh`, `spawn-remote.sh`, `agent-id-retire.sh`, edits none of them | C4, C5, C12 | claude / grok | 2 |
| B5 | switch, clean, back, lock, `status` | `orc/run/spl-channel-move.func.sh` (the other commands), `orc/tests/channel-move-switch.tst.sh` | C8, C9, C10 | claude / grok | 3 (after B1-B4) |
| B6 | dev drill on two boxes with a test channel; measure each step; put the numbers in 4.3 | this spec | the drill journal | claude / grok | 3 |
| B7 | docs: one operator and owner how-to page | new `csi-spl-doc/doc/md/channel-box-move.md`, its row in `fleet-rules-index.md` | `do_check_fleet_rules_drift` green | agy / claude | 3 |

Spec 164 is not a prerequisite: until its B2 is served, S8 switches the
channel-rules seat and the channel membership only; once it is served, S8 also
sets the pin. B5 calls spec 164's API and never edits its files.

## 7. Owner questions

One poll in the topic, four questions:

- **Q1 Who may run it**: (A) you and the orchestrator seat only (recommended);
  (B) any agent seated in the channel; (C) only you.
- **Q2 When the source is cleaned**: (A) at once after the new seat acks
  (recommended: matches "delete anything after the move"); (B) after 2 hours;
  (C) after 24 hours.
- **Q3 The old seats' session transcripts** (they quote the channel's code):
  (A) delete them with the cleanup (recommended; the handoff carries the
  state); (B) keep them on the source; (C) move them to the target.
- **Q4 Keys and other secrets**: (A) never move; the target box uses its own,
  and a step that needs a missing one waits (recommended); (B) move them over
  ssh with your GO each time; (C) move them, and delete them on the source,
  with your GO each time.

## 8. Risks and open checks

1. **R1 The manifest is only as good as its declarations.** A file a seat
   wrote and never declared stays on the source. Mitigation: the marker
   report of 4.8 and the derived lines; not a proof.
2. **R2 Remote spawn latency.** The serve tick is 1 min, and the hub relay
   once took 4 min each way (SPL-2801, `spawn-remote.sh` header). S6 is the
   long pole; B6 measures it.
3. **R3 NAT.** The cloud box cannot open ssh to a box behind NAT (T10). A
   move that needs a secret must be driven from the box that can open ssh.
4. **R4 Agent ceiling.** The target must be below 40 agent windows; `plan`
   refuses otherwise.
5. **Open check**: whether the hub queues a channel post for a seat that is
   between S8 and the new seat's first read; measured in the B6 drill.

<!-- version: 0.1.0 · updated: 2026-10-29 · last-edit: 2026-10-29T13:00:00Z -->
