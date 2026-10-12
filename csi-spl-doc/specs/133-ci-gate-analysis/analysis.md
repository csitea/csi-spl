# 133: CI gate analysis

Status: **draft v0.1, skeleton** (editor c-296, 2026-10-12). The seats'
findings are folded in here as they land; until then the sections below hold
only the starting facts and the questions each section must answer.

## 1. Starting facts

Source: c-002's 48 h measurement, msg a4348171
(https://spool-hub.ai/m/f98b1b77-d73d-4ccb-9618-68a1cca089af), wf 10
(`10_ci-quality.yml`) on master, runs since 2026-10-10T06:00Z, **n=629**.
To be re-measured by the seats with the command and sha stated.

| fact | value |
|---|---|
| runs cancelled as superseded | 577 (92%) |
| runs failed | 48 |
| runs green | **3** |
| median wall time of a completed run | 47 min |
| push rate on master | ~13 an hour |

Failed runs per job (one run can fail several jobs):

| job | failed runs |
|---|---|
| orc hermetic (`orc-suite`) | 41 |
| hub go (`hub-suite`) | 38 |
| wui e2e (`wui-e2e`) | 33 |
| iac (`iac-suite`) | 22 |
| nuxt generate (`wui-generate`) | 15 |
| orc feature (`orc-features`) | 12 |

Structure, each checked on tree `7d950a8ec`:

- **No per-part job selection in CI.** The only skip is the docs-only
  classify: `grep -n "^  classify:" .github/workflows/10_ci-quality.yml` ->
  line 133; the code jobs it skips are listed in the file's header comment
  (`grep -n "skips the code jobs" .github/workflows/10_ci-quality.yml` -> 1
  line). Its helper is `csi-spl-orc/src/bash/scripts/ci-doc-only.sh`.
- **No `paths:` filter, on purpose**: `grep -n "NO \`paths:\` FILTER"
  .github/workflows/10_ci-quality.yml` -> 1 line (the wrong allow-list
  "fails SILENTLY" argument). Pre-push is selective (touched parts only,
  [pre-push-gate.md](../../doc/md/pre-push-gate.md)); CI deliberately is not.
- **One running + one pending gate per ref**:
  `grep -n -A2 "^concurrency:" .github/workflows/10_ci-quality.yml` ->
  `group: quality-gate-${{ github.ref }}`, `cancel-in-progress: false`.
  So "cancelled" = superseded pending run, not a lost run.
- **13 jobs** in wf 10: `awk '/^jobs:/{j=1;next} /^[a-z]/{j=0} j &&
  /^  [a-z0-9_-]+:$/' .github/workflows/10_ci-quality.yml | wc -l` -> 13
  (includes `classify`, `gate-health`, `distribution-hygiene`,
  the box-reference ban job, `pr-sec-scan`).
- **Runners**: 6 self-hosted runners on sat (16 CPU, shared with agents);
  `gh-runner-cpu-budget` keeps about 3 online.
- **Spec 131** ([131-ci-red-trunk](../131-ci-red-trunk/spec.md)) already
  landed C1..C5.
- **Fleet state now**: every non-CI lane paused by owner order; only CI lanes
  push. c-294 is landing the hourly non-replaceable wf 10 verdict.

## 2. Why the gate almost never gives a verdict

(Folded from the seats. Each cause: the mechanism, the measurement with
command + sha + n, and its share of the lost verdicts.)

### 2.1 Cadence: pushes vs gate wall time

### 2.2 Selection: every push runs every code job

### 2.3 Reds: which jobs fail, and why (defect vs flake vs load)

### 2.4 Capacity: runners, queue wait, box load

### 2.5 Wall time: the critical path inside one run

## 3. What the seats found

| seat | file | area | status | sha |
|---|---|---|---|---|
| A | `seat-a.md` | | pending | |
| B | `seat-b.md` | | pending | |
| C | `seat-c.md` | | pending | |
| D | `seat-d.md` | | pending | |
| E | `seat-e.md` | | pending | |

## 4. The axes (ONE set, 5-8)

Each axis: what it measures, the exact command, the baseline now (with sha,
window and n) and the target. Every round of the CI-refactor seat reports its
before and after on every axis.

| # | axis | command | baseline (sha, window, n) | target |
|---|---|---|---|---|
| X1 | | | | |
| X2 | | | | |
| X3 | | | | |
| X4 | | | | |
| X5 | | | | |

Candidates from the brief, to be confirmed or replaced by the seats: median
push-to-verdict minutes, % master runs finished green, red-minutes per day,
runner queue wait p90, jobs run per code push, cancelled %.

## 5. Candidate fixes, ranked by expected axis gain per effort

| rank | fix | axes it moves (expected) | effort | risk | from seat |
|---|---|---|---|---|---|
| | | | | | |

## 6. Open questions

## 7. Sign-off

| version | date | by | what |
|---|---|---|---|
| v0.1 | 2026-10-12 | c-296 | skeleton |
