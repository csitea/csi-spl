# Spec review SPL-5884, re-review — mistral verdict on `bb3cc8d4`

- Reviewer: m-534, placement `c002-spl5884-spec-mistral-reviewer`, issue SPL-5884.
  Second commit on the seat branch, per the dispatch holder's task on
  `dispatch-spl5884` (msg `c47bd3cd`): re-review the author's fixed head.
- Reviewed sha: `bb3cc8d4f097446e3be3e949f3b2803f623a3b07`, branch
  `review/c002-spl5884-message-kinds-seven-spec`, fast-forward over `94e046bbf`,
  base still `405fe0885`. `git fetch origin review/c002-spl5884-message-kinds-seven-spec`
  then `git rev-parse FETCH_HEAD` printed `bb3cc8d4f097446e3be3e949f3b2803f623a3b07`;
  `git log --oneline -2 FETCH_HEAD` printed `bb3cc8d4f docs(spec-033, SPL-5884): section K, review fixes W1 W2 N1 N2 N5`
  on `94e046bbf`; `git diff --stat 94e046bb bb3cc8d4` printed
  `csi-spl-doc/specs/033-spool-message-levels/spec.md | 40 ++++... 1 file changed, 29 insertions(+), 11 deletions(-)`.
- Section: lines 149-434, version 0.2.1
  (`git show bb3cc8d4:...spec.md | wc -l` -> 434; `grep -n '^## Message kinds: seven more\|version: 0.2'`
  -> 149 and 434). The spec still names `origin/master 405fe0885` as the cite
  base (lines 157-158), so all code cites below were re-checked at `405fe0885`
  with `git show 405fe0885:<file> | sed -n '<N>p'`.
- First review (FAIL on `94e046bbf`, W1-W3) is in
  `review-spl5884-mistral.md` on the same branch.

## Verdict: PASS on `bb3cc8d4f097446e3be3e949f3b2803f623a3b07`

W1, W2 and W3 are fixed and verified; my re-run of the kind-branch sweep over
all of `csi-spl-orc/src/bash` at `405fe0885` finds no message-kind site the
new K.3 tables miss that would treat a new kind differently from a note.

## W1 fixed: the two watchdog sites are in K.3 group 2 and T024

- New group-2 rows (spec lines 265-266):
  `orc/run/spl-watchdog.func.sh:1010` (`spl_wd_job_after`) and
  `orc/features/watchdog/situations/s1.sh:58` (`s1_jobs`).
- `git show 405fe0885:csi-spl-orc/src/bash/features/watchdog/situations/s1.sh | sed -n '56,61p'`
  printed `s1_jobs() { wd_has inbox || return 0; awk -v p=... -v me="$WD_ID" ... '
  $1 + 0 > p + 0 && $3 != "note" && $4 != me && !(box != "" && $4 == me "@" box)' "$WD_CTX/inbox" }` —
  line 58 is exactly "an inbox line that is not a `note` (and not the agent's
  own) is a job", as the row says. My first sweep covered only `run/`,
  `spawn-agents/scripts` and `spawn-agents/lib`, so it missed the `watchdog/`
  dir; the author's sweep over all of `csi-spl-orc/src/bash` caught it.
- `git show 405fe0885:.../spl-watchdog.func.sh | sed -n '1010p'` re-printed
  `.kind == "note" or ((.from // "") | sub("@.*"; "")) == $me` — the W1 site.
- T024 row (spec line 419) now reads "(d) `spool-notify-take.inc.sh:23`,
  `spl-review-go.func.sh:202`, `spl-watchdog.func.sh:1010` and
  `watchdog/situations/s1.sh:58` ..." — all four group-2 sites.
- The `SPOOL_NOTE_KINDS` semantics (spec lines 278-285): `note` + the 7; the
  two watchdog sites take it alone so `msg` stays a job there, as today
  (verified: at both sites today `msg` fails the `note` test, so it is a job).
  `spool-notify-take.inc.sh` keeps `task`/`msg`, `spl-review-go.func.sh` keeps
  `result` — both verified at their cited lines in the first review.
- Group 1 gained the note-like rows I had listed as missed:
  `spool-send.sh:231` (`.kind == "task"`), `spl-watchdog.func.sh:996`,
  `spl-lane-rotate.func.sh:963`, `spl-rotate-lib.func.sh:1844` (all
  `.kind == "result"`) — spec lines 257-258. Each re-verified at `405fe0885`.

## My re-run sweep (all of csi-spl-orc/src/bash, 405fe0885, tests/docs out)

`git grep -nE '\.kind ?(==|!=)|kind" ?(==|!=)|case "$kind"|get\("kind"\)|(==|!=) ?"?(task|note|blocker|result|reject|msg)"?\b' 405fe0885 -- csi-spl-orc/src/bash`
(plus the api sweep from the first review, unchanged). Every message-kind hit
is now in a K.3 table except two note-like rows that do not change a new kind's
behaviour (notes N1, N2 below): `spl-wd-orch-outcome.func.sh:119`
(`jq -r '.kind // empty' ... == task` — counts only `task`, a new kind is not
counted, same as a note) and `spl-peer-poll.func.sh:317` (rewrites
`.kind = "note"` on a DEAD delivery — a new kind is overwritten to note there
anyway). Both are group-1 in effect; listing them is cosmetic.

## W2 fixed: the MsgKind path

T025 (spec line 420) now cites `src/types/spool.ts:1`.
`git grep -n MsgKind 405fe0885 -- csi-spl-wui` ->
`csi-spl-wui/src/types/spool.ts:1: export type MsgKind = 'task' | 'result' | 'note' | 'reject' | 'blocker' | 'msg'`.
Path resolves under the spec's `wui/` root; line 1 matches.

## N1, N2, N5 fixed as claimed

- N1: T022 row (spec line 416) now says "the `is:` enum holds 14 values (the 13
  kinds plus `relay`)" — matches the tree: `git show 405fe0885:.../grammar.go | sed -n '181,182p'`
  printed the 7 current values incl. `relay`.
- N2: the colour bullet (spec lines 207-212) now states exactly what I measured:
  six of seven dark colours are `variables.css:420-446` hexes, `decision`
  `#2dd4bf`/`#0f766e` is new; on light, `feature`/`question`/`docs`/`alert`
  reuse `#3f51b5`/`#8e24aa`/`#616161`/`#f6bf26`, `bug` `#c43e00` and `idea`
  `#c2185b` are new darker values with a 3:1 contrast test in T025.
- N5: T021 row (spec line 415) now says "`msg_test.go:61`, which loops over the
  6 today, is widened to loop over all 13" — `git show 405fe0885:.../msg_test.go | sed -n '61p'`
  printed the 6-kind loop.

## W3 resolved

The section is 149-434 at `bb3cc8d4` (the dispatch holder's "149-434" is right);
the 149-415 vs 149-416 mismatch was only against the old head.

## Checks re-run on `bb3cc8d4`

- Checks 1, 3, 4, 5, 6, 7 from the first review are unchanged by the diff
  (`git diff 94e046bb bb3cc8d4` touches only the K.2 colour bullet, the K.3
  tables + "One list in orc" paragraph, the T021/T022/T024/T025 rows and the
  version comment); their cites were re-verified at `405fe0885` and hold.
- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` in a scratch worktree at
  `bb3cc8d4` -> `INFO distribution-hygiene: clean over the tracked tree`, exit 0.
- `cd csi-spl-orc && ./run -a do_check_fleet_rules_drift` in the same worktree
  -> `OK fleet rules: no drift over 9 pinned facts`, exit 0.

## Defects

None on `bb3cc8d4f097446e3be3e949f3b2803f623a3b07`.

## Notes

- N1: `spl-wd-orch-outcome.func.sh:119` and `spl-peer-poll.func.sh:317` are the
  only message-kind sites still unlisted in K.3; both are note-like for a new
  kind (see the sweep above), so no change is needed — listing them in group 1
  would be cosmetic.
- N2: origin/master has moved to `897e67e1` since the spec's base `405fe0885`;
  `git diff --stat 405fe0885 origin/master` over the cited api/wui/rdb dirs
  prints no file, so the cites hold on current master too.
- N3: the K.3 provenance note (spec lines 286-291) names the two sweep commands
  the author ran; I re-ran equivalent sweeps over all of `csi-spl-orc/src/bash`
  and `csi-spl-api` at `405fe0885` and got the same site set plus the two
  note-like rows of N1.

<!-- review by m-534, 2026-11-18, on bb3cc8d4f097446e3be3e949f3b2803f623a3b07 -->
