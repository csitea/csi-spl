# Lane brief: the night's reflection, night of {NIGHT} (one small task, refactor, from do_spl_reflection_gather)

Class: refactor
Kind: specs_and_docs
Epic: SPL-2129
Spec: csi-spl-doc/specs/166-orchestrator-daily-rhythm

Queued by `do_spl_reflection_gather` (spec 166 row B8, section 3.3), placement
slug `reflection-{NIGHT}`. Window: {SINCE} .. {UNTIL}, the last 24 h. Report
to the CURRENT dispatch lease holder (`cd csi-spl-orc && LEASE_CMD=show ./run
-a do_spl_dispatch_lease`) on task `dispatch-reflection-{NIGHT}`, kind result.
Never post in an owner topic or a channel.

## Why

Owner HUM-10, t1 topic c0b0d572, msg 421e479a: "internal reflections ...
shoould be performed each 24h, starting from 20:00 till 07:00 CET". Poll
d102c775 Q4 A: "A Qto doc page per day in the system workspace, linked from
the morning owner digest; never git, the repo is public".

## Do

1. Read the gathered file below (also on the queuing box at `{GATHER_FILE}`).
   For each owner message id in its section 4, read the message
   (`spool tail --task <topic>` on the hub) and mark the **corrections**: the
   owner saying a rule was broken or a result was wrong, each with its msg id.
2. Write ONE Qto doc page in the workspace `system`, titled
   `Reflection {NIGHT}`, through `do_spl_desk_doctree` under your own seat
   (`TENANT_ID=system`). Its sections: CI reds, reverts, lanes ended without
   landing, owner corrections (msg id each), what each correction asks the
   fleet to change, the class share and the zombie count, and at most 3
   proposed rows.
3. Each proposed row is refactor or bug, one small task, with its own
   `Class:`, `Epic: SPL-<n>` and `Spec: <spec folder on origin/master>` lines.
   Send each to the dispatch holder as a spawn request (kind task); it goes
   through the normal enqueue gates (`do_spl_spawn_enqueue`,
   `SPAWN_CLASS=refactor|bug`), so it runs the same night.
4. **Never git**: no commit, no file in the repository, no branch. The owner's
   messages may carry private matter; quote ids, not text, outside the page.
5. Result: the page's doc id and title, the counts per section, the rows sent.
   Nothing to land: end your issue with `LANE_ISSUE_OP=end` and the page id as
   the reason once the result is sent.

## The gathered file

{GATHER}
