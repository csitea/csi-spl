# Bug round 53 plan - panel seat claude (c-749@<box2>)

Issue: SPL-6657  
Plan: `csi-spl-doc/doc/md/bug-round-53-plan.md` v0.1 at **`4c8cdbe9186f24b8c013b9aec22d0e25d23ebcfa`** (`git ls-remote origin refs/heads/review/c001-bug-round-53-planner` -> that sha, 2026-11-27 16:5xZ). Plan base `3308d118f`; `origin/master` = `3308d118f` at review time (`git rev-parse --short origin/master` after a fresh fetch).  
Seat: c-749@<box2>, claude, cross-vendor seat of rulebook 3.2 (the planner is agy). Read only the tree; n=1 per command unless stated.

## Verdict: **FAIL** on `4c8cdbe91`

One blocking defect (W1): row b53-01's fix scope narrows the `HUNK` target check from the line to the sentence, which turns two briefs that hold today into a false GO. The header the row keeps (`spl-review-go.func.sh:718-719`) says "a false hold to clear by hand, never a false go". The plan's own security control does not catch it. Rows b53-02 and b53-03 are sound; W2 and W3 are accounting fixes.

## Checks

### 1. Slug b53 unused since W

- `git log origin/master -1 --format='%cI %h' -E --grep='^docs\(b52-plan'` -> `2026-11-27T02:28:02+02:00 ce158c1fe` (matches the plan's `Window:`).
- `git log origin/master --since="2026-11-27T02:28:02+02:00" --oneline -E --grep='\(b53-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b53-[0-9]{2}|bug-round-53'` -> only `4c8cdbe9186f24b8c013b9aec22d0e25d23ebcfa refs/heads/review/c001-bug-round-53-planner` (this seat's branch is pushed after this file).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b53-[0-9]{2}|bug-round-53'` -> nothing on <box2> (this seat's brief lives under `spawn-remote/briefs/`; the planner's brief is on sat).

### 2. Sites exist on the base and on origin/master

- `git diff --name-only 3308d118f origin/master -- <the 5 row files> csi-spl-wui/src/utils/reporting-releases.ts | wc -l` -> `0` (origin/master is the base).
- Every cited line checked with `git show 3308d118f:<file> | sed -n <N>p`:
  - `spl-review-go.func.sh:723` `NARR = ...measured)\b")`, `:724` `NEVER = ...out of scope)\b")`, `:768` `DRY = ...`, `:771` `if HUNK.search(l) and not TGT.search(l):`, `:779` `ls[i] = l`, `:913` c4 `NARR` (already has `at (?:queue|brief) time|lane-map clearance`), `:914` c4 `NEVER = ...files you must not touch|must not touch|owned elsewhere)\b")`, `:935` `rc = re.match(r"rc(\d{2})(?:-([br]\d{2}))?", m)`, `:936` the `rc.group(2) in (None, own[0])` drop. `_spl_review_go_instr()` starts at `:720` and `_spl_review_go_c4_missing()` at `:900` (`grep -n '^_spl_review_go_[a-z0-9_]*()'`). All match the plan.
  - `spawn-remote.sh`: `reply_file()` `:222-231` (jq `.task_id` at `:227`, `body_of` at `:228`); `request()` `:152-211` (60 lines, `body_of "$f"` at `:201`); `read_msg_fields()` `:279-288`; `issue_reply()` `:467-478` (`reply_file` `:470`, `body_of` `:475`); `task_cancelled()` `:647`, `body_of` `:659`, `jq -r '.from'` `:662`. All match.
  - `releases-row-alternate.test.mjs:70-74` `measure()` / longest day / `data-alt-probe` 1..3; `:121-128` S3 toggle on `[data-alt-probe="2"]` with `else ok(... 'shaded row 2 has notes to open', false)`. `reporting-releases.ts:393` `const bare = j % 5 === 0`. The toggle is `v-if="hasTrailers(n)"` at `csi-spl-wui/src/components/reporting/ReleasesDailyList.vue:75-79` (the plan writes `ReleasesDailyList.vue:79` without its directory, see N5).
  - Test anchors: `spl-review-go.tst.sh` has 1522 lines, and case 36 runs to `:1519`. In `test-spawn-remote.sh` (490 lines), case 16 is the section at `:420` (`# ---- 16. a request acked mid-read ...`). The R2 test files all exist on `3308d118f` (`git cat-file -e`, 10/10 ok), as does `do_check_pre_push_e2e` with `WUI_E2E_RANGE` (`check-pre-push-e2e.func.sh:51,60`).

### 3. Red controls, run on the base in a scratch copy

I extracted each script from plan section 4 with awk. `sha256sum` first 12 hex and byte counts: `rc01-b53.sh 75a649275f67 8843 B`, `rc02-b53.sh 38e1b5d20e6e 10399 B`, `rc03-b53.sh 4aea04a9e42c 10659 B`, all equal to the plan. I ran them from this worktree as `bash <copy> 3308d118f [fix-shape]`:

| run | last lines | exit |
|---|---|---|
| `rc01-b53.sh 3308d118f` | 7 red probes `rc=1 (want 0)` / `red_n2_c4_non_br_rc_suffix: rc=0 (want 1) tok_ok=0`; 4 controls hold; `rc01 exit 1` | 1 |
| `rc01-b53.sh 3308d118f fix-shape` | all 7 probes at want; `ctrl_rdb_plus_prd_holds: rc=1 ... keyword 'ENV=prd'`; `rc01 exit 0` | 0 |
| `rc02-b53.sh 3308d118f` | `A(request_reply_ack_after_match): rc=4 (want 0) out=[spawn-remote: refused by home: ]` / `B(...): rc=4 ... FATAL refused by home: ` / C, D hold; `rc02 exit 1` | 1 |
| `rc02-b53.sh 3308d118f fix-shape` | `A: rc=0 out=[c-009@home %42]` / `B: rc=0 has_key=1` / C, D hold; `rc02 exit 0` | 0 |
| `rc03-b53.sh 3308d118f` | `rc03 24h UTC sweep: pass=20/24 fail_hours=[4,9,14,19]` / `rc03 exit 1` | 1 |
| `rc03-b53.sh 3308d118f fix-shape` | `pass=24/24 fail_hours=[]` / `rc03 exit 0` | 0 |

A second run (n=2) of each base gave exit 1 again. Each red fails for the plan's reason (the hold message names the keyword the defect leaks, the `refused by home: ` empty reason, the four hours), not for an environment reason. Live state: each script works only in its `mktemp -d`. After a third rc02 run, `find /var/spool-hub/c-001 /var/spool-hub/spawn-remote -newer <marker> -type f | wc -l` -> `0`, and `git status --short` showed only my untracked lane-state file.

### 4. Defects real, scope narrow

- **b53-01:** the five holds are real on `3308d118f`; rc01 shows them. N1 and N2 of `a-537` are real: `:914` lacks the three headings, and `:935` matches `rc01-p19.sh` as `rc01` with `group(2)=None`, so `:936` drops it. **But fix item 2 (sentence-local `TGT`) is not narrow enough: see W1.** Fix items 1, 3, 4 and 5 are narrow. In item 5, `\.sh$` is safe because `m` always comes from a `...\.sh` match at `:934`.
- **b53-02:** real. `reply_file` returns the inbox path, then `request()` and `issue_reply()` read it again with `body_of` (`jq -r '.body'` on the path, `:125`). An ack between the two reads leaves `b=""`, which falls to `refused ... exit 4`. The fix (one `read_msg_fields` read with `archive/` fallback) is narrow and reuses b52-03's helper. See N2 on what the green proves.
- **b53-03:** real and deterministic. Days are grouped by UTC (`reporting-releases.ts:228` `toISOString().slice(0, 10)`). At hour H, today holds j=0..2H, so yesterday's row 2 is j=2H+2, and `(2H+2) % 5 === 0` exactly when H ∈ {4, 9, 14, 19}. That matches the three CI hours (19, 14, 14). Test-only fix, `reporting-releases.ts` untouched: narrow. See N3 on rc03's strength.

### 5. R2 / vendor / kind / batch / R1

Every row has a red that fails today and a fix-shape that passes, plus a test list, a vendor (claude on all 3), a kind (`simple_coding`, `simple_coding`, `tests`) and batch 1. No mistral row and no mistral R7. R7 is agy, or the claude waiver fallback `c-001` `77ba5669`. R1: the rows' 5 files are pairwise distinct (plan section 5 lists them, and I compared them by hand). Batch 1 shares no file.

### 6. R3

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 5 row files> --agent c-749` (16:5xZ) -> **exit 4**: `WARN no live lane lists <the 5 files>`, plus 3 `unknown:` lanes that record no files: `a-719@sat` (the planner), `c-651@sat c-651-rotate`, `c-722@sat c-722-c001-6635-rotate-case32-flake-trunk-red`. The plan quotes 23 `unknown:` lanes at 16:40Z, a different reading at a different time. c-722's slug names the `dispatch-rotate.tst.sh` case-32 flake, which is not a row file, but I cannot see its tree from <box2>. Not free until the holder re-runs `--check` at placement, as the plan already says. The b52-02 file `spl-review-go.func.sh`: b52-02 landed as `138d4829f` (on origin/master), and no live lane lists the file, so b53-01 does not collide.

### 7. Inputs accounted for

The plan's section 3.5 against `bug-round-52-plan.md` section 7 (`git show origin/master:...`, `:1119`): items #1 and #3 to #9 are carried, or carried by name. #2 is served as b53-01 except for two parts, see W2. `/var/spool-hub/dispatch/c002-next-round-candidates.md` does not exist on <box2> (`ls` -> No such file). Items `:170` and `:173` are checked only as the plan quotes them: NOT RUN here. Row count: 3 against the "aim at 2, cap 3" of rulebook 5.1. That is justified by the 24 h bug share UNDER (as quoted, not re-measured here) and by b53-03 being a 3rd-sighting flake (rulebook 2.11.3).

### 8. Hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` on a tree at `4c8cdbe91` (the plan's sha) -> `INFO distribution-hygiene: clean over the tracked tree`, exit 0.

## Defects

**W1 (blocking): b53-01 fix item 2 makes a held owner-go brief a false GO** (plan `:57`, `:67`, `:211-216`). I applied the plan's own fix-shape (plan `:183-244`, unchanged) to a scratch copy of `spl-review-go.func.sh` from `3308d118f` and ran `_spl_review_go_owner_go` on probe briefs:

| probe (a `## Do` step) | base `3308d118f` | fix-shape |
|---|---|---|
| p1 `Apply the plan's verbatim hunks. Then roll them out on the live prd database.` | `rc=1` keyword `Apply` | **`rc=0 [ok]`** |
| p2 `Apply the plan's verbatim hunks to e.g. the live prd database.` | `rc=1` keyword `Apply` | **`rc=0 [ok]`** |
| p3 `Apply the verbatim hunks; target: the prd schema.` | `rc=1` | `rc=1` |
| p5 `` `DRY_RUN=0 ./run -a do_rdb_migration_next` `` then next line `` `ENV=prd ./run -a do_provision` `` | `rc=1` | `rc=1` (`ENV=prd`) |
| p7 `` `DRY_RUN=0` `./run -a do_rdb_migration_next` then `DRY_RUN=0 ./run -a do_gcp_project_delete` `` | `rc=1` | `rc=1` |

`prd`, `live` and `database` are not owner-go keywords (`:818` `fixed=`). `Apply` is the only token that holds p1 and p2, and the per-sentence split (`[.!?]+(?:\s+|$)`, which also splits after `e.g.`) strips it whenever the target sits in a later sentence. That is a false go, against `:718-719`. Fix before v1.0: keep the line-wide `TGT` check for every sentence from the `HUNK` sentence to the end of the line, and clear only a later-sentence `TGT` that is itself negated (`never|not|no` before it in that sentence: the r08 shape `never the box's live tmux server`). Or exempt exactly `live tmux`. Add p1 and p2 to rc01 and case 37 as controls that must hold on base and fix.

**W2: b52 section 7 #2 is not fully accounted for** (`bug-round-52-plan.md:1119` against plan `:46`, `:125`). `3748a973` ("another round's `DRY_RUN=0`") and "prose/backtick/identifier `apply`/`Apply`" appear nowhere in the plan (`grep -c 3748a973` -> 0, `grep -c identifier` -> 0, `grep -c backtick` -> 0). The `:61` note declines broad `DRY_RUN=0` prose for `d3c6d171`/`d185b420`, but it does not name `3748a973` or the `apply` identifier class. Of the "4 more rc 4 holds `20:27Z..22:12Z`", the 20:27Z hold is not named. Name each one as served by a b53-01 probe, dropped with the `:61` reason, or carried to b54.

**W3: the plan names the wrong holder** (plan `:833`): "sent to ... dispatch holder `c-003@sat`". At 16:28Z the holder was `c-002@sat` (its msg 45909728), and `LEASE_CMD=show` printed `c-002@sat` at 16:5xZ. Name the holder from `LEASE_CMD=show` at send time.

## Notes

- N1 (b53-01 NEVER widening, fix item 1): `not\s+your(?:\s+files|s)\b` also matches a heading such as `## Not yours to skip: do these`. Under fix-shape, a `DRY_RUN=0 ./run -a do_spl_desk_up` step under that heading went from `rc=1` to `rc=0` (probe p6). The heading is contrived, but anchoring it costs nothing: `not\s+your(?:s|\s+files)\s*(?:\(|$)`.
- N2 (rc02): on fix-shape, cases A and B pass because the jq shim never fires: the fix reads with `cat` and parses from memory, so no `jq ... .body <inbox path>` call happens. The control proves that the second path read is gone. It does not prove survival of a move between `files_holding` and the `cat`; `read_msg_fields`' `archive/` fallback covers that (`:281-282`), and case C covers the archive-only case. Case 17 in `test-spawn-remote.sh` should move the file before the read (as case 16 does at `:420+`), not only after it.
- N3 (rc03): rc03 runs `measure()` verbatim, but on a hand-built mock DOM. It re-implements the day bucketing (`buildMockDays`) and only regex-checks that `mockCommits` still has `j % 5` and the 30-minute step. Its pass on a fix is decided partly by a regex over the S3 source (`/for\s*\(|find\(|nth-child|shaded|querySelectorAll/`), so a fix that still clicks row 2 through a reworded selector could pass rc03. The plan's Chrome proof with `Date.now` stubbed to `14:30Z` is the real gate. Keep it mandatory in R7's `ran:`.
- N4: the plan cites `request()` as `:197-207` and `:199-206`. The function is `:152-211` (60 lines, as the plan says); `:197-207` is its wait loop. Fine as a site, but say "wait loop".
- N5: write `csi-spl-wui/src/components/reporting/ReleasesDailyList.vue:79` with its directory (plan `:100`).
- N6: the plan's `Panel` line says this seat was "placed `07:43:20Z`". This review does not depend on it; I did not verify it.


---

## Re-review: v0.2 at `0fb8a0f9cab6db1c7a62f9f4fdb233fb6178b546` - verdict **FAIL**

Read at 17:1xZ: `git ls-remote origin refs/heads/review/c001-bug-round-53-planner` printed `0fb8a0f9cab6db1c7a62f9f4fdb233fb6178b546`. `git log --oneline 3308d118f..0fb8a0f9c` shows v0.1 then v0.2 (a fast-forward). `origin/master` is `3308d118f`.

### Red controls re-run (n=1 each way)

I extracted each script from v0.2 section 4. Their hashes: `rc01-b53.sh e974bf054e59 9712 B` (new), `rc02-b53.sh 38e1b5d20e6e 10399 B` and `rc03-b53.sh 4aea04a9e42c 10659 B` (unchanged). On `3308d118f`, rc01, rc02 and rc03 exit 1 on the base and 0 with fix-shape. In rc01 on the base, the 7 red probes are off their want and all 8 controls hold. With fix-shape, all 15 lines are at want, including the new `ctrl_hunk_later_sentence_live_prd_holds`, `ctrl_hunk_eg_live_prd_holds`, `ctrl_hunk_positive_live_tmux_holds` and `ctrl_not_yours_to_skip_holds`.

### Folded findings

- W1 (sentence split): removed. My v0.1 probes p1 and p2 now hold (`rc=1`) under the v0.2 fix-shape. Fixed.
- W2: `grep -c 3748a973` gives 8 and `grep -c 13a65603` gives 5; each is named and has a verdict (plan `:63`, `:65`). Fixed.
- W3: the history line names `c-002@sat` at send time. Fixed.
- N1: the `NEVER` heading is anchored; p6 (`## Not yours to skip: do these`) holds. See N7 for the colon form.
- N2 to N6: folded (`:152-211` appears 5 times, the full `ReleasesDailyList.vue:79` path once, `MANDATORY` twice, and `07:43` no longer appears).

### W4 (blocking): `NEG_LIVE_TMUX` swallows a real target between an unrelated negator and `live tmux`

`NEG_LIVE_TMUX = (?i)\b(?:never|not|no)\b[^.;:\n]{0,40}\blive[^\S\n]+tmux\b` (plan `:217`, used at `:221`) deletes up to 40 characters after any `not`/`no`/`never`. Those characters may include a target word, which is then never seen by `TGT`. I applied the v0.2 fix-shape unchanged to a scratch copy and ran `_spl_review_go_owner_go`:

| probe (a `## Do` step) | base | v0.2 fix-shape |
|---|---|---|
| p8 `Apply the verbatim hunks, do not wait, then run on prd in the live tmux pane.` | `rc=1` keyword `Apply` | **`rc=0 [ok]`** |
| p9 `Apply the plan's verbatim hunks with no delay to the prod db via the live tmux.` | `rc=1` keyword `Apply` | **`rc=0 [ok]`** |
| p10 the r08 shape (`... never the box's live tmux server.`) | `rc=1` | `rc=0` (the intended clear) |

This is the same false-go class as W1, against `spl-review-go.func.sh:718-719`. Fix: let no target word stand between the negator and `live tmux`. I checked this regex in python3 against the same `TGT`:

`NEG_LIVE_TMUX = re.compile(r"(?i)\b(?:never|not|no)\b(?:[^\S\n]+(?!(?:prd|prod|production|dev|live|database|db|schema|sql|migrations?|steps?|terraform|tf|tfvars|gcp|cloud|iam|billing|infra|provision)\b)[\w'’-]+){0,4}?[^\S\n]+live[^\S\n]+tmux\b")`

-> r08 and `never touch the box's live tmux server` are cleared (`TGT` gives False after the sub), while p8, p9, the positive `live tmux` case and p1 still block (`TGT` gives True). Add p8 and p9 to rc01 and case 37 as must-hold controls.

### N7

The anchor `not\s+your(?:s|\s+files)\s*(?:\(|:|$)` still skips a `## Not yours: do these` section: a `DRY_RUN=0 ./run -a do_spl_desk_up` step under it goes from `rc=1` to `rc=0` under the v0.2 fix-shape. A heading like that contradicts itself, so this is a note, not a defect. Dropping `:` from the anchor costs nothing.

### Unchanged from v0.1 review

Rows b53-02 and b53-03, R1, R3 (`lane-map --check` exit 4, re-run at placement) and hygiene: as above.
