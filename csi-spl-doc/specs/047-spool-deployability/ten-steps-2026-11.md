# 047 — Ten steps to improve how spool-hub deploys (2026-11)

Epic **SPL-57** (Deployability), issue **SPL-5408**. Discussion
`7c09b274` (t1, #spool-hub-devel). The owner's ask (HUM-10, 2026-11-12):

> "I would like to see 10 concrete proposal steps to improve the deployability
> of the spool-hub project"

"Deployability" here is both angles of [the 047 analysis](deployability-analysis.md):
how fast and how safely **our own** commits reach dev and prd, and how easily
a **new customer** takes spool-hub into use (self-hosted compose, or a tenant
bought on spool-hub.ai). This file proposes; it changes no code, cnf or other
doc. Each step becomes a lane of its own once the owner picks it.

**Evidence rule** (the "three fields" rule). Measured 2026-11-13 on tree
`0a50cbb88` (`git describe` -> `v1.0.1-c4-6-g0a50cbb88`), read-only on GCP
and GitHub. A CI number covers the last 100 runs of its workflow unless the
row names another n; `p50` / `p90` are run wall time, `createdAt` to
`updatedAt`. Every number names the command that produced it. **Not
measured** says so.

## 1. Baseline, measured

| what | number | command |
|---|---|---|
| hub: push to served on prd (wf 20) | p50 **36.9 min**, p90 40.5 min; 99 green, 1 red (n=100, over 222 h) | `gh run list -w 20_hub-build-deploy.yml -L 100 --json conclusion,createdAt,updatedAt,status` |
| WUI: push to served (wf 30) | p50 10.4 min, p90 11.5 min; 97 green, 2 red (n=100, over 172 h) | same, `-w 30_wui-build-deploy.yml` |
| CI gate (wf 10) | p50 21.5 min, p90 32.4 min; 82 green, 5 red, 13 cancelled (n=100, over 29 h) | same, `-w 10_ci-quality.yml` |
| CI gate red runs, per job | 6 of 100 red: hub pg gate 2, wui e2e 3/8 2 (one defect, same sha `3eca9132` twice), hub go test 1 (a 35-min timeout), orc hermetic 2/4 1 | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` |
| deploy lag now | dev and prd, hub and WUI `current`, n=0 behind | `cd csi-spl-orc && ENV=<dev\|prd> ./run -a do_check_deploy_lag` |
| one hub deploy, broken down (run 43324507174, n=1) | suite 20.9 min (pg leg; plain 17.7) -> deploy prd 17.3 min, of which **"Roll the 030 service" 12.3 min**, migrations 2.1, heal 1.0 | `gh api repos/csitea/csi-spl/actions/runs/43324507174/jobs` (job and step times) |
| GHCR images (wf 56), weekly | 3 green, 3 red, 1 skipped (n=7, 2026-10-04..11-09); the last 3 green | `gh run list -w 56_ghcr-images.yml -L 7` |
| stable release (wf 55), weekly | 7 green, 1 red (n=8) | `gh run list -w 55_release-stable.yml -L 8` |
| paid checkouts on prd | **0 rows**; 23 tenants = 21 `manual` + 2 `internal` | `cd csi-spl-orc && ENV=prd SQL="SELECT status, count(*) FROM payment_checkouts GROUP BY status" ./run -a do_spl_db_query` (and `billing_status` on `tenants`) |

## 2. The ten steps, ordered by value for effort

### 2.1 Step 1 — the compose file pins the newest stable, not one from October

- **Pain, measured.** `docker compose up -d` with no env pulls
  `stable-2026-10-12` (`grep -n ghcr.io/csitea docker-compose.yml` -> lines
  136, 179, 276, all `stable-2026-10-12@sha256:...`), while the newest release
  is `stable-2026-11-09` (`gh release list -L 6` -> `stable-2026-11-09 (v9.2.7)
  Latest`). A new self-hoster starts **4 stables, 32 days behind**. The pin
  is a hand step: wf 56 only prints `PIN_TAG=<tag> DRY_RUN=0 ./run -a
  do_pin_compose_images` into its job summary
  (`.github/workflows/56_ghcr-images.yml:147`), and nobody has run it since
  `stable-2026-10-12` (`git log -3 --format='%h %cs' -- docker-compose.yml`
  -> newest commit 2026-10-28, a dev-mode change).
- **Change.** wf 56, on a `stable-*` tag and after its images are pushed,
  runs `do_pin_compose_images` itself and lands the pin as a commit of its
  own (or a box cron does, if CI may not push to master). The alternative: the
  compose default becomes a moving `stable` tag, with the digest pin kept as
  an opt-in.
- **Touches.** `.github/workflows/56_ghcr-images.yml`,
  `csi-spl-orc/src/bash/run/pin-compose-images.func.sh` (reused as is, or
  given a push mode), `docker-compose.yml`.
- **Size.** S.
- **Worked when.** `grep -o 'stable-[0-9-]*' docker-compose.yml | sort -u`
  equals the newest `gh release list` tag within 1 day of every release, for
  4 releases running.

### 2.2 Step 2 — one live buy on prd (047 W3, still open)

- **Pain, measured.** The paid path has **never run on prd**:
  `payment_checkouts` has 0 rows, and all 23 prd tenants are `manual` or
  `internal` (section 1). It is proven on dev only (`316951195`,
  `do_spl_paid_owner_probe`), and it is still rank 1 in 047 section 2.1.
- **Change.** The owner runs the W3 checklist (topic `bea3a4e6`, SPL-1164):
  one 20 EUR buy, a sign-in as the buyer, a refund. The same session checks
  the spec 072 F31 gap (no `box-wui` pin for a bought tenant).
- **Touches.** No code: the owner's card and 30 min. A defect it finds becomes
  its own lane.
- **Size.** S (owner, 30 min).
- **Worked when.** `payment_checkouts` on prd holds 1 `paid` row, then the
  refund; the buyer reached the app as `biz_owner` with 0 operator actions.

### 2.3 Step 3 — the hub deploy stops re-running the suite the gate already ran

- **Pain, measured.** Every hub deploy waits for its own run of
  `csi-spl-api/src/bash/tests/run-all-tests.sh`: wf 20 job `test`, legs
  `plain` and `pg`, and `deploy` has `needs: [test, prepare-deploy, prebuild]`
  (`grep -n 'needs:' .github/workflows/20_hub-build-deploy.yml` -> line 368).
  Wf 10 runs the same suite on the same sha (`grep -n run-all-tests
  .github/workflows/10_ci-quality.yml` -> lines 326-334 and 437-445). In run
  43324507174 that second run is **20.9 of the 38.2 min** from push to prd
  served. Hub deploys run about 11 a day (100 runs in 222 h).
- **Change.** The deploy waits for wf 10's hub jobs on the same sha and
  deploys on their green (a short poll step, or `workflow_run` on wf 10). Wf
  20 keeps its own suite only as the fallback when wf 10 skipped or cancelled
  the hub part. Measure first: how often wf 10 runs the hub part for a sha
  that wf 20 deploys (**not measured**), and that the two runs are the same
  set (the wf 20 header says `HUB_SUITE_PART` runs "as wf 10 runs it"). Wf 20
  runs on a hosted runner on purpose; that choice stays for the fallback.
- **Touches.** `.github/workflows/20_hub-build-deploy.yml` (the `test` job and
  the `deploy` needs), perhaps a small wait action in `csi-spl-orc` with its
  test.
- **Size.** M.
- **Worked when.** wf 20 p50 falls from 36.9 min to under 22 min over the next
  100 runs, and its red rate stays at or under 1 in 100.

### 2.4 Step 4 — the canary decides on traffic, not on a fixed 10 minutes

- **Pain, measured.** "Roll the 030 service" takes **12.3 of the 17.3 min**
  of a deploy job (run 43324507174). It is the SPL-2249 canary:
  `hub.cloud_run.canary` has `percent: 10` and `minutes: 10`
  (`csi-spl-cnf/csi-spl/all.env.yaml:423-427`), enabled on dev and on prd
  (`dev.env.yaml:274`, `prd.env.yaml:289`). How many requests the 10 % share
  receives in those 10 min is **not measured**. On dev, with little traffic,
  the window may prove nothing and still cost 10 min.
- **Change.** First measure, read-only: for each canary over the last 20
  deploys, the request count and the 5xx and WS-upgrade errors the canary
  revision served (Cloud Run request logs, by the canary revision). Then
  `do_canary_hub_deploy` ends the window early once a request floor is met
  with zero errors, and `minutes` stays the cap; dev may take a lower floor.
  The floor is cnf, beside `percent` and `minutes`.
- **Touches.** `csi-spl-orc/src/bash/run/canary-hub-deploy.func.sh` and its
  test, `hub.cloud_run.canary` in `csi-spl-cnf/csi-spl/all.env.yaml`.
- **Size.** S (the measurement), then M (the early end).
- **Worked when.** the roll step p50 falls under 5 min and rollbacks still
  fire: a red control (a canary image that answers 5xx) is rolled back on dev.

### 2.5 Step 5 — CI proves the path the README gives a stranger, and times it

- **Pain, measured.** wf 50, the stranger test on every push (99 of 100
  green, p50 4.8 min), runs `SPOOL_IMAGE_TAG: local` and `docker compose up
  --build` (`.github/workflows/50_oss-standalone.yml:46,61`). It proves the
  **source build**, not the documented default (`docker compose up -d`, which
  pulls the pinned GHCR images). A stranger's time to the first message was
  last measured on **2026-09-28: 6 min 26 s** (047 section 1.1); it is **not
  measured** since images became the default (`251ab6f8d`). 047 section 3.3
  sets the target at under 5 min.
- **Change.** A second wf 50 leg, or wf 55 on each stable (spec 072 T052 P1),
  runs the default pull path with no env, times clone -> healthy -> first
  human message -> first agent message, and writes the four numbers to the
  job summary.
- **Touches.** `.github/workflows/50_oss-standalone.yml` or
  `.github/workflows/55_release-stable.yml`, with the browser proof wf 50
  already runs.
- **Size.** S.
- **Worked when.** every stable carries the four timings in its run summary,
  and 047 section 3.3 rows "pull to healthy" and "stranger to first message"
  are filled from them instead of "not re-measured".

### 2.6 Step 6 — a red release or image build alarms someone

- **Pain, measured.** The deploy-failure alarm (spec 055 section 2) polls only
  workflows 20 and 30 (`sed -n 27p
  csi-spl-orc/src/bash/run/spl-deploy-failure-poll.func.sh` -> `for wf in "20
  ci-cd: spool hub build + deploy" "30 ci-cd: spool wui build + deploy"`). The
  two workflows that ship to self-hosters were red in **3 of 7** (wf 56, GHCR
  images) and **1 of 8** (wf 55, stable) weekly runs, and no alarm fired for
  them.
- **Change.** Add wf 55 and wf 56 to that list; the post already names the
  failing step and the sha.
- **Touches.** `csi-spl-orc/src/bash/run/spl-deploy-failure-poll.func.sh` and
  its test.
- **Size.** S.
- **Worked when.** a red run of wf 56 on a throwaway branch posts one `#alerts`
  line (the red control), and the next real red is seen the same day.

### 2.7 Step 7 — the compose stack runs without a repo checkout (spec 072 T033)

- **Pain, measured.** `docker-compose.yml` still bind-mounts three files from
  the checkout: `pg-init.sh` (line 86) and `secret-env.sh` (lines 116 and 159)
  (`grep -nE 'pg-init\.sh|secret-env\.sh' docker-compose.yml`). A self-hoster
  must clone the whole repo (a full clone's `.git` is 614 MB, 047 section
  1.1) to run the stack. T033 is open (`grep -n T033
  csi-spl-doc/specs/072-rapid-deployability/tasks.md` -> `- [ ]`).
- **Change.** Bake `pg-init.sh` and `secret-env.sh` into the published images,
  so that downloading `docker-compose.yml` and running `docker compose up -d`
  is enough. The README quick start says so.
- **Touches.** `docker-compose.yml`, `csi-spl-api/src/docker/pg-init.sh`,
  `csi-spl-api/src/docker/secret-env.sh`, the hub Dockerfile, wf 55 (the
  files T033 owns).
- **Size.** M.
- **Worked when.** the leg from step 5 runs from the compose file alone, in an
  empty directory, and is green.

### 2.8 Step 8 — the e2e shard weights refresh themselves

- **Pain, measured.** The CI gate's wall time is set by its slowest job. The 8
  WUI e2e shards are already packed longest-first from
  `csi-spl-wui/src/node/test/e2e-shard-weights.txt`, but they still ran p90
  **937 s to 1170 s** (shard 5/8 vs 6/8, n=48, `do_report_ci_gate`, timeout
  headroom section): a 233 s spread. In run 43175952216, a code push, the
  slowest shard ran 18.4 min and the fastest 13.5 min. The weights file is
  refreshed by hand (`git log --format='%h %cs' --
  csi-spl-wui/src/node/test/e2e-shard-weights.txt` -> 5 edits, the last
  2026-11-10), so it drifts as specs grow between edits.
- **Change.** A scheduled job rewrites the weights from the per-file times of
  the last green wf 10 runs (the runner already prints them, per its header)
  and lands the file when it moves by more than a set margin. The shard count
  stays.
- **Touches.** `csi-spl-wui/src/node/test/e2e-shard-weights.txt`, a small
  `csi-spl-orc` action and its test, a schedule in `.github/workflows/`.
- **Size.** S.
- **Worked when.** the p90 spread across the 8 shards stays under 60 s for 4
  weeks with no hand edit of the weights; wf 10 p50 falls by about that
  spread (2-3 min, estimate).

### 2.9 Step 9 — a blank cnf template and `do_spl_cnf_init` (spec 072 T041)

- **Pain, measured.** Standing up the GCP estate outside Csitea starts from
  our cnf: **3018 lines** in 4 yaml files, `spool-hub.ai` in **19** cnf files,
  and no template (`wc -l csi-spl-cnf/csi-spl/*.yaml`; `grep -rl spool-hub.ai
  csi-spl-cnf | wc -l`; `ls csi-spl-cnf/csi-spl` -> no `template`). This is
  047 G4, still open (T041 is `- [ ]`).
- **Change.** `csi-spl-cnf/template/` with every estate value as a named
  placeholder, and `do_spl_cnf_init`, which writes a new `<org>-<app>` cnf
  from it and runs the conf-validator.
- **Touches.** `csi-spl-cnf/template/`, a new `csi-spl-iac` action and its
  test.
- **Size.** M.
- **Worked when.** `do_spl_cnf_init` for a made-up org renders tfvars for
  every step with `do_tpl_gen`, and `grep -rc spool-hub.ai` over its output
  finds 0.

### 2.10 Step 10 — byo-GCP without a fork: org optional, workflows read cnf (spec 072 T026 + T021)

- **Pain, measured.** `gcp-001` still refuses to run without an org or folder
  (`csi-spl-iac/src/bash/run/gcp-001-create-project.func.sh:62`: "GCP_ORG_ID
  or GCP_FOLDER_ID must have a value"). The workflows name our estate
  directly: `GCP_KEY_CSI_SPL_` **83** times and `self-hosted` **44** times
  (`grep -rn GCP_KEY_CSI_SPL .github/workflows/ | wc -l`; `cat
  .github/workflows/*.yml | grep -c self-hosted`), and 9 terraform files
  accept only `dev`/`prd`. These are 047 G3, G5 and G6; spec 072 D1 made
  byo-GCP a supported path. 047 puts the cost at 2-3 days for an expert
  (an estimate, not measured).
- **Change.** T026 (org optional: a project under a billing account alone)
  and T021 (wf 20 and wf 30 take env names and secret names from cnf); then
  T051 `do_spl_estate_up` strings the steps together.
- **Touches.** `gcp-001-create-project.func.sh` and its test; the env and
  secret lines of wf 20 and wf 30; later a new `do_spl_estate_up`.
- **Size.** L.
- **Worked when.** both counts reach 0 outside one cnf-reading helper, and the
  spec 072 T052 clean-room estate stands up in a second org with a measured
  time.

## 3. Summary

| # | step | pain (measured) | size |
|---|---|---|---|
| 1 | compose pins the newest stable (automate `do_pin_compose_images`) | default pull is `stable-2026-10-12`, newest `stable-2026-11-09`: 4 stables, 32 days behind | S |
| 2 | one live buy on prd (W3) | 0 `payment_checkouts` rows on prd, ever | S (owner, 30 min) |
| 3 | the deploy reuses the gate's hub suite | 20.9 of 38.2 min push-to-prd is a second suite run; wf 20 p50 36.9 min | M |
| 4 | the canary ends on traffic, not after 10 min | roll step 12.3 of 17.3 min; canary request count not measured | S, then M |
| 5 | CI proves and times the README pull path | wf 50 builds from source; stranger time last measured 2026-09-28 (6 min 26 s) | S |
| 6 | wf 55/56 reds alarm | the alarm polls only wf 20/30; wf 56 red 3 of 7, wf 55 1 of 8 | S |
| 7 | compose without a checkout (T033) | 3 bind mounts from the repo; a full `.git` is 614 MB | M |
| 8 | e2e shard weights refresh themselves | shard p90 937..1170 s, 233 s spread; weights edited by hand | S |
| 9 | cnf template + `do_spl_cnf_init` (T041) | 3018 cnf lines, `spool-hub.ai` in 19 files, no template | M |
| 10 | byo-GCP: org optional, workflows read cnf (T026, T021) | org required; `GCP_KEY_CSI_SPL_` 83 and `self-hosted` 44 in workflows | L |

Noted, not a step: the shown version wraps after `9.9.9` to `1.0.1` of the
next cycle (`csi-spl-orc/src/bash/run/release-version.func.sh:13`). The
stables read `v7.0.9` on 10-12, `v2.1.5` on 10-19 and `v9.2.7` on 11-09
(`gh release list`), so a self-hoster cannot order builds by version number;
the `stable-<date>` tag orders them. This is by design (repo `CLAUDE.md`,
"Never roll the version by hand").
