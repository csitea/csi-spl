# Refactoring round 3 - retrospective

Measured 2026-10-06T09:31:12Z. Doc only. Each count names the command that produced it. n is that count.

Plan: `csi-spl-doc/doc/md/refactor-round-3-plan.md`, baseline trunk `755e86235`. 30 practices and 19 behaviour bugs (plan section 4). The plan already marked six bugs (B7, B10, B11, B12, B13, B15) as fixed by an earlier row.

## 1. What landed

`git log origin/master --grep=r3- --oneline | wc -l` at 2026-10-06T09:31:12Z returned **45**. The same command returned 45 at the brief (09:2xZ), and again at 2026-10-06T09:35:17Z after `git fetch origin master` (trunk `6e8b5957d`). No r3 commit landed between the three counts.

| bucket | n | how |
|---|---|---|
| practice rows with at least one commit | 30 of 30 | one subject `refactor(r3-NN)` each, except row 12 |
| row 12 commits | 4 | `77c42ef95`, `de110b9ce`, `2499c6e0f`, `4b8c3ee9d`, one lane |
| practice commits | 33 | 30 rows + 3 extra on row 12 |
| bugs with their own commit | 11 | B01, B02, B03, B05, B06, B08, B14, B16, B17, B18, B19 |
| bugs carried inside another bug's commit | 2 | B04 inside `be5e2d5e1` (B02); B09 inside `8164c269c` (B08) |
| B16 follow-up commit | 1 | `faf1031eb` after `1aba02377` |
| bugs verified already fixed, no commit | 6 | g-355, below |
| bug commits | 12 | 11 first commits + the B16 follow-up |
| rows or bugs with neither a commit nor a verify | 0 | |

45 = 33 practice commits + 12 bug commits.

`git show --name-only` on those 45 commits: 15 paths appear under two row ids. Fourteen of those are the planned order (a bug after the row that owns the file, or rows 13 and 28 sharing `tf-destroy-local-step-bucket.func.sh`). The fifteenth is `.shellcheck-warning-baseline.txt`, in rows 27, 28, 29 and B18. Section 4.

## 2. Lanes

Lane id and kind come from `registry.tsv` / `registry.retired.tsv` on the box that spawned the lane, joined to the row by the spawn-request slug, the lane's result mail, or the session transcript. Kind is the registry column. No agy lane: 0 rows in either registry with kind `agy` for these ids.

Spawn is the registry stamp. Land is the committer time of the row's last r3 commit, converted to UTC (`git log --format=%cI`). Minutes are spawn to that land, rounded.

| row | lane | kind | box | spawn | land | min | live |
|---|---|---|---|---|---|---|---|
| 01 | c-299 | claude | satellite | 2026-10-05T04:55:38Z | 2026-10-05T05:57:38Z | 62 | 2026-10-05T06:10:44Z hub |
| 02 | c-300 | claude | satellite | 2026-10-05T04:55:39Z | 2026-10-05T05:35:07Z | 39 | 2026-10-05T05:46:41Z hub |
| 03 | c-301 | claude | satellite | 2026-10-05T04:55:39Z | 2026-10-05T05:40:15Z | 45 | 2026-10-05T05:54:44Z hub |
| 04 | c-302 | claude | satellite | 2026-10-05T04:55:40Z | 2026-10-05T05:46:40Z | 51 | 2026-10-05T05:58:04Z hub |
| 05 | c-278 | claude | primary | 2026-10-05T04:56:05Z | 2026-10-05T05:04:29Z | 8 | 2026-10-05T05:14:23Z hub |
| 06 | c-279 | claude | primary | 2026-10-05T04:57:09Z | 2026-10-05T05:12:13Z | 15 | 2026-10-05T05:15:44Z wui |
| 07 | c-280 | claude | primary | 2026-10-05T04:58:05Z | 2026-10-05T05:29:53Z | 32 | 2026-10-05T05:33:25Z wui |
| 08 | c-281 | claude | primary | 2026-10-05T04:59:05Z | 2026-10-05T05:33:22Z | 34 | 2026-10-05T05:37:04Z wui |
| 09 | c-282 | claude | primary | 2026-10-05T05:00:06Z | 2026-10-05T05:36:24Z | 36 | 2026-10-05T05:39:42Z wui |
| 10 | c-283 | claude | primary | 2026-10-05T05:01:05Z | 2026-10-05T05:22:04Z | 21 | 2026-10-05T05:25:47Z wui |
| 11 | g-303 | grok | satellite | 2026-10-05T04:55:41Z | 2026-10-05T05:50:15Z | 55 | land (bash) |
| 12 | c-304 | claude | satellite | 2026-10-05T04:55:41Z | 2026-10-05T05:54:54Z | 59 | land (bash) |
| 13 | c-305 | claude | satellite | 2026-10-05T04:55:42Z | 2026-10-05T06:10:39Z | 75 | land (bash) |
| 14 | g-306 | grok | satellite | 2026-10-05T04:55:43Z | 2026-10-05T06:04:40Z | 69 | land (bash) |
| 15 | g-284 | grok | primary | 2026-10-05T05:02:09Z | 2026-10-05T05:34:28Z | 32 | land (bash) |
| 16 | g-285 | grok | primary | 2026-10-05T05:03:07Z | 2026-10-05T05:35:41Z | 33 | land (bash) |
| 17 | c-296 | claude | primary | 2026-10-05T06:46:05Z | 2026-10-05T07:23:50Z | 38 | 2026-10-05T07:36:42Z hub |
| 18 | c-299 | claude | primary | 2026-10-05T07:34:06Z | 2026-10-05T08:01:21Z | 27 | 2026-10-05T08:15:47Z hub |
| 19 | c-319 | claude | primary | 2026-10-05T19:30:58Z | 2026-10-05T20:17:40Z | 47 | 2026-10-05T21:37:41Z hub |
| 20 | c-336 | claude | primary | 2026-10-05T21:28:07Z | 2026-10-05T21:35:45Z | 8 | 2026-10-05T21:43:10Z wui |
| 21 | c-337 | claude | primary | 2026-10-05T21:53:22Z | 2026-10-05T22:06:00Z | 13 | 2026-10-05T22:13:17Z wui |
| 22 | g-320 | grok | primary | 2026-10-05T19:36:06Z | 2026-10-05T19:59:02Z | 23 | 2026-10-05T21:24:03Z wui |
| 23 | c-338 | claude | primary | 2026-10-05T21:55:00Z | 2026-10-05T22:02:48Z | 8 | 2026-10-05T22:09:44Z wui |
| 24 | c-341 | claude | primary | 2026-10-06T02:43:19Z | 2026-10-06T04:11:11Z | 88 | 2026-10-06T04:31:31Z wui |
| 25 | g-342 | grok | primary | 2026-10-06T02:43:23Z | 2026-10-06T03:39:11Z | 56 | 2026-10-06T04:31:31Z wui |
| 26 | g-343 | grok | primary | 2026-10-06T02:43:27Z | 2026-10-06T04:04:13Z | 81 | 2026-10-06T04:31:31Z wui |
| 27 | g-319 | grok | satellite | 2026-10-05T07:34:06Z | 2026-10-05T07:55:05Z | 21 | land (bash) |
| 28 | g-313 | grok | satellite | 2026-10-05T06:47:49Z | 2026-10-05T07:29:46Z | 42 | land (bash) |
| 29 | g-329 | grok | satellite | 2026-10-05T09:14:52Z | 2026-10-05T09:44:28Z | 30 | land (bash) |
| 30 | g-344 | grok | primary | 2026-10-06T02:43:31Z | 2026-10-06T04:00:48Z | 77 | land (bash) |

Practice lanes: 19 claude, 11 grok, 0 agy (n=30). The plan named row 17 as grok. The lane that landed it is claude c-296: registry kind `claude`, and the session transcript carries the slug `r3-17-go-errors-new`.

Spawn to land, n=30, row 12 counted at its fourth commit: min 8, median 38, mean 41.5, max 88 (row 24).

How the id was tied to the row:

- Satellite rows 01-04, 11-14, 27-29: the lane's own result mail names the row and the sha.
- Primary rows 05-10, 17, 18: spawn-request slug order matches registry order, and the session transcript repeats the slug (`r3-05` through `r3-10`, `r3-17`, `r3-18`). Outboxes for 05-10, 15 and 16 are empty (0 json files).
- Rows 15, 16, 22, 25, 26, 30 and the bug lanes below: the retired identity record's `title` is the row slug.
- Rows 19-21, 23, 24: the result mail names the row.

Live, for a hub or WUI commit, is the `updatedAt` of the first successful run of workflow `20_hub-build-deploy.yml` (any path under `csi-spl-api/`) or `30_wui-build-deploy.yml` (any path under `csi-spl-wui/`) whose head contains the commit (`git merge-base --is-ancestor`). Lists: `gh run list --workflow <file> --created 2026-10-05 --limit 80`, plus the first three hub runs and the first eight WUI runs on 2026-10-06. Two local deploys are not in that list. c-360's result at 2026-10-06T04:31:31Z proved hub `32edac5d1` and then WUI `60d8049de` on dev and prd, n=3 each. Those two shas are included as deploys at that timestamp. A bash commit has no image, so live is land. Workflow 20 pushes dev, then prd, in one run (the workflow file). Historical runs were not re-probed on the hosts. At 2026-10-06T09:31:12Z the running images match across hosts: hub `0200d7c8` built 2026-10-06T09:01:18Z, version 1.6.5, dev and prd `/version` (n=1 each); WUI `67c98d58` version 1.6.7, dev `build.json` built 2026-10-06T09:18:53Z and prd built 2026-10-06T09:18:58Z (n=1 each). Every one of the 45 commits is an ancestor of both of those shas.

### Bugs

| bug | lane | kind | spawn | land | live |
|---|---|---|---|---|---|
| B01 | c-345 | claude | 2026-10-06T02:43:35Z | 2026-10-06T03:09:52Z | 2026-10-06T09:11:11Z hub |
| B02 + B04 | c-346 | claude | 2026-10-06T02:43:38Z | 2026-10-06T03:28:01Z | 2026-10-06T09:11:11Z hub |
| B03 | c-347 | claude | 2026-10-06T02:43:42Z | 2026-10-06T02:54:54Z | 2026-10-06T04:31:31Z hub |
| B05 | g-348 | grok | 2026-10-06T02:43:46Z | 2026-10-06T03:14:43Z | 2026-10-06T09:11:11Z hub |
| B06 | g-349 | grok | 2026-10-06T02:43:50Z | 2026-10-06T03:27:00Z | 2026-10-06T04:31:31Z wui |
| B08 + B09 | g-350 | grok | 2026-10-06T02:43:54Z | 2026-10-06T03:56:28Z | 2026-10-06T04:31:31Z wui |
| B14 | g-351 | grok | 2026-10-06T02:43:58Z | 2026-10-06T03:00:13Z | land (bash) |
| B16 | c-352 | claude | 2026-10-06T02:44:03Z | 2026-10-06T02:49:28Z | land (bash) |
| B16 comment | g-361 | grok | 2026-10-06T04:06:03Z | 2026-10-06T04:09:09Z | land (bash) |
| B17 | c-353 | claude | 2026-10-06T02:44:06Z | 2026-10-06T03:22:09Z | land (bash) |
| B18 | g-362 | grok | 2026-10-06T04:08:44Z | 2026-10-06T04:19:11Z | land (bash) |
| B19 | g-354 | grok | 2026-10-06T02:44:11Z | 2026-10-06T02:51:57Z | land (bash) |
| B7, B10, B11, B12, B13, B15 | g-355 | grok | 2026-10-06T02:44:44Z | none | verified 2026-10-06T02:52:48Z |

g-355 read trunk `c11eb9a9a` and ran one test per bug (n=1). All six passed. No follow-up lane. The fixes it names: B7 and B12 in `65ca14703` (row 08), B10 in `33962b3cc` (row 23), B11 in `eb6e4a1f0` (row 07), B13 in `39135e921` (row 13), B15 in `77c42ef95` (row 12).

## 3. CI

`cd csi-spl-iac && CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (workflow `10_ci-quality.yml`), finished exit 0. Window: last 200 runs, 2026-10-05T05:00:32Z .. 2026-10-06T09:19:23Z.

| conclusion | runs |
|---|---|
| cancelled | 147 |
| failure | 31 |
| success | 20 |
| running | 2 |

Failures per job, across those 31 runs (one run fails several jobs):

| job | n |
|---|---|
| wui: browser e2e (mock, generated) 3/3 | 29 |
| wui: browser e2e (mock, generated) 2/3 | 27 |
| wui: browser e2e (mock, generated) 1/3 | 27 |
| orc: hermetic action tests | 24 |
| hub: gofmt, go vet, go test, smoke, Postgres + GCS gates | 23 |
| iac: tfvars parity, step contracts, terraform validate | 11 |
| wui: unit tests + typecheck | 4 |
| wui: nuxt generate (mock tenant) | 3 |
| cnf: conf-validator exit codes | 1 |

Of the 31 failure runs, **2** have an r3 commit as `headSha`.

| head | run | created | what the first FAIL line shows |
|---|---|---|---|
| `c12f01ab` (row 25) | 37410630611 | 2026-10-06T03:47:22Z | iac, hub, orc, and all three e2e shards failed. The iac line the gate printed is `PASS: 1. green trunk + break -> FAIL (blocks)`, which is the pin test's own expected-failure text, not a new assertion. g-342's result on this sha says that iac failure is the pin test owned by the deploy lane, and that hub, orc and the e2e shards then stopped with the run. |
| `8164c269` (B08) | 37411366238 | 2026-10-06T03:56:49Z | orc, plus e2e shards 1/3, 2/3 and 3/3. The orc line is `PASS: a failed post: exit 1, one FAIL line in the log`. The e2e lines are `build-watch.test.mjs` (129s) and a selector wait on channel mid. B08's commit is the workspace-docs mock retry and TopicPane i18n. Neither signature names those files. |

The gate file has 0 lines containing `curl-time-bounded`. The red an r3 commit did cause is not in those two heads. It is B16, section 4.

147 of 200 runs cancelled: a later push superseded the run. That is what 45 commits in one day do to a gate that cancels the previous head. It is not 147 defects.

## 4. The five lessons

### 4.1 Parallel work on disjoint files

Confirmed for batch 1, with one later miss.

Batch 1 is rows 01-16. Satellite spawned 8 of them within 5 seconds (2026-10-05T04:55:38Z through 04:55:43Z). The primary box spawned the other 8 from 04:56:05Z to 05:03:07Z, about a minute apart. `git show --name-only` on those 16 rows' commits: **0** paths shared by two of the 16. n=16 rows.

The shared paths in section 1 are later. Rows 13 and 28 share one file and were serial (row 13 landed 06:10:39Z, row 28 spawned 06:47:49Z). The bug lanes touch the row's file after that row, which the plan required. `.shellcheck-warning-baseline.txt` is the path the plan's per-site check did not name. Rows 27 and 28 overlapped by 3 minutes (g-319 spawned 07:34:06Z, g-313 retired 07:37:48Z). Each of 27, 28, 29 and B18 has one commit, so the share did not produce a second commit. n=1 commit each.

The same row was spawned on both boxes. Slug `r3-28` was requested on the primary at 2026-10-05T06:45:35Z in the same second as `r3-17`. c-296 took `r3-17` (transcript). c-297 spawned one second later (06:46:06Z) and is the other of that pair. On the satellite, g-313 spawned 06:47:49Z with title `r3-28-bash-nofork-trim-iac` and landed `947aacbfd`. c-297's outbox has 0 files, its worktree is gone, its pane is gone, and its registry row is still live. One landed commit, one empty lane.

### 4.2 A comment-only change broke a test

Confirmed. `1aba02377` (c-352, B16, landed 2026-10-06T02:49:28Z) moved the bearer token off curl's argv and reworded the comment in `spl-db-health.func.sh`. c-352's result ran `gandi-livedns.tst.sh` and `spl-db-health.tst.sh`, 21 to 25 PASS each, n=1, and did not name `curl-time-bounded.tst.sh`.

The queue and c-360's result both say that comment broke `curl-time-bounded.tst.sh`, and c-360 routed it to g-361. g-361 landed `faf1031eb` at 2026-10-06T04:09:09Z (spawn 04:06:03Z, 3 minutes). After that commit the suite exits 0, n=1: 24 PASS, including `metrics comment no longer says the token is never in argv` and `metrics comment records the -K move as a behaviour change`. The gate extract in section 3 does not print that test (0 matches), because the failing run's head was not `1aba02377`.

### 4.3 Landed fixes waited on "deploy pending"

Confirmed for the pause, not for the morning.

Workflows 20, 21 and 30 were disabled about 2026-10-06T02:53Z, with re-enable set for 08:48Z (the queue file). `gh run list` shows the gap. The last successful WUI run before it is `c11eb9a9a` updated 2026-10-05T22:50:22Z. The next GitHub WUI success is `75d46f760` updated 2026-10-06T08:52:12Z. The last successful hub run before the evening stall is `c0b5c1d65` updated 2026-10-05T21:47:50Z. The next GitHub hub success is `0200d7c8` updated 2026-10-06T09:11:11Z. Row 19's own hub run, head `272da60fa`, is a failure at 2026-10-05T20:27:10Z. It went live on the next success that contains it, 21:37:41Z.

The local deploy covered part of the gap. c-360 at 2026-10-06T04:31:31Z: hub `32edac5d1` on dev and prd, n=3, then WUI `60d8049de` on dev and prd, n=3. That WUI sha contains rows 24, 25, 26 and bugs B06 and B08, so those five were live 20 to 64 minutes after they landed. That hub sha contains B03 and does **not** contain B01 `fae084628`, B02 `be5e2d5e1` or B05 `ea1b2ab8e` (`git merge-base --is-ancestor` exits non-zero). Those three hub fixes landed 03:09:52Z to 03:28:01Z and next appear in hub `0200d7c8`, run updated 09:11:11Z. Wait about 5 hours 43 minutes to 6 hours 1 minute, and the 04:31 hub image did not carry them.

Morning rows were not in this wait. Rows 01-10 went live 3 to 14 minutes after land (the table). The long waits are row 19 (its own run failed, next success 80 minutes after land) and row 22 (WUI gap, live 85 minutes after land), then the pause.

The lanes also stayed seated after land. At 2026-10-06T09:31:12Z, tmux still has windows for c-345, c-346 and c-347, and all three are still in `registry.tsv` (spawn 02:43Z). Their last outbox notes are 03:48Z to 03:49Z and say deploy pending. B03 has been in the running hub since 04:31:31Z. B01 and B02 have been in it since 09:11:11Z. g-348's window was still up at 09:26:44Z and was gone by 09:31:12Z, so that lane sat about 6 hours 12 minutes after it landed at 03:14:43Z.

### 4.4 A hand-kept status table went stale

Confirmed. `stat` on `/var/spool-hub/dispatch/r3b3-queue.md`: mtime 2026-10-06T04:08:52Z. Read again at 09:31:12Z, same mtime. The file still says row 24 is running and B18 is running. Row 24 landed `60d8049de` at 04:11:11Z. B18 landed `a44659e58` at 04:19:11Z. The table is 5 hours 22 minutes behind those two commits, and it still says rows 25 and 26 are deploy pending after both were in the WUI image at 04:31:31Z.

### 4.5 Six bugs were already fixed by earlier rows

Confirmed. The plan said so before any bug lane spawned. g-355 verified all six (section 2), n=1 test each, and opened no fix lane. It was spawned at 02:44:44Z, 69 seconds after the first bug lane (c-345 at 02:43:35Z), so the verify ran beside the wave rather than before it. The queue had already marked those six "verify only", which is why no fix lane was wasted.

## 5. Rework, stalls, re-seats

Rework that took a second commit:

- Row 12, still one lane. c-304's result names all four shas. The fourth, `4b8c3ee9d`, is an SC2064 disable on the site the third commit had just edited. Not a second lane.
- B16, a second lane. g-361, one commit, 3 minutes. Section 4.2.

No other r3 subject has a second lane. n=2 rows with more than one commit (row 12 has four, B16 has two).

Stalls and re-seats:

- c-305 (row 13) sent a blocker at 2026-10-05T05:36:10Z: blocked on the push, not on the code. The commit landed 06:10:39Z. Result 06:22:12Z. That lane is the slow batch-1 row (75 minutes) and the time went into the push.
- c-299 on the primary (row 18) has two retired registry rows, same retire time 2026-10-05T10:04:55Z. First spawn 07:34:06Z. Second spawn 09:55:27Z, different pane. The only commit is `8992f7c7a` at 08:01:21Z, before the second spawn. The re-seat did not add a commit.
- c-297, section 4.1. Registry row still live at 09:31:12Z, 26 hours 45 minutes after spawn, with no worktree and no pane.
- c-345, c-346, c-347 still seated at 09:31:12Z. Section 4.3.

## 6. Round 4

Each one is a rule, a gate or an action. The owner is who changes the process.

1. **Rule.** The status table is `git log origin/master --grep=<round>`, not a hand-edited file. Generate it at post time. Owner: the lane that posts the round. The hand file in section 4.4 is the cost (5 hours 22 minutes stale, two rows marked running after they had landed).
2. **Gate.** A change under `spl-db-health.func.sh` runs `curl-time-bounded.tst.sh` before push, including a comment-only diff. Owner: the pre-push selector. The miss is section 4.2: the lane ran the two suites it named and not the suite that reads the comment.
3. **Rule.** A row lane exit-cleans when the commit is on trunk. One deploy lane proves live and names the sha it actually built. Owner: the orchestrator, in the row brief. The cost is section 4.3: three lanes still seated at 09:31:12Z, and the 04:31 hub image left B01, B02 and B05 out.
4. **Rule.** Run the already-fixed verify, and drop those bugs from the spawn list, before the bug wave. Owner: the orchestrator. This round's verify was right and 69 seconds late (section 4.5). The part to keep is "no fix lane". The part to move is "before".
5. **Gate.** A row slug cannot be spawned on a second box while the first spawn is live. Owner: the spawn path. The miss is c-297 beside g-313, both on `r3-28` (section 4.1).
6. **Rule.** The disjoint check includes generated files, not only the sites in the plan. `.shellcheck-warning-baseline.txt` was in four rows (section 1). Owner: whoever writes the next plan. Serialise those rows, or give the baseline to one follow-up lane.

## 7. Commands

Re-run from a checkout of `origin/master`. Registry and mail paths are on the box that spawned the lane.

```text
git log origin/master --grep=r3- --format='%H %cI %s'
git show --name-only --format= <sha>
git merge-base --is-ancestor <commit> <deploy-sha>
gh run list --workflow 10_ci-quality.yml --limit 200
gh run list --workflow 20_hub-build-deploy.yml --created 2026-10-05 --limit 80
gh run list --workflow 30_wui-build-deploy.yml --created 2026-10-05 --limit 80
```

CI per job: `cd csi-spl-iac && CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate`.

Lane stamps: `registry.tsv` and `registry.retired.tsv` (columns id, kind, pane, worktree, spawned). Result mail: the lane's `outbox`. The queue file's mtime is `stat` on `/var/spool-hub/dispatch/r3b3-queue.md`.
