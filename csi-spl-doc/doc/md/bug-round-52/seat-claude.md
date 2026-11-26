# Bug round 52 plan - panel seat, claude

Seat: c-129@sat (claude, cross-vendor panel seat of rulebook 3.2; the editor is a-264@sat, agy).  
Issue: SPL-6606. Brief: `c002-bug-round-52-claude-panel-seat.md`.  
Plan read: `csi-spl-doc/doc/md/bug-round-52-plan.md` at **v0.1 `1d0f7ec938cb0759ecc5e1cb06bfe28f2b42262a`** on `review/c002-bug-round-52-planner` (`git ls-remote` at 23:28Z, confirmed by the planner in msg `229d8abf` and by the holder in msg `e779985a`). Plan base `ecc05e480`; `origin/master` at review time `7f0c93aa3`.  
Checks ran on sat, 2026-11-26 23:28Z..23:40Z, n=1 per command.

## Verdict v0.1: FAIL

One blocking defect, W1 (b52-02 fix scope contradicts rulebook C4 and would hold compliant reviews). Rows b52-01 and b52-03 are ready as written. Everything else checks out.

## 1. Slug b52 free

- `git log -1 --format='%H %cI' -E --grep='^docs\(b51-plan' origin/master` -> `2485f3956cb1ad9576aa7a21bf02fe5f0d3282cc 2026-11-26T17:48:03+02:00`, which matches the plan's `Window: W=`.
- `git log origin/master --since="2026-11-26T17:48:03+02:00" --oneline -E --grep='\(b52-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b52-[0-9]{2}|bug-round-52'` -> only `1d0f7ec9… refs/heads/review/c002-bug-round-52-planner` (my own seat branch was not pushed yet).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b52-[0-9]{2}|bug-round-52'` -> `c002-bug-round-52-claude-panel-seat.md`, `hand-sat-c002-bug-round-52-planner.md`. Both expected.
- `git log --oneline 2485f3956..ecc05e480 | wc -l` -> `27`, matching the plan's header.

## 2. Sites on the base and on origin/master

Every cited line was printed with `git show ecc05e480:<file> | sed -n <N>p`:

- `useMobileStack.ts:382-398`: `function listenPopState(` through `}`. Also checked `:377-381` (`popSeq`, `POP_ROUTE_WAIT_MS`).
- `mobile-stack.mjs:147-149`: `export function mobilePopWaitsRoute(tagged, level, routeLags) {` ... `}`.
- `mobile-back-wait.test.mjs:91-101`: `const plantSlow = …` through `}, [ms, only])`.
- `mobile-back-wait.test.mjs:180-194`: `await plantSlow(page, SLOW_MS, 'alerts')` through the `gone once the feed has loaded` assertion.
- `mobile-stack.test.mjs:207-218`: an insertion point next to the `mobilePopWaitsRoute` cases. The file has 327 lines.
- `spl-review-go.func.sh:839-876`: `_spl_review_go_one`, 38 lines.
  - `:858` is `abrief=…`.
  - `:864` is `do_spl_review_line_check`.
  - `:866` is the rc 8 hold.
  - `:711` is `NARR`, `:756` is `DRY`, and `:806` is `local fixed=…DRY_RUN=0…`.
- `spl-review-go.tst.sh`:
  - `:1148-1151` is case 27, the joined-names fixture with `spl-billing-sa.tst.sh`.
  - Case 35 ends at `:1456`, and the file has 1459 lines.
- `rounds-rulebook.md:126` is C4.
- `spawn-remote.sh`:
  - `:255-261` is `reply()`.
  - `:277-282` is `handle()`'s four reads, with `echo "$msg" >>"$STATE/seen"` at `:280`.
  - `:486-491` is `handle_issue()`, the same shape.
  - `:684-691` is `note_cancel()`, the same shape.
  - `spool-send.sh:299` mints `task="${TASK:-$(cat /proc/sys/kernel/random/uuid)}"`.
- Drift check: `git diff --name-only ecc05e480 origin/master -- <the 8 row files>` printed nothing, rc 0. Two commits landed since the base (`39bb380f8`, `7f0c93aa3`), and neither touches a row file.

## 3. Red controls

All three were extracted verbatim from plan sections 4.1 to 4.3 and run from this worktree.

`sha256sum`:

- `rc01-b52.sh`: `642aa582b7a67a9bdc9dcdbed26db064b28aebeb70f94cc2c85cef465095c9b7`, 15243 B.
- `rc02-b52.sh`: `1aad8be673cb1a05b3e9b2f39b80783f0bced64b43d19bf8587db79d6b7ab7b9`, 11166 B.
- `rc03-b52.sh`: `8d2ec920278de8ab27f8efae2d3451843ee5f7deb98dd86877893378c0788627`, 12260 B.

All three match the plan's prefixes and sizes.

| run | last line | exit |
|---|---|---|
| `bash rc01-b52.sh ecc05e480` | `rc01 exit 1` (A `premature=1`, B `immediate=1 after_timer=1`, C `premature=1`, D `untagged_cancels=false`, E `records=false asserts=false`, F `rc=0`) | 1 |
| `bash rc01-b52.sh ecc05e480 fix-shape` | `rc01 exit 0` | 0 |
| `bash rc02-b52.sh ecc05e480` | `rc02 exit 1` (3 red probes `rc=0 gos=1`; both controls `rc=0 gos=1`) | 1 |
| `bash rc02-b52.sh ecc05e480 fix-shape` | `rc02 exit 0` (red probes `rc=12 gos=0 tok_ok=1`) | 0 |
| `bash rc03-b52.sh ecc05e480` | `rc03 exit 1` (A `calls=0 good_task=0`, A2 `calls=0`, B `cancelled_recorded=0`, C `sent=1`) | 1 |
| `bash rc03-b52.sh ecc05e480 fix-shape` | `rc03 exit 0` | 0 |

- **Each red fails for the defect the plan names**, never for an environment reason: the site guards print `=1` for every site, and the fix shapes turn each one green.
- **No live state is touched.** I ran `grep -nE '/var/|/opt/|/mnt/|\$HOME|~/|gcloud|gh |curl|tmux|SPOOL_ROOT='` over the three scripts.
  - The only hits are `SPOOL_ROOT="$tmp/spool"` (rc02) and `SPOOL_ROOT="$A"` with `A="$tmp/home"` (rc03).
  - rc03 stubs `spool-send.sh` and the spawn command inside its `mktemp -d` copy.
  - All three use `git archive` into `mktemp -d`, with a trap that removes it.

## 4. The defects on the tree

- **b52-01 is right.** In `listenPopState`, `land` takes no arguments, so any `afterEach`, including a cancelled or aborted one, applies the level. vue-router 4 does call `afterEach(to, from, failure)` for aborted and cancelled navigations. The fix is narrow: four WUI files, and `stores/channel.ts` is excluded. rc01 drives the real `listenPopState` with a mock router, so it proves the guard's logic, not vue-router's timing. That is enough for the plan; the e2e W2 assertion covers the browser.
- **b52-02's defect is real**, but its fix scope is wrong: see W1.
  - `_spl_review_go_one` goes from line check rc 0 straight to tip, siblings and send, with no comparison against the author brief (`:864-875`).
  - Evidence brief lines checked:
    - `c002-6e8c1cdb-wui-loops-dialog-radio-title-drag.md:45` names `cd csi-spl-iac && ./run -a do_check_pre_push`.
    - `c002-s153-q3-queue-route-holds.md:43` names `do_check_pre_push` and `PRE_PUSH_TIER=full`.
- **b52-03 is right.** `handle()`, `handle_issue()` and `note_cancel()` mark `$msg` seen at `:280`, `:489` and `:687`, then re-read `$f` up to three more times. `reply()` passes `--task ""`, and `spool-send.sh:299` then mints a uuid. The fix is narrow: one script and its test.

## 5. Row form (R2, vendors, R1)

- **R2:** all three rows have a red control that fails today and passes after, a test list, vendor claude, kind `simple_coding`, and batch 1.
- **Vendors:** there is no mistral row, and every R7 seat is agy (cross-vendor) or the claude waiver `77ba5669`.
- **R1:** the file sets in plan section 5 share no file (b52-01: 4 WUI files; b52-02: 2 review-go files; b52-03: 2 spawn-remote files).

## 6. R3

I ran `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 8 row files> --agent c-129` at `23:29:55Z`.

- The output was **exit 4**: `WARN no live lane lists <the 8 files>, but 21 live lane(s) record no files`.
- All 21 `unknown:` lanes are on `<box2>`.
- No live lane lists a row file. The plan's account of the lanes and the queue agrees, and the holder re-checks at placement as the plan says. See N3.

## 7. Inputs

- **Round 51's first inputs:** every item in `bug-round-51-plan.md` section 7 (origin/master) is a row or **Carried** in plan sections 3.5 and 7. That covers the `DRY_RUN=0` false hold, `a-767` N2, `a-823` N2, `a-769` N1/N2, `c-625` N1-N3, `a-995` N1, `a-790` N1, `a-911` N2, hours-minutes, `c-708`, `a-683`, `a-490`, `a-480`, the buffer budgets, `unknown_token`, and the long tail.
- **Candidates file:** `/var/spool-hub/dispatch/c002-next-round-candidates.md` has 167 lines. Each cited line was checked with `sed -n <N>p`:
  - `:154` is SPL-5254, served by b52-01.
  - `:155` is the seat-rotation poke, carried.
  - `:156` is the declined asks, each accounted for.
  - `:157` is the `DRY_RUN=0` keyword gate, carried.
  - `:159-163` is review-go C4, served by b52-02.
  - `:166` is `MessageCard.vue`, carried.
  - `:167` is spawn-remote, served by b52-03.
  - No bug-shaped item is unaccounted for.
- **SPL-5254** is served by b52-01. `git log origin/master --oneline --grep SPL-5254 | wc -l` -> `0`, so it is still unfixed.
- **b52-02 and b51-03:** b52-02 edits `spl-review-go.func.sh`, and b51-03 has landed: `git merge-base --is-ancestor a5bb05350 origin/master` rc 0.
- **Row count** is 3 against an aim of 2. It is justified: one owner order, two explicit c-001 rulings (`ee10c09a`, `e1db57c6`), and bug share under its band. It is within the 5.1 cap.

## 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` on this worktree (`7f0c93aa3`) printed `INFO distribution-hygiene: clean over the tracked tree`, exit 0.

## Defects

**W1 (b52-02, plan lines 93, 105, 107-108, 1021; rc02 helper at lines 567-631).** The fix compares the author brief's required tests against `ran:` only.

Rulebook C4 (`rounds-rulebook.md:126`) also accepts a column test named in `read:` as `NOT RUN <test>: <why>`. Under the planned `_spl_review_go_c4_missing`, a C4-compliant review is held with rc 12, so the row would add the very false-hold class that round 53 carries for the owner-go gate.

I proved it by running the plan's own helper code, lines 574-630 written out as `c4.py`:

- Brief: `` `bash …/foo.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` ``.
- Line `ran: bash foo.tst.sh | read: NOT RUN do_check_pre_push: box at 255% CPU` -> prints `do_check_pre_push`, rc 1 (HOLD).
- Control `ran: bash foo.tst.sh; cd csi-spl-iac && ./run -a do_check_pre_push` -> rc 0.

The "0 false holds" audit on 7 real pairs (plan line 98) holds no `NOT RUN` entry, so it does not cover this case. `NOT RUN` is common: `grep -n 'NOT RUN' /var/spool-hub/dispatch/briefs/*.md | wc -l` -> `1286`.

Fix for v0.2:

- A required item counts as present when `ran:` names it **or** `read:` carries `NOT RUN <item>`.
- Section 3.2, the row's fix scope and case 36 should say so, with a control case.
- `rc02-b52.sh` should add a `ctrl_not_run_in_read` probe that wants GO.

## Notes

- **N1 (b52-02, false-hold surface).** The extractor counts every test-file token in the brief's instruction text except tokens after `not|never|except|excluding|stay off`.
  - A sibling row's script named in passing is required. A brief line `` R7 runs `rc01-b52.sh`; see sibling row b52-02 which runs `rc02-b52.sh`. `` with `ran: bash rc01-b52.sh; bash x.tst.sh` -> prints `rc02-b52.sh`, rc 1.
  - That is not blocking, since the hold names the item and the holder can GO by hand. Case 36 should pin one such sibling mention, and the R7 should run the helper against the b52 row briefs themselves before GO.
- **N2 (b52-03, rc03 labels).**
  - On the base, Case A takes the `REFUSED … sender is not an agent id` path (`from=""`, `rej=0 minted=0`), not the live `REJECTED … bad kind ''` plus minted-task path (`.from` read, then `.task_id` lost). The minted task is proven only by Case C, which calls `reply()` directly.
  - The rc03 comment calls Case A2 `(control)`, but it is red on the base: it is a second red.
  - Suggestion: add a variant whose shim moves the file after the `.from` read, which reproduces the exact live line.
  - The candidates file `:167` also records a live workaround: both orchs leave spawn-request and cancel messages unacked for one serve tick. The plan should mention it, and the row should say whether it can be lifted once b52-03 lands.
- **N3 (R3).** The plan's R3 command (line 1028) lists `bug-round-52-plan.md` instead of `test-spawn-remote.sh`, so b52-03's test file was not checked. My run covers all 8 row files: exit 4, 21 `<box2>` unknowns, none listing a row file.
- **N4 (b52-01).** Moving `++popSeq` before the untagged return means that a later untagged popstate stops a waiting tagged pop's level from ever applying, including on the 3 s fallback. That is intended (rc01 D), but it should be one named unit case in `mobile-stack.test.mjs`, so the behaviour is pinned, not only tested in the red control.
- **N5 (evidence wording).** Plan line 97 says the `04:4xZ` GOs on b49-01, b49-02 and r05-02 all omitted `do_check_pre_push` and 3 iac tests. Candidates `:162` says the 3 iac tests were r05-02's only.
