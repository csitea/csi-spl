review: c-519 claude FAIL 431bae0a5 ran: git diff 95eaba40c 431bae0a5 -- spec.md, grep -n per folded line, git show spl-rotate-lib.func.sh / spl-lane-rotate.func.sh / tmux-close-window.sh / directive-session.sh / directive-sign.sh, tmux show-options remain-on-exit on the box, a private-socket tmux window probe, git grep remain-on-exit, ban grep | read: spec.md@431bae0a5 and those files | log: csi-spl-doc/specs/167-channel-box-move/reviews/c-519-claude-rereview-v05.md

# R7 re-review 2 of spec 167 v0.5 (SPL-4227), claude seat c-519, same-vendor waiver

Re-review of `431bae0a5` (c-873 msg 8ea23a2d), asked by the dispatch holder
c-002 (msg 0a21dbe2). Earlier rounds:
[v0.3 review](c-519-claude-review.md), [v0.4 re-review](c-519-claude-rereview-v04.md).
Line numbers are the spec's at `431bae0a5`; every output is pasted from the
command as run.

## Verdict: FAIL

N1-N4 are folded. The S9 command chosen for N1 hits a new hole (N5, blocking):
on the live box the window is already gone when
`tmux-close-window.sh --agent <id> --retire` runs, so it exits 3 and retires
nothing. The test sandbox would hide that, because the test lib turns
`remain-on-exit` on. N6 and N7 are wording.

## The four findings of the v0.4 re-review

| N | fold at 431bae0a5 | verdict |
|---|---|---|
| N1 S9 `/exit-clean` | S9 line 183, 4.7.4 lines 295-301, C12 line 354, B4 line 378 | folded (no `/exit-clean`, rotation RETIRE); see N5 and N6 |
| N2 owner test not a proof | 4.1 lines 100 and 104-110, C22 line 364, R5 line 414 | folded; see N7 |
| N3 open-ended paused wait | 4.5 lines 233-241, C20 line 362 | folded |
| N4 manifest row | 4.2 line 146 | folded |

`spl_rotate_end` exists where B4 says:

```
$ git grep -nE '^(function )?spl_rotate_end *\(\)' origin/master -- csi-spl-orc
origin/master:csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh:1304:spl_rotate_end() {
```

## New findings

### N5 (blocking) S9 line 183 / 4.7.4 line 301 / C12 line 354: after RETIRE the window is already gone, so `tmux-close-window.sh --agent <id> --retire` exits 3 and retires nothing

The RETIRE stops the pane's root process (the restore wrapper) and then the
agent. On the live box `remain-on-exit` is off:

```
$ tmux -S <box socket> show-options -g remain-on-exit
remain-on-exit off
$ tmux -S <box socket> show-options -gw remain-on-exit
remain-on-exit off
```

With it off, a window whose only pane's process ends goes away. Private
socket, n=1 (the pane's command exits by itself: the kill guard refuses a
computed pid, so I did not signal it):

```
$ tmux -S $S -f /dev/null new-session -d -s s0 -n keep 'sleep 60'; tmux -S $S set-option -g remain-on-exit off; tmux -S $S new-window -d -n c-997 'sleep 2'; echo "before:"; tmux -S $S list-windows -a -F '#{window_name}'; sleep 4; echo "after the pane root exits:"; tmux -S $S list-windows -a -F '#{window_name}'; tmux -S $S kill-server
before:
keep
c-997
after the pane root exits:
keep
```

Then `--agent` finds no window and stops before its retire:

```
$ git show origin/master:csi-spl-orc/src/bash/features/spawn-agents/scripts/tmux-close-window.sh | sed -n 390,395p
elif [[ -n "$AGENT_ARG" ]]; then
  if ! PANE="$(resolve_pane_for_agent "$AGENT_ID")"; then
    echo "tmux-close-window: REFUSED — no live window named '$AGENT_ID' on $sock" >&2
    echo "                   (checked ${SPOOL_ROOT}/registry.tsv and every window name); closed nothing" >&2
    exit 3
  fi
```

C12 expects that call to exit 0, and the sandbox would agree, because the
test lib turns the option on:

```
$ git grep -n 'remain-on-exit' origin/master -- csi-spl-orc | head -5
...tests/lib.inc.sh:82:  tmux -S "$SPOOL_TMUX_SOCKET" set-option -g remain-on-exit on >/dev/null
```

So C12 goes green in the tests while the live S9 leaves the old id
unretired: its spool dir, registry row and desk seats stay, and S10's clean
then runs against an id that was never retired.

Fix: after RETIRE, if a window still carries the id (with the retire's own
loose match, `agent-id-retire.sh` lines 123-124), run
`tmux-close-window.sh --agent <id> --retire`; if none does, run
`agent-id-retire.sh --apply <id>` directly. That command is what
`tmux-close-window.sh --retire` itself runs (`tmux-close-window.sh` line 805).
C12 gets both branches, and its test sets `remain-on-exit off` as on the box.

### N6 (wording) B4 line 378: the wrapper stop is not in `spl_rotate_end`

S9 says "`/exit`, the restore wrapper stopped, TERM, KILL", and B4 cites only
`spl_rotate_end` in `spl-rotate-lib.func.sh`. The wrapper stop is a hook the
lane rotation passes in from its own file:

```
$ git show origin/master:csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh | sed -n 588,589p
  if ! ROTATE_TMUX_TIMEOUT="$ROTATE_LANE_TMUX_TIMEOUT" ROTATE_PRE_TERM=spl_lane_rotate_unwrap \
       spl_rotate_end "$ROTATE_OLD_PANE" "$ROTATE_OLD_PID" /exit "$ROTATE_LANE_EXIT_WAIT" "$ROTATE_TERM_WAIT"; then
```

`spl_lane_rotate_unwrap` (same file, line 601) TERMs the pane's
`#{pane_pid}`. A B4 that calls `spl_rotate_end` alone leaves the wrapper
running, and it starts the old seat again. Name `ROTATE_PRE_TERM=spl_lane_rotate_unwrap`
(or that file) in B4, and add "the seat is not relaunched" to C12.

### N7 (wording) 4.1 lines 108-110 / R5 line 414: an open directive window lets an agent sign too

The feature's own header states the limit:

```
$ git show origin/master:csi-spl-orc/src/bash/features/directive/scripts/directive-session.sh | sed -n 21,27p
# This window costs the owner the same single passphrase entry, but every
# directive is still signed over ITS OWN TEXT. What survives is: the text the
# receiving box acts on is the text that was signed on the owner's box inside a
# window they opened. Drift cannot get through. An agent here deliberately signing
# something they did not write still can -- that is the price of typing the
# passphrase once instead of every time, it is identical under a session token,
# and it is the honest limit of both.
```

So C22's proof holds outside an open window, or when `directive-sign.sh`
prompts for the passphrase (its header: "gpg will PROMPT FOR THE PASSPHRASE.
That prompt is the security boundary"). Two things to put in the spec:

- R5 adds this limit.
- The owner's "single shell action" (c0b1208c): when the owner runs
  `DRY_RUN=0` at his own tty, the action itself calls `directive-sign.sh` (one
  passphrase prompt), so the owner does not run a separate signing step
  first. Say which way it works.

## Hygiene

```
$ grep -cEf ban.rx spec.md
1
```

The one hit is still the link to spec 069's folder on master. The box socket
path is written as `<box socket>` above, because it holds the box user's uid.

## What a PASS needs

N5 fixed in S9, 4.7.4 and C12 (both branches, `remain-on-exit off` in the
test). N6 and N7 worded. A re-review then checks only those lines.
