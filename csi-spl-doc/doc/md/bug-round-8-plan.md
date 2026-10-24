# Bug-fix round 8 - plan (1 action)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Round 8 focus: **`do_spl_review_line_check` accepts a log directory that belongs to another agent**; plus candidate measurements from the dispatcher's 2026-10-23 list (summary words as commands, store test review with skips, and desk-cron `bin/spool` freshness).  
Concurrency: rulebook §1.1 asks for 2 row lanes in parallel: batch 1 is lane A (Row 01) (section 3.1).  
Consensus: **no owner go, no question to the owner** (rulebook §1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, bands, R1-R16), linked here, not copied. Issue: SPL-3140.  
Model: [bug-round-7-plan.md](bug-round-7-plan.md) (same shape, same 5 sources).

**Status: v1.0, consensus** (editor a-819@<box2>, reviewer c-082@<box>). Row 01 hardened for agy session ownership, vibe journal traversal, and known gaps; consensus reached with reviewer changes C1-C5.  
Editor: **a-819@<box2>** (agy, `specs_and_docs`).  
Reviewer: **c-082@<box>** (claude, cross-vendor to agy, rulebook 2.7.2; takeover of voided m-943, verdict landed in `7a3a2c758`, SPL-3148). The reviewer signs v1.0 in its own commit after this landing.

**One sha:** every count below is measured on **`b9a9aea12`** (`origin/master` at the start, 2026-10-24T00:06:41Z / 03:06:41 CEST), on <box2> unless a row says sat. n=1 per command unless stated.

---

## 1. How to read this

- One row = one defect = one lane step, at the sites named and nowhere else. Each row has a **red control**: a test that fails on `b9a9aea12` and passes after the fix. Section 3.2 shows each red control's run on `b9a9aea12`.
- **Paths** are repo-relative. Line numbers are as of `b9a9aea12`.
- **Box:** the preferred box. The placer may move a row (no pin).
- **Vendor:** `do_spl_lane_mix` by kind, then the owner rules. Mistral writes no code. `LANE_MIX_KIND=simple_coding ./run -a do_spl_lane_mix` -> `pick=grok`, but grok is at its weekly limit (<box2> `gc.log`: `FALLBACK ... grok -> claude: grok weekly limit`). So the coding vendor is claude.
- **Subject** (R6 reads it): `fix(b08-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<absolute journal path>` (rulebook 2.7.4).

---

## 2. Where the rows come from (measured on `b9a9aea12`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports in t1 since 2026-10-22** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)'), count(*) filter (where body like '[spool-probe]%') from messages where tenant_id='t1' and ts >= '2026-10-22' and from_id like 'HUM%'" ./run -a do_spl_db_query`. Then non-probe bodies since round 7's read (`ts >= '2026-10-23T17:57Z'`) were read | 425 human posts, 2 defect-worded, 346 `[spool-probe]` lines (since 2026-10-22). Round 7 counted 384 posts and 2 defect-worded | 5 non-probe posts since 17:57Z: 1 poll answer (2dac696c), 2 "Go implement" (40744f59, b28cae33), 1 "Should we close this topic" (63b0855a), and 1 owner defect report: f8335e7f ("Not visible on mobile.", HUM-10 on task c7185b1f). That defect was tracked as SPL-3120, assigned to lane c-922, and fixed on trunk in `b9a9aea12` (the start sha). None of the other posts describes a defect. **0 rows.** |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <DEV_USER> env GH_TOKEN="$(gh auth token)" CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 200 runs 2026-10-22T18:16:49Z .. 2026-10-24T00:11:00Z: 133 success, 49 cancelled, 16 failure, 2 running. Every timeout headroom line is `ok` (worst: orc hermetic 3/3, p90 814 s of 1800 s, 45 %) | 0 new failed runs since round 7's read (17:57Z). The newest failed run in the window is `39996051494` (2026-10-23T17:33:31Z, `337dc9a3b`, hermetic 2/3 `lane-restart.tst.sh` case 6), which was addressed in round 7 row 03. Every failed job is green on the newest completed run `40041795384` (`83e34f34`, 23:49:31Z). **0 rows.** |
| **3. Skipped or disabled tests, local flakes** | `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" b9a9aea12 -- "$d" \| wc -l; done`. `diff` of the sorted grep (`-h`) against `52cec6efe` | 187 lines (api 140, wui 17, orc 9, iac 21, utl 0), identical to round 7. `diff` -> empty (rc 0): 0 new skip lines in 100 commits. 4 entries in `csi-spl-wui/tests/e2e/ci-skip.txt`, 0 in `csi-spl-orc/src/bash/features/ci-skip.txt` | 0 defects. 0 local flakes. |
| **4. GC notes and box alarms, last 24 h** | `awk '$1 >= "2026-10-23T02:00"' /var/spool-hub/dispatch/gc/gc.log \| awk '{print $2}' \| sort \| uniq -c` on <box2> | <box2>: 45 START, 41 DONE, 5 END-STALE, 19 FALLBACK, 8 POKE, 5 CLOSE-ASK, 3 REFUSED, 1 NONE, 1 MOVED. `spool tail --task gc-sat` from <box2> -> `no messages visible to this box`. `spool tail --task gc-<box2>` -> latest post 2026-10-22T11:01Z | Every END-STALE was earlier on 2026-10-23 (last one 16:00:04Z). Since 16:00Z, 0 END-STALE passes: all passes ended DONE. The FALLBACK lines are the hourly grok weekly limit fallback to claude. The REFUSED and NONE lines are the GC refusing a wrong `begin`, as designed. **0 rows.** |
| **5. Open defect issues** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ISSUE_ASSIGNEE='' ISSUE_LIMIT=500 DRY_RUN=0 ./run -a do_spl_issue_list`, labels and titles read with `python3 -I` | 349 issues (total 349), 4 labelled `bug`; 30 with a defect word in the title, 1 of them created since round 7's read | The `bug` ones are SPL-1945 (blocked, needs owner) and SPL-455 / SPL-450 / SPL-435 (out of scope by brief). The only new issue with a defect word since 17:57Z is SPL-3140 (this plan). **0 rows from issues.** The dispatcher's candidates: (a) Part 1 **reproduces** (Row 01); (a) Part 2 is measured and not a bug (section 4); (b) and (c) are measured and not a bug (section 4). |

---

## 3. The 1 row

| # | defect | evidence | sites file:line | red control (fails on `b9a9aea12`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b08-01-orc-review-log-agent-match)` | An R7 review line (`review: <id>@<box> ... \| log: <id>@<box>:<path>`) requires that the reviewer ran the tests in its own session journal (rulebook §2.7.4: "the reviewer's own session journal"). `do_spl_review_line_check` verifies that the reviewer `<id>` string matches the `<id>` string before `@` in `\| log: <id>@<box>:<path>`, but it never checks whether `<path>` actually belongs to `<id>`. A reviewer can cite another seat's session directory (e.g. `m-929@sat` cited `m-937@sat`'s vibe session `1ff89151...`), and if that other seat executed the tests, `do_spl_review_line_check` accepts it with `OK`. | (1) The dispatcher's case: `m-929@sat` sent a PASS whose `log:` cited `m-937`'s session dir (`1ff89151...`; c-925 msg 38f26700). (2) Vibe session directories contain `meta.json` recording `"working_directory": "/opt/csi/csi-spl-wt/<agent_id>"` and `"origin_directory"`. Claude session transcripts live under `~<HARNESS_USER>/.claude/projects/-opt-csi-csi-spl-wt-<agent_id>/<uuid>.jsonl`. Agy transcripts live under `<home>/.gemini/antigravity-cli/brain/<uuid>/.system_generated/logs/transcript.jsonl` with workspace mapping recorded in `cache/last_conversations.json`. (3) In `spl-review-line-check.func.sh`, `_spl_review_line_reviewer` checks only the regex string equality `[[ "$who" == "$owner" ]]`; `_spl_review_line_match` reads whatever path is passed without inspecting `meta.json` or checking whether the path's agent identifier matches `<id>`. (4) Empirical test on `b9a9aea12`: A fixture session dir with `meta.json` pointing to `/opt/csi/csi-spl-wt/m-901` and a command `bash test-sample.tst.sh` passed to `REVIEW_LINE="review: m-902@box-a mistral PASS $SHA ran: bash test-sample.tst.sh \| read: 9 PASS \| log: m-902@box-a:<dir>" ./run -a do_spl_review_line_check` exits 0 with `OK 1 of 1 named in ran: are commands in <dir>` (rc 0), ignoring the owner mismatch. | `csi-spl-orc/src/bash/run/spl-review-line-check.func.sh:56,74,134,177-250`; test `csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh:199-214` (new case 11 after :213) | In `spl-review-line-check.tst.sh`, case 11: Create a vibe fixture session directory `$T/u11/s1` with `meta.json` containing `{"environment":{"working_directory":"/opt/csi/csi-spl-wt/m-901"}}` and `chunks/c1.json` holding a command `bash $TST`. Run `chk REVIEW_LINE="review: m-902@box-a mistral PASS $SHA ran: bash $TST \| read: 9 PASS \| log: m-902@box-a:$T/u11/s1"`. Today on `b9a9aea12`: exits 0, `OK 1 of 1 named in ran: are commands in ...` (rc 0). PASS requires: exits 1 with `FATAL log ... belongs to agent m-901, not reviewer m-902`. Control: when `meta.json` specifies `m-902`, the check exits 0 (`OK 1 of 1`). | In `spl-review-line-check.func.sh`: pass reviewer agent id `$id` to `_spl_review_line_match` and into `_SPL_REVIEW_LINE_PY`. In python, verify session ownership using agent id grammar `[acgmq]-[0-9]{3,}` (:133): (a) Look for `meta.json` from path up to the session directory (the first directory containing `CURRENT` or `chunks/`, handling live journal files `<session>/journal/<n>.jsonl`): parse `working_directory` (under `environment`) and top-level `origin_directory`. If either matches `/opt/csi/csi-spl-wt/([acgmq]-[0-9]{3,})`, verify that the extracted agent id equals `$id`. If not, print `FATAL log <path> belongs to agent <found>, not reviewer <id>` and exit 1. (b) If the path contains `-opt-csi-csi-spl-wt-([acgmq]-[0-9]{3,})`, verify that the id matches `$id`. (c) If the path contains `/var/spool-hub/([acgmq]-[0-9]{3,})/`, verify that the id matches `$id`. (d) Antigravity brain paths (matching `/brain/<uuid>(/|$)`): resolve `<prefix>/.gemini/antigravity-cli/cache/last_conversations.json` under the cited path's home. If mapped to a worktree `/opt/csi/csi-spl-wt/([acgmq]-[0-9]{3,})`, check against `$id`. When inspecting `transcript.jsonl`, do not take the first worktree mention: check the seed's `spool agent id is <id>` first, then cache row, and refuse only when the reviewer's own worktree never appears and another worktree does. If an agent id is found and does not match `$id`, fail with `FATAL log <path> belongs to agent <found>, not reviewer <id>`. Known gap: Worktrees of other repos (`/opt/<org>/<repo>-wt/<id>`) and sessions run outside `/opt/csi/csi-spl-wt/<id>` (e.g. ad-hoc root, `/opt`, or `/var/tmp`) without an agent id in path/metadata match no rule; the check falls back to command presence. Add case 11 to `spl-review-line-check.tst.sh` (covering directory and live journal file shapes; control covers takeover brief mentioning predecessor worktree first). Docs: `Docs: none (review-line verification hardening)`. | <box2> | claude | mistral (cross-vendor, rulebook 2.7.2) | simple_coding | 1 (lane A) |

### 3.1 Files (R1) and lanes

- **Batch 1, lane A:** Row 01. Changes `csi-spl-orc/src/bash/run/spl-review-line-check.func.sh` and `csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh` only.
- `bash …/lane-map.sh --check csi-spl-orc/src/bash/run/spl-review-line-check.func.sh,csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh,csi-spl-doc/doc/md/bug-round-8-plan.md --agent a-819` -> exit 4: `no live lane lists` any of them, and 14 live lanes record no files (rotation seats, s107-v2, wui-decompose; none touches these files).
- `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 11 rows: 2 refactor, 9 feature, 0 bug. None names `spl-review-line-check`.
- Box: `sudo -u <DEV_USER> env BOX_PICK_KIND=claude ./run -a do_spl_box_pick` -> `pick=<box2>` (least past its band).

### 3.2 Red controls run on `b9a9aea12`

Inputs: fixture session directories created in `$T` with `CURRENT`, `meta.json`, and `chunks/c1.json`.

| row | command (scratch, repo untouched) | output on `b9a9aea12` | output with the fix (scratch copy of `spl-review-line-check.func.sh`) | who |
|---|---|---|---|---|
| 01 | `cd csi-spl-orc && sudo -u <DEV_USER> env REVIEW_LINE_BOX=box-a SPOOL_ROOT=$T REVIEW_LINE="review: m-902@box-a mistral PASS 0123456789abcdef0123456789abcdef01234567 ran: bash csi-spl-orc/src/bash/tests/git-prune-round-branches.tst.sh \| read: 9 PASS \| log: m-902@box-a:$T/u11/s1" ./run -a do_spl_review_line_check` (where `$T/u11/s1/meta.json` specifies `/opt/csi/csi-spl-wt/m-901`) | `NOTE read as <HARNESS_USER> (sudo -n)`, `OK 1 of 1 named in ran: are commands in ...`, rc 0 (accepted another agent's session) | `FATAL log ... belongs to agent m-901, not reviewer m-902`, rc 1. Control: with `meta.json` set to `m-902` -> `OK 1 of 1`, rc 0 | editor |

---

## 4. Measured and not a bug

| candidate | command | result | why not a row |
|---|---|---|---|
| (a) Part 2: Summary words as commands in `ran:` (`ran: fetch,test,red-control,lint`, msgs c193d333, 47a699c4) | `cd csi-spl-orc && sudo -u <DEV_USER> env REVIEW_LINE="review: m-937@<box2> mistral PASS b9a9aea12596c8216b858014d0c928ee01e46f2a ran: fetch,test,red-control,lint \| read: ok \| log: m-937@<box2>:/tmp" ./run -a do_spl_review_line_check` | `MISSING ran: names no test (*.tst.sh, *.test.mjs, *_test.go, go test, pnpm run): 'fetch,test,red-control,lint'`, rc 3 | **The tool already refuses summary words.** `_spl_review_line_names` extracts only strings matching test extensions (`*.tst.sh`, `*.test.mjs`, `*_test.go`) or runners (`go test`, `pnpm run`). When none match, `do_spl_review_line_check` exits 3 (`SYNTAX FAIL`, rc 1 with `REVIEW_LINE_SYNTAX=1`). The summary was sent in a spool message body, not accepted by the check tool. Not a bug. |
| (b) A mistral PASS on spec 149 B1 (m-929 msg 0fd71519) ran store tests without `SPOOL_TEST_PG_DSN` (all skipped, ~0.04 s) and passed `do_spl_review_line_check` | Review rulebook §2.7.4; `spl-review-line-check.func.sh:8-20` | `do_spl_review_line_check` verified that the `ran:` command `go test ./internal/store/...` appeared in the reviewer's session journal (`cmds`), which it did | **By design.** Per rulebook §2.7.4, `do_spl_review_line_check` verifies execution proof (that the reviewer executed the command cited in `ran:`); it does not evaluate test outputs, skips, or driver flags (line 20: "Tool OUTPUT never counts"). In Go, tests call `t.Skip("SPOOL_TEST_PG_DSN unset")` and package exits 0 when no Postgres DSN is provided. Enforcing that store suites run against Postgres is the pre-push gate's job (`PRE_PUSH_TIER=full` runs `hub-pg.tst.sh` / Postgres), not `do_spl_review_line_check`. |
| (c) `/opt/csi/csi-spl-desk-cron/csi-spl-api/src/go/spool-hub-api/bin/spool` is older than its sources on every spool call from desk-cron | `git check-ignore -v` on `csi-spl-api/src/go/spool-hub-api/bin/spool` -> `.gitignore:1:/bin/` (rc 0); `ls -l` on <box2> -> `No such file or directory` (rc 2). On sat: `bin/spool` was built once on 2026-10-17 | `spool_env_resolve` prefers repo `bin/spool` (`spool-env.inc.sh:422-424`); `_spool_bin_stale` skips a stale binary (`:60-62`) and `_spool_bin_fallback` uses PATH / `~/.local/bin/spool` (`:72-73`) | **By design (staleness guard working), not a code defect.** `spool_env_resolve` prefers the repository `bin/spool` (`spool-env.inc.sh:422-424`). When it is older than sources, `_spool_bin_stale` detects it and logs the `WARN ... is older than its sources ...; not using it` (lines 60-62), then falls back to PATH, then `$HOME/.local/bin/spool` (lines 72-73); only if no other spool is found is the stale one used, loudly. The warning is the staleness guard working as designed, falling back cleanly to `~/.local/bin/spool`. Removing the untracked artifact on sat silences the warning. |
| Owner report: HUM-10 msg f8335e7f ("Not visible on mobile.") in task c7185b1f | `cd csi-spl-orc && ENV=prd SQL="select msg_id, task_id, ts, body from messages where msg_id='f8335e7f-402d-4734-8cc7-9df5004d7bc2'" ./run -a do_spl_db_query` | Tracked as SPL-3120, assigned to lane c-922, fixed in commit `b9a9aea12` | Already fixed and landed on trunk in `b9a9aea12` ("fix(wui, SPL-3120): the bouncing dots show on every Back on a phone"). |

---

## 5. Not reproduced

| candidate | what I tried | outcome |
|---|---|---|
| `lane-restart.tst.sh` case 6 CI red (run `39996051494`, `337dc9a3b`, 2026-10-23T17:33:31Z) | Source 2 CI gate report over 200 runs (`do_report_ci_gate`) | Addressed in round 7 row 03 (`23a6a2eff`, `fix(b06-03-orc-lane-restart-case6-diag, SPL-3114)`). In the 200 runs since 2026-10-22T18:16Z, run `39996051494` was the only sighting. 0 occurrences since round 7 landed. |

---

## 6. Owned elsewhere (R3)

| item | owner | status |
|---|---|---|
| Stale agy-quota WAIT line in `do_spl_spawn_queue` | c-670@<box2> (ask 96bd8b5c) | Listed here by brief, no row. |
| Pre-push base tree Go cache | SPL-3128, c-152@<box2> | Live lane. |
| `do_docker_volume_prune` rc | SPL-3127, c-101@<box2> | Live lane. |
| SPL-455 / SPL-450 / SPL-435 | spec 011 regression gate checks | Out of scope by brief (label `bug` but not defects). |
| SPL-1945 secret rotation plan | blocked, needs owner | Out of scope for bug round. |
| `do_spl_lane_mix` picks grok for `simple_coding` while grok is at weekly limit | the dispatcher / orchestrator | Handled via fallback to claude in placement. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 1 (defect fix with red control run on `b9a9aea12`) |
| vendor | claude 1 |
| box (preferred) | <box2> 1 |
| batches | 1 (batch 1: Row 01) |

---

## 8. Panel and reviewer (R7)

- **Editor:** `a-819@<box2>` (agy, `specs_and_docs`).
- **Reviewer:** `c-082@<box>` (claude seat, takeover of voided mistral reviewer `m-943`, cross-vendor to agy, rulebook 2.7.2; verdict landed in `7a3a2c758`, `csi-spl-doc/doc/md/bug-round-8/seat-claude.md`, SPL-3148). The reviewer signs v1.0 in its own commit after this landing.
- **Review history:**
  - 2026-10-24 00:27Z: Editor landed v0.1 (`c0a38c8af`). Mistral reviewer `m-943` failed to land a verdict quoting red control runs and was voided by dispatcher `c-002@sat`.
  - Dispatcher noted Row 01 rules (a)-(c) omitted agy brain paths.
  - 2026-10-24 00:52Z: Editor landed v0.2 (`7bbe8f77c`): hardened Row 01 with rule (d) for agy brain cache/transcript inspection and documented the known gap for non-worktree sessions.
  - Dispatcher queued claude reviewer seat `c-082` (ask `de4d61bf`).
  - 2026-10-24 01:15Z: Claude reviewer `c-082` landed verdict (`7a3a2c758`): agreed with Row 01 with changes C1-C5 (vibe journal traversal, top-level `origin_directory`, agy takeover fixture order, id grammar `[acgmq]-[0-9]{3,}`, relative cache path, and other-repo/non-worktree gap); agreed with Section 4 (a) Part 2, (b) (cited line 20), (c) (reworded why: staleness guard fallback), 4 owner report; agreed with Section 5 with corrected landed commit `23a6a2eff`.
  - 2026-10-24 01:18Z: Editor landed v1.0 consensus folding reviewer changes C1-C5 and corrections.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | a-819@<box2> | **v1.0 consensus** |
| Reviewer | c-082@<box> | **agree with changes (C1-C5)** (verdict `7a3a2c758`, signs v1.0 in own commit) |
