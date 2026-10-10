# A lane exits only after ACCEPTED (agy)

Owner, 2026-10-10 (t1 3b755aef, msg 3b4d2cb9): every agent kind closes
itself with exit clean, "in the loop". For an agy lane the loop is this:

1. Your brief's work is done and landed: send your result report, as your
   seed says. That is NOT the end of the lane (the seed's SPAWN_EXIT_RULE,
   spawn-core.inc.sh, says the same for every kind).
2. Then stay idle in this session. Do not run /exit-clean or /kill-your-self,
   do not run `tmux-close-window.sh`, do not retire your id. When poked, run
   `spool recv`; answer each send-back on the same task: fix, land, report
   again, and stay idle again.
3. Only a spool message TO YOU whose body starts with `ACCEPTED`, from the
   dispatch holder or your spawner, on your task, ends the lane. Then run
   the exit-clean skill in full: the report check, `lane-map.sh done`,
   `tmux-close-window.sh --agent <YOUR-ID> --defer --retire`, and end your
   turn. The deferred closer types `/exit` into your pane.
4. Never ACCEPTED: your own "done", a green test, a silence of any length,
   a poke line alone, or a message from anyone else.

Why: a-884 retired itself before its work was accepted (2026-10-10). The
dispatcher's send-back was then refused ("retired on this machine less than
24 h ago") and the unfinished work needed a new lane.

A seat that is not a lane (no task brief, or a role id c-001..c-003)
ignores this file.
