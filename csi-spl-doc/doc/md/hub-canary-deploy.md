# Hub canary deploy (Cloud Run radar step 3, SPL-2249)

Status: **on master** since `e32bef074`. cnf `hub.cloud_run.canary.enabled`
is `true` on **dev** (owner GO HUM-10 msg `828eb2f5`, 2026-10-18, t1 poll
`35012991`) and on **prd** (owner GO HUM-10 msg `320a8bfd`, t1 `8f476aa8`,
poll `a71b612b`: "roll prd through the canary from the next hub deploy").

## 1. What it does

Workflow 20 rolls the hub through a canary instead of a straight
`gcloud run services update --image`, when cnf
`env.hub.cloud_run.canary.enabled` is `true` for that env. No load balancer
(owner, 2026-10-07): Cloud Run's own traffic split and revision tags, which
the 032 domain mappings and the WUI's Firebase rewrite both honour.

`csi-spl-orc/src/bash/run/canary-hub-deploy.func.sh`, `do_canary_hub_deploy`:

1. The revision serving 100 % is the old one. A split already in place can
   only be a killed run (the deploy job is serialised per env): it is pinned
   to its largest share first.
2. `gcloud run services update --image <minted> --no-traffic --tag canary`:
   a new revision with 0 % of traffic and its own URL,
   `https://canary---<service run.app host>`.
3. At 0 %: three `/v1/health` probes on that URL, and `/version .commit`
   equals the commit being deployed.
4. `update-traffic --to-tags canary=<percent>` (default 10 %). For
   `<minutes>` (default 10) the tag URL is probed every 30 s; two failures in
   a row fail the canary.
5. After `metrics_lag_s` (default 120 s, Cloud Run metrics arrive late),
   Monitoring `run.googleapis.com/request_count` of the new revision over the
   window, by response class. It fails when
   - 5xx >= `max_5xx` (3) AND 5xx > `max_5xx_pct` (1 %) of its requests, or
   - no WebSocket upgrade (1xx) reached it although its share of the old
     revision's upgrades predicts 5 or more, or
   - Monitoring cannot be read (fail closed).
6. Pass: `update-traffic --to-latest --remove-tags canary`, the latest 100 %
   shape that `do_heal_hub_deploy` and `do_gcp_hub_restart` need. Fail:
   `update-traffic --to-revisions <old>=100 --remove-tags canary`, rc 1, the
   deploy job goes red and its later steps skip.

`DRY_RUN=1` (the default) prints every mutation and makes none.
`CANARY_CMD=status` is read only; `CANARY_CMD=rollback` pins the largest share.

## 2. The other changes

| file | change |
|---|---|
| `csi-spl-iac/src/terraform/030-cloud-run-hub/04-cloud-run-service.tf` | `traffic` joins `lifecycle.ignore_changes`: the split belongs to workflow 20, like the image. An apply mid-canary never snaps it to latest, nor un-pins a rolled-back service. |
| `csi-spl-cnf/csi-spl/all.env.yaml` | `hub.cloud_run.canary`: `enabled: false`, `percent: 10`, `minutes: 10`, `tag: canary`, `probe_interval_s: 30`, `metrics_lag_s: 120`, `max_5xx: 3`, `max_5xx_pct: 1`, `verify_margin_s: 300` (SPL-3461). No tfvars change. |
| `.github/workflows/20_hub-build-deploy.yml` | the roll step runs `do_canary_hub_deploy` when the cnf flag is `true`, else the straight roll as today. |
| `csi-spl-orc/src/bash/run/check-hub-deploy.func.sh` | traffic not 100 % on the latest ready revision is `unhealthy` (rc 4). Without it a rolled-back canary (template on the new image, old revision pinned) read `current`. SPL-3461: without `SPL_HUB_IMAGE_TAG` (the hourly workflow 00 watch, an operator), a two-revision split whose latest ready revision is younger than `minutes` + `verify_margin_s` (900 s by default, counted from the revision's creation) is `rolling`, rc 0: a canary in flight. An older split, a rolled-back canary, a three-revision split, an unreadable revision age and a deploy's own verify stay rc 4. |

## 3. Would it have caught the 2026-10-16 stuck instance?

**No.** Measured with `ENV=prd do_spl_hub_run_metrics`, prd, 2026-10-16:

- Revision `csi-spl-hub-prd-00734-7ln` rolled at 16:10:51Z and served
  normally for an hour: 16:05..16:55Z 3334 WS upgrades (1xx), 0 5xx, p99
  in-flight per instance at most 32.
- At 17:10Z Cloud Run started a **second instance of the same revision**
  (instance count 1 -> 2). From 17:15Z in-flight requests climbed 24 -> 970
  by 17:40Z and WS upgrades fell to 0 per minute from 17:20Z: the SPL-2238
  hello deadlock on a cold process.
- 5xx stayed rare: 7 in 31 min, of 1767 requests.

A canary only watches the roll. This roll was healthy; the failure came an
hour later, on an autoscaled instance, with no deploy. A 5xx gate would also
have passed the stuck window itself (7 of 1767 = 0.4 %); the WS-upgrade rule
in 1.5 is the one that matches its signature. Catching that class needs an
always-on alert on per-revision WS upgrades and in-flight growth, not a
deploy gate (a separate row, not this one).

What the canary does catch: a revision that fails at once under real
traffic: crash loops, a broken migration read, a 5xx burst, WS upgrades that
never land on the new code, a wrong image (`/version`).

## 4. Cost, risk, undo

### 4.1 Cost

One extra instance (1 vCPU, 512 MiB, CPU always allocated) for about 13 min
per roll: the old revision keeps its `min_instances: 1` while the canary runs.
Revisions created 2026-10-09..16: dev 188, prd 190, an upper bound for rolls
(restarts included). About 190 x 13 min = 41 instance-hours a week per env,
~178 a month. At list price ~0.07 USD per instance-hour (an estimate, not
checked against the billing account): **about 12 USD a month per env, 24 for
both**. A deploy job takes ~13 min longer (measured today: 3-4 min), well
inside its 30 min timeout.

### 4.2 Risk

- DB connections: two revisions x `max_instances` 2 = 4 instances, the same
  `4 x (4 + 1) + 1 = 21 of 22` budget a roll already uses, held ~13 min
  instead of seconds. A heal restart during a canary is not possible (heal
  runs after it).
- Cross-instance frames: edits, reactions, deletes, presence and issue frames
  reach only the instance's own sockets (cnf note at `max_instances`); with a
  split they also do not cross revisions. The same gap as `max_instances` 2,
  for 10 % of new sockets, for 10 min.
- Session affinity with a split: how the affinity cookie interacts with a
  revision split is not checked.
- The WIF deploy identity (`roles/run.developer`) has no Monitoring read; the
  deploy uses the project SA key today (secrets `GCP_KEY_CSI_SPL_DEV/PRD`
  exist), which read Monitoring in this measurement. On WIF the gate fails
  closed: every canary rolls back until `roles/monitoring.viewer` is granted
  (an IAM change, the owner's go).
- The WS rule needs upgrades to show up in a fresh revision's first minutes.
  Measured once (n = 1 roll): prd `csi-spl-hub-prd-00736-t98`, created
  19:23:23Z, counted 67 1xx in 19:23..19:24Z and 925 in its first 10 min
  (`_chd_counts`, read only). A 10 % share predicts ~90, far above the
  floor of 5. In the same 10 min the drained stuck revision `00734-7ln`
  ended 577 hung requests as 5xx.
- Old sockets stay on the old revision until they reconnect (the Cloud Run
  request timeout, 3600 s today, 600 s with radar step 7); a canary of 10 min
  sees only new sockets.

### 4.3 Undo

- One canary: `ENV=<env> CANARY_CMD=rollback DRY_RUN=0 ./run -a do_canary_hub_deploy`
  pins the old revision in seconds, no cold start (it kept its instance).
- The feature: `hub.cloud_run.canary.enabled: false` in cnf; the next deploy
  rolls straight, as today. The 030 `ignore_changes` stays harmless.

## 5. Turning it on

1. Owner's go for dev. Set `enabled: true` in `csi-spl-cnf/csi-spl/dev.env.yaml`,
   render (`ENV=dev ./run -a do_tpl_gen`, no tfvars change), push. Done
   2026-10-19. The 030 `ignore_changes` is a lifecycle rule, not a resource
   change: it needs no apply (the dev 030 plan of 2026-10-19 shows no line of
   it; its one change is another lane's env flip, applied under that lane's go).
2. A week of dev deploys; read each run's `canary:` lines.
3. Owner's go for prd: the same in `prd.env.yaml`, render
   (`ENV=prd ./run -a do_tpl_gen`, no tfvars change), push. Done 2026-10-19
   (msg `320a8bfd`). That go covers the cnf flip and the next prd deploy
   through workflow 20 only, no 030 apply: as on dev, the `ignore_changes`
   is a lifecycle rule and needs none.

Test: `bash csi-spl-orc/src/bash/tests/canary-hub-deploy.tst.sh` (gcloud, curl
and sleep stubbed; includes the gate on the 2026-10-16 numbers) and
`check-hub-deploy.tst.sh` (the traffic cases).
