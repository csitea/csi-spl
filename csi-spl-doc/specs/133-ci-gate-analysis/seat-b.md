# 133 seat B: red causes, and why pre-push missed them

Seat B, agent g-858, 2026-10-12. Doc only. Draft v0.1.

> Owner: "I thought we had the functionality to not test everything when only
> a certain part of the system is changing."

**Short answer.** The completed master gate was red for **76.8 of 82.8 h**
(92.8 %, 11 streaks, n=127 finished verdicts). Pre-push did not catch the reds
because three of the loudest CI jobs have **no local part** (browser e2e,
`nuxt generate` / the perf budget, orc feature tests: **97 of 209** first-red
job rows, 46 %), and the parts that do exist run only when the push touches
them, so a green local push still lands on a trunk whose other suites are
already red. One ceiling is measured: `ci_initial_gzip_kb` **155.1 > 155**
(n=2 logs), and **31 of 31** generate jobs that were a first-red failed on
that budget step.

## 0. How this was measured

Window: workflow `10_ci-quality.yml` on `master`, the newest 1000 runs the
list API returned.

```text
gh api --paginate \
  "/repos/csitea/csi-spl/actions/workflows/10_ci-quality.yml/runs?branch=master&per_page=100"
```

Pulled 2026-10-12T06:41Z. n=1000. Oldest created `2026-10-08T19:50:22Z`, newest
`2026-10-12T06:36:15Z` (82.8 h; the page cap, not a full 100 h). Conclusions:
871 cancelled, 109 failure, 18 success, 2 still empty.

A **verdict** is a run whose conclusion is `failure` or `success`. Cancelled
is superseded (`cancel-in-progress: false` in `.github/workflows/10_ci-quality.yml`,
the comment at the concurrency block). A **red streak** is consecutive failure
verdicts, ended by the next success. Time to green is the success run's
`updated_at` minus the first failure's `created_at`.

The same slice since `2026-10-10T06:00Z` is n=639: 586 cancelled, **48 failure,
3 success**, 2 empty. The 48 and the 3 match the panel's c-002 count. The
cancelled total differs (586 here, 577 there): different list cut, same
completed reds.

**First-red** is a failed, timed-out or runner-lost job whose check-run
annotations do **not** contain `gate fail-fast: stopped` (that annotation is
what `csi-spl-orc/src/bash/scripts/gate-fail-fast.sh` writes on a job it
killed). Timeout = annotation `exceeded the maximum execution time`.
Runner-lost = annotation `lost communication with the server`. Coverage:
**96 of 109** failure runs (13 jobs payloads timed out on the API). Annotation
fetches also timed out on some jobs (37 error lines): a stopped job whose
annotation never loaded is counted as a first-red, so a multi-job row is an
upper bound.

File claims below are `grep` on worktree `15fe61d85`, then again after
rebase onto `origin/master` at `8c4f2c4fe`. The five counts and the two line
numbers (114, 560) did not move.

This box's pre-push log (`~/.cache/csi-spl/pre-push.log`, lines with
timestamp >= `2026-10-08T19:50:00Z`, n=32700 lines) is **this box only**.
61 of 109 failure shas have no line in it.

## 1. The 11 streaks

| streak | n runs | first red sha | first-red jobs (covered runs) | cause | to green | completing green |
|---|---:|---|---|---|---:|---|
| R1 | 1 | `fecc09693a` 2026-10-08T20:01Z | orc hermetic (hand-checked: hub and e2e were fail-fast stops) | orc, then fixed in-range | 1.01 h | `7c9af075fa` full gate |
| R2 | 2 | `63defac426` 2026-10-08T23:47Z | orc hermetic, both runs | orc hermetic | 3.26 h | `60b7f4f9ff` full gate |
| R3 | 1 | `a56c163131` 2026-10-09T03:33Z | orc feature tests | suite with no local part | 0.82 h | `eba44c18e4` full gate |
| R4 | 17 | `2abdeed4d5` 2026-10-09T05:03Z | generate 5, orc hermetic 3, e2e 2, mixes (14/17 covered) | budget + orc + e2e | 6.13 h | `c8a9a10c60` full gate |
| R5 | 9 | `9900bfae34` 2026-10-09T11:08Z | unit+generate 3, unit 2, mixes (8/9) | unit tests and the budget | 1.43 h | `edcca0da39` full gate |
| R6 | 5 | `5d7400ce6d` 2026-10-09T12:59Z | iac+orc 2, orc, hub+orc, hub+iac+orc | iac, orc, hub together | 1.52 h | `bfb1ca83e9` full gate |
| R7 | 24 | `9a66ca85ae` 2026-10-09T15:39Z | iac 3, orc features 2, e2e+orc 2, mixes; 1 runner-lost, 1 timeout (20/24) | several suites on one red trunk | 12.07 h | `f008343938` full gate |
| R8 | 1 | `892f26545d` 2026-10-10T03:34Z | e2e shard 3 | e2e flake, n=1 | 2.40 h | `2611990753` full gate |
| R9 | 44 | `3ca4c2cae5` 2026-10-10T05:57Z | iac 5, e2e+iac+orc-features 3, generate 3, e2e+hub+orc 3, e2e+orc 3; **17 timeout, 2 runner-lost** (42/44) | overlapping defects plus load | 42.51 h | `33d505c7df` full gate |
| R10 | 2 | `f88e3a0790` 2026-10-12T00:26Z | e2e (1/2 covered) | e2e, no local part | 2.34 h | `460398ada8` full gate |
| R11 | 3 | `a9b5c5f403` 2026-10-12T02:45Z | orc hermetic (1/3 covered) | orc hermetic | 3.35 h | `48ed9c1314` full gate |

Full gate means the code jobs (hub, orc hermetic, orc features, wui unit,
nuxt generate, e2e, iac) concluded `success`, and 2 jobs were `skipped`
(the pattern on every success whose jobs payload returned). Job counts are
9, 10 or 14 across the window because orc hermetic gained a second shard.
R1's green `7c9af075fa` is 12 success / 2 skipped, 9 of them code. R2's
green `60b7f4f9ff` is 13 success / 2 skipped, 10 of them code. The other
greens in the table were read the same way (14 success / 2 skipped). Three
extra success runs that sit between streaks (`ed6d613e6e`, `d0167e3922`,
`ff2ea05e43`) timed out on the jobs API and are not classified.

The completing green is the first sha whose run **finished** success. It is
not always the commit that fixed the suite: a newer push supersedes the
pending run, so the fix's own run is often cancelled. R1's range
`fecc09693a..7c9af075fa` contains orc commits (`cee3be46a` "fix(orc): m-
lanes report running", `91bb7f4f5`, `b56fb7e2c`) and the green itself is a
doc commit (`git diff-tree --name-only -r 7c9af075fa` -> one `tasks.md`).
R7's green subject names the fix: `f008343938` "fixed in `c52eed566`", and
`git log -1 --format=%s c52eed566` -> `fix(hub): spec 112 - the deploy sync
never prunes an in-app goal`.

### 1.1 Who landed the green

Sat worktree is named only when this box's hook log has a summary `PASS`
line for that sha. Otherwise the lane is not on this box.

| streak | first-red push | green / the fix the subject names |
|---|---|---|
| R1 | `c-582`, summary PASS in 13 s, paths `AGENTS.md` + `fleet-rules-index.md` | green is a doc sha; orc commits in the range as above |
| R2 | `c-608`, summary PASS, one spec `tasks.md` | `c-620`, summary PASS, spec 113 review md |
| R3 | `c-622` logged SKIP-WIP for this sha | `eba44c18e4` touches `spawn-mistral.sh` (orc features) |
| R4 | no sat log; bench files under spec 113 | `c8a9a10c60` `login.vue` only |
| R5 | no sat log; wui body-time files | `edcca0da39` "LiveTopicPane.vue header back (6 unit files red on trunk)" |
| R6 | no sat log; one orc func | `bfb1ca83e9` splits `spl_doc_tree_repair_sql` |
| R7 | no sat log; hub calendar files | `c-706` pushed the doc green; fix named `c52eed566` |
| R8 | `c-706`, summary PASS in 1 s; orc + spec 115, no wui | `c-707`, summary PASS; orc only, no wui |
| R9 | `c-682` has a PART line for `3ca4c2cae` (blog check + spec) | `33d505c7df` wui scroll anchor; no sat log |
| R10 | no sat log; two spec mds | `460398ada8` wui doctree |
| R11 | no sat log; orc asks tick | `48ed9c1314` desk-role fix |

## 2. Real defects, and why the local gate missed them

A first-red **job row** is one job on one run (a run with two red suites
counts twice). n=209 rows on 96 runs.

| job (shard collapsed) | failure | timeout | runner-lost |
|---|---:|---:|---:|
| wui browser e2e | 48 | 11 | 2 |
| orc hermetic | 39 | 5 | 0 |
| wui nuxt generate | 31 | 0 | 0 |
| iac suite | 28 | 0 | 1 |
| orc feature tests | 18 | 0 | 0 |
| hub suite | 16 | 0 | 0 |
| wui unit + typecheck | 8 | 2 | 0 |

### 2.1 No local part (46 % of first-red rows)

`grep -c` on `csi-spl-iac/src/bash/run/check-pre-push.func.sh`:

| what CI runs | command | result |
|---|---|---|
| `pnpm run generate` / the budget | `grep -c 'nuxt generate\|pnpm run generate'` | 1, and it is a comment (line 114), not a command |
| `perf-budget.py` | `grep -c perf-budget` | 0 |
| browser e2e | `grep -c test:e2e` | 0 |
| orc feature tests | `grep -c run-ci-tests` | 0 |
| the wui part's actual command | `grep -n 'run test:unit'` | line 560, then `run typecheck` |

`_pp_part_wui` runs `pnpm run test:unit` and `pnpm run typecheck`.
`_pp_part_orc` runs `csi-spl-orc/src/bash/tests/run-all-tests.sh` (hermetic,
`--changed` on the fast tier) plus `bash-cleancode.tst.sh`. It does not call
`csi-spl-orc/src/bash/features/run-ci-tests.sh`, which is the CI job
`orc-features` (workflow comment at the `orc-suite` job: feature tests are
the job below).

On the 38 failure shas that have both a first-red list and a sat summary
PASS, the unmapped jobs are: generate 13, e2e 12 failures + 2 runner-lost
+ 1 timeout, orc features 9.

**The budget, measured.** Every generate job that was a first-red failed in
the step `Initial JS gzip stays within the performance budget`: **31 of 31**,
0 API misses. Two logs:

| run | sha | when | line |
|---|---|---|---|
| 37921855024 | `9900bfae34` | 2026-10-09T11:12Z | `FAIL ci_initial_gzip_kb 155.1 > 155` and `FAIL ci_home_gzip_kb 352.9 > 352.1` |
| 38121286726 | `3f0949fbdc` | 2026-10-11T07:24Z | `FAIL ci_initial_gzip_kb 155.1 > 155` (home 351.0 was under the 352.1 cap) |

The initial-JS ceiling is 0.1 KB under the build. Later full gates did pass
generate (the greens in section 1), so the tree does go back under 155, and
then crosses it again. Pre-push cannot see it.

**E2e, one opened log.** Run 38021028676, sha `892f26545d` (R8, an orc
commit, `git diff-tree --name-only` has no `csi-spl-wui/`):

```text
FAIL tests/e2e/calendar-phone.test.mjs (exit 1, then exit 1 on retry)
phone-back-matrix: 52/72 passed, 20 known red, 0 failed
```

The only commit between that sha and the green `2611990753` is the green
itself, and it does not touch `csi-spl-wui` (`git diff --name-only
892f26545d 2611990753 -- csi-spl-wui` is empty). The suite failed, then
passed, with no wui change. n=1. That is a flake, not a rate.

### 2.2 The part exists, and the push did not run it

Fast tier selects by path (`check-pre-push.func.sh` header: a push that
touches none of a part's paths logs `SKIP-untouched`). CI runs every code
job unless classify proves doc-only since the last **green**
(`ci-doc-only.sh`: every path is `*.md` outside `csi-spl-wui/**` and
`.github/**`). A doc or wui push can be locally green while iac, api and
orc stay red in CI, and the red trunk then lasts until some later run
finishes green.

On those 38 sat PASS shas, the local part versus the CI first-red:

| CI job | local part on that sha | n |
|---|---|---:|
| iac | `SKIP-untouched` | 8 |
| api (hub) | `SKIP-untouched` | 8 |
| orc hermetic | `SKIP-untouched` | 3, plus 1 timeout |
| wui unit | `SKIP-untouched` | 2 |
| orc hermetic | `PASS` (fast tier, not the full file list) | 1 |
| iac | `PASS` | 1 |
| orc hermetic | no PART line in the log | 9 |

The two local `PASS` then CI failure rows are the only measured
false-greens of a part the hook actually ran (n=2 job rows). The fast orc
tier runs the tests that name a touched file and leaves the full list to CI
when the map says `full` (`_pp_part_orc`). One local PASS does not mean the
CI shard list passed.

R1 is the clean example. `fecc09693a` is two markdown paths. `c-582`'s hook
summary is PASS in 13 s (hygiene and the lint parts; orc is not selected).
The completed CI run's real red, read from annotations by hand, is orc
hermetic. Hub and the three e2e shards carry `gate fail-fast: stopped`.

### 2.3 Override, and the waiver that keeps a streak alive

Sat worktree overrides in the window (hook line `SPL_PREPUSH_OVERRIDE=1`,
path under `/opt/csi/csi-spl-wt/`, not `/tmp`): **12 lines, 8 shas, 7
lanes** (`c-574`, `c-643`, `c-649`, `c-668`, `c-682`, `c-695`, `c-686` four
times, `c-721`). One of those shas is itself a completed failure:
`c752eb74e`, `c-686`, `2026-10-09T23:31:14Z`. The other 11 `/tmp` override
lines are the hook's own tests (broken-git-config drill), not pushes.

`WARN-pre-existing` lets a push land when the same failure items already
fail on trunk (section 1.3 of `csi-spl-doc/doc/md/pre-push-gate.md`). In
this box's log for the window: orc 20, iac 14, api 2. Those are attempts,
not landed shas. It is why R9 can stay red for 42.5 h while other lanes
keep pushing: a new commit does not have to turn the red suite green.

## 3. Flakes, with n

A flake here is a red that the next full gate does not reproduce, on a tree
that did not change that suite, or a job that died from the clock or the
runner rather than an assertion.

| kind | n | of | what was measured |
|---|---:|---:|---|
| timeout, first-red job | 18 | 209 job rows (8.6 %) | e2e 11, orc hermetic 5, wui unit 2. Annotation `exceeded the maximum execution time` |
| runner-lost | 3 | 209 (1.4 %) | e2e 2, iac 1. Annotation `lost communication with the server` |
| e2e fail then pass with no wui diff | 1 | 1 pair | R8, `calendar-phone.test.mjs`, section 2.1. Not a rate |
| orc hermetic, one failure, next full gate green | 1 | R1 | the range also contains orc commits, so this one may be a fix whose run was superseded, not a flake |

The workflow file already records the load failure mode, at the `orc-suite`
job: both shards ran 850..1180 s under CPU pressure and timed out 8 times in
11 started master runs on 2026-10-11, while the cap was 20 min (it is 30 min
in this tree). This seat did not re-count started-versus-timeout for that
day; the 5 orc timeouts above are first-red rows inside failure runs, a
subset.

Not a flake: the gzip ceiling. Two logs a day apart both read `155.1 > 155`.
It is a real budget sitting on the line, and it returns after a green.

Log text for the other 157 failure rows was not recovered: the collector's
matcher required a `FAIL` token and then a broken character class, so those
rows say `(no FAIL line)`, and 31 log downloads timed out. Job, step and
annotation are what sections 1 and 2 use, plus the two budget logs and the
one e2e log.

## 4. Measurable axes

| axis | command | baseline | target |
|---|---|---|---|
| A1 red-streak share of the window | Section 0's run list. Keep `failure` and `success`. A streak is consecutive failures. Sum (green `updated_at` − first failure `created_at`) / (newest created − oldest created) | **76.8 h / 82.8 h = 92.8 %**, 11 streaks, n=127 verdicts, window `2026-10-08T19:50:22Z`..`2026-10-12T06:36:15Z` | under 10 % of window hours |
| A2 first-red rows with no pre-push part | Of first-red rows (section 0's annotation rule), count e2e + nuxt generate + orc feature tests | **97 / 209 = 46 %** (48 + 31 + 18 failure rows; timeouts on those jobs are extra and not in the 97), 96 of 109 failure runs | under 10 % |
| A3 generate budget breaches | For each run whose first-red includes `nuxt generate`, the failed step name. A breach log contains `FAIL ci_initial_gzip_kb` | **31 / 31** failed the step `Initial JS gzip stays within the performance budget`. Logs n=2, both `155.1 > 155` | 0 in 50 completed gates |
| A4 timeout + runner-lost share | First-red rows whose annotation is the timeout sentence or `lost communication with the server` | **21 / 209 = 10 %** (18 + 3) | under 2 % |
| A5 local PASS, then that suite red in CI | Join failure shas to this box's hook summary line (`PASS` / `FAIL` / `OVERRIDE`, not a `PART` line). Then the part verdict versus the CI job | **42 / 109** failure shas are a sat summary PASS (61 have no sat line). Of the 38 of those with a first-red list, the part the hook ran was `PASS` and CI still failed it **2 times** (orc 1, iac 1). The rest were `SKIP-untouched` or a suite with no part | false-green of a part the hook ran: under 1 % of that part's CI runs. Unmapped suites move onto A2 |
