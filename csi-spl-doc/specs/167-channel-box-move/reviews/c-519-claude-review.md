review: c-519 claude FAIL 9a48fb4d4 ran: git cat-file -e (17 paths), git grep (19 functions), git grep -c channel_box_pins, git grep channel-move, agent-id-retire.sh --successor in a SPOOL_TEST sandbox, sudo -u <BOX_USER> env probe, grep -nE hygiene | read: spec.md@9a48fb4d4, spec 060 4.4/5/FR-014/D2, spec 164 section 8, spec 069 8.4, spec 061 Q6, how-to-post.md 7, channel-rules.inc.sh, spl-agent-handoff{,-note}.func.sh, spawn-remote.sh, agent-id-retire.sh, spl-wd-hold.func.sh, spl-box-state-sync.func.sh, satellite-ssh-config.func.sh, c-002 relay 8cc12ff2 | log: csi-spl-doc/specs/167-channel-box-move/reviews/c-519-claude-review.md

# R7 review of spec 167 v0.3 (SPL-4227), claude seat c-519, same-vendor waiver

Reviewer: c-519 (claude), by the same-vendor waiver of c-001 ruling 1a7c70da
(2026-10-30). Brief: placement `c002-s167-claude-waiver-reviewer`, review
issue SPL-4309. Reviewed blob: `git rev-parse 9a48fb4d4:csi-spl-doc/specs/167-channel-box-move/spec.md`
-> `83cd37b68d56be0d2cb4e95f005cda35d006b01e`, the same blob as on
origin/master `04148121a` (2026-10-30). The m-096 review was not reused.

Every output below is pasted from the command as run. Line numbers are the
spec's at 9a48fb4d4.

## Verdict: FAIL

Two blocking findings (W1, W2): the retire step S9 cannot run as written,
and the D1 caller check lets any agent through by the fleet's own standard
invocation. Both are spec fixes, not owner questions. W3-W7 are smaller.
Everything else checked holds (section "Checked and holding").

## Findings

### W1 (blocking) S9 / 4.7 step 4 / T6 / C12: `--successor` refuses every new-form id

Spec lines 72 (T6 "writes an alias row `<id> -> <successor>`"), 163 (S9
"`do_spl_agent_id_retire` with the new `<id>@<BOX_B>` as successor"), 256-259
(4.7.4 "so an @mention of the old id reaches the new seat"), 305 (C12), 325
(B4 "edits none of them").

The script maps a legacy id only:

```
$ git show origin/master:csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-id-retire.sh | sed -n 62,63p
#     --successor  the new id that takes over (a legacy <ID> only: the alias
#                  table maps legacy -> new, spec 061 section 5)
```

Run in a sandbox (`SPOOL_TEST=1`, private `SPOOL_ROOT`), tree = origin/master
`04148121a`, n=1:

```
$ SPOOL_TEST=1 SPOOL_ROOT=$T SPOOL_DESK_BOX=boxb bash csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-id-retire.sh --successor c-998@boxb c-997; echo "rc=$?"
agent-id-retire: --successor maps a legacy id only; c-997 is retired with no alias
rc=2
```

Every live seat is a new-form id (`[acgmq]-[0-9]{3}`), so S9 exits 2 and
retires nothing, and C12 cannot turn green while B4 "edits none of" the
retire script. Fix: either B4 (or a new row) owns a change to
`agent-id-retire.sh` / the alias table that accepts a new -> `<id>@<box>`
successor, with its own red control; or drop the alias promise and make S8's
"one post in each open topic naming the new seat" the only redirect, and
rewrite T6, 4.7.4 and C12 to match. Also: the "old number is not reused for
24 h" claim (line 259) is spec 061's quarantine (spec 061 line 266: "Is a
24 h quarantine before an id is reused ... acceptable? | yes"), not a
property of `--successor`; cite it there.

### W2 (blocking) 4.1 lines 91-94 / C14: the owner test is "no `SPOOL_AGENT_ID`", which `sudo -u <BOX_USER>` produces for every agent

Spec lines 91-94: "an agent caller (`SPOOL_AGENT_ID` set) must be the fleet's
orch lease holder ...; a caller with no agent id is the owner at a terminal."

Every agent seed tells the agent to run actions as `sudo -u <BOX_USER> ...`, and
sudo resets the environment:

```
$ echo "SPOOL_AGENT_ID=${SPOOL_AGENT_ID-<unset>}"
SPOOL_AGENT_ID=c-519
$ sudo -u <BOX_USER> bash -c 'echo "under sudo -u <BOX_USER>: SPOOL_AGENT_ID=${SPOOL_AGENT_ID-<unset>}"'
under sudo -u <BOX_USER>: SPOOL_AGENT_ID=<unset>
```

(The box user's literal name is replaced by `<BOX_USER>` in both the command
and its output, for the hygiene gate; nothing else in the output changed.)

So a lane agent running `sudo -u <BOX_USER> ./run -a do_spl_channel_move` is
classified as the owner and passes D1. C14's red control ("the plan runs for
a lane agent") only plants a caller WITH the id set, so it stays green on this
hole. Fix: the owner path needs a positive proof (a tty plus not inside any
agent's tmux pane / process tree, or an owner-signed directive as
`/signed-prompt` does), and C14 gains a second plant: an agent caller under
`sudo -u <BOX_USER>` with no `SPOOL_AGENT_ID` -> refused.

### W3 S1 line 155: `do_spl_wd_hold` does not make the seat stop editing

Spec: "**hold** them (`do_spl_wd_hold`): they stop editing, so the snapshot
is final".

```
$ git show origin/master:csi-spl-orc/src/bash/run/spl-wd-hold.func.sh | grep -nE '@description' | head -5
3:# @description Put one agent out of the watchdog's reach for MIN minutes
4:# @description (spec 093 6.2 and 6.3: a human working in that pane): the
5:# @description watchdog still writes its verdict, but sends it no key, no ring
6:# @description and no takeover. Writes <spool root>/<id>/.human-hold holding
7:# @description the epoch the hold ends at; MIN=0 lifts it.
```

The hold keeps the watchdog away; it does not stop the agent. After the
QUIESCE Escape, a spool poke or a pane line can start the seat working again
between S3's snapshot and S8, and those edits are lost on the target. Fix:
name a real freeze (no poke delivered to a held seat, or S3 re-checks each
worktree's `git status --porcelain` + HEAD sha just before S8 and re-ships a
delta), with a case: a commit made on the source after S3 -> either carried or
the switch refused.

### W4 4.7.1 line 242 / C18: "tests NOT run, from the seat's handoff note" has no field to read

The handoff has no tests section; the note action takes only `next`, `notes`,
`lesson`:

```
$ git show origin/master:csi-spl-orc/src/bash/run/spl-agent-handoff-note.func.sh | grep -nE '@param' | head -2
9:# @param SECTION (required) - next, notes or lesson
10:# @param TEXT (required) - the text, at most 8 KB
$ git show origin/master:csi-spl-orc/src/bash/run/spl-agent-handoff.func.sh | sed -n 5,6p
# @description brief, done, in flight, next step, open questions, owned topics,
# @description notes, lessons), about 250 lines at most. The ONLY writer of
```

So the move block "written from code" (W9 lesson, line 60) would have to
parse free text for the not-run list, and C18 has nothing mechanical to
check. Fix: a structured source (e.g. a `tests` handoff.d section or a
`MOVE_TESTS_NOT_RUN` input to the ack), and give that file to a build row.
Side note: T3 (line 69) says "9 sections" and lists 8 names; the handoff's
own header lists the same 8 (sed -n 5,6p above).

### W5 section 6 line 318: "Disjoint files" is false for B1 and B5

B1 (line 322) and B5 (line 326) both list `orc/run/spl-channel-move.func.sh`.
They are in different batches (1 and 3), so it works in sequence, but the
heading claim is wrong; say "B5 extends B1's file after B1 lands".

### W6 4.5 lines 203-204 vs S8: does the switch wait for a GO-less secret?

"Without the GO the secrets stay, and the step that needs one waits; the
rest of the move goes on." It does not say whether S7 ack / S8 switch happen
while a secret is missing on the target. A target seat that cannot reach a
key and still takes the channel at S8 is the W4 incident of section 2 again.
Say which: S8 waits for every secret step, or S8 proceeds and the move block
lists the missing secret by kind as a not-run item for the target seat. Add
a case.

### W7 7 / D4 line 345: "(never deleted on the source by the move)" is not in the relayed answer

The relay of the owner's answer (c-002 msg 8cc12ff2, read from c-873's
spool archive on this box): "Q4 B (move secrets over ssh, with his GO each
time)". Nothing about keeping the source copy. v0.1 (`68266b41a`) line 258
said "not deleted unless the owner's GO says so"; v0.2 hardened it to
"never". I could not read the poll's option text (7f6fe3d3) or the owner's
message 0102e85b itself (the spool-prd MCP did not connect from this seat;
`spool tail --task 0941c5c2-...` printed 1 line), so this is unchecked: if
option B's text says "keep on the source", cite it in the D4 row; if not,
D4's parenthesis is the author's addition and conflicts with the owner's
"delete anything after the move" (line 42) and D2.

## Checked and holding

### 1. Owner words -> spec coverage

| owner word | spec |
|---|---|
| one shell action, owner or administrator | 4.1 lines 84-106 (`do_spl_channel_move`), D1 (but see W2) |
| EVERYTHING: configs, data, binaries, src | manifest kinds 4.2 lines 115-127: `config`, `data`, `binary` (rebuilt), `repo` + `uncommitted`, `seat`, `spool`; desk: S6 line 160 |
| ball pass, receiver knows how to continue | 4.7 lines 232-261: handoff + move block, seed with ACK command, ack re-checked |
| sending agents killed after transfer | 4.7.3 "No ack, no kill", S9 after S7 (but see W1) |
| vice versa | 4.8 `back` lines 280-288, C9, C17 |
| nothing left on the source, find proof | 4.8 lines 265-277; roots include `/tmp` and the box user's home (W7 row, C16); the report says the marker find cannot prove absence (lines 276-277) |

### 2. Citations on origin/master `04148121a`

```
$ for p in ...; do git cat-file -e origin/master:$p; echo "rc=$? $p"; done
rc=0 csi-spl-doc/specs/164-channel-box-pin/spec.md
rc=0 csi-spl-doc/specs/069-ysg-box-out/spec.md
rc=0 csi-spl-doc/specs/060-role-rotation/spec.md
rc=0 csi-spl-doc/specs/058-multi-machine-fleet/spec.md
rc=0 csi-spl-doc/specs/064-fleet-without-the-pc/spec.md
rc=0 csi-spl-doc/doc/md/fleet-rules-index.md
rc=0 csi-spl-orc/src/bash/features/spawn-agents/lib/channel-rules.inc.sh
rc=0 csi-spl-orc/src/bash/run/spl-agent-handoff.func.sh
rc=0 csi-spl-orc/src/bash/run/spl-agent-handoff-note.func.sh
rc=0 csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh
rc=0 csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh
rc=0 csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-id-retire.sh
rc=0 csi-spl-orc/src/bash/run/spl-box-leave.func.sh
rc=0 csi-spl-orc/src/bash/run/spl-desk-up.func.sh
rc=0 csi-spl-orc/src/bash/run/spl-desk-check.func.sh
rc=0 csi-spl-orc/src/bash/run/spl-desk-probe.func.sh
rc=0 csi-spl-doc/doc/help/how-to-post.md
$ git cat-file -t 26838cdd1
commit
```

Functions and actions (`git grep -lE "^(function )?<f> *\(\)" origin/master`):

```
cr_sole_seat -> csi-spl-orc/src/bash/features/spawn-agents/lib/channel-rules.inc.sh csi-spl-orc/src/bash/tests/desk-reply-lease-gate.tst.sh
do_spl_agent_handoff -> csi-spl-orc/src/bash/run/spl-agent-handoff.func.sh
do_spl_agent_handoff_note -> csi-spl-orc/src/bash/run/spl-agent-handoff-note.func.sh
do_spl_agent_id_retire -> csi-spl-orc/src/bash/run/spl-agent-id-retire.func.sh
do_spl_box_leave -> csi-spl-orc/src/bash/run/spl-box-leave.func.sh
do_spl_channel_agent_add_op -> csi-spl-orc/src/bash/run/spl-channel-agent-add-op.func.sh
do_spl_channel_agent_remove_op -> csi-spl-orc/src/bash/run/spl-channel-agent-remove-op.func.sh
do_spl_desk_up -> csi-spl-orc/src/bash/run/spl-desk-up.func.sh
do_spl_desk_check -> csi-spl-orc/src/bash/run/spl-desk-check.func.sh csi-spl-orc/src/bash/tests/desk-move.tst.sh
do_spl_desk_probe -> csi-spl-orc/src/bash/run/spl-desk-probe.func.sh
do_satellite_ssh_config -> csi-spl-iac/src/bash/run/satellite-ssh-config.func.sh
do_spl_box_state_sync -> csi-spl-orc/src/bash/run/spl-box-state-sync.func.sh
spl_box_state_upload_scan -> csi-spl-orc/lib/bash/funcs/spl-box-state-mounts.func.sh
do_spl_wd_hold -> csi-spl-orc/src/bash/run/spl-wd-hold.func.sh
do_spl_desk_move -> csi-spl-orc/src/bash/run/spl-desk-move.func.sh
do_spl_private_overlay_pull -> csi-spl-orc/src/bash/run/spl-private-overlay-pull.func.sh
do_check_fleet_rules_drift -> csi-spl-orc/src/bash/run/check-fleet-rules-drift.func.sh
do_spl_channel_move -> NO DEFINITION
do_spl_channel_manifest_add -> NO DEFINITION
```

The last two are the spec's proposed actions (rows B1, B5): expected
absent, not a finding. No proposed test file is claimed as run.

Spec sections cited:

```
$ git show origin/master:csi-spl-doc/specs/060-role-rotation/spec.md | grep -nE '^#+ *(4\.4|5)[ .]|FR-014|^\| *D2|QUIESCE.*(60|Escape)'
30:| D2 | a new session that fails to start or never acks: KEEP THE OLD session in the role, and ALERT ...
191:- **FR-014** ACK: the script waits up to `ROTATE_ACK_TIMEOUT` (900 s) for the
346:### 4.4 Seed, ack and handoff delivery
506:## 5. State machines
512:GATE --> QUIESCE (grace 60 s, Escape, busy-rotated) --> HANDOFF --> SPAWN
$ git show origin/master:csi-spl-doc/specs/164-channel-box-pin/spec.md | grep -nE '^#+ *8[ .]'
253:## 8. Build Rows
$ git show origin/master:csi-spl-doc/specs/069-ysg-box-out/spec.md | grep -nE '^#+ *8\.4'
685:### 8.4 Per-box cutover (sat first, then `<pc box>`)
```

(Line 30 is cut here for width.) Spec 164's B2 is "Hub REST routes", so
"until its B2 is served, S8 switches ... only" (line 330) is consistent.
Spec 102 exists as `csi-spl-doc/specs/102-agent-lifetime`.

Facts in section 3:

```
$ git show origin/master:.../lib/channel-rules.inc.sh | sed -n 1,40p | grep -nE 'Channel:|sole' | head -3
7:#   Channel: <tenant> #<channel>
11:#   <tenant> <channel> <doc id> <env dev|prd> <desk agent the export runs as> [<sole seat>]
12:# The optional 6th column names the channel's SOLE SEAT, <agent id>@<box>:
$ git show origin/master:.../scripts/spawn-remote.sh | grep -nE 'Could not resolve|SPL-2801|every minute|lease.orch'
6:# to the PC (behind NAT: "Could not resolve hostname", measured 2026-10-03),
24:#   is refused there instead of racing this side's local fallback (SPL-2801:
27:# SERVE (the receiver, one tick; the box user's crontab runs it every minute,
164:  local f="$SPOOL_ROOT/dispatch/lease.orch" h="" id
$ git show origin/master:csi-spl-orc/src/bash/run/spl-box-state-sync.func.sh | grep -nE 'exit 3'
10:# @description Refused (exit 3, nothing sent) when anything under SRC is a
$ git grep -c channel_box_pins origin/master -- csi-spl-rdb; echo rc=$?
rc=1
$ git grep -n 'channel-move' origin/master -- ':!csi-spl-doc/specs/167-channel-box-move' | head -5
(no output)
```

(The spawn-remote grep is abridged to the lines named; the full output also
has lines 34, 35 and 205.) T1, T2, T5, T10, T11, T12 hold. T3 see W4, T6
see W1.

### 3. Secrets, slow links, source keeps the channel

- Secrets: GO per move id (4.5 lines 198-204, C6, C15), ssh only, bucket
  refused (C7, T10 `exit 3` above), never in a log (C13), data rule for the
  seat (lines 209-210). Holds, apart from W6 and W7.
- Slow links: bundles on a shared base before data (S3 before S4, 4.4), a
  full bundle only with its size printed, chunks + sha256 per file +
  `rsync --partial --checksum`, `partial` state + `resume` (4.6, C3). Holds.
- Source keeps the channel until S8 and a failure before S8 releases the hold
  (lines 171-174, C5, C17). Holds, but the seats are paused from S1 to S8
  (estimate 8-10 min, up to 900 s of ack on top), so "keeps working" (line
  227) means "keeps the channel", and W3 is the risk in that window.

### 4. Cases, rows, poll

- Each of C1-C18 has a red control column; C12 cannot pass (W1), C14 misses
  the sudo plant (W2).
- Rows B1-B7 name files, vendor and batch; no row sends customer work to
  agy or qwen (B7, docs only, goes to agy). W5 on "disjoint".
- Poll: v0.3 asks none ("No other question is open", line 347). D1-D3 match
  the relay (Q1 A, Q2 A, Q3 A); D4 see W7.

### 5. Hygiene

The ban pattern (box, OS user, person, bank and customer names) is kept in a
scratch file and not pasted here, because pasting it would trip the repo's
own gate:

```
$ git show 9a48fb4d4:csi-spl-doc/specs/167-channel-box-move/spec.md | grep -cEf ban.rx
1
$ git show 9a48fb4d4:csi-spl-doc/specs/167-channel-box-move/spec.md | grep -nEf ban.rx | cut -c1-30
11:gate), [spec 069 section 8.
```

The one hit is the link to an existing spec folder on master (spec 069's
folder name), not new text of this spec. The repo gate
`cd csi-spl-iac && ./run -a do_check_dist_hygiene` over the tracked tree
(spec.md included) printed `INFO distribution-hygiene: clean` before this
review file was staged. No other host, person, customer name or customer
path.

## What a PASS needs

W1 and W2 fixed in the spec (with their cases); W3 and W4 named with an
owning row; W5-W7 worded. A re-review then checks only those lines.
