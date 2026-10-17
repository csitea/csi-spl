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
   `origin/main`), or carry a patch already on it: `git cherry <trunk> <sha>
   <sha>^` prints `- <sha>` (same patch-id under another sha, as a
   review-branch sha the rebase landed anew; c-002@sat, msg a34e2b44, n=3:
   bbaa9fe83, 5deaf8c1e, ad064cf5e). A sha of another repo is checked
   in that repo.
4. No sha, or a sha on no trunk: ONE note to the dispatch lease holder on
   task `done-claim-check`: lane, msg id, the shas, "not in the repository".
   Every judged message goes to the ledger
   (`$XDG_STATE_HOME/csi-spl/done-claim-check/seen.tsv`) and is never judged
   again; a failed send stays out of it and is retried on the next run.

A repo dir that is not a clone, or a failed fetch, refuses the run: a missing
clone must not turn every sha into an alert.

### 1.1 Seat, reviewer and plan lanes, and parked shas (SPL-2313)

Those lanes never push code, so a note for them is noise (c-928's 24 h dry
run on the main box: a-586, a-592, a-738 among the 12 alerts). Both rules read only
metadata the fleet writes itself, never the message body (t1 37349c9b):

1. **Verdict `seat`** (ledger, no note) when the lane's slug marks it: its
   LAST word, once a trailing vendor (`claude`, `agy`, `mistral`, `grok`,
   `qwen`), `takeover` or issue key (`spl-2219`, `spl2285`) is cut, is
   `seat`, `seatN`, `review`, `reviewer`, `plan` or `planner`
   (`a-212-c002-rel03-r7-reviewer-agy`, `c-285-c002-rel-seat-claude`,
   `a-812-c001-review-spl-2219`, `a-591-c002-perf6-wui-speed-plan`). The
   first brief's "contains `-seat-` / `-reviewer-`" was measured wrong both
   ways on 241 slugs of both boxes (10-17): it matches the code lane
   `m-341-c002-done-claim-skip-seat-lanes` and misses the review lanes
   `...-i18n-review-agy` (a-738, a-168). The last-word rule marks 33 of the
   241, and none of the code lanes whose topic only mentions seats (m-341,
   m-284 `lane-map-role-seats`). Both the no-sha and the sha case are
   skipped: a reviewer cites the reviewed sha, which is by design not on
   trunk. The slug, both sources surviving the retire until the disk sweep
   removes the worktree 24 h later (the window the check reads):
   - the lane's worktree branch, `<id>-<slug>`, from `git worktree list` of
     each repo in `DONE_CLAIM_REPO_DIRS`;
   - its retired row in `$SPOOL_ROOT/workdirs.tsv` (agent, branch), written
     by `agent-id-retire.sh`.
   Every slug found for the id must mark it (one code slug, as from an old
   lane of a recycled id, and it is judged as before); a lane with no slug
   is judged as before. No list of ids is kept anywhere.
2. **Verdict `pending`** (no note, no ledger, judged again on the next run)
   when every missing sha is on a remote branch `origin/<id>-...`,
   `origin/review/<id>-...` or `origin/wip/<id>-...` (`git branch -r
   --contains`) of a lane still in this box's `registry.tsv`: a plan lane
   waiting for a go. Once that lane is retired the sha alerts as before. A
   lane of another box is not in this box's registry, so its branch does not
   hold a sha back. The lane map is not read: it exits 4 whenever a lane
   recorded no files.

Not covered (report only): a sha whose work landed under a rewritten patch
(`git cherry` `+`, a different patch-id), e.g. aea648fbe -> ac699baf1.

## 2. Standing

The box cron `done-claim-check`, every 5 min (row in
`csi-spl-orc/cnf/box-crons/box-crons.manifest`, script
`csi-spl-orc/src/bash/scripts/done-claim-check-cron.sh`), installed with
`./run -a do_install_box_crons`.

## 3. Tests

`csi-spl-orc/src/bash/tests/spl-done-claim-check.tst.sh`: m-595's shape (no
sha) alerts after 15 min and not before; a landed full sha and a 9-hex short
sha do not, nor a rebased sha whose patch is on the trunk; a sha of a second repo is checked in that repo; an unpushed sha
alerts; one note per message; a failed send is retried; a missing clone
refuses. SPL-2313: a reviewer slug from a live worktree and a seat and a
plan slug from retired `workdirs.tsv` rows are `seat`, with a sha or none; a
code slug and no slug alert; a sha on a live lane's `review/` branch is
`pending` and alerts once the lane leaves the registry; a gone lane's `wip/`
sha alerts.
