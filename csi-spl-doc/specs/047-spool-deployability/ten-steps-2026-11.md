# 047 — Ten steps to improve how spool-hub deploys (2026-11)

Version **1.2** (2026-11-13): folds in the five notes of the grok R7 review
of v1.1 (PASS, no blocking finding): the stable-lag dates (step 2), the
wf 56 red count on master (step 3), the weights-file history (step 7), the
fourth bind mount (step 8) and the `GCP_KEY_CSI_SPL` count (step 10).
v1.1 (`23d7bf331`) added the DevX bar (section 2), one DevX line per step,
and re-ranked the steps by it (section 3). v1.0: `57efca675`.

Epic **SPL-57** (Deployability), issue **SPL-5408**. Discussion
`7c09b274` (t1, #spool-hub-devel). The owner's asks (HUM-10, 2026-11-12 and
2026-11-13):

> "I would like to see 10 concrete proposal steps to improve the deployability
> of the spool-hub project"

> "And all of this must be as DevX-friendly as possible."

"Deployability" here is both angles of [the 047 analysis](deployability-analysis.md):
how fast and how safely **our own** commits reach dev and prd, and how easily
a **new customer** takes spool-hub into use (self-hosted compose, or a tenant
bought on spool-hub.ai). This file proposes; it changes no code, cnf or other
doc. Each step becomes a lane of its own once the owner picks it.

**Evidence rule** (the "three fields" rule). Measured 2026-11-13 on tree
`0a50cbb88` (`git describe` -> `v1.0.1-c4-6-g0a50cbb88`), read-only on GCP
and GitHub; the v1.1 timings on the lane box at load average ~58. A CI number
covers the last 100 runs of its workflow unless the row names another n;
`p50` / `p90` are run wall time, `createdAt` to `updatedAt`. Every number
names the command that produced it. **Not measured** says so.

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
| compose pin, dry run (n=1) | **4.0 s**; it would pin `stable-2026-11-09` | `cd csi-spl-orc && ./run -a do_pin_compose_images` (DRY_RUN=1 default) |
| a stranger's shallow clone (n=1) | **6.2 s**, 133 MB on disk | `git clone --depth 1 https://github.com/csitea/csi-spl.git` |

## 2. The DevX bar every step must meet

The owner's "as DevX-friendly as possible", made checkable. A step's lane is
done only when all four hold, and its R7 review checks them:

1. **One named command.** The step is run by one `./run -a do_<verb>_<noun>`
   action or one `make` target (developer guide section 2.4.1), or by CI with
   no command at all. Never a sequence of commands copied from a doc.
2. **No hand-edited file.** Nothing the step needs is edited by hand: a
   generated file (a pin, tfvars, a weights file, a cnf) is written by its
   action and re-written by the next run.
3. **A failure says what to do next.** Every refusal prints the one command
   or setting that fixes it (the shape of `do_spl_self_host_up`'s preflight,
   or `FATAL ... (not deployed: ./run -a do_spl_self_host_up)` in
   `do_check_hub_deploy`), never a bare stack trace or exit code.
4. **The wait is stated and measured.** Each step names how long a developer
   waits for the answer, today and after the step, with n and the box; the
   lane re-measures it after landing.

Each step below carries one **DevX** line: what a developer types and waits
for today, and after the step.

## 3. The ten steps, ranked by value for effort with DevX

**Re-ranked in v1.1.** The DevX lens weighs how often a developer pays the
wait. So the step that cuts ~21 min off every hub push (~11 a day) moves from
3 to 1, and the alarm for silent reds from 6 to 3. The owner's live buy moves
from 2 to 6: it is still the highest risk, but it is 30 minutes of the
owner's time once, not a developer's wait, and it can run on any day. The e2e
weights (was 8) and the no-checkout compose (was 7) swap places: the first is
paid on every push, the second once per new self-hoster. The old number is
given in each heading.

### 3.1 Step 1 (was 3) — the hub deploy stops re-running the suite the gate already ran

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
- **DevX.** Today: the developer pushes with `./run -a do_spl_push_master`,
  then waits a p50 **36.9 min** (n=100) until `ENV=prd ./run -a
  do_check_deploy_lag` says `current`. After: the same one command and about
  16 min (an estimate: 36.9 minus 20.9 measured on n=1). A red in wf 10 now
  also stops the deploy, and the deploy summary names that wf 10 job and its
  log, so there is one place to look.
- **Size.** M.
- **Worked when.** wf 20 p50 falls from 36.9 min to under 22 min over the next
  100 runs, and its red rate stays at or under 1 in 100.

### 3.2 Step 2 (was 1) — the compose file pins the newest stable, not one from October

- **Pain, measured.** `docker compose up -d` with no env pulls
  `stable-2026-10-12` (`grep -n ghcr.io/csitea docker-compose.yml` -> lines
  136, 179, 276, all `stable-2026-10-12@sha256:...`), while the newest release
  is `stable-2026-11-09` (`gh release list -L 6` -> `stable-2026-11-09 (v9.2.7)
  Latest`). A new self-hoster starts **4 stables behind**: the pinned
  stable was released 27 d 23.5 h before the newest (2026-10-12T07:20Z to
  2026-11-09T06:51Z, `gh release list`), and is 32 days old on the day of
  measurement (2026-11-13). The pin
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
- **DevX.** Today: someone must notice the wf 56 summary line, run
  `PIN_TAG=<tag> DRY_RUN=0 ./run -a do_pin_compose_images` (dry run 4.0 s,
  n=1, lane box), then commit and push two files by hand; for 4 releases
  nobody did. After: nothing to type; the pin lands with the release, and a
  failed pin is a red wf 56 run that step 3 posts to `#alerts`.
- **Size.** S.
- **Worked when.** `grep -o 'stable-[0-9-]*' docker-compose.yml | sort -u`
  equals the newest `gh release list` tag within 1 day of every release, for
  4 releases running.

### 3.3 Step 3 (was 6) — a red release or image build alarms someone

- **Pain, measured.** The deploy-failure alarm (spec 055 section 2) polls only
  workflows 20 and 30 (`sed -n 27p
  csi-spl-orc/src/bash/run/spl-deploy-failure-poll.func.sh` -> `for wf in "20
  ci-cd: spool hub build + deploy" "30 ci-cd: spool wui build + deploy"`). The
  two workflows that ship to self-hosters were red in **2 of 6** (wf 56, GHCR
  images: master weekly runs, one more skipped; a 7th run, workflow_dispatch
  37205358043 on branch `c-191-t015-ghcr-proof`, also failed and is not
  counted; `gh run list -w 56_ghcr-images.yml -L 12`) and **1 of 8** (wf 55, stable) weekly runs, and no alarm fired for
  them.
- **Change.** Add wf 55 and wf 56 to that list; the post already names the
  failing step and the sha.
- **Touches.** `csi-spl-orc/src/bash/run/spl-deploy-failure-poll.func.sh` and
  its test.
- **DevX.** Today: a developer learns of a red release only by typing `gh run
  list -w 56_ghcr-images.yml` and reading it. After: nothing to type; one
  `#alerts` post with the failing step, the sha and the run link, from the
  cron that runs every 10 min (the interval stated in
  `csi-spl-orc/src/bash/scripts/spl-ops-alarm-cron.sh`; the delay itself is
  not measured).
- **Size.** S.
- **Worked when.** a red run of wf 56 on a throwaway branch posts one `#alerts`
  line (the red control), and the next real red is seen the same day.

### 3.4 Step 4 (was 4) — the canary decides on traffic, not on a fixed 10 minutes

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
- **DevX.** Today: nothing to type, a fixed 12.3 min wait inside every hub
  deploy (n=1). After: nothing to type, a wait of "until the floor is met",
  **not measured** until the first half of this step has run. A rolled-back
  canary prints the request count, the error count and the floor it missed,
  so the developer knows whether it was the code or too little traffic.
- **Size.** S (the measurement), then M (the early end).
- **Worked when.** the roll step p50 falls under 5 min and rollbacks still
  fire: a red control (a canary image that answers 5xx) is rolled back on dev.

### 3.5 Step 5 (was 5) — CI proves the path the README gives a stranger, and times it

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
- **DevX.** Today, for the stranger: `git clone --depth 1` (6.2 s, n=1, lane
  box), then `docker compose up -d` or, on a domain, `./run -a
  do_spl_self_host_up`, and a wait that is **not measured** since 2026-09-28.
  After: the same commands, and the wait is a number on every stable's run
  summary. A leg that breaks the README path turns wf 50 red on the push that
  broke it, not on a stranger's machine.
- **Size.** S.
- **Worked when.** every stable carries the four timings in its run summary,
  and 047 section 3.3 rows "pull to healthy" and "stranger to first message"
  are filled from them instead of "not re-measured".

### 3.6 Step 6 (was 2) — one live buy on prd (047 W3, still open)

- **Pain, measured.** The paid path has **never run on prd**:
  `payment_checkouts` has 0 rows, and all 23 prd tenants are `manual` or
  `internal` (section 1). It is proven on dev only (`316951195`,
  `do_spl_paid_owner_probe`), and it is still rank 1 in 047 section 2.1.
- **Change.** The owner runs the W3 checklist (topic `bea3a4e6`, SPL-1164):
  one 20 EUR buy, a sign-in as the buyer, a refund. The same session checks
  the spec 072 F31 gap (no `box-wui` pin for a bought tenant).
- **Touches.** No code: the owner's card and 30 min. A defect it finds becomes
  its own lane.
- **DevX.** Today: a checklist done by hand, and the check after it is by hand
  too: `do_spl_paid_owner_probe` refuses prd ("ENV must be dev (a test
  checkout; prd checkouts are real)",
  `csi-spl-orc/src/bash/run/spl-paid-owner-probe.func.sh`). After: the card
  payment stays by hand (the one exception to bar item 1: a real payment is
  the owner's), and a read-only prd mode of that probe checks the result in
  one command. Not measured: how long the checklist takes.
- **Size.** S (owner, 30 min), plus S for the read-only prd probe.
- **Worked when.** `payment_checkouts` on prd holds 1 `paid` row, then the
  refund; the buyer reached the app as `biz_owner` with 0 operator actions.

### 3.7 Step 7 (was 8) — the e2e shard weights refresh themselves

- **Pain, measured.** The CI gate's wall time is set by its slowest job. The 8
  WUI e2e shards are already packed longest-first from
  `csi-spl-wui/src/node/test/e2e-shard-weights.txt`, but they still ran p90
  **937 s to 1170 s** (shard 5/8 vs 6/8, n=48, `do_report_ci_gate`, timeout
  headroom section): a 233 s spread. In run 43175952216, a code push, the
  slowest shard ran 18.4 min and the fastest 13.5 min. The weights file is
  refreshed by hand (`git log --format='%h %cs' --
  csi-spl-wui/src/node/test/e2e-shard-weights.txt` -> 13 commits, 7 of
  them weight refreshes, the last refresh `81c58efff` on 2026-10-19; the
  newest commit, `bc685b890` on 2026-11-10, is a feature commit that also
  touched the file), so it drifts as specs grow between refreshes.
- **Change.** A scheduled job rewrites the weights from the per-file times of
  the last green wf 10 runs (the runner already prints them, per its header)
  and lands the file when it moves by more than a set margin. The shard count
  stays.
- **Touches.** `csi-spl-wui/src/node/test/e2e-shard-weights.txt`, a small
  `csi-spl-orc` action and its test, a schedule in `.github/workflows/`.
- **DevX.** Today: a developer who notices the drift reads per-file times off
  job logs and hand-edits the weights file; every push waits a gate p50 of
  21.5 min (n=100). After: no hand edit (bar item 2); the same action can be
  run by hand when needed, and every push waits about 2-3 min less (an
  estimate from the spread).
- **Size.** S.
- **Worked when.** the p90 spread across the 8 shards stays under 60 s for 4
  weeks with no hand edit of the weights; wf 10 p50 falls by about that
  spread.

### 3.8 Step 8 (was 7) — the compose stack runs without a repo checkout (spec 072 T033)

- **Pain, measured.** `docker-compose.yml` still bind-mounts two files from
  the checkout, in four mounts: `pg-init.sh` (line 86) and `secret-env.sh`
  (lines 116, 159 and 248)
  (`grep -nE 'pg-init\.sh|secret-env\.sh' docker-compose.yml`). A self-hoster
  must clone the repo to run the stack: 133 MB shallow (6.2 s, n=1), and a
  full clone's `.git` is 614 MB (047 section 1.1). T033 is open (`grep -n
  T033 csi-spl-doc/specs/072-rapid-deployability/tasks.md` -> `- [ ]`).
- **Change.** Bake `pg-init.sh` and `secret-env.sh` into the published images,
  so that downloading `docker-compose.yml` and running `docker compose up -d`
  is enough. The README quick start says so.
- **Touches.** `docker-compose.yml`, `csi-spl-api/src/docker/pg-init.sh`,
  `csi-spl-api/src/docker/secret-env.sh`, the hub Dockerfile, wf 55 (the
  files T033 owns).
- **DevX.** Today: `git clone` (6.2 s shallow, n=1), `cd`, `docker compose up
  -d`. After: one download of one file, then `docker compose up -d`; nothing
  else on disk. A missing secret makes `hub-init` print which variable to set
  (bar item 3), as its default-password refusal already does.
- **Size.** M.
- **Worked when.** the leg from step 5 runs from the compose file alone, in an
  empty directory, and is green.

### 3.9 Step 9 (was 9) — a blank cnf template and `do_spl_cnf_init` (spec 072 T041)

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
- **DevX.** Today: hand-edit 3018 lines and find the 19 files that name our
  domain (bar item 2 broken by design). After: `ORG=<org> APP=<app>
  BASE_DOMAIN=<domain> ./run -a do_spl_cnf_init`, then fill only the values it
  lists as missing; the conf-validator names each missing key and its file.
  Not measured: either time.
- **Size.** M.
- **Worked when.** `do_spl_cnf_init` for a made-up org renders tfvars for
  every step with `do_tpl_gen`, and `grep -rc spool-hub.ai` over its output
  finds 0.

### 3.10 Step 10 (was 10) — byo-GCP without a fork: org optional, workflows read cnf (spec 072 T026 + T021)

- **Pain, measured.** `gcp-001` still refuses to run without an org or folder
  (`csi-spl-iac/src/bash/run/gcp-001-create-project.func.sh:62`: "GCP_ORG_ID
  or GCP_FOLDER_ID must have a value"). The workflows name our estate
  directly: `GCP_KEY_CSI_SPL_` **82** times (83 for the bare
  `GCP_KEY_CSI_SPL`; the extra hit is a notice text in
  `32_docs-publish.yml:60`) and `self-hosted` **44** times
  (`grep -rn GCP_KEY_CSI_SPL_ .github/workflows/ | wc -l`; `cat
  .github/workflows/*.yml | grep -c self-hosted`), and 9 terraform files
  accept only `dev`/`prd`. These are 047 G3, G5 and G6; spec 072 D1 made
  byo-GCP a supported path. 047 puts the cost at 2-3 days for an expert
  (an estimate, not measured).
- **Change.** T026 (org optional: a project under a billing account alone)
  and T021 (wf 20 and wf 30 take env names and secret names from cnf); then
  T051 `do_spl_estate_up` strings the steps together.
- **Touches.** `gcp-001-create-project.func.sh` and its test; the env and
  secret lines of wf 20 and wf 30; later a new `do_spl_estate_up`.
- **DevX.** Today: fork, then hand-edit the workflows and terraform, then run
  gcp-000..004 and 30 terraform steps one by one (2-3 days, estimate). After:
  step 9's `do_spl_cnf_init`, then `ENV=<env> ./run -a do_spl_estate_up`, which
  stops at the first missing prerequisite and prints it (billing account,
  domain delegation, SMTP). Not measured until spec 072 T052's clean-room run.
- **Size.** L.
- **Worked when.** both counts reach 0 outside one cnf-reading helper, and the
  spec 072 T052 clean-room estate stands up in a second org with a measured
  time.

## 4. Summary

| # (was) | step | pain (measured) | DevX after | size |
|---|---|---|---|---|
| 1 (3) | the deploy reuses the gate's hub suite | 20.9 of 38.2 min push-to-prd is a second suite run; wf 20 p50 36.9 min | same push, ~16 min wait (estimate) | M |
| 2 (1) | compose pins the newest stable (automate `do_pin_compose_images`) | default pull is `stable-2026-10-12`, newest `stable-2026-11-09`: 4 stables behind, released 28 days apart (32 days old on 11-13) | no hand step, no hand-edited pin | S |
| 3 (6) | wf 55/56 reds alarm | the alarm polls only wf 20/30; wf 56 red 2 of 6 on master, wf 55 1 of 8 | an `#alerts` post instead of `gh run list` | S |
| 4 (4) | the canary ends on traffic, not after 10 min | roll step 12.3 of 17.3 min; canary request count not measured | a rollback says why | S, then M |
| 5 (5) | CI proves and times the README pull path | wf 50 builds from source; stranger time last measured 2026-09-28 (6 min 26 s) | the stranger's wait is a number per stable | S |
| 6 (2) | one live buy on prd (W3) | 0 `payment_checkouts` rows on prd, ever | the check after the buy is one action | S (owner, 30 min) |
| 7 (8) | e2e shard weights refresh themselves | shard p90 937..1170 s, 233 s spread; weights edited by hand | no hand edit; ~2-3 min less per push (estimate) | S |
| 8 (7) | compose without a checkout (T033) | 4 bind mounts of 2 repo files; 133 MB shallow clone | one file, one command | M |
| 9 (9) | cnf template + `do_spl_cnf_init` (T041) | 3018 cnf lines, `spool-hub.ai` in 19 files, no template | one action instead of 3018 lines by hand | M |
| 10 (10) | byo-GCP: org optional, workflows read cnf (T026, T021) | org required; `GCP_KEY_CSI_SPL_` 82 and `self-hosted` 44 in workflows | one action that stops at the first missing prerequisite | L |

Noted, not a step: the shown version wraps after `9.9.9` to `1.0.1` of the
next cycle (`csi-spl-orc/src/bash/run/release-version.func.sh:13`). The
stables read `v7.0.9` on 10-12, `v2.1.5` on 10-19 and `v9.2.7` on 11-09
(`gh release list`), so a self-hoster cannot order builds by version number;
the `stable-<date>` tag orders them. This is by design (repo `CLAUDE.md`,
"Never roll the version by hand").
