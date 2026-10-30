review: c-519 claude FAIL 95eaba40c ran: git diff 9a48fb4d4 95eaba40c -- spec.md, grep -n of each folded line, git show agent-id-retire.sh / tmux-close-window.sh / spl-lane-rotate.func.sh, exit-clean SKILL.md section 0, setsid -f script ancestry probe, poll text grep, ban-pattern grep | read: spec.md@95eaba40c, agent-id-retire.sh, tmux-close-window.sh, spl-lane-rotate.func.sh, exit-clean SKILL.md, the v0.1 owner post file of c-873 | log: csi-spl-doc/specs/167-channel-box-move/reviews/c-519-claude-rereview-v04.md

# R7 re-review of spec 167 v0.4 (SPL-4227), claude seat c-519, same-vendor waiver

Re-review of `95eaba40c` (c-873 msg 434851db), asked by the dispatch holder
c-002 (msg 4027315a). The first review is
[c-519-claude-review.md](c-519-claude-review.md) (v0.3, `9a48fb4d4`). Line
numbers below are the spec's at `95eaba40c`; every output is pasted from the
command as run.

## Verdict: FAIL

W1, W3-W7 are folded. W2 is folded for the standard path but its new owner
test is still beatable (N2). One new blocking hole is in the S9 text the W1
fold rewrote (N1): the "kill" the owner asked for cannot complete as written.

## The seven findings of the first review

| W | fold at 95eaba40c | verdict |
|---|---|---|
| W1 retire `--successor` | T6 line 74, S9 line 175 (no `--successor`), 4.7.4 line 281, C12 line 334 | folded; see N1 for the step around it |
| W2 owner test | 4.1 lines 93-104, C14 (b) line 336, C21 line 343 | folded for `sudo -u <box user>`; see N2 |
| W3 hold does not freeze | S1 line 167, 4.4 lines 202-208, C19 line 341 | folded |
| W4 no tests field | T3 line 71 (8 sections), 4.7.1 line 267, C18 line 340 | folded; see N4 |
| W5 not disjoint | section 6 line 350 | folded |
| W6 S8 vs a GO-less secret | S8 line 174, 4.5 lines 222-227, C20 line 342 | folded; see N3 |
| W7 D4 source copy | 4.8 line 307, D4 line 377 | folded and checked, below |

W7 check: the v0.1 owner post (c-873's post file on this box,
`grep -nE '\(A\)|\(B\)|\(C\)'`) has, for the secrets question:

```
30:(A) Never move; the new box uses its own (recommended)
31:(B) Move over ssh, with your GO each time
32:(C) Move, and delete on the old box, with your GO each time
```

The relay (c-002 msg 8cc12ff2) says "Q4 B". So keeping the source copy is
the owner's choice of B over C: the D4 row is right.

## New findings

### N1 (blocking) S9 line 175 / 4.7.4 line 281 / C12 line 334: `/exit-clean` typed into a moved seat is refused, so the retire then exits 3

S9: "`/exit-clean` typed, then `do_spl_agent_id_retire` WITHOUT
`--successor`". C12 expects "the retire of the old new-form id exits 0".

1. `/exit-clean` refuses a seat that has no ACCEPTED, and a seat being moved
   mid-work has none. From the installed exit-clean skill (`~/.claude/skills/exit-clean/SKILL.md`
   of the agent user), section 0, lines 33-36:

   ```
   It exits 0 on an ACCEPTED from the dispatch holder or your spawner that is
   newer than every REJECT / SEND-BACK in your spool `inbox` and `archive`, and
   for a role seat (the rotation). If it exits 3: stop. Land, report, close and
   retire nothing;
   ```

   After the ACCEPTED it also refuses a `wip` issue with no landed commit and
   no end reason (lines 45-47). A seat whose work moves on to `<BOX_B>` has
   exactly that.
2. While its window is still there, the retire refuses:

   ```
   $ git show origin/master:csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-id-retire.sh | sed -n 123,126p
   if "${SPOOL_TM[@]}" list-windows -a -F '#{window_name}' 2>/dev/null \
       | grep -E "(^|[^A-Za-z0-9])${ID}([^0-9]|\$)" >/dev/null; then
     echo "agent-id-retire: a tmux window still carries ${ID}; close it first (tmux-close-window.sh --agent ${ID} --retire)" >&2
     exit 3
   ```

3. When `/exit-clean` does pass, it already retires the id itself
   (`tmux-close-window.sh --defer --retire`, skill lines 118-120), so S9's
   second retire finds nothing to retire (exit 4, "nothing on this machine
   holds the id", the exit code I got in the first review's sandbox run).
4. The lane rotation that T4 cites already says `/exit-clean` is the wrong
   verb here:

   ```
   $ git show origin/master:csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh | sed -n 580,583p
   # RETIRE: /exit (a lane's /exit-clean would land and report a task that goes
   # on), the restore wrapper stopped before the TERM (it would relaunch the old
   # session in place), TERM, KILL. Every tmux call is bounded by
   # ROTATE_LANE_TMUX_TIMEOUT, so a stuck one falls through to the TERM
   ```

Fix: S9 reuses the lane rotation's RETIRE (`/exit`, wrapper stop, TERM,
KILL: `spl_lane_rotate_from_ack` in `spl-lane-rotate.func.sh`, or the steps
it runs), then `tmux-close-window.sh --agent <id> --retire` (that is the
command the retire's own error names), and C12 checks that order. B4 calls
these and edits none of them, so the row's file list stays as it is.

### N2 (wording, non-blocking) 4.1 lines 97-104: the "positive" owner test is a guard against mistakes, not a proof

The fold closes the standard path (`sudo -u <box user>` with no agent id):
C14 (b). But an agent's own shell can get a tty and an ancestry with no agent
CLI and no pane. Run from this seat's Bash tool (n=1):

```
$ setsid -f script -qc 'sleep 1; p=$$; while [ "$p" -gt 1 ]; do ps -o pid=,user=,comm= -p $p; p=$(ps -o ppid= -p $p | tr -d " "); done; tty' /dev/null > probe2.out 2>&1; sleep 4; cat probe2.out
1542042 <AGENT_USER> bash
1542038 <AGENT_USER> script
/dev/pts/32
```

(The agent OS user's literal name is replaced by `<AGENT_USER>` for the
hygiene gate.) The walk ends at pid 1 after `bash` and `script`: no claude, no tmux pane,
and a tty. The same command under `sudo -u <box user>` runs as the box user,
so by the line 101 test ("no agent in the ancestry or the pane, a tty, and
the box user's own login") it would count as the owner. I did not run it
under sudo. Two more things:

- `sudo` also strips the pane variables (the installed exit-clean skill,
  line 116: "(`$CLE_TMUX_PANE` ...), which sudo strips"), so "the tmux pane
  it runs in" (line 98) has to be found by walking the ancestry to a
  `#{pane_pid}`; the spec should say so.
- Fix, wording only: say the process test catches mistakes (the normal
  `sudo` path), and that only the `/signed-prompt` envelope proves the owner.
  Either make the envelope required for `DRY_RUN=0` (`move`, `back`,
  `clean`), or state the remaining risk in section 8.

### N3 (non-blocking) 4.5 line 224: the wait for a GO is open-ended, and the seats stay paused all that time

"S8 waits for every secret step ... The source keeps the channel
meanwhile." The source seats were quiesced at S1, and the spec releases the
hold only on a failure (line 183), a missing ack (line 279) or a `back`
(line 315). An owner who does not answer leaves the channel's seats paused,
and the target agent seated, with no end. Say which happens: the hold is
lifted while S8 waits (the S1 re-check then ships the delta, C19), or a
`MOVE_GO_TIMEOUT` aborts the move as C17 does.

### N4 (non-blocking) 4.2: the new `tests-not-run` line kind is not in the manifest table

```
$ grep -c '^| `tests-not-run`' spec.md
0
```

Line 267 adds a manifest line `tests-not-run <suite command>`, but the kinds
table (lines 127-139) that says "The action moves what the channel's
manifest lists, and nothing else" has no row for it. Add the row (declared,
not moved, written into the move block).

## Hygiene

The ban pattern is in a scratch file, not pasted (pasting it trips the repo
gate):

```
$ grep -cEf ban.rx spec.md
1
```

The one hit is still the link to spec 069's folder on master (line 13 now).

## What a PASS needs

N1 fixed in S9, 4.7.4 and C12. N2-N4 worded. A re-review then checks only
those lines.
