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
2. Its shas: every token of 9..12 or 40 lowercase hex with at least one
   letter a..f, UUIDs cut out first. An all-digit token is a sha only when
   `git cat-file -t` names it a commit in a checked repo (SPL-2706: c-597's
   `sha: 704617890`, a trunk commit, read as no sha); else it is a CI run id.
   13..39 hex is no git sha: a 32-hex md5 file hash (c-350, notes d60b054e
   and 48df14ac, 10-17) was read as four missing shas. A token right after
   an `md5` / `md5sum` label is skipped too (SPL-2332). So is a relay
   run-on-box request id (SPL-2953: c-368's `gr-cmd-890b4562175b`, a
   12-hex token that is no object, read as a pre-rebase sha): the hex of
   `gr-cmd-<hex>` (also `.zip`) and a token right after a `gr-cmd`,
   `request id` or `req` label. An unlabelled lettered token that is no
   object still counts as a pre-rebase sha.
   **The claim is the sha line** (SPL-2338): when a line of the body starts
   with the word `sha` or `shas`, after list marks and bold (`sha:`,
   `- **sha**:`, `- **Sha:**`, `SHA:`, `- sha \`<sha>\``), and such a line
   holds a sha, only those lines' shas are checked. A sha quoted on any
   other line (another lane's, another repo's, a reverted one, one in a
   pasted log) is context, not a landing. With no sha line, or only
   `sha: none`, every sha of the body is checked, as before. So a lane makes
   its claim exact by writing its landing sha on a `sha:` line.
   Why this rule, not "alert only when no sha of the body is on a trunk":
   that one clears a refused push whose result also quotes the trunk sha it
   rebased onto, m-595's failure plus one line. Measured on the satellite
   spool, 2026-10-17, DRY_RUN=1, empty ledger, one clock, repo csi-spl at
   origin/master 4ee9dfa07, n=1 run over 205 judged results: would-alert
   30 -> 28 (c-355 88580b2e, which quotes another repo's 9c741867a396; c-320
   df0edc06, which quotes another lane's stale aea648fbe); no result whose
   sha line names an unlanded sha moved to landed. The any-sha rule would
   have cleared 5.
3. 15 min after the message: `git fetch` of each repo in
   `DONE_CLAIM_REPO_DIRS` (default csi-spl), then each sha must resolve in
   one of them and be an ancestor of its `origin/master` (else
   `origin/main`), or carry a patch already on it: `git cherry <trunk> <sha>
   <sha>^` prints `- <sha>` (same patch-id under another sha, as a
   review-branch sha the rebase landed anew; c-002@sat, msg a34e2b44, n=3:
   bbaa9fe83, 5deaf8c1e, ad064cf5e). A sha of another repo is checked
   in that repo. The sender lane's own repo is one of them too (section
   1.3).
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
metadata the fleet writes itself, never the message body (t1 37349c9b); the
one exception is the R7 review line of rule 1 (SPL-2916):

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
     by `agent-id-retire.sh`;
   - SPL-2838: a lane whose worktree is a detached HEAD (an R7 reviewer
     checks the reviewed sha out detached: m-744, alerts 1ae5165f and
     b987fe29) lists no branch, and its retired row has an empty branch.
     For such a lane only, the spawn's own local branch `refs/heads/<id>-...`
     of each repo is its slug.
   SPL-2916: ids are recycled, so only the id's LATEST slug counts (the
   rule before, "every slug found must mark it", let an old code lane of the
   same id turn the R7 reviewer m-120 of the other box into 3 alerts on 10-22: f6471a6c,
   6e992de7, d0a3f930). In order: the branches of the id's live worktrees
   (every one must mark it); else, its live worktree detached, its newest
   local `<id>-...` branch by tip commit date (a spawn branches off the
   trunk of its day); else its newest `workdirs.tsv` row by `finished_at`
   (an empty branch reads the newest local branch). A lane with no slug is
   judged as before. No list of ids is kept anywhere.

   SPL-2916: a result whose first non-blank line is an R7 review line,
   `review: <id>[@<box>] [<vendor>] PASS|FAIL ...` (the format
   `do_spl_review_line_check` reads), is also `seat`, whatever the slug: it
   names the reviewed branch sha, never a landing. A rotated reviewer seat
   carries the slug `<id>-rotate`, which marks nothing; on sat's 24 h dry run
   (10-22, empty ledger) this rule moved 9 results of m-766, m-767 and m-776
   from `landed` to `seat` (114 landed, 10 seat, 17 alerts before; 105, 19,
   17 after). An R7 line below a landing claim is no exception.
2. **Verdict `pending`** (no note, no ledger, judged again on the next run)
   when every missing sha is on a remote branch `origin/<id>-...`,
   `origin/review/<id>-...` or `origin/wip/<id>-...` (`git branch -r
   --contains`) of a lane still in this box's `registry.tsv`: a plan lane
   waiting for a go. Once that lane is retired the sha alerts as before. A
   lane of another box is not in this box's registry, so its branch does not
   hold a sha back. The lane map is not read: it exits 4 whenever a lane
   recorded no files.

### 1.2 A sha that is no object in any repository (SPL-2327)

A lane that rebased in its own tree reports its pre-rebase sha; that object
never reaches this box, so `git cherry` cannot match it (c-297's dry run,
msg 6be2504d: 7 of 26 would-alerts, e.g. c-298's b9a10361 landed as
41b89d255). When every missing sha of a result is no object in any repo
(`git cat-file -e`), the check looks for its landing by the issue key:

- **Verdict `rewritten`** (ledger, no note, counted apart in the OK line)
  when EXACTLY one trunk commit carries an `SPL-<n>` key of the result body
  in its subject (`SPL-9001` does not match `SPL-90011`), committed at or
  after the lane's spawn (`registry.tsv` column 5), else within the last
  48 h.
- Zero or several such commits: the note as before, the sha marked "not an
  object in any repository (a pre-rebase sha?)". A sha that IS an object
  but on no trunk (an unpushed commit) keeps "not in the repository".

Not covered (report only): a sha that exists here but whose work landed
under a rewritten patch (`git cherry` `+`, a different patch-id).

### 1.3 The lane's own repository (SPL-2930)

A lane that lands outside csi-spl alerted "not in the repository" (c-001
msgs 6e7246a7 + 0bf0a44f, 2026-10-22, on the second box: c-179's sha
a486355b0 was an ancestor of that repo's `origin/master`; c-189 lands in its
own customer repo). The check read only the tree holding it plus cnf
`env.box.landed_repos`.

- The repos read for a result also include the sender lane's OWN repo:
  its worktree from `registry.tsv` (column 4), else its newest
  `workdirs.tsv` worktree row that still exists, then
  `git rev-parse --git-common-dir`. A repo already read (same common dir,
  e.g. a csi-spl worktree) is not read twice. No cnf list to keep, and no
  repo name in this tree.
- Its fetch runs with no terminal prompt and a 60 s limit. When it fails (an
  https origin with no credential), the sha is judged on that repo's last
  fetched trunk: the printed row gets a fifth column "own repo <dir> not
  fetched, judged on its last fetched origin/master", and an alert note a
  line saying so. The sha is an object there, so it is never "not an
  object in any repository".
- A lane whose worktree is gone (swept after 24 h) is judged as before.

### 1.4 A sha on a review branch (SPL-3673)

Three false alarms of one class on SPL-3481 (alarms 166d17f7, c4933166,
bb60fd55): c-271's results 68039e73 ("on a review branch, not on master",
9286598f6), 0195b188 (a80eb4de5) and 8dd71e81 (8cf3fef52) read "not in the
repository", while `git branch -r --contains 8cf3fef52` ->
`origin/review/grok-dispatch-grade`. The lane was no longer in the registry,
so the `pending` rule of section 1.1 did not hold them.

- A sha on no trunk that `git branch -r --contains` finds on an
  `origin/review/*` branch is reported as "on review branch <name>, not on
  master" (the repo's trunk name), in the printed row and in a note, never
  as "not in the repository".
- **Verdict `review`** (ledger, no note, counted apart in the OK line) when
  every such sha of the result is on one AND the body says it is not landed:
  "not (yet) on|in master|main|trunk", "not (yet) landed", "unlanded" or
  "on a|the review branch". A bare "review" is not one: a "review request"
  names no state, and still alerts once its lane is retired.
- A result that claims the review-branch sha landed alerts, with that
  wording. A sha on no branch at all alerts exactly as before.

### 1.5 Box-local clones and patch-ids (SPL-4085)

- **Box-local clones.** A clone that no list names was never read (alert
  9c8aa4c2, n=1: a lane on a csi-spl worktree committed, by its brief, on a
  work branch of a box-local customer clone marked
  `spool.landedOnAnyBranch`). The box-local file
  `$SPOOL_ROOT/done-claim-local-repos.txt` (`DONE_CLAIM_LOCAL_REPOS`), one
  absolute path per line, `#` a comment, lists such clones; a listed clone
  is read for every message when it sets `spool.landedOnAnyBranch` or
  `spool.localTrunk`, else it is skipped with a WARN. It is read as it is,
  never fetched. The list lives on the box, never in git: this repo names no
  customer repo or path. Neither the lane's brief nor its workdir names the
  clone, so neither could be the source.
- **Patch-ids** (c-002 msg 60b5dc28, n=3 on 2026-10-28: c-441, c-522,
  c-533). A hex token that is no object in any repo is no sha when it
  stands after a `patch-id` / `patch-ids` label on its line, or in a
  markdown table column headed `patch-id`. Those tokens had kept two live
  lanes' review requests from being `pending` (section 1.1).
- **Amended shas.** A sha on no branch whose `git patch-id --stable` equals
  that of a parked or review-branch sha of the same message (the sha before
  an amend of the message only) goes with it: `pending`, or on the review
  branch "(same patch as <sha>)".

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
sha alerts. SPL-2838: a detached-HEAD reviewer, live or retired with an
empty branch, is `seat` by its spawn branch; a detached code lane and a
detached one with no branch alert. SPL-2916: a recycled id is judged by its
latest slug (a live reviewer worktree, on a branch or detached, or the newest
retired reviewer row beats an older code slug), a first-line R7 review line
is `seat` from a lane with no slug, and a newest code slug still alerts. SPL-2327: a no-object sha is `rewritten` with one trunk commit
of its key after the spawn, alerts with none, with two, with one older than
48 h or older than the lane's spawn. SPL-2332: md5 tokens are no shas.
SPL-2953: run-on-box request ids (`gr-cmd-<hex>`, `.zip`, a labelled one) beside
a landed sha are no shas: landed.
SPL-2338: a landed sha on the sha line plus a quoted unknown sha on another
line is landed; an unlanded sha on the sha line alerts though a landed sha
is quoted elsewhere; `sha: none` and a body with no sha line read every sha.
SPL-2930: a sha on the trunk of the lane's own repo (a clone of a repo that is
neither csi-spl nor in `landed_repos`) alerts with the worktree unknown (red
control) and is landed once `registry.tsv` names it; a retired lane's repo
whose fetch fails is judged on its last fetched trunk (pushed sha landed,
unpushed sha one "not in the repository" note, never "not an object").
SPL-3673: a retired lane's sha on `origin/review/grok-dispatch-grade` with
"not on master" or "not landed" is `review`, no note (red on the code before:
both would alert); the same sha claimed landed alerts "on review branch
origin/review/grok-dispatch-grade, not on master"; a sha on no branch with
"not on master" alerts "not in the repository".
