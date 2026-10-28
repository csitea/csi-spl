# CI panel 2026-10-28, seat grok (g-019)

Verdict on v0.1 ([ci-panel-20261028.md](ci-panel-20261028.md), commit `3bb99eda4`): **sign**. W items: none.

Git claims below were checked with `git merge-base --is-ancestor <sha> origin/master` on 2026-10-29. `origin/master` was `c2e69d1d1`. The editor's tree was `beefee4c6` .. `9699d4165`. `git diff --name-only 9699d4165 c2e69d1d1` is the panel doc plus WUI calendar and locale files. None of those paths are an F1-F4 file.

`lane-map.sh --check` on 2026-10-29, for this file and the F1-F4 paths, exited 4. No live lane lists them. Seven lanes record no files. This seat edits only this file.

## 1. What this seat measured

Command, n=100:

`gh run list --repo csitea/csi-spl --status failure --limit 100 --json databaseId,workflowName,headSha,createdAt,conclusion,displayTitle,event,url`

Window: oldest `2026-10-25T04:36:49Z`, newest `2026-10-28T19:55:42Z`.

| workflow | runs |
|---|---|
| `10_ci-quality.yml` | 75 |
| `00_deploy-lag-watch.yml` | 8 |
| `70_supply-chain.yml` | 4 |
| `20_hub-build-deploy.yml` | 3 |
| `13_ci-next-image.yml` | 3 |
| `40_tenant-host-reconcile.yml` | 3 |
| `30_wui-build-deploy.yml` | 2 |
| `45_db-backup.yml` | 2 |

Events: push 62, schedule 28, workflow_dispatch 10. Attempts: 94 first, 6 second. Branches: master 89, other 11.

Job logs: 321 of 321, `gh api repos/csitea/csi-spl/actions/jobs/<id>/logs`. `gh run view --log-failed` printed nothing on this token. A job is **stopped** when the log has `gate fail-fast` and no other FAIL, ERROR, FATAL or `##[error]` hit. Otherwise it is **red**.

| | this seat | v0.1 |
|---|---|---|
| stopped | 162 | 163 |
| red | 159 | 158 |

Three jobs have both a real FAIL hit and a fail-fast line: `122975076213`, `122966258501`, `122299601866`. This seat counts those red. That accounts for a one-job gap. It does not change a fix row.

## 2. Open rows

### F1, signed

Re-read the six `Does <env> serve this commit?` logs. Count of `age_from=commit:gh-api-failed`:

| job | created | sha | count |
|---|---|---|---|
| 121796144172 dev | 2026-10-26T19:24:56Z | f609f4d6 | 0 |
| 121796144015 prd | 2026-10-26T19:24:56Z | f609f4d6 | 0 |
| 122136784412 dev | 2026-10-27T10:27:54Z | 2d74bdd4 | 1 |
| 122136784739 prd | 2026-10-27T10:27:54Z | 2d74bdd4 | 1 |
| 122475944131 prd | 2026-10-27T21:17:54Z | 2498f3df | 1 |
| 122669134094 dev | 2026-10-28T06:29:55Z | 6389ad92 | 1 |

`f396f2ba8` is `2026-10-26T22:47:21Z`. The two zeros are before it. The four ones are after it. Same split as section 3.1.

The lag step env (`.github/workflows/00_deploy-lag-watch.yml:217-224`) is `ENV`, `SHA`, `GRACE_MINUTES`. The only `GH_TOKEN` in that file is line 155, on the `watch` job's dispatch step. The fallback is `check-deploy-lag.func.sh:203-207`.

The 2026-10-28 dev log also prints `dev wui pending ... age=32m grace=45m age_from=commit` beside the hub line `age_from=commit:gh-api-failed`. That matches `_spl_lag_age` (`check-deploy-lag.func.sh:190-191`): inside the grace it does not call `gh`. Hub ages on the four jobs: 46m, 46m, 45m, 50m, grace 45m.

Red control: as F1 in v0.1. Agree.

### F2, signed

| run | created | `startTime` in the log | verdict |
|---|---|---|---|
| 40264963172 | 2026-10-26T03:37:12Z | 2026-10-26T03:38:33.351Z | RUNNING, age_hours=0, ALERT |
| 40444881296 | 2026-10-27T03:34:04Z | 2026-10-27T03:35:28.444Z | RUNNING, age_hours=0, ALERT |

Schedule `.github/workflows/45_db-backup.yml:76` is `17 3 * * *`. The backup window starts at `01:00` (`csi-spl-iac/src/terraform/040-cloud-sql-postgres/03-cloud-sql.tf:61`). Any newest backup that is not `SUCCESSFUL` is an ALERT (`cloud-sql-backup-verify.func.sh:180-184`). Agree with F2.

### F3, signed

`_ppe_generate` is `csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh:267`, called at line 311. That file does not call `perf-budget.py`. wf 10 does, at `.github/workflows/10_ci-quality.yml:597-599`. The ceiling `ci_initial_gzip_kb` is 155.0.

Hits: 8 jobs whose first line is `FAIL ci_initial_gzip_kb 155.1 > 155`, 8 runs, 2026-10-27 00:28Z .. 01:43Z, newest sha `35bb93506d87`. Plus one AC-02 job (`121950186695`, run `40431328118`): `FAIL AC-02: the initial download is <= 155 KB gzip 155.1`, on a run that also has the gzip failure. That is 9 jobs and 8 runs, matching row 2.

`31559e80c` and `840fdec0b` are ancestors of `origin/master`. Agree with F3.

### F4, signed as measure-first

`_ppe_names` returns nothing for `src/layouts/*` (`check-pre-push-e2e.func.sh:120`). This seat did not run the pick on `46afd70ba`'s diff. The row stays off until that listing exists, as section 3.4 says.

Phone stack in these hits: the three level assertions are 7 runs and 21 jobs, newest sha `79f2eb9ef00f`. Grip is 3 runs, `gripTop` 175 against limit 119. `FAIL 2 the snackbar is gone after Undo` is a second hit on a channel-tap job, not an extra run. `8b3bcbc52` and `687b0e50d` are ancestors of `origin/master`.

## 3. Rows already fixed on origin/master

Class for each is "fixing commit is an ancestor of origin/master". No local re-run. n is jobs, then runs.

| signature | n | smell | fixing sha on origin/master |
|---|---|---|---|
| phone stack level assertions | 21 jobs, 7 runs | `mobile-overlay.test.mjs:148`, `hours-settings.test.mjs:221`, `mobile-stack.test.mjs:126` | `8b3bcbc52`, cause `46afd70ba` |
| omnibox grip `gripTop` 175 limit 119 | 3, 3 | `omnibox-grip.test.mjs` | `687b0e50d` |
| `155.1 > 155` plus one AC-02 | 9, 8 | `perf-budget.py` check, ceiling 155.0 | `31559e80c`, cause `840fdec0b` |
| reporting sha click | 6, 6 | `reporting.test.mjs:110` | `865a0cfd8` |
| desk under B not found | 4, 4 | `desk-root-readers.tst.sh:81` | `ed3c1c4a6` |
| `./run` tee line changed | 3, 3 | wd-reload-leak model | `d1549ea17` |
| tmux-health-guard | 2, 2 | `tmux-health-guard.tst.sh:189` case 5 | `273becaba` (earlier bound `87b1eb023`) |
| role seat list copy | 2, 2 | `spl-spawn-place.func.sh:575` | `a2da59555` |
| agent-user-check, early window | 7 jobs, 5 shas, 2026-10-25 04:50Z .. 06:57Z | faked CLI | `ce7f0fda3` |
| no SPOOL_ROOT | 3, 3, newest `2026-10-28T19:55:42Z` | file-stream follow | `372d72579` |
| C5 recreated file | 1 | inode | `91f6ee584` |
| osv-scanner known vulnerabilities | 3 | go-jose | `3b98831d9` |
| S4 / `REFUSED c-932: no S4 hit` | 3 jobs, 2 runs | agent-restart fixture | `4f861e051` |
| pop animation `fired:false` | 3, 3 | micro-animation e2e | `e72b7a7b5` |
| SPOOL_TEST guard `changed-only` | 3, 3 | weekly-limit-alert case 8 | `ab136899b` |
| origin/master smoke, review branches only | 8, 8 | reconcile smoke | `74f1640da` |
| go proxy INTERNAL_ERROR | 2, 2 | hermetic `go mod download` | mitigated `d78fd66a2` |
| mirror pull blip | 4 jobs, 3 runs | Caddy image pull | mitigated `709d1f32e` |
| canary key in ps.log | 1 | set-mistral-key test | `e0b6a21ab` |
| TestWorkspaceTokenCosts | 1 | model name suffix | `3730c043d` |
| an orc check skipped in CI | 1 | Mailpit walk | `4b7f554ca` |
| desk-cron-trunk false reports | 2, 2 | case 12 | `dea358a0f` |
| wf 00 `Is <env> running the cnf image?` | 11 jobs, 6 runs | watcher | `a4bd90555`; the 2026-10-28T06:29:55Z dev job is the later red v0.1 splits out |

Plants, left out of the fix rows: fontconfig `DejaVu Math TeX Gyre` and the 193.64 vs 185 label on `tmp/c-256-font-*`; wf 13 `planted host assumption: not on 26.04` on `ci-next-image/c250-red` and `c250-red2`.

wf 70, checked 2026-10-29: `gh run list --workflow 70_supply-chain.yml --branch master --limit 6`. Newest run `40678801296` succeeded at `2026-10-28T11:17:33Z` (sha `a8ffb12c`). Run `40658222806` at `2026-10-28T08:38:15Z` (sha `3b98831d9`) succeeded. Run `40654815101` at `2026-10-28T08:09:43Z` failed. Row 14's "green since 08:38Z" holds on that list. The one trivy `misconfiguration(s) found` job's inner id was not extracted.

## 4. Not re-checked

Same-sha green retries. The inner line of the WUI prd live-proof job and of the canary probe. A local re-run of any red test. None of those is required for the sign above: the open rows were re-read from the job logs and from the files v0.1 names, and the fixed rows' shas are on `origin/master`.
