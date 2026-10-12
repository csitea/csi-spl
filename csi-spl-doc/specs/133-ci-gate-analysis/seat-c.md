# 133 seat C: per-part test selection (the owner's question)

Seat C, agent c-297, 2026-10-12. Doc only. Draft v0.1 for the editor (c-296).

> Owner: "I thought we had the functionality to not test everything when only
> a certain part of the system is changing."

**Short answer.** We have it **before the push** (the pre-push hook runs only
the parts a push touches, and orc even picks single test files). We do **not**
have it **in CI**: wf 10 runs every code job on every push. Its one skip, the
express docs lane, compares against the last GREEN gate. With 3 green gates in
48 h it fired on **0 of 51** completed runs. Had CI selected jobs per part, the
same 614 pushes would have needed **58-65 % fewer job-minutes**. The biggest
single saving is the WUI browser e2e (61 % of a gate's job-minutes), which
needs a WUI input on only 28 % of pushes.

Tree for every file claim: `36c185fec` (= `origin/master` at
2026-10-12T06:27Z). Window for every count: wf 10 push runs on master created
2026-10-10T06:27Z..2026-10-12T06:27Z, **n=615 runs** (614 push-to-push diffs).

## 1. What exists today

### 1.1 Pre-push: selective, per part and per test

`csi-spl-iac/src/bash/run/check-pre-push.func.sh`, function `_pp_paths`
(`grep -n "^_pp_paths()" csi-spl-iac/src/bash/run/check-pre-push.func.sh` ->
line 180). A part runs only when the push (`origin/master...HEAD` plus the
working tree) touches a path it reads. Otherwise it logs `SKIP-untouched`.

| part | selected by (verbatim from `_pp_paths`) |
|---|---|
| `api` | `csi-spl-api csi-spl-rdb .version` |
| `wui` | `csi-spl-wui` plus the **file-level** list of repo files its unit tests read (`_pp_wui_external`, 38 entries on this tree) |
| `iac` | `csi-spl-iac csi-spl-cnf .github .zap` + 5 root scanner configs |
| `cnf` | only the cnf env files + tpl-gen inputs (instead of `iac` when that is all the push touched) |
| `orc` | `csi-spl-orc`; inside it, `run-all-tests.sh --changed` picks the single `*.tst.sh` files that name a changed file (`csi-spl-orc/src/bash/tests/changed-tests.sh`, fails safe to `full`) |
| `blog` | `csi-spl-doc/blog` + its check |
| `hygiene`, `stale-tree` | always |
| `lint-*` | touched files only |

There is also a content-keyed verdict cache, so a rebase over other lanes'
commits re-runs nothing. The owner remembered **this**.

### 1.2 CI (wf 10): every code job on every push

- **No `paths:` filter.** This is deliberate:
  `grep -n 'NO \`paths:\` FILTER' .github/workflows/10_ci-quality.yml`
  -> line 34 ("an allow-list that is wrong fails SILENTLY").
- **Every code job has the same `if:`**:
  `grep -c "needs.classify.outputs.doc_only != 'true'" .github/workflows/10_ci-quality.yml`
  -> 9 (hub, wui-suite, wui-generate, wui-e2e, iac, orc-suite, orc-features,
  cnf, plus the comment line). No job looks at which part changed.
- **Job instances on a push.** 11 code instances: hub 1, wui-suite 1,
  wui-generate 1, wui-e2e 3 shards, iac 1, orc-suite 2 shards,
  orc-features 1, cnf 1. Plus 4 that always run and take seconds: classify,
  distribution-hygiene, no-ysg-box-ref, gate-health. pr-sec-scan is skipped
  on a push.

### 1.3 The express docs lane: right idea, base too far back

`csi-spl-orc/src/bash/scripts/ci-doc-only.sh` returns `doc_only=true` only
when every path in `<base>..<head>` is a `*.md` outside `csi-spl-wui/` and
`.github/`. wf 10 sets `<base>` to the **head of the newest successful push
run** (`grep -n 'status=success&per_page=1' .github/workflows/10_ci-quality.yml`
-> 1 line). That is correct for safety: a doc push must not hide a red code
push whose gate was superseded. But it means the lane can only fire right
after a green gate.

Measured:

| fact | value | command |
|---|---|---|
| green push runs in the window | **3** (`33d505c7d` 10-11 23:39Z, `460398ada` 10-12 02:00Z, `48ed9c131` 10-12 05:17Z) | Appendix A.1: `cut -f5 runs.tsv \| sort \| uniq -c` -> 562 cancelled, 48 failure, 3 success, 2 running |
| completed runs where classify said `doc_only=true` (hub-suite `skipped`) | **0 of 51** | Appendix A.2: hub's conclusions over the 51 runs = success 12, failure 38, cancelled 1, skipped 0 |
| pushes whose OWN diff was docs only | **220 of 614 (35.8 %)** | Appendix A.3 |
| job-minutes the lane saved, simulated over all 614 pushes with its real base | **0.0 %** | Appendix A.3, row `lastgreen` |

So one push in three changes only docs, yet each one paid for a full
139-job-minute gate.

### 1.4 Deploy workflows: path filters exist (wf 20, 30)

`for w in .github/workflows/*.yml; do grep -cE '^\s+paths(-ignore)?:' $w; done`
-> 12 workflows carry `paths:`. They include `20_hub-build-deploy.yml` (Go
sources minus `_test.go`, hub Dockerfile, rdb DDL, `.version`, the 3 cnf env
yaml, its own workflow) and `30_wui-build-deploy.yml` (`csi-spl-wui/**`,
`*.env.json`, 4 orc scripts, blog posts, its own workflow). Two notes:

- **wf 20 runs the hub suite again** in its own `test` job:
  `grep -n "run-all-tests.sh" .github/workflows/20_hub-build-deploy.yml` -> line 124.
  On a hub push, `hub-suite` therefore runs twice, once per workflow.
- These path lists are kept in step by a test (`hub-deploy-guard.tst.sh`,
  named in wf 20's header). That is the model for a wf 10 selection list:
  an allow-list **with a test that keeps it in step**, not an allow-list
  nobody checks.

## 2. What a change in each part really needs

### 2.1 Cross-part reads (who reads whom)

Lower bound: for each suite, the number of its test files that name another
part's path literally,
`grep -lE "csi-spl-<dst>/" csi-spl-<src>/src/bash/tests/*.sh | wc -l`
(tree `36c185fec`):

| suite (files) | reads api | iac | orc | cnf | rdb | wui | doc | .github |
|---|---|---|---|---|---|---|---|---|
| hub / api (19) | - | 0 | 0 | 3 | 1 | 0 | 0 | 0 |
| iac (138) | 24 | - | 20 | 45 | 5 | 13 | 8 | 39 |
| orc (357) | 39 | 13 | - | 30 | 35 | 7 | 15 | 16 |
| cnf (1) | 0 | 1 | 1 | - | 0 | 0 | 0 | 0 |
| wui unit (file-level) | 10 Go files | `run` | 2 scripts | 4 cnf files | 7 migrations | - | 11 md / dirs | 4 workflow entries |

The wui row is `_pp_wui_external` (exact file list, 38 entries). Other
dependencies that are not literal path reads:

- **orc needs the api Go module.** The orc jobs run `go mod download` in the
  api module (`grep -n "go mod download" .github/workflows/10_ci-quality.yml`
  -> lines 220, 728, 891). 32 orc tests build or run the spool binary
  (`grep -lE "spool build|build.sh|go build" csi-spl-orc/src/bash/tests/*.sh | wc -l` -> 32).
- **The hub job runs orc scripts**: `gate-fail-fast.sh` and
  `docker-pull-mirror.sh`
  (`grep -n "csi-spl-orc/src/bash/scripts" .github/workflows/10_ci-quality.yml`).
- **cnf -> tfvars -> iac.** iac's render-parity tests read the cnf env files
  (45 iac tests name cnf). The wui unit tests read `*.env.json`. The hub
  suite reads `csi-spl-cnf/csi-spl` (3 tests).
- **Whole-tree scanners.** 5 iac tests and 2 orc tests call `git ls-files`
  over the tree
  (`grep -lE 'git (-C "?\$[A-Za-z_{}]+"? )?ls-files' <dir>/*.sh | wc -l`).
  They read every part, so any change at all selects iac and orc unless
  those scanners move to an always-on cheap job.
- **Docs are read by tests.** 35 distinct `.md` paths are named by 32 bash
  test files (for example the CLAUDE.md drift checks and the spec progress
  tests). Ten wui unit test files read `csi-spl-doc` paths, among them
  `docs.test.mjs` and `help-sync.test.mjs` on `doc/help/*.md`. The express
  lane already accepts this risk: a help `.md` edit can break
  `help-sync.test.mjs` and still skip the wui job. **That is a known hole
  in today's lane, not a new one.**

A grep for literal paths is a **lower bound**: it cannot prove that a test
does NOT read a part, because a path built from variables is invisible to it.
Any rule built on it must fail safe (section 3).

### 2.2 Per part: the jobs a change really needs

| changed part | must run (direct) | must also run (reads it) | may skip |
|---|---|---|---|
| hub (`csi-spl-api`, `csi-spl-rdb`, `.version`) | hub | orc-suite + orc-features (Go module, spool binary); iac (24 tests); wui only for a file on the wui list (10 Go files, 7 migrations) | cnf; wui otherwise |
| wui (`csi-spl-wui/**`) | wui-suite, wui-generate, wui-e2e | iac (13 tests), orc (7) | hub, cnf |
| iac (`csi-spl-iac/**`) | iac | orc (13), cnf (1); wui for `csi-spl-iac/run` | hub, wui |
| orc (`csi-spl-orc/**`) | orc-suite, orc-features | iac (20), cnf (1), hub (gate scripts); wui for the 2 listed scripts | wui otherwise |
| cnf (`csi-spl-cnf/**`) | cnf, iac (tfvars parity) | orc (30), hub (3), wui (`*.env.json`, `all.env.yaml`) | - (cnf feeds every part) |
| doc (`*.md` outside wui/.github) | none (express lane) | wui for a file on its list; the 32 doc-reading bash tests | most |
| workflows (`.github/**`) | **all** | - | none |
| root files (`docker-compose.yml`, `.zap`, scanner configs, ...) | **all** | - | none |

In short: **wui is the part that can be cut cleanly**, and it is the costly
one. **iac and orc are read by almost everything** (whole-tree scanners plus
cross reads), so a part-level rule keeps them on most pushes. Cutting them
needs test-level selection, which `changed-tests.sh` already does for orc
before the push.

## 3. Fail-safe rules: when CI runs everything

These are proposals for the builder seat. Each one says when to **widen** to
the full gate. Anything not proven narrow is wide.

1. **Workflows or the gate's own code changed** -> full gate: `.github/**`,
   the selection script and its map, `ci-doc-only.sh`, `gate-fail-fast.sh`,
   any `run-all-tests.sh` / `run-ci-tests.sh` / `changed-tests.sh`.
2. **A shared lib or dispatcher changed** -> full gate: `csi-spl-*/run`,
   `*/src/bash/run/run.sh`, `*/lib/**`, the test libraries
   (`test-lib.inc.sh`, `lib.inc.sh`), `go.mod` / `go.sum`,
   `csi-spl-wui/package.json` / `pnpm-lock.yaml`, the root configs
   (`docker-compose.yml`, `.zap/**`, scanner configs), `.version`.
3. **A path no rule maps** -> full gate (an unknown top-level dir, or a
   non-md file outside the 7 parts).
4. **The base is per JOB, not per push.** Job J skips only if every file
   changed since **J's own last success on master** is outside J's inputs.
   This is the express lane's safety argument, applied per job. A red hub job
   keeps running on every push until it is green, and a wui-only push no
   longer has to wait for a green hub before it can skip hub. Today's
   whole-gate base is why the lane fired 0 times in 51 runs. No such success,
   an API error, a merge, a force-push or a non-ancestor base -> that job
   runs (as `ci-doc-only.sh` already fails safe).
5. **The hourly non-replaceable verdict** (c-294's lane) **always runs the
   full gate** at the tip, with no selection and no cache. It is the backstop
   for every allow-list mistake: a missed dependency is caught within the
   hour, not never. This answers the "fails SILENTLY" objection in wf 10's
   header, because the silence lasts at most one hour.
6. **Pull requests from outside** (wf 11) -> full gate, always.
7. **A drift test keeps the map honest**, as `hub-deploy-guard.tst.sh` does
   for wf 20. It fails when a test file names a path in another part that the
   selection map does not route to its job. It generalises the
   `_pp_wui_external` approach to every suite.
8. **One source of truth.** The CI selection reads the same part -> paths map
   as `_pp_paths` (pre-push), so a local PASS and a CI selection never
   disagree about which part a file belongs to.

## 4. What selection would have saved (last 48 h)

Method (Appendix A.3): the 615 wf 10 push runs, sorted by creation time. For
each consecutive pair, `git diff --no-renames --name-only <prev head> <head>`,
with the files mapped to parts. The 2 non-ancestor pairs and the 1 empty diff
count as full gates. Job-minute weights are the per-job **median** wall time
over the 51 completed runs (Appendix A.2): hub 12.7, wui-suite 6.5,
wui-generate 5.5, wui-e2e 28.2 per shard (x3), iac 6.8, orc-suite 8.7 per
shard (x2), orc-features 5.3, cnf 0.6. That is **139.4 job-min per full
gate**, of which wui-e2e alone is 84.6 (61 %).

### 4.1 What the pushes touched (n=614)

| push touched only | pushes | share |
|---|---|---|
| doc | 220 | 35.8 % |
| orc | 129 | 21.0 % |
| wui | 99 | 16.1 % |
| hub | 45 | 7.3 % |
| iac | 25 | 4.1 % |
| cnf | 4 | 0.7 % |
| workflows / root | 2 / 2 | 0.7 % |
| 2+ parts | 87 | 14.2 % |
| (empty) | 1 | 0.2 % |

Pushes touching each part, any mix: doc 260, orc 180, wui 116, hub 83,
iac 51, cnf 25, workflows 8, root 4.

### 4.2 Savings per model

| model | rule | job instances (of 6,754) | job-minutes (of 85,592) | saved |
|---|---|---|---|---|
| today | full gate unless docs only since the last green | 6,754 | 85,592 | **0.0 %** |
| E | express lane only, base = previous push | 4,345 | - | 35.7 % of instances |
| A2 | part-level (section 2.2, dir level) + express lane, rules 1-3 | 2,859 | 30,322 | **64.6 %** of job-min (57.7 % of instances) |
| B | file-level (own dir + the literal paths its tests name), no express lane, rules 1-3 | 3,419 | 35,815 | **58.2 %** of job-min (49.4 % of instances) |

How often each job would run, of 614 pushes (A2 / B): the wui jobs 170 / 170
(27.7 %), hub 265 / 133, cnf 229 / 37, iac and orc on most pushes in both. In
B the whole-tree scanners and bare dir names in test fixtures keep iac and orc
on 595-614 pushes.

**Read these numbers as an upper bound for a green trunk, not as a
forecast.** The per-push base assumes each push gets its own run. Under rule 4
(per-job base), a red job keeps running until it is green, so on today's red
trunk the red jobs (hub, orc, wui-e2e) would still run on most pushes. wui is
the exception that still pays: it is red often (77 failed e2e shards of 153),
but a push that touches no wui input never needs it, and after one green wui
run it skips. **n=614, one 48 h window, with the fleet partly paused**: this
is evidence of the push mix, not proof that it is stable.

## 5. Findings for the editor

- **C1. CI has no per-part selection, by design.** The owner's memory is
  right for pre-push and wrong for CI (section 1.2).
- **C2. The express docs lane is dead while trunk is red.** It fired 0/51,
  while 35.8 % of pushes were docs only. The cause is a whole-gate base (the
  last green run). The fix is a per-job base (rule 4).
- **C3. wui-e2e is 61 % of a gate's job-minutes, and only 27.7 % of pushes
  need it.** It is the cleanest and largest cut.
- **C4. iac and orc are read by nearly everything** (whole-tree scanners,
  cross reads), so a part-level rule saves little on them. The next step is
  test-level selection in CI (`changed-tests.sh` already exists for orc),
  backed by the hourly full verdict.
- **C5. hub-suite runs twice on a hub push** (wf 10 `hub-suite` and wf 20
  `test`), at a 12.7 min median each, on the same runners. Noted for seats
  B/E to weigh.
- **C6. The express lane already skips tests that read docs** (wui unit files
  on help `.md`, and 32 bash tests that name `.md` files). The hourly full
  verdict (rule 5) closes that hole too.

## 6. Measurable axes (seat C)

| # | axis | measurement command | baseline (tree `36c185fec`, 10-10 06:27Z..10-12 06:27Z) | target |
|---|---|---|---|---|
| C-X1 | code job instances per completed push run | A.2 query; count jobs with conclusion `success` or `failure`, excluding classify, hygiene, no-ysg-box-ref and gate-health, divided by runs | 11 per run, every run ran all 11 (n=51) | <= 5 median |
| C-X2 | code job-minutes per completed push run | A.2 query; sum of `completed_at - started_at` over the code jobs per run, median | 139.4 (sum of the per-job medians, n=51) | <= 60 |
| C-X3 | docs-only pushes that got a verdict without code jobs | A.2 runs whose `hub-suite` conclusion is `skipped`, over A.3 pushes whose own diff is docs only | 0 of 220 (0 %) | >= 90 % |
| C-X4 | share of completed push runs that ran wui-e2e | A.2: runs with a `wui: browser e2e` job concluded `success`/`failure`, over completed runs | 100 % (51 of 51), while 27.7 % of pushes touched a wui input (A.3) | <= 35 % |
| C-X5 | selection misses caught by the hourly full verdict | hourly full runs red on a job that the selection skipped at that tip (the selection writes its skipped jobs to the step summary) | n/a (no selection yet) | 0 a week; each miss gets a drift-test fix the same day |

## Appendix A: commands

All run on `36c185fec`, with `gh` authenticated (`GH_TOKEN` from the box's
token file). `$S` is a scratch dir.

### A.1 The runs

```bash
gh api --paginate "repos/csitea/csi-spl/actions/workflows/10_ci-quality.yml/runs?branch=master&event=push&created=>=2026-10-10T06:27:00Z&per_page=100" --jq '.workflow_runs[] | [.id,.head_sha,.created_at,.status,(.conclusion//"-")] | @tsv' > $S/runs.tsv
```

-> 615 rows: 562 cancelled, 48 failure, 3 success, 2 still running.

### A.2 The jobs of the 51 completed runs

```bash
awk -F'\t' '$5=="failure"||$5=="success"{print $1}' $S/runs.tsv > $S/done.ids
```

```bash
while read id; do gh api "repos/csitea/csi-spl/actions/runs/$id/jobs?per_page=100" --jq ".jobs[] | [\"$id\", .name, (.conclusion//\"-\"), .started_at, (.completed_at//\"-\")] | @tsv"; done < $S/done.ids > $S/jobs.tsv
```

-> 816 job rows. Per job (conclusions; median minutes over success+failure):

| job | n | conclusions | median min |
|---|---|---|---|
| hub | 51 | success 12, failure 38, cancelled 1 | 12.7 |
| wui: browser e2e (3 shards) | 153 | success 62, failure 77, cancelled 14 | 28.2 |
| orc: hermetic (2 shards) | 102 | success 20, failure 75, cancelled 7 | 8.7 |
| iac | 51 | success 29, failure 22 | 6.8 |
| wui: unit + typecheck | 51 | success 49, cancelled 2 | 6.5 |
| wui: nuxt generate | 51 | success 36, failure 15 | 5.5 |
| orc: feature tests | 51 | success 38, failure 12, cancelled 1 | 5.3 |
| cnf | 51 | success 50, cancelled 1 | 0.6 |

A failed job often ends early through `gate-fail-fast.sh`, so its minutes
understate a full run: the medians are a floor.

### A.3 The selection simulation

The suites' literal path reads (a lower bound):

```bash
RE='(csi-spl-(api|cnf|dat|doc|iac|orc|rdb|utl|wui)|\.github)/[A-Za-z0-9_./-]*'; grep -rhoE "$RE" csi-spl-iac/src/bash/tests/ | sed 's#/*$##' | sort -u > $S/ext-iac.txt; grep -rhoE "$RE" csi-spl-orc/src/bash/tests/ csi-spl-orc/src/bash/features/*/tests/ | sed 's#/*$##' | sort -u > $S/ext-orc.txt; grep -rhoE "$RE" csi-spl-api/src/bash/tests/ | sed 's#/*$##' | sort -u > $S/ext-hub.txt; grep -rhoE "$RE" csi-spl-cnf/src/bash/tests/ csi-spl-cnf/src/python | sed 's#/*$##' | sort -u > $S/ext-cnf.txt; bash -c '. csi-spl-iac/src/bash/run/check-pre-push.func.sh; _pp_wui_external .' | tr ' ' '\n' | grep . | sort -u > $S/ext-wui.txt
```

The classifier's rules, in full (a throwaway script, not committed: doc-only
seat):

- **part(f)**: `.github/` -> workflows; `csi-spl-api`, `csi-spl-rdb`,
  `.version` -> hub; `csi-spl-wui` -> wui; `csi-spl-iac` -> iac;
  `csi-spl-orc` -> orc; `csi-spl-cnf` -> cnf; `csi-spl-doc|dat|utl` or any
  other `*.md` -> doc; else root.
- **Both models**: workflows or root touched, a non-ancestor pair, or an
  empty diff -> all 11 instances. The wui jobs (5 instances) run iff a file
  is under `csi-spl-wui/` or matches `ext-wui.txt`.
- **A2**: a push whose every file is a `*.md` outside wui/.github runs
  nothing (express lane, per-push base). Otherwise: hub iff it touched
  {hub, cnf, orc}; iac iff {iac, hub, orc, cnf, wui, doc}; orc-suite +
  orc-features iff {orc, hub, iac, cnf, wui, doc}; cnf iff {cnf, iac, orc}
  (section 2.1, dir level).
- **B**: each suite iff a file is under its own dir or matches an entry of
  its `ext-<suite>.txt` (prefix or glob), plus orc on any
  `csi-spl-api/src/go/` change and hub on any `csi-spl-orc/src/bash/scripts/`
  change.
- **lastgreen** (today's rule): the full gate unless `git diff` from the
  newest green run created before this run is docs only (the 3 greens of A.1).

Output on `36c185fec`: pushes 614, non-ancestor 2, empty 1; instances full
6,754 / E 4,345 / A2 2,859 / B 3,419; job-min full 85,592 / A2 30,322 /
B 35,815 / lastgreen 85,592.
