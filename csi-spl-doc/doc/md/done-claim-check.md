# A "done" claim that is not in the repository (SPL-2265)

Owner HUM-10, t1 thread b61851fb (analysis msg 8b56951c, row D2 ticked in
poll answer c5c9687b): m-595 sent its result and closed itself before its
push was refused, and the result read like a landing. Plain coded checks, no
AI in the loop (t1 37349c9b, 0626b425); no language parsing beyond the hex
sha.

## 1. The check

`cd csi-spl-orc && ./run -a do_spl_done_claim_check` (DRY_RUN=1 default:
reads and fetches, sends nothing, writes no ledger). Code:
`csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh`.

1. Every spool message of kind `result` from a lane (`c-`/`m-`/`a-`/`g-`/`q-`
   id above 003; 001..003 are role seats, spec 061 Q1) in the last 24 h,
   read from every `inbox/`, `archive/` and `outbox/` under the spool root,
   once per `msg_id`. Skipped: a lane of another box (`<id>@<box>`: that
   box checks it) and a result a lane sends itself (`to` = `from`, the
   lane-rotate ACK).
2. Its shas: every token of 9..40 lowercase hex with at least one letter
   a..f, UUIDs cut out first (an all-digit token is a CI run id).
3. 15 min after the message: `git fetch` of each repo in
   `DONE_CLAIM_REPO_DIRS` (default csi-spl), then each sha must resolve in
   one of them and be an ancestor of its `origin/master` (else
   `origin/main`). A sha of another repo is checked in that repo.
4. No sha, or a sha on no trunk: ONE note to the dispatch lease holder on
   task `done-claim-check`: lane, msg id, the shas, "not in the repository".
   Every judged message goes to the ledger
   (`$XDG_STATE_HOME/csi-spl/done-claim-check/seen.tsv`) and is never judged
   again; a failed send stays out of it and is retried on the next run.

A repo dir that is not a clone, or a failed fetch, refuses the run: a missing
clone must not turn every sha into an alert.

## 2. Standing

The box cron `done-claim-check`, every 5 min (row in
`csi-spl-orc/cnf/box-crons/box-crons.manifest`, script
`csi-spl-orc/src/bash/scripts/done-claim-check-cron.sh`), installed with
`./run -a do_install_box_crons`.

## 3. Tests

`csi-spl-orc/src/bash/tests/spl-done-claim-check.tst.sh`: m-595's shape (no
sha) alerts after 15 min and not before; a landed full sha and a 9-hex short
sha do not; a sha of a second repo is checked in that repo; an unpushed sha
alerts; one note per message; a failed send is retried; a missing clone
refuses.
