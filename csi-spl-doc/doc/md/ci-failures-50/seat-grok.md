# CI failures 50, grok seat

Verdict: PASS on `62397a34ce67260efd00c18fe00ac0c0e6bb5b8e`.

Reviewed file: `csi-spl-doc/doc/md/ci-failures-50-2026-11-15.md` (320 lines, parent `d7882a7d82542ec290bc515df60db7aab731e171`). Blob `1617f7ab2d1d7c54ce9d3f782431b27210e776ee`. Not an ancestor of origin/master.

Cited file:lines were read on origin/master `1067feb463db1f81dcdb17e73212f45a059c3379`. The same lines matched `45b897bdb67405624ed93384b971d6d42a2eb732`. `git diff --stat 45b897bdb 1067feb46` on `hub-pg.tst.sh`, `check-pre-push.func.sh`, and `docs.test.mjs` printed nothing.

No blocking defect.

## Check 1. The window

Command: `gh run list --branch master --status failure --limit 55 --json databaseId,createdAt,workflowName,headSha,event,conclusion`.

Printed: 55 runs. Newest `2026-11-15T10:27:30Z` id `43704165906` workflow `10 ci: quality gate`. The latest 50 start `2026-11-14T02:46:25Z` id `43548126862` and end at that newest id. Overlap with the earlier 50-row file is 50, dropped 0, added 0.

`python3 /tmp/g-160-ev/win-sum.py` on that 50 printed: n 50; first `2026-11-14T02:46:25Z` id `43548126862` push `15 sec: deps and secrets` sha `8c39ee3ef2c8` failure; last `2026-11-15T10:27:30Z` id `43704165906` push `10 ci: quality gate` sha `100cbbff23ff` failure; workflows `15 sec` 10, `10 ci` 30, `20 ci-cd` 4, `00 ops` 5, `13 ci` 1; events push 31, schedule 19; distinct shas 28; wf 10 is push 18 and schedule 12. Matches doc section 1.

The doc prints one run id. Command: `git show 62397a34ce67260efd00c18fe00ac0c0e6bb5b8e:csi-spl-doc/doc/md/ci-failures-50-2026-11-15.md | grep -nE '[0-9]{11}'`. Printed only line 72, run `43596303051`.

`gh run view <id> --json conclusion,headSha,name,createdAt,event,displayTitle,status` (all `status` completed):

| id | printed | matches |
|---|---|---|
| 43596303051 | failure, push, wf 20, `2026-11-14T12:44:40Z`, sha `9d6043eae86f996ff70aa36836f0f0270d5473d4` | the one id in the doc (line 72, F5 inside D1). In the 50. |
| 43548126862 | failure, push, wf 15, `2026-11-14T02:46:25Z`, sha `8c39ee3ef2c8f17e762b03bf62948c890e45dd1d` | window start. D3 signature is on its log (check 2). |
| 43632676279 | failure, push, wf 10, `2026-11-14T19:32:48Z`, sha `b8b10b8e17e2a1bd312e75088bea80fedef3c485` | D5 first red time 19:32Z. |
| 43642712395 | failure, push, wf 10, `2026-11-14T21:25:12Z`, sha `4d90d24d78b4a503822c0736ba42cedd3a3185a2` | D6 first red time 21:25Z. |
| 43680713852 | failure, push, wf 10, `2026-11-15T05:21:14Z`, sha `26128ed71205b5a0b6c6d610fcd7ae61ee9c59f5` | D4 first failure time 05:21Z. This sha is not the named cause (N2). |
| 43551836712 | failure, push, wf 10, `2026-11-14T03:28:48Z`, sha `cb2bf460f01d76d1c74eea4a2dab18a5954c5b81` | F2 first. |
| 43704165906 | failure, push, wf 10, `2026-11-15T10:27:30Z`, sha `100cbbff23ff42ed01695ad8e4d4acff94fd87db` | F2 second, window end. |

The five ids after `43596303051` come from this list, not from the doc text. Section 9 already says the raw rows are not in git. See N1.

## Check 2. Three breaks and two flakes

Class sum on doc line 74: `14+5+10+5+2+2+3+2+2+2+2+1 = 50`. Recount printed `sum 50`. Shares on lines 80-84: 28/50, 10/50, 7/50, 5/50. F5 is labelled flake and is inside D1's run, not in the 7.

Break means doc lines 52-53: the cause commit is the first red sha's own change.

D1 holds. `gh run list --commit 9d6043eae86f996ff70aa36836f0f0270d5473d4 --workflow '10 ci: quality gate'` printed push failure `43596302891` at `12:44:40Z` and schedule failure `43596394566` at `12:45:46Z`. `git rev-parse 9d6043eae86f996ff70aa36836f0f0270d5473d4^` printed `aa48d077b8014723d326ab72b25efb2f9caed973`. That parent's wf 10 push `43591461479` and schedule `43591516280` are both success. Job log `j132451426593` (run `43596303051`) line 2342 `--- FAIL: TestHoursExportCSV (0.15s)`; line 2343 `hours_export_test.go:88` lists `HUM-1000` then `HUM-999`. Line 2332 `--- FAIL: TestCostMonthReadRLS (0.11s)` is the F5 line in the same job.

D5 holds. Cause `b8b10b8e17e2a1bd312e75088bea80fedef3c485`: wf 10 push failure `43632676279` at `19:32:48Z` and schedule failure `43633772533`. Parent `f81bc444419b5070c11559dbb73a4b3ab2de1651` wf 10 push `43631070971` is success. Log `j132563444696` line 3610: `FAIL: 2. orc eager files at most 88 -- 89`.

D6 holds, with N4. Doc names the range `5eff7c9df..4d90d24d7`. `gh run list --commit 5eff7c9df5e01423d8eb28401807d8a9eb5bb1e0` printed `[]`. End sha `4d90d24d78b4a503822c0736ba42cedd3a3185a2`: push failure `43642712395` at `21:25:12Z` and schedule failure `43644459606`. `git log --oneline 5eff7c9df5e..4d90d24d7` printed `4d90d24d7` then `97b08fd88` (docs, SPL-5527). The first red sha is the range's last commit. Log `j132594351906` line 3629: the same eager-files FAIL.

F2 holds, two later greens on the same sha. Push failure `43551836712` at `03:28:48Z` and schedule success `43553221401` at `03:45:06Z`, both sha `cb2bf460f01d76d1c74eea4a2dab18a5954c5b81` (16 min 18 s). Push failure `43704165906` at `10:27:30Z` and schedule success `43705585751` at `10:45:10Z`, both sha `100cbbff23ff42ed01695ad8e4d4acff94fd87db` (17 min 40 s). Logs `j132316728163` lines 1193 and 1318, and `j132785138246` lines 1234 and 1359, each print `FAIL signed-out: DEPLOY.md opens from the list "Deploying spool: choose your path"`. The doc's "17..18 min" does not fit the first gap (N6).

## Check 3. Themes and smells

Opened with `git show origin/master:<file> | sed -n <N>p` on `1067feb463`.

S1. `marketing_meta_dispatch.go:133` is `st.StuckMarketingPosts(...)`. `:141` is `st.MetaMarketingChannels(ctx)`. `marketing_meta_followups_test.go:91` asserts `Published != 1 || Retried != 0 || Failed != 0`. `:183` asserts `Failed != 1`. Those are process-wide counts. `cost_read_test.go:228-229` wants `len(control.Parts) != 2` and prints the CONTROL line. `hub-pg.tst.sh:206` is `store_groups()` ("a red group does not stop the next"). `:216` is `hub_groups()` with the same comment. Lines 186-195 are comments plus two `source` lines; the comments say sequential groups on the one store database and the one hub database (N12).

S2. `changed-tests.sh:40` is `always="${ORC_TEST_ALWAYS-require-cloud-env.tst.sh}"`. `check-pre-push.func.sh:645-647` on origin/master and on claim tree `01cac6fce6cba655afebd2a1f2903993b3e161e6` are the same three lines: `if grep -q '^full'`, the echo that leaves the orc map to CI workflow 10, and `args=()`. `git diff --stat 01cac6fce origin/master -- csi-spl-iac/src/bash/run/check-pre-push.func.sh` printed `31 +++++++++++++++++++------` (24 insertions, 7 deletions). Hunks are inside `_pp_run` at 1001, 1005, 1011, and 1017. The cited 645-647 did not drift (N11). `682af9225b1b78c65de4372c585717c56c522b85` (SPL-5574) is an ancestor of both the claim tree and origin/master.

S3. `git grep -nE '(cp|ln -s?f?)[^|;#]*(command -v sleep|/bin/sleep|which sleep)' origin/master -- '*.sh'` exited 1, no line. At `cc0a51eeb3b187140e88a56eb31e7d0bdc34080e`, `check-pre-push-lint-timeout.tst.sh:62` is `cp "$(command -v sleep)" "$LINT_TO_DIR/go"`. `git grep -n sleep origin/master -- csi-spl-iac/src/bash/run/check-pre-push-lint.func.sh` printed lines 597 and 608, both `sleep 0.1`.

S4. D4 log `j132712306984` lines 3234-3235 run `./run -a do_check_wui_lang_review`; line 3242 is `FATAL action(s) requested: "do_check_wui_lang_review" NOT found !!!`.

S5. `docs.test.mjs:88-91`: `page()` waits for `[data-test=docs-content]`, `data-page`, and `[data-testid=md-block][data-rendered=true]`, timeout 15000. The doc's shorthand `md-block[data-rendered=true]` is not the selector (N5). Line 451 holds `['DEPLOY.md', 'Deploying spool: choose your path']`. Line 454's note argument is `await h1(o)`. Both conditions and 15 s match. "Prints only the h1" matches line 454.

T3 / T4. `osv-scanner.toml` has 8 `[[IgnoredVulns]]`. ignoreUntil `2026-11-27`: `GHSA-vjh5-4x84-xrqp`, `GHSA-xfq5-w38q-pc2x`, `GHSA-jjm6-p2m9-9w4x`, `GHSA-gcqx-w48m-w2h4`. ignoreUntil `2026-11-30`: `GHSA-g3hv-75wg-m249`, `GHSA-3g3m-2fjr-6pw4`, `GHSA-648h-gw55-m2g7`, `GHSA-mjrq-cffv-q4qc`. Five reasons end `Real fix: nuxt 4 migration.` (`vjh5`, `xfq5`, `jjm6`, `648h`, `mjrq`). `git grep -il 'nuxt 4 migration' origin/master -- csi-spl-doc` exited 1, no file. D3 log `j132304093348` line 3306 `INFO govulncheck control (want exit 3) v1.8.0`, line 3567 `FATAL pnpm audit failed (exit 1)`, line 3583 `GHSA-mjrq-cffv-q4qc`.

T6. `fanout_encode_bench_test.go:125-129` says the frame is encoded once, the old bound counted process allocs, and under `-race` the spread was `-87..+117`, n=200 (SPL-5499).

`git log --oneline origin/master | grep -c '(ci100-'` printed 8. `grep -cE '\(ci-0[1-5]-'` printed 5.

## Check 4. Ranked rows

Formula, doc lines 244-249: U = reds per week x jobs blocked per red; reds per week = runs / 1.32 days x 7. Recount (exact, not the table's rounded figures):

| theme | reds/week | jobs/red | U | doc U |
|---|---|---|---|---|
| T1 21 runs, 39 jobs | 111.3636 | 1.8571 | 206.8182 | 207 |
| T2 7 runs, 16 jobs | 37.1212 | 2.2857 | 84.8485 | 85 |
| T4 10 runs | 53.0303 | 1 | 53.0303 | 53 |
| T3 2 runs, 6 jobs | 10.6061 | 3 | 31.8182 | 32 |
| T5 5 runs | 26.5152 | 1 | 26.5152 | 27 |
| S5 2 runs | 10.6061 | 1 | 10.6061 | 11 |
| F4 1 run | 5.3030 | 1 | 5.3030 | 5 |

Rounding is not one rule (N8). Rank order is not U order: rank 4 prints U 207 after two rows at 85. Rulebook `### 2.1 R1` on origin/master: no file path in two actions of the same batch; shared files are serialised across batches. Rows 1-7 and 9-10 name disjoint files inside batch 1. Row 8 is batch 2 and says it shares `hub-pg.tst.sh` with row 4 (N9). Row 5 kind is `spec`, red control `none (doc row)`, and the notes say it is the only doc row (N10). No row edits `.github/workflows`. Row 7 adds a test file. `git show` of the doc `| grep -n mistral` printed two lines: line 98 `| agy, mistral | 0 |` and line 103, the coding lane is claude and mistral does docs and reviews only. No mistral coding or testing row.

Job totals 39 and 16 were not rebuilt from a job list (N8).

## Check 5. Left unchecked

These stay unchecked. This seat did not re-measure them: the rates table (success and cancelled counts); T2's 150-commit measurement and whether the map at the old shas matched; T5's n=54; 18 of 73 fail-fast stops; `ubuntu-26.04` on 73 of 73; section 6 greens on `fd3b0c647`; T4 pnpm-audit versus osv expiry; F3's push green; the D7 job log; D8's orc job logs on run `43645173322`; "green 5 of 5" for F1; whether master is green now. The doc already marks the open ones unchecked.

D8 iac log `j132601343535` line 3936 did print `FAIL: 1. hung lint part -- rc=1 verdict=FAIL el=3s comm=missing part_gone=yes go_gone=yes` on run `43645173322` (sha `cc0a51eeb`). The parent `e1f8657dfce9e390793579d89f4a62dc3e60c3c3` has no wf 10 run (`[]`).

## Check 6. Hygiene

Command: `cd csi-spl-iac && ./run -a do_check_dist_hygiene` after `git add` of this file, on `1067feb463`. Exit 0. Printed `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/g-160`. The ok lines were org, personal name, OS user, home directory, mail, hidden workspace, retired relay, and no tracked `.vibe/` dir. The allowed lines were the cnf keys only.

The review blob is not in this worktree. A scan of that blob for the public sweep patterns (bank names, personal names, OS-user names, box hostnames, home-directory paths, mail domains, the retired relay token) printed 0 hits. The private overlay was not read.

## Notes

N1. The doc prints one run id (line 72). Other sampled ids were taken from `gh run list`. Full assignment of all 50 runs to rows was not redone. Section 9 says the raw rows are not in git.

N2. D4 named cause `d6bcf43095fb82c67d4e98aa1c0f266beb9eb9ea` wf 10 is push cancelled `43680212480` at `2026-11-15T05:14:25Z`. First failure sha is `26128ed71205b5a0b6c6d610fcd7ae61ee9c59f5` (run `43680713852`). `git log --oneline d6bcf4309..26128ed71` printed three docs commits (`26128ed71`, `1ff69545a`, `1f14bce2e`). The failure log matches the D4 signature. The workflow diff was not re-read.

N3. D7 named cause `035dc15012686aac430500ddbda3a5d06b456ced` wf 10 is push cancelled `43661883406` at `01:11:22Z`. First failure sha is child `d99a6febb2879288b5692769c2313647151329c4` (run `43662660943` at `01:20:51Z`). The range between them is that one commit. The D7 lane-restart log was not read.

N4. D6 range start `5eff7c9df5e01423d8eb28401807d8a9eb5bb1e0` has no wf 10 run. One docs commit (`97b08fd88`) sits between it and the first red sha.

N5. `docs.test.mjs:90` selector is `[data-testid=md-block][data-rendered=true]`, not the doc's `md-block[data-rendered=true]`. Both conditions and the 15 s timeout match. Row 9 does not tell a lane to grep the shorthand.

N6. F2 first green is 16 min 18 s (`03:28:48Z` to `03:45:06Z`), not "17..18". The second is 17 min 40 s.

N7. F1: `gh run list --commit` on `48125658af91a37f5bf39f291af11e495d8acc36` printed only push failure `43653115686`. On `dbea8ac1f9271f6571d69a12d3545edbb7c4ed92` only push failure `43702056126`. No same-sha green was found. F4 sha `9a96747b31297b10c2b00a3d2287519927af33e8` has push success `43626368359` at `18:23:51Z` and schedule failure `43628359772` at `18:45:21Z`. The green is earlier than the red.

N8. U rounding differs across rows (T3 31.8 to 32, T5 26.5 to 27, S5 10.6 to 11, F4 5.3 to 5). Rank is not sorted by U. Job counts 39 and 16 were not rebuilt.

N9. Row 8 shares `hub-pg.tst.sh` with row 4 across batches. R1 allows that. The row says so.

N10. Row 5 is kind spec with red control none. The doc discloses it.

N11. Cited `check-pre-push.func.sh:645-647` match the claim tree. `_pp_run` hunks at 1001 and after differ (`31` line stat).

N12. `hub-pg.tst.sh:186-195` are comments plus two `source` lines, and those comments do state one database per package.

N13. The cost-read CONTROL log line shows an estate row. The part count was not counted (the line is truncated in the saved extract).

N14. D8 orc conclusions on run `43645173322` were not read. The iac log on that run shows `comm=missing`.
