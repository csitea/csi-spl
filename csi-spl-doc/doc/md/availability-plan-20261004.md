# Availability and redundancy plan, 2026-10-04

Topic: t1 "Improve redundancy and availability of the system", task
`2c74edd5-d87d-4ceb-a5f7-a700085ba461`. Owner HUM-10 (aa35699c msg 4e7c0a46):
*"the self-heal aspect from this discussion - it should become a new
discussion titled - improve redundancy and availability of the system - and
move the comments there and start identifying other aspects on those
according to best practices to resolve and implemnt"*.

This doc plans. It changes no product code, cnf, terraform or workflow, and
it wrote nothing to GCP.

## 1. How it was measured

| field | value |
|---|---|
| tree | origin/master `de6f975f` (2026-10-04) |
| identity | each env's project SA from its key, `--account` on every call, a throwaway `CLOUDSDK_CONFIG` per env, removed after. Read-only: `describe`, `list`, `logging read` |
| when | 2026-10-04T18:45Z..18:59Z |
| n | given per row: "n=2 envs" = one reading per env; log counts are every matching entry in the window, capped at 5000 |
| reused, not redone | c-221's prd 429 analysis (aa35699c msg 0dc0bec0, `3f31d22d`); g-225's restore drill (spec 029 section 6.7, `3ff2d7fe`) |

## 2. Inventory: every single point of failure

Status: **SPOF** = one failure stops the service or loses data; **gap** =
redundancy exists but is unproven or unwatched; **ok** = matches best
practice today (listed so the next reader does not re-measure it).

### 2.1 Hub (Cloud Run)

| # | item | status | evidence |
|---|---|---|---|
| 2.1.1 | one instance holds every box and WUI WebSocket | **SPOF** | cnf `hub.cloud_run.max_instances: 1`, `min_instances: 1` (`csi-spl-cnf/csi-spl/all.env.yaml:246-247`); tf `030-cloud-run-hub/04-cloud-run-service.tf:8` (OQ-05). Live annotation `maxScale=1;minScale=1`, n=2 envs |
| 2.1.2 | right after a rollout Cloud Run stops routing to the single allowed instance (429 "no available instance") | **SPOF** | c-221, 0dc0bec0: n=6 bursts in 390 revisions 2026-09-25..10-04, each within 25 s..4 min of a revision's creation; the worst 17:30:55..17:41:31Z, 1209 x 429. Re-read here, prd 429 per day (7 d): 09-27 1, 09-28 19, 10-02 144, 10-03 1, 10-04 1210; dev: 10-02 1 |
| 2.1.3 | rollout frequency (each one is an exposure to 2.1.2) | context | revisions created in the last 7 days: 298 per env (n=2 envs; 392 / 394 total). 6 bursts / 390 revisions = 1.5 % per rollout, so ~0.6 bursts/day at ~42 rollouts/day |
| 2.1.4 | rollout is a 100 % cut-over, no no-traffic revision, no health-gated traffic shift | **gap** | `.github/workflows/20_hub-build-deploy.yml:642` (`gcloud run services update --image`); the post-roll check is the control plane (`:650-661`, `do_check_hub_deploy`) and the HTTPS smoke runs only after (`:720-726`, workflow 22) |
| 2.1.5 | dev and prd roll at the same moment; prd does not wait for dev's smoke | **gap** | `20_hub-build-deploy.yml:367-371`: one matrix over the envs, `fail-fast: false`; the concurrency group is per env (`:361-363`) |
| 2.1.6 | migrations run before the roll; a failed roll leaves the old image on the new schema | **gap** | `20_hub-build-deploy.yml:618` (`do_spl_db_bootstrap`) precedes the roll at `:642`. No N-1 compatibility test: `grep -rln 'previous release' csi-spl-api/src/bash/tests \| wc -l` -> 0 |
| 2.1.7 | 5xx | context | prd per day (7 d): 09-29 1, 10-01 70, 10-04 47; dev: 10-01 29, 10-03 1 |
| 2.1.8 | probes | ok, blind to 2.1.2 | startup 1 s x 120, liveness 30 s x 3 on `/healthz` (`04-cloud-run-service.tf:114-131`). Both instances answered `/healthz` 200 through the whole 17:31Z outage (c-221), so a probe cannot catch it |
| 2.1.9 | the container is stateless | ok | `04-cloud-run-service.tf:1-3`: Postgres and the files bucket hold everything |
| 2.1.10 | ingress is a Cloud Run domain mapping, no load balancer | **gap** (owner decision) | cnf `032-gcp-cloud-run-domain-mapping` comment (`all.env.yaml:150-156`, owner 2026-09-19 "exactly csi-rel: no load balancer"). Google documents domain mappings as preview and not recommended for production; a global external LB is the standard front |

### 2.2 Database (Cloud SQL)

| # | item | status | evidence |
|---|---|---|---|
| 2.2.1 | one zone, no standby | **SPOF** | cnf `availability_type: ZONAL` (`all.env.yaml:167`); live `availabilityType ZONAL`, `gceZone europe-north1-a`, no `secondaryGceZone`, n=2 envs |
| 2.2.2 | shared-core tier: outside the Cloud SQL SLA, 25 connections | **SPOF** | cnf `tier: db-f1-micro` (`all.env.yaml:166`), live n=2 envs. `max_connections` 25; hub pool 8 per instance, two instances in a roll take 16 (`all.env.yaml:278-283`). Also caps 2.1.1: a second instance has no connection budget on this tier |
| 2.2.3 | weekly maintenance window restarts the only instance when Google applies an update | **gap** | `040-cloud-sql-postgres/03-cloud-sql.tf:53-56`: day 7 hour 3 (Sunday 03:00 UTC); ZONAL, so a maintenance restart is a hub outage. `gcloud sql operations list`, 30 d, n=2 envs: 0 MAINTENANCE / FAILOVER / RESTART operations since the instances were created (2026-09-18), so it has not bitten yet |
| 2.2.4 | automated backups + PITR | ok, **never drilled** | tf `03-cloud-sql.tf:47-51`; live: backups on at 01:00, `retainedBackups 7`, `pointInTimeRecoveryEnabled true`, `transactionLogRetentionDays 7`, the last 3 `SUCCESSFUL`, n=2 envs. No PITR restore was ever run: `grep -rln 'point-in-time' csi-spl-iac/src/bash csi-spl-orc/src/bash \| wc -l` -> 0 |
| 2.2.5 | off-instance dumps: daily, RPO ~11 h measured | **gap** | workflow 45 cron `17 5 * * *`, best effort (`.github/workflows/45_db-backup.yml:60-63`: "treat this as once a day"). g-225, n=2: RPO 39 376 s (prd), 39 509 s (dev) |
| 2.2.6 | a restore fails verification whenever the dump predates a migration | **gap** | g-225, n=2 DB restores: exit 5, `box_stats` (0117) and `operator_audit` (0115) missing; dump at migration 114, live at 119. The compare is restored vs LIVE (`csi-spl-orc/src/bash/run/spl-db-restore.func.sh:124-146`), so any dump older than the newest migration reads red |
| 2.2.7 | deletion protection | ok | prd `deletion_protection: true` (`prd.env.yaml:106`), dev false |

### 2.3 Buckets and the off-project copy

| # | item | status | evidence |
|---|---|---|---|
| 2.3.1 | every bucket, the off-project copy included, is in ONE region | **gap** | `location = upper(var.gcp_region)` in 000 (`03-state-bucket.tf:4`), 020 (`03-relay-bucket.tf:22`), 045 (`03-backups-bucket.tf:28`), 046 (`03-offsite-bucket.tf:20`), 050 (`03-files-bucket.tf:18`), 051 (`03-docs-bucket.tf:18`); region europe-north1 |
| 2.3.2 | versioning | ok by design | off in 020/045/050/051 (relay transient, dumps uniquely named, files content-addressed, docs are git's); on in 046 and 000. Soft delete 7 d (30 d on 046) |
| 2.3.3 | off-project copy: byte restore never run | **gap** | g-225: listed as the env SA, 17 dumps per env; `BACKUP_SOURCE=bkp DRY_RUN=1` exit 1 `no key for csi-spl-bkp` on the satellite. Spec 044 T077 unmeasured |
| 2.3.4 | off-project copy exists and runs daily | ok | cnf `046 copy_enabled: true` (`prd.env.yaml:136`, `dev.env.yaml:132`); 30-day retention policy, unlocked (`03-offsite-bucket.tf:31-33`) |

### 2.4 Front end, DNS, secrets, CI

| # | item | status | evidence |
|---|---|---|---|
| 2.4.1 | WUI on Firebase Hosting | ok | global CDN, static bundle (019); nothing regional to fail over |
| 2.4.2 | Cloud DNS zones | ok | 025, managed zones; Cloud DNS carries a 100 % SLA |
| 2.4.3 | hub DSN and auth secrets: Secret Manager, one replica in europe-north1 | ok for now | `040-cloud-sql-postgres/03-cloud-sql.tf:102-126`, `030-cloud-run-hub/06-auth-secret-slots.tf:15-16` (user_managed). Same region as every reader, so no new failure domain |
| 2.4.4 | deploys and the daily dump are scheduled by GitHub Actions only | **gap** | workflows 20, 30, 45; GitHub's cron is best effort (`45_db-backup.yml:60-62`). A GitHub outage stops deploys and the dump; it does not stop the hub |

### 2.5 Boxes, desks, lease

| # | item | status | evidence |
|---|---|---|---|
| 2.5.1 | box -> hub WebSocket reconnect | ok | capped exponential backoff, full jitter, 1 s..30 s, reset after 60 s stable (`csi-spl-api/src/go/spool-hub-api/internal/hubclient/backoff.go:29-38`); an offline box's queue is kept 168 h (`all.env.yaml:276`) |
| 2.5.2 | every desk cron checks out `origin/master` on each tick: trunk is the desk deploy, no canary, no lock | **SPOF** | the desk user's crontab on the satellite: 8 of 10 entries begin `git checkout -q --detach origin/master` in the one shared desk checkout, n=1 box. A red trunk reaches every desk within 5 min; two crons in the same minute share one work tree |
| 2.5.3 | fleet lease (orch, dispatch) fails over between the box PC and the satellite | ok | 180 s silence, then take-over (`csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh:52,92`); live since 2026-10-01 (`SPEC-spool-fleet-roles.md` section 7); tested (`csi-spl-orc/src/bash/tests/fleet-lease.tst.sh` cases 3-4). Holder read now: the box PC's master, age 48 s, n=1 |
| 2.5.4 | the lease lives on the hub: a hub outage past 180 s leaves NO orchestrator and NO dispatcher | **gap** (by design) | `SPEC-spool-fleet-roles.md` section 4.1; `fleet-lease.tst.sh` case 8 "hub unreachable past LEASE_STALE: the holder demotes itself locally" (`spl-dispatch-lease.func.sh:1075`). Correct fencing (no split brain), but it means the fleet cannot be the thing that notices or heals a hub outage: detection and the first heal must be software plus a page to the owner (rows R01, R03) |
| 2.5.5 | the satellite VM: one zone, no snapshot schedule | **gap** | `grep -rc 'resource_policies\|snapshot' csi-spl-iac/src/terraform/060-gcp-vm-satellite/` -> 0 in every file; 100 GB data disk (`prd.env.yaml:188`). It is the failover machine: losing it removes the failover, not the service |
| 2.5.6 | role failover beyond the lease (fence, health pinger, drill) | proposal | `PRINCIPLES-role-failover.md`: status PROPOSAL, no code. Its own topic (27f01e16); not re-planned here |

### 2.6 Watching it

| # | item | status | evidence |
|---|---|---|---|
| 2.6.1 | nothing pages: zero alert policies, zero uptime checks, zero notification channels | **SPOF** (detection) | `gcloud alpha monitoring policies list` (call ok, 0 rows), `monitoring uptime list-configs` 0, `beta monitoring channels list` 0, n=2 envs. `grep -rl google_monitoring_ csi-spl-iac/src/terraform \| wc -l` -> 0. The 17:31Z outage (1209 x 429 over 10 min) was found by a person |
| 2.6.2 | no SLO, no error budget | **gap** | `grep -rliE '\bSLO\b\|error budget' csi-spl-doc csi-spl-iac csi-spl-orc \| wc -l` -> 1 (spec 053, a mention). At ~42 prd rollouts a day, nothing slows deploys after an outage |
| 2.6.3 | deploy-lag watch | ok | workflow 00, hourly; watches versions, not availability |
| 2.6.4 | a 500 does not always log its cause | **gap** | 10-01: 99 x 500 on `GET /v1/view/topics` (prd 70, dev 29) and 0 app lines at severity >= WARNING in the window (`logging read`, 14:28-14:40Z, n=0). Only a panic (`internal/hub/server.go:583-588`) or a handler that logs itself (10-04: `read marks write`, `internal/hub/read_marks.go:120`) leaves a cause; 192 `StatusInternalServerError` call sites in `internal/hub` (`grep -rn ... \| grep -v _test \| wc -l`) |
| 2.6.5 | the per-human event log cannot see a hub outage | **gap** | `human_events` is written through the hub (`rdb 0045`). prd, 2026-09-25..10-03, n=129 rows: 0 rows with status 429 or 5xx, and 0 rows during the 10-04 17:31Z outage. It records client bugs, not availability |
| 2.6.6 | boxes are watched only by themselves | **gap** | `box_stats` (rdb 0117, `efde07f6`): each desk reports load/memory every 5 min, but nothing alerts when a box goes silent. A lane that wanted GCP VM metrics plus an IAM grant on the satellite's project (c-203, 8c4fcc46) was stopped before the grant |


## 3. Incident history

Owner addendum (HUM-10 msg e0074d9a): *"investigate all of the incidents from
the past - they are recorded now in the db and we do have history"*.

### 3.1 Where incidents are recorded

There is no incident table (`git grep -il incident -- csi-spl-rdb | wc -l` -> 0). The
history is spread over four places, each read read-only as the env SA:

| source | read with | range covered | n |
|---|---|---|---|
| Cloud Run request logs (429, 5xx), per revision | `gcloud logging read`, 30 d | prd 2026-09-18T20:02Z .. 10-04T19:00Z; dev 2026-09-18T18:55Z .. (oldest entry = service creation) | prd 1 380 x 429 on 11 revisions, 118 x 5xx; dev 110 x 429 on 11 revisions, 30 x 5xx |
| Cloud Run app logs (severity >= ERROR, panics) | the same | the same | prd 47 `deadlock detected`; 0 panics; dev 1 CRITICAL (09-19) |
| Cloud SQL operations | `gcloud sql operations list` | creation .. now | prd 5, dev 15 ops; 0 maintenance, failover or restart |
| hub DB, prd: `human_events` (errors a human saw), t1 `messages` from humans matching outage words, the topics they started | `ENV=prd ./run -a do_spl_db_query` (READ ONLY transaction) | human_events 09-25 .. 10-03; messages all of t1 | 129 events; 15 owner posts matched, 5 were incidents |

A "burst" below is one revision's 429 run (hours with >= 1 x 429 on one
revision). Durations come from the first and last log entry of the burst.

### 3.2 Hub incidents (the service was down or erroring)

| id | when (UTC) | how long | what failed | root cause | what fixed it | can it recur today? | plan row |
|---|---|---|---|---|---|---|---|
| I-01 | 10-04 17:30:55 .. 17:41:31 | 10.6 min | prd hub: every request 429, 1209 entries (00388 759, then 00387 450 after a traffic rollback) | post-rollout routing stall under max_instances 1 (c-221, 0dc0bec0) | an ad hoc fresh revision (00389) | yes, ~1.5 % of rollouts; auto-heal `f7e190b3` landed 2026-10-04, unproven on a real stall | R01, R17, R18 |
| I-02 | 10-02 05:12:52 .. 05:15:29 | 2.6 min | prd: 144 x 429 | same class (revision 00283) | the next revision 00284 | yes | R01, R17, R18 |
| I-03 | 09-28 03:49:00 .. 03:53:44 | 4.7 min | prd: 19 x 429 | same class (00101) | cleared by itself | yes | R01, R17, R18 |
| I-04 | 09-25 17:03, 09-26 12:47, 09-26 18:15, 09-27 17:37, 09-27 21:54, 10-03 02:57, 10-04 09:17 | < 1 min each | prd: 1-2 x 429 each, n=7 revisions (00054, 00074, 00083, 00094, 00097, 00341, 00378) | same class | itself | yes | R01 |
| I-05 | dev, 09-19 .. 10-02 | 11 bursts; worst 00036 09-22 11:51..13:31 (41, sparse) and 00052 09-25 15:05..15:17 (37) | dev: 110 x 429 over revisions 00006, 00029, 00032, 00036, 00052, 00057, 00061, 00076, 00078, 00091, 00327 | same class (one revision per burst) | the next revision or itself | yes | R01 |
| I-06 | 10-01 07:5x .. 19:xx | ~11 h, on and off | `GET /v1/view/topics` 500: prd 70 (revisions 00223..00250), dev 29; the owner saw "Failed to fetch" / "spool 500 internal" (human_events 10-01: 27 rows) | **unknown**: no app log line names it (2.6.4) | a later revision; no commit names it (`git log` 10-01 api fixes, n=7 read) | unknown; the class (an unlogged 500 shipped to dev and prd in the same run) can | R05, R06 |
| I-07 | 10-04 12:xx .. 18:xx | ~6 h, on and off | `PUT /v1/me/reads` 500, prd 47; app log `read marks write: deadlock detected (SQLSTATE 40P01)` x 47 | probable, from the code: the upsert's key arrays are built in Go map order (`internal/store/read_marks.go:155`), so two concurrent writes for one member lock the same rows in different orders | **not fixed** (`git log` since 10-04 08:00 on api, n=0 matching commits; no spool message names it) | yes, still open | R02 |
| I-08 | 09-29 | 1 request | prd `/api/v1/auth/preferences` 500 | unknown | - | unknown, n=1 | R05 |

### 3.3 Delivery and fleet incidents (the hub was up; the system was not)

| id | when (UTC) | how long | what failed | root cause | what fixed it | can it recur today? | plan row |
|---|---|---|---|---|---|---|---|
| F-01 | 09-30 ~05:00 .. 07:15 | ~2.5 h | no hub deploy reached dev or prd (t1 topic 3ebb5bde, owner "why the hub deployes were stuck ?!") | the shared test gate went red 6 times from 6 agents, then GitHub refused the release-tag push | `be3a871b` (tag via the API); epic SPL-1250 deploy-gate (pre-push gate) | lower: the pre-push hook now runs the gate; a red trunk still blocks every deploy | none new (SPL-1250 owns it) |
| F-02 | 09-30, overnight | ~8 h | three owner posts sat unanswered (SPL-1225) | the hub delivered them to no live agent | `29c1bb3c` unanswered-post sweep (every 10 min) | lower: the sweep is a cron on the desks, so it shares 2.5.2 | R07 |
| F-03 | 10-01 | unmeasured here | the whole agent fleet stopped | every agent ran under one login that hit its weekly limit | the fleet moved to the agent login (owner standing order 2026-10-01) | yes for any single login | none here (spec 068) |
| F-04 | 10-03 ~06:00 .. 07:50 | ~1.8 h | no orchestrator acted; topic a12a1f62 unanswered (t1 865b7a05: "it isn't working at all right now") | the satellite orchestrator hit its usage limit while holding the lease | the limit reset at 07:50Z; the lease's stall detector (`LEASE_STALL_RE`, `spl-dispatch-lease.func.sh:289`) now demotes a stalled holder | yes: spec 068 (four peer seats) is written, not built (t1 484d66e6 12:55Z: "ODs running: 0 of 8") | none here (spec 068) |
| F-05 | 10-03 ~03:40 | minutes after a hub update | every machine's agents showed offline (t1 b3bf3d13) | the shared presence stamp after a hub update | c-062's fix (t1 484d66e6 07:56Z) | it happened after a rollout; R05 shrinks rollouts' blast radius | R06 |
| F-06 | 10-03 11:51 | 193 s | the box PC's orchestrator went silent | unknown | the fleet lease failed over to the satellite at 181 s, as designed | - (the redundancy worked) | - |
| F-07 | 10-03 ~12:40 | - | four lanes the orchestrator started never ran: the launcher printed an id and a pane, the agents died at once (t1 484d66e6 12:42Z) | the brief file write failed, the launcher did not check | not verified here whether the launcher now checks the brief | unknown | none (spawn tooling) |

### 3.4 What the history says

- **Measured over 2026-09-18 .. 10-04 (16 days):** 21 hub incidents of the
  post-rollout class (prd 10: rows I-01..I-04; dev 11) and 2 code-defect 500 runs (I-06, I-07),
  plus 1 single 500. Zero Cloud SQL, bucket, DNS or Firebase incidents, and
  zero instance crashes. Every hub outage minute in the window came from a
  ROLLOUT or a CODE DEFECT, none from infrastructure.
- **Every hub incident was found by a person** (2.6.1). The longest (I-06,
  ~11 h, I-07, ~6 h, still open) are the ones nobody was paged for.
- The fleet incidents (F-01..F-07) are as long as or longer than the hub's:
  the longest is 8 h (F-02). Most are owned elsewhere (SPL-1250, spec 068);
  the plan names them so they are not counted twice.
- So the ranking below weights rows with incidents behind them first; rows
  with none (the infrastructure SPOFs of section 2) are real but have not
  broken yet, and each says so.

<!-- last-edit: 2026-10-04T19:40:00Z -->
