# Bug round 45 — panel seat mistral (m-228@<box>)

Issue: SPL-6416 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/dispatch/briefs/c002-bug-round-45-mistral-panel-seat.md`.
Review target: `csi-spl-doc/doc/md/bug-round-45-plan.md` on branch
`review/c002-bug-round-45-planner`, at the plan version sha
`5148267759d5dc04140d072fb98749afc11c4899` (v0.1), named by the brief (planner
c-025@<box2>). `git ls-remote origin refs/heads/review/c002-bug-round-45-planner`
-> exactly that sha, still the branch head at my check (2026-11-24T20:0xZ); the
branch is one docs commit (`+207`) on `ab45997fa`. The plan was measured on
`d9030330e`; `origin/master` at my fetch is `93b03457a` (the head moved past the
`ab45997fa` the brief names), so per the brief I review only the planner-named
sha. The three row files are unchanged from the measurement sha to the current
head: `git diff --stat d9030330e origin/master -- csi-spl-orc/src/bash/run/spl-review-go.func.sh csi-spl-orc/src/bash/tests/spl-review-go.tst.sh csi-spl-doc/specs/157-dispatch-automation/spec.md`
-> empty.
Rules: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5 (3.2: this
seat reviews the plan only and writes no code). Form:
`csi-spl-doc/doc/md/bug-round-44-plan.md` on origin/master. Every file:line below
was printed with `git show d9030330e:<file> | sed -n <N>p` before it is cited;
every command below was run by me on this box, 2026-11-24 19:5xZ..20:0xZ.

**Verdict: PASS, 1 row, on `5148267759d5dc04140d072fb98749afc11c4899` (v0.1).**
No defect W. Notes N1..N5 below.

## Check 1 — slug b45 unused since the plan's W

The plan records `Window: W=2026-11-24T11:46:36+02:00` (commit `4577630c5`).
Re-reading `git log origin/master -1 --format=%cI -E --grep='^docs\(b44-plan'`
now gives `2ec8927ba` at `2026-11-24T20:20:31+01:00` (the round-44 close record);
per rulebook 5.3 the planner reads W once, so the recorded W stays — the plan
handled this correctly and says so.

- `git log origin/master --since="2026-11-24T11:46:36+02:00" --oneline -E --grep='\(b45-' | wc -l`
  -> `0` (re-run on current master `93b03457a`, 93 commits since W).
- `git ls-remote origin | grep -E 'b45-[0-9]{2}|bug-round-45'` ->
  `5148267759d5dc04140d072fb98749afc11c4899\trefs/heads/review/c002-bug-round-45-planner`
  only — the planner's branch, expected; this seat's review branch did not exist
  yet at this check. Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b45-[0-9]{2}|bug-round-45'` ->
  `c002-bug-round-45-mistral-panel-seat.md` and `c002-bug-round-45-planner.md` —
  this brief and the planner's, both expected.

## Check 2 — the defect is real on `d9030330e` (every cited file:line printed)

- `csi-spl-orc/src/bash/run/spl-review-go.func.sh:59` ->
  `# @description       or a prohibition `no [w [w [w]]] apply`, b44-01;` — matches.
- `:626-628` -> the comment naming the prohibition forms (`no` and up to three
  words, none of them and / then / but / so, before `apply`) — matches.
- `:675` ->
  `neg = r"(?i)\b(?:(?:(?:does|do|did|will|would|should|shall|may|might|can|could|must)\s+not|doesn't|don't|didn't|won't|cannot|can't|never)\s+|no(?:[^\S\n]+(?!(?:and|then|but|so)\b)\w[\w-]*){0,3}[^\S\n]+)apply\b"`
  — the `no ... {0,3} ... apply` branch is there — matches.
- `:677` -> `print(re.sub(neg, "", "\n".join(out)))` — the removal site — matches.
- `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh:1171` -> the case-29 header
  (`# --- 29. a prohibition in a step is no instruction (b44-01) ---`);
  `:1189` -> `done` (case 29's end, so a new case 30 goes after it) — matches.
- `csi-spl-doc/specs/157-dispatch-automation/spec.md:259` -> names the negated
  forms including the b44-01 prohibition — matches.
- `git diff --stat 92caf63c2 d9030330e -- <the three files>` -> empty, as the plan
  claims; `git diff --stat d9030330e origin/master -- <the three files>` -> empty
  too, so the defect is still present at the current head.
- b44-01 re-read: `git show 14b6055c2 -- csi-spl-orc/src/bash/run/spl-review-go.func.sh`
  shows exactly the plan's account — the old `neg` (only `<aux> not apply` /
  `never apply` forms) replaced by the new one adding the
  `no(?:[^\S\n]+(?!(?:and|then|but|so)\b)\w[\w-]*){0,3}[^\S\n]+` branch, plus the
  `:59` and `:626-628` comment updates. The regression account is right: "If no
  errors apply the migration to prd." matches `no errors apply` and is stripped at
  `:677`, so rule [4] sees no keyword and answers GO with no `Owner-go:` line
  (fail-open).
- g-750's N2 is in `14b6055c2`'s body (`git show 14b6055c2 --format=%B -s | grep -n '^review:'`
  -> line 43): "N2 unpunctuated fixture \"if no errors apply\" strips helper rc 0
  at spl-review-go.func.sh:675; punctuated \"if no errors, apply\" holds; none of
  the 7 freed is that form" — matches the plan's quote.
- The "0 of 650" recount: on this box at 20:0xZ,
  `ls /var/spool-hub/dispatch/briefs | wc -l` -> `6972`,
  `ls /var/spool-hub/spawn-remote/briefs | wc -l` -> `199` (7171 files total),
  `grep -lis '\bapply\b' /var/spool-hub/dispatch/briefs/* /var/spool-hub/spawn-remote/briefs/* | wc -l`
  -> `628` (the plan's 6747/650 was the other box's corpus at 19:25Z; different
  corpus, same shape). Sample n=8 briefs with `apply`, each read by me
  (`grep -n '\bapply\b' <brief>` printed) and run through `_spl_review_go_instr`
  on the `d9030330e` copy and on the fix-shape copy; `apply`-keyword count in the
  instruction text, tree vs fix: `availability-plan.md` 1=1,
  `c002-r11-08-wui-small-store-notification.md` 0=0,
  `c002-spl4495-cron-no-stack-claude-waiver-reviewer.md` 0=0, `069-Y7.md` 1=1,
  `20261011-c001-wine-testbox` 2=2, `c001-r11-09-bash-small-tf-init.md` 0=0,
  `c001-bug-make-replace-statepush-dry-run.md` 0=0,
  `20261009-csi-rel-tahan-no-organic.md` 3=3 — 0 of 8 differ, consistent with the
  plan's "0 briefs differ".

## Check 3 — red control `rc01-b45.sh`

Extracted from plan section 4.1 (awk between the ` ```bash ` fence and its close):
`wc -c` -> `2674` (the plan's 2674 B), `sha256sum` ->
`cc6ed6fecc0aa734d57aa94d96db773a18e34317faafc3e6b8f48f6e63e7bafb` — first 12 hex
`cc6ed6fecc0a`, matches the plan. Runs from this worktree:

- `bash rc01-b45.sh d9030330e` ->
  `rc01 'If no errors apply the migration' -> rc 0 (want 1); 'no drift apply step 053' -> rc 0 (want 1); 'no terraform apply' -> rc 0 (want 0); 'NO terraform plan or apply' -> rc 0 (want 0)`
  / `rc01 exit 1`, exit=1 — the defect reproduces.
- `bash rc01-b45.sh d9030330e fix-shape` ->
  `rc01 fix-shape: a 'no ... apply' after a condition word in the same clause stays a keyword`
  / `rc01 ... -> rc 1 (want 1); ... -> rc 1 (want 1); ... -> rc 0 (want 0); ... -> rc 0 (want 0)`
  / `rc01 exit 0`, exit=0 — the control turns green.
- `bash rc01-b45.sh 14b6055c2^` -> rc 1, 1, 1, 1 / `rc01 exit 1`, exit=1 — the
  regression's parent holds both the conditionals and b44-01's prohibitions, so
  the row keeps b44-01's gain.

All three match the plan's output table. Live state: the script writes only under
`mktemp -d` (trap `rm -rf`), reads the tree with `git show`, and runs the copied
func with `SPOOL_ROOT`/`SPL_STATE_DIR` pointed at that tmp dir;
`_spl_review_go_owner_go` only globs/reads under those dirs and echoes — no hub,
prd, GitHub, spool or checkout write, no network. It touches no live state.
Suite: `bash csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` ->
`spl-review-go: 0 failure(s)` (97 PASS, 0 FAIL lines);
`REVIEW_GO_FUNC=<the fix-shape copy> bash csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`
-> `spl-review-go: 0 failure(s)` (94 PASS, 0 FAIL) — green both ways, as the plan
claims.

## Check 4 — the row

Scope is narrow: one action file (`spl-review-go.func.sh`, the `no` branch of
`neg` at `:675`, applied at `:677`, its comment `:626-628`, the `@description`
`:59`), its test (a new case 30 after `:1189`), one spec line (`spec.md:259`).
The red control proves the defect (exit 1 on `d9030330e`) and turns green on the
fix shape (exit 0), and the gates are named (test column: the review-go suite,
`rc01-b45.sh` on the fix sha, the brief count re-run). The fix shape keeps BOTH
b44-01's prohibitions negated AND the true positives held — probed directly with
`_spl_review_go_owner_go` on the `d9030330e` copy and the fix-shape copy:
"Then apply the migration to prd." -> rc 1 on both; "If no errors, apply the
migration to prd." -> rc 1 on both; "If no errors apply the migration to prd." ->
rc 0 on the tree, rc 1 on the fix shape; rc01's `no terraform apply` /
`NO terraform plan or apply` -> rc 0 on both. Keep, not cut or split: rulebook
5.1 aims at 2 rows and caps at 3, and 5.2 says a planner never waits to collect
more rows — 1 row is a round; one candidate met the bar (plan section 3), so 1
row is justified by the inputs.

## Check 5 — inputs accounted for

The plan's 10 sources (section 2) are each named with a command and a count.
Round 44's first inputs (bug-round-44-plan.md section 7 on origin/master: the
non-instruction `apply`, the topic loop cap race, the store tests' fresh-DB need,
the `unknown_token` box, the hub dir mode, the hermetic 2/4 timeout, the composed
testids, plus the carried N2s) are re-read one by one in the plan's section 3.4 —
all accounted for. The holder's candidate list (section 3.5: 0 new bug items at
its 19:4xZ read, 134 lines) — my read now: `wc -l
/var/spool-hub/dispatch/c002-next-round-candidates.md` -> `139`; the new lines
133-139 are the refactor-97 item (r96-01 N1), the perf-19 heap note, and one
bug-shaped item at line 139 (2026-11-24 20:0xZ, c-003@<box>: the release-transfer
tool SPL-6361 `zip_dirs` offers `proj.zip` AND `proj.<UTC>.zip` byte-identical for a repeated
drop, reproduced by c-945@<box2> on `a0cbed9`, "Not yet placed") — added after
the plan's 19:4xZ read, so the plan neither serves nor accounts for it; it is a
round-46 input, not a plan defect (N2). The `PUT /v1/me/hours/minutes` 400s are
carried to round 46 with a first step (the hub logs the `bad_minutes` detail on a
400); the cited lines verify on `d9030330e`: `hours_me.go:33`
(`hoursMinuteSkew = 2 * time.Minute`), `:541` (the skew check), `:560-563` (the
whole-batch refusal on `bad != ""`), `hours-recorder.mjs:121`
(`if (e && e.status) return` — the refused batch dropped as final), `:127`
(`function hoursTick(st)`). Judgement: carrying is right — n=4, the cause read
from a response byte count only, the member unnamed; not row-grade yet, and the
named first step is the correct next measurement.

## Check 6 — R3 lane map

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-doc/doc/md/bug-round-45-plan.md,csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh --agent m-228`
-> exit 4: no live lane lists these paths, but 25 live lanes record no files
(`unknown:` c-005, c-010, c-018, c-025 (the planner), c-026, c-029, c-041, c-086,
c-146, c-187, c-721, c-728, c-774, c-916, c-927, c-935, c-936, c-945, c-957,
c-960, c-965, c-975, c-978, c-988, c-998, all @<box2>) — not free until those are
asked or the holder re-runs `--check` at placement, the same verdict the planner's
own R3 recorded.

## Check 7 — distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-228`,
exit 0.

## Notes

- N1: the brief corpus counts differ by box and time (plan: 6747 briefs / 650 with
  `apply` on the planner's box at 19:25Z; this box at 20:0xZ: 7171 files / 628);
  the sample of 8 I read myself shows 0 differences tree vs fix shape, so the
  "harm today: latent" claim holds on my sample.
- N2: the holder's candidate list grew after the plan's read (134 -> 139 lines);
  the one new bug-shaped item (line 139, SPL-6361 `zip_dirs` duplicate zip,
  reproduced, not yet placed) is a round-46 input the plan could not have seen.
- N3: `origin/master` moved since the brief (`ab45997fa` -> `93b03457a`); the
  three row files are unchanged `d9030330e..origin/master`, so the defect and the
  red control still apply at the current head; I reviewed the planner-named sha
  `5148267759d5dc04140d072fb98749afc11c4899` as the brief requires.
- N4: lane-map exit 4 (25 `unknown:` lanes) matches the planner's own R3; the
  paths are not free until the holder re-runs `--check` at placement.
- N5: the hours-minutes 400 carry is judged correct (n=4, cause from a byte count
  only); its cited hub and WUI lines all match on `d9030330e`.

## Signed v1.0 — `9f3c8a72eb1e7fff09485eacb4d6e8d44049fa32`

The editor's v1.0 landed on `origin/master` (the dispatch holder's ACCEPTED,
msg `c3fb6695`, 2026-11-24T20:19:11Z, names it). Verified by me at 20:2xZ:

- `git fetch origin master && git merge-base --is-ancestor 9f3c8a72eb1e7fff09485eacb4d6e8d44049fa32 origin/master`
  -> rc 0; `git log -1 --format='%H %s' origin/master` ->
  `9f3c8a72eb1e7fff09485eacb4d6e8d44049fa32 docs(b45-plan, SPL-6416): bug round 45 plan v1.0, panel m-228 PASS on v0.1 folded, 1 row unchanged`.
- The v1.0 commit's own diff touches only the plan file: my PASS is folded into
  its section 8 review history and N2 into section 7's round-46 inputs; the row
  table is unchanged (`git diff 5148267759 9f3c8a72e -- csi-spl-doc/doc/md/bug-round-45-plan.md`
  adds no row line; the row at v1.0 `:167` is byte-identical to v0.1's).
- The measurement sha is still `d9030330e` (v1.0 plan `:18` says so and records
  the v1.0 re-measure); `git diff --stat d9030330e 9f3c8a72e -- <the three row files>`
  -> empty, so every site and the red control hold at the v1.0 head.
- Red control re-run at signing: `bash rc01-b45.sh d9030330e` -> `rc01 exit 1`;
  `bash rc01-b45.sh d9030330e fix-shape` -> `rc01 exit 0`.

**Verdict on v1.0 `9f3c8a72eb1e7fff09485eacb4d6e8d44049fa32`: PASS, unchanged —
1 row, no W.** The fold changed no row, no site and no control.
