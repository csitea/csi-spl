review: c-519 claude FAIL 89c3ca32e ran: git diff 431bae0a5 89c3ca32e -- spec.md, grep -n / sed -n on spec.md@89c3ca32e, git show directive-verify.sh, ban grep | read: spec.md@89c3ca32e, directive-verify.sh, directive-sign.sh | log: csi-spl-doc/specs/167-channel-box-move/reviews/c-519-claude-rereview-v06.md

# R7 re-review 3 of spec 167 v0.6 (SPL-4227), claude seat c-519, same-vendor waiver

Re-review of `89c3ca32e` (c-873 msg 0903d081), asked by the dispatch holder
c-002 (msg a1617d44). Earlier rounds:
[v0.3](c-519-claude-review.md), [v0.4](c-519-claude-rereview-v04.md),
[v0.5](c-519-claude-rereview-v05.md). Line numbers are the spec's at
`89c3ca32e`; every output is pasted from the command as run.

## Verdict: FAIL

N5, N6 and N7 are folded. Two blocking holes remain, both in 4.1. N8 has been
there since v0.2 (D1), and I missed it in the earlier rounds. N9 comes from
the N7 fold. Each needs a few lines and a case.

## The three findings of the v0.5 re-review

| N | fold at 89c3ca32e | verdict |
|---|---|---|
| N5 window gone after RETIRE | S9, 4.7.4 (two branches), C12 with `remain-on-exit` OFF, both branches | folded |
| N6 wrapper stop hook | 4.7.4, B4 (`ROTATE_PRE_TERM=spl_lane_rotate_unwrap`), C12 "no pid carries the id 30 s later" | folded |
| N7 directive limit, one action | 4.1 lines 112-116, R5 | folded; see N9 for the box the envelope names |

## New findings

### N8 (blocking) 4.1 lines 94-95 vs line 124 and 4.7.2 line 291: the D1 caller check refuses the target seat's `ack`

```
$ sed -n 94,95p spec.md
- Runs from either box, by the owner or the orchestrator seat only (D1).
  Any other caller is refused before `plan` reads anything. "No
$ sed -n 123,124p spec.md
  direction, from the journal), `clean` (the source cleanup, 4.8), `ack` (run
  by a target seat, 4.7).
$ sed -n 290,291p spec.md
   the handoff and one ACK command:
   `MOVE_CMD=ack MOVE_ID=<id> SEAT=<new id> ./run -a do_spl_channel_move`.
```

The target seat is an agent, and it is not the orch lease holder. By the
"agent" branch of 4.1 (the process ancestry or the pane names an agent id,
which must be the lease holder) its ack is refused. No line exempts `ack`.
Every move then waits out `MOVE_ACK_TIMEOUT` and aborts (4.7.3, C5), so no
move ever reaches S8.

Fix: `ack` is the one command a non-orchestrator agent may run. It is
accepted only when the caller's pane-resolved agent id equals the new seat
id the journal records for that `MOVE_ID`. It cannot reach any other
command, and it needs no signed directive. Add a case: an ack by the
journal's seat is accepted; an ack by any other agent, or `MOVE_CMD=move` by
that seat, is refused. This has been in the text since v0.2, and I did not
catch it in the three earlier rounds.

### N9 (blocking) 4.1 lines 112-114: the envelope is addressed to `<BOX_B>`, but it is verified on the driver, which may be `<BOX_A>`

```
$ sed -n 112,114p spec.md
    At the owner's own tty the action makes that envelope itself: it calls
    `directive-sign.sh <BOX_B> "<the move: channel, target, move id>"`,
    which asks the passphrase once, so the move stays one shell action
```

The verifier refuses an envelope addressed to another box. From
`git show origin/master:.../directive/scripts/directive-verify.sh | sed -n 212,300p | grep -nE 'refuse|BOX_TAG_EXPECT|to:'`
(line numbers relative to 212):

```
32:[ -n "$TO" ] || refuse "envelope has no 'to:' field"
33:[ "$TO" = "$BOX_TAG_EXPECT" ] \
34:  || refuse "addressed to '$TO', this box is '$BOX_TAG_EXPECT'"
...
47:  refuse "nonce already used: $NONCE
48:         This envelope has been acted on before. Replay refused."
```

The move "runs from either box" (line 94), and the envelope is "verified
before the first change" (line 110). The first changes are on the source
(S1 quiesce). So the owner driving from `<BOX_A>`, the usual case of a move
away from the box he sits at, gets exit 78 and no move. The nonce ledger is
per box, and a spent nonce is refused, so one envelope cannot serve two
verifications on the same box.

Fix: sign for the box that verifies, which is the driver
(`directive-sign.sh <driver box tag> ...`). If the other box must verify too
(it changes channel-rules at S8 and runs S6), sign a second envelope for it
in the same passphrase window. Say whether `back`, `resume` and `clean`
under `DRY_RUN=0` each need a fresh envelope (each verify spends its nonce).
Add a case: the owner drives from `<BOX_A>` and the envelope verifies there;
an envelope for the wrong box is refused (exit 78).

## Hygiene

```
$ grep -cEf ban.rx spec.md
1
```

The one hit is still the link to spec 069's folder on master.

## What a PASS needs

N8 and N9 fixed in 4.1, with their cases. A re-review then checks only those
lines.
