# Bug round 12 - mistral panel seat verdict

Reviewer: m-075@sat (mistral; docs and reviews only, no code written)
Plan reviewed: `csi-spl-doc/doc/md/bug-round-12-plan.md` at commit
`3e5695cfff63d78257da451b9c2159b9b78394c7` (v0.3) on branch
`review/c002-bug-round-12-planner`. Line numbers below are lines of that file
at that sha.

Sha provenance: `git fetch origin review/c002-bug-round-12-planner && git
rev-parse FETCH_HEAD` -> `3e5695cfff63d78257da451b9c2159b9b78394c7`;
`git ls-remote origin review/c002-bug-round-12-planner` -> the same sha. On
task `dispatch-8b6cf04c`, c-210's message from the planner's box (fwd
verbatim by c-002@sat 15:23:29Z) names it: "Bug round 12 plan v0.3 ... Sha
3e5695cfff63d78257da451b9c2159b9b78394c7 on review/c002-bug-round-12-planner.
This is the sha for the panel seat (ask c5e4eef4) to sign." v0.2
`0f4a9c567689b3a2ec7758757ed6019020ac5056` is superseded.

## Verdict: PASS (objections W1, W2 to fold into v1.0 before row spawning, rulebook 3.2)

Signed sha: `3e5695cfff63d78257da451b9c2159b9b78394c7`

## Checks (each with the command run and what it printed)

### 1. Slug b12 unused

- `git log origin/master --oneline -E --grep='\(b12-' | wc -l` -> `0`
- `git log origin/master -E --grep='\bb12-[0-9]{2}-' --oneline | wc -l` -> `0`
- `git ls-remote origin 'refs/heads/*b12-*'` -> exactly one branch:
  `39cd5b98cfd7e302beedf55381bb8e1ad71a37b1 refs/heads/review/c-019-s160-b12-wui-globs`
  — spec 160 row B-12's branch, name form `s160-b12-wui-globs`, not this
  round's `b12-NN-` slug form. **I agree it does not collide.**
- `git ls-remote origin | grep -E 'b12-[0-9]{2}|bug-round-12'` -> only
  `review/c002-bug-round-12-planner` (the planner's own branch; the plan's
  14:5xZ "empty" was measured before it existed — see N2).

### 2. Row sites exist at `e9748a03d` and on origin/master

`e9748a03d` exists: `git log -1 --format='%H %cI %s' e9748a03d` ->
`e9748a03d296322b6fc101c50a8c2e493bef24c3 2026-11-17T16:46:59+02:00 fix(wui,
SPL-5706): ...` (14:46:59Z, as the plan says). origin/master is now
`69bf1936910b9eaa77fd9d14fb2f061e385ebee4`.

Every cited site checked with `git show <sha>:<file> | sed -n <N>p` at BOTH
`e9748a03d` and `origin/master`; all identical, none drifted:

- row 01: `spl-review-go.func.sh:653` = `# _spl_review_go_owner_go ...`;
  `:662` = the `b=`/`a=` boundary classes; `:665-666` = the two greps;
  `spl-review-go.tst.sh:1017` = the section-27 case with `` `x/billing` ``,
  `:1020` = `pass "27. ... -> GO"`.
- row 02: `tf-apply.func.sh:28-30`, `tf-apply-target.func.sh:53-54`,
  `tf-destroy.func.sh:28-31`, `tf-destroy-target.func.sh:22,24,43-44`,
  `tf-destroy-local-step-bucket.func.sh:17,19,59-61` all show the
  `terraform ... | do_tf_log_mask | tee -a` calls; `grep -c -- '-input=false'`
  in each of the five files -> `0` at both shas (matches the plan's evidence);
  `tf-log-mask-billing-id.tst.sh` exists (`git cat-file -t` -> `blob`).
- row 03: `spl-archived-followup.func.sh:200` = `spl_afu_inherit() {`, `:215`
  `}`, `:227-230` = `spl_afu_final_refusal`, `:232-243` =
  `spl_afu_inherit_failed`, `:245-268` = `spl_afu_pending`;
  `spl-archived-followup.tst.sh:405-414` = cases 14j/14e.
- row 04: `spl-agent-steps-log.func.sh:59` = `spl_agent_steps_log_one`,
  `:63` = the `FATAL agent-steps-log: $id: no claude session jsonl` line,
  `:66` = `return "${PIPESTATUS[0]}"`; `agent-steps-log-cron.sh:37-41` (the
  `WARN do_spl_agent_steps_log rc=$rc` at `:41`);
  `spl-agent-steps-log.tst.sh:142` asserts `rc == 3` today;
  `csi-spl-cnf/csi-spl/all.env.yaml:1286` = `- id: agent-c-141`, `:1289` =
  the `agent-logs/c-141.steps.log` path.

Stronger than the plan's own drift claim:
`git diff --stat e9748a03d origin/master -- <all 17 row files>` -> empty.
`git log 770de68f4..origin/master --oneline --
csi-spl-orc/src/bash/run/spl-review-go.func.sh | wc -l` -> `0` (row 01
evidence 3 holds). r60-05 wait: `git show
origin/master:csi-spl-doc/doc/md/refactor-round-34-plan.md | grep -n
spl-agent-steps-log` -> line 124 names `orc:run/spl-agent-steps-log.func.sh:22,49`
in row 05, batch 2.

### 3. Row hygiene (read from the table at the signed sha)

- Each of the 4 rows has a red control with command and expected output on
  `e9748a03d` (section 3.2, lines 74-77: rows 01, 02, 03, 04 all present) and a
  counting test: row 01 `spl-review-go.tst.sh` section 27; row 02 the
  `tf-log-mask-billing-id.tst.sh` `run_action` harness (or a new
  `tf-apply-no-input.tst.sh`); row 03 `spl-archived-followup.tst.sh` cases
  14j/14e; row 04 `spl-agent-steps-log.tst.sh:142` rewritten.
- Vendor `claude` and kind `simple_coding` on all 4 rows; batch 1 (section 7
  counts: rows 4, vendor claude 4, box sat 4, batches 1).
- File sets of the batch-1 rows as listed (lines 56-59) are disjoint, except
  the disclosed spec.md overlap — see W2.
- No mistral coding or testing rows: the R7 column is "a codex seat
  (cross-vendor); grok instead if `BOX_PICK_KIND=grok` picks a box at row
  time; else the claude waiver seat" — never mistral.

### 4. One red control re-run (row 01, read-only, no prd write, no terraform)

`git show e9748a03d:csi-spl-orc/src/bash/run/spl-review-go.func.sh` sourced
from a temp dir; then for each phrase
`printf '# b\n\n## Do\n\n1. %s\n' "$phrase" > b.md` +
`bash -c 'do_log(){ :; }; source <file>; SPOOL_ROOT=/nonexistent
_spl_review_go_owner_go b.md c-002'`:

- `This is an IAM/billing change.` -> `rc=0`, no output
- `Run plan/apply on prd for step 016.` -> `rc=0`, no output
- `` Names only: `x/billing`, `apply.sh`. `` -> `rc=0`, no output

**Reproduces** the plan's claimed output on `e9748a03d` exactly (lines 48, 74):
the `/`-joined prose hides the keyword (the bug), the backticked names stay
names.

### 5. Section 2 source re-run (source 3, read-only)

`for s in d0137722c e9748a03d; do for d in csi-spl-api csi-spl-wui csi-spl-orc
csi-spl-iac csi-spl-utl; do echo -n "$s $d: "; git grep -n -E
"(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)" $s -- "$d" | wc -l; done; done` ->
`api 197, wui 17, orc 10, iac 21, utl 0` on BOTH shas — **agrees** with the
plan's source-3 row. `git show e9748a03d:csi-spl-wui/tests/e2e/ci-skip.txt |
wc -l` -> `8` lines, `grep -vc '^#'` -> `4` entries — agrees ("4 entries").
See N1 for the printed `\|` form.

### 6. R3 lane-map

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh
--check <the 17 row paths + the plan file, comma-separated> --agent m-075` ->
**exit 4**: no live lane records any of the paths (no exit 3); 15 live lanes
record no files and are unknown scope, ask first: c-054, c-060, c-192, c-202,
c-210, c-382, c-390, c-528, c-545, c-570, c-669, c-714, c-888, c-924, c-927
(all on the planner's box; c-210 is the planner). Same for my own seat file path
(`--check csi-spl-doc/doc/md/bug-round-12/seat-mistral.md --agent m-075` ->
exit 4, same list). Per R3 the holder re-runs this before each spawn and asks
an exit-4 lane first.

### 7. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of
/opt/csi/csi-spl-wt/m-075`, exit 0.

## Defects

- **W1** (plan line 44): the section header reads `## 3. The 3 rows` but the
  table holds 4 rows (01-04) and the title says "(4 rows)". Cosmetic; fold
  into v1.0.
- **W2** (plan line 60): row 01 and row 03 may both touch
  `csi-spl-doc/specs/157-dispatch-automation/spec.md` inside batch 1, and the
  plan serialises that within the batch by rebase. Rulebook R1
  (`rounds-rulebook.md` 2.1) says shared files are serialised ACROSS batches
  ("Batch 1, then Batch 2 after Batch 1 lands"), and "no file path may appear
  in two actions of the same batch". The listed file sets (lines 56-59) are
  disjoint, so this is conditional on both rows choosing the spec.md doc
  edit. Recommend the editor pin one row to `Docs: none (<why>)` or move its
  spec.md edit to a later batch at v1.0.

## Notes

- **N1**: the plan's source-3 command is printed with `\|` (markdown table
  escaping). Run as printed under `-E`, `git grep -n -E
  "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)"` prints `0` for every
  module; with plain `|` (check 5 above) the counts reproduce exactly. The
  measurement is right; only the printed form is escaped.
- **N2**: `git ls-remote origin | grep bug-round-12` now matches the planner's
  own `review/c002-bug-round-12-planner`; the plan's 14:5xZ "empty" predates
  it. No collision with the `b12-NN-` slug form (check 1).
- **N3**: lane-map exit 4 lists 15 no-file lanes, up from the 8 the plan
  recorded at 14:58:21Z; none owns a row file.
- **N4**: origin/master moved to `69bf19369` since the plan's `c7ee2effd`;
  `git diff --stat e9748a03d origin/master` over all row files is empty, so
  the sites and red controls hold on current master.
- **N5**: not re-run by me (outside checks 1-7): the section-2 sources 1, 2, 4,
  5 (prd SQL, CI gate report, box cron logs) and the section-8 lane-mix state
  (agy paused, grok 99%). They are the planner's measurements, marked as such
  in the plan.

## v1.0 delta sign-off (second signature)

Signed sha: `3f1261a8afb7c650f105e58f52726b526122ef26` (v1.0) on branch
`review/c002-bug-round-12-planner`. Named as the v1.0 head on task
`dispatch-8b6cf04c` (holder c-002@sat, quoting c-210's msg d38ff955) and as
the branch head by `git ls-remote`.

Delta checked, only `3e5695cff..3f1261a8a`:

- `git fetch origin review/c002-bug-round-12-planner && git rev-parse FETCH_HEAD`
  -> `3f1261a8afb7c650f105e58f52726b526122ef26`;
  `git ls-remote origin review/c002-bug-round-12-planner` -> the same sha.
- `git log --oneline 3e5695cff..3f1261a8a` -> one commit:
  `3f1261a8a docs(b12-plan, SPL-5806): bug round 12 plan v1.0, panel PASS folds W1 W2 N1 N4`.
- `git diff --stat 3e5695cff 3f1261a8a` -> `1 file changed, 10 insertions(+),
  7 deletions(-)`: only `csi-spl-doc/doc/md/bug-round-12-plan.md`.
- `git diff 3e5695cff 3f1261a8a -- csi-spl-doc/doc/md/bug-round-12-plan.md`
  hunks: status line v0.3 -> v1.0; the N1 note under the section 2 table
  (`\|` is the markdown escape of `|`); `## 3. The 3 rows` -> `## 3. The 4 rows`
  (W1 closed); row 03's fix-scope cell now carries `Docs: none (the bound is
  documented in the action header)` and section 3.1 pins
  `csi-spl-doc/specs/157-dispatch-automation/spec.md` to row 01 alone, batch 1
  disjoint with no condition (W2 closed); review-history and consensus-table
  entries. No hunk touches any row's defect, sites, red control (section 3.2)
  or the rows 01/02/04 cells.

Verdict on `3f1261a8afb7c650f105e58f52726b526122ef26`: **PASS**.
