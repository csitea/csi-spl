review: c-519 claude PASS 966a58bbf ran: git diff 89c3ca32e 966a58bbf -- spec.md, grep -n on spec.md@966a58bbf (folded lines, stale-text check), git show directive-session.sh, ban grep | read: spec.md@966a58bbf, directive-session.sh | log: csi-spl-doc/specs/167-channel-box-move/reviews/c-519-claude-rereview-v07.md

# R7 re-review 4 of spec 167 v0.7 (SPL-4227), claude seat c-519, same-vendor waiver

Re-review of `966a58bbf` (c-873 msg ea720c6d). Earlier rounds:
[v0.3](c-519-claude-review.md), [v0.4](c-519-claude-rereview-v04.md),
[v0.5](c-519-claude-rereview-v05.md), [v0.6](c-519-claude-rereview-v06.md).
Line numbers are the spec's at `966a58bbf`; every output is pasted from the
command as run.

## Verdict: PASS

N8 and N9 are folded, with cases C23 and C24 owned by B1. No earlier finding
(W1-W7, N1-N9) is open. One note (N10) is wording for B1, not a blocker.

## The two findings of the v0.6 re-review

| N | fold at 966a58bbf | verdict |
|---|---|---|
| N8 `ack` refused by D1 | 4.1 line 97 ("with ONE exception": `ack` only, only to the journal's new seat, id from the pane ancestry walk, never env), C23 line 399 (a accepted; b, c, d refused), B1 | folded |
| N9 envelope to the wrong box | 4.1 lines 118-133 (addressed to the driver; a second envelope to the other box when it acts through the hub; `move`, `resume`, `back`, `clean` sign fresh; `plan`, `status` sign nothing), C24 line 400, B1 | folded |

Stale text from earlier versions:

```
$ grep -nE 'as successor|`/exit-clean` typed|directive-sign.sh <BOX_B>' spec.md
388:| C12 | ... | `tmux-close-window.sh --agent` on a gone window (exit 3, nothing retired), a retire before a live window is closed (exit 3), `--successor` (exit 2), no wrapper stop (the seat relaunches), or `/exit-clean` typed into the seat |
```

(abridged to the red-control cell.) The one hit is C12's red control, which
is right to name it. Nothing stale is left in the steps.

## N10 (note, non-blocking) 4.1 line 125: the action should close the signing window it opens

"the same signing window (`directive-session.sh`, one passphrase for
both)". A window stays open for its whole length, 60 minutes by default:

```
$ git show origin/master:csi-spl-orc/src/bash/features/directive/scripts/directive-session.sh | sed -n 6,8p
#   directive-session.sh [--minutes N]   open a window (default 60)
#   directive-session.sh --status        is one open, and for how much longer
#   directive-session.sh --close         shut it now
```

Inside an open window an agent can sign text the owner did not write (R5,
line 453). B1 should open the window with a short `--minutes`, sign, and run
`--close` at once; if the owner already had a window open, it should leave
that one as it found it. One line in 4.1 and a check in C24 ("no window
opened by the move is still open after it signs").

## Hygiene

```
$ grep -cEf ban.rx spec.md
1
```

The one hit is still the link to spec 069's folder on master.

## Outcome

ACCEPTED by the dispatch holder c-003 (msg 264de3ed, 2026-10-30) on this
PASS; N10 goes to c-873 as a last one-line fold, checked by c-003.
