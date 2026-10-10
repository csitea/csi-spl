signed against 15e4e5479

# Spec 122 review, seat s122-claude-2

Target: `git show 15e4e5479:csi-spl-doc/specs/122-capacity-scale-out/spec.md`
(66 lines). Every claim about the code below carries the command that shows
it, run on origin/master at 15e4e5479. Verdict: **NO at 15e4e5479, YES once
R1..R3 below are folded**. The direction (scale on 80 %, budget-bounded,
price gated on measurement) fits the owner's words; the draft does not yet
say WHICH capacity it scales, and the mechanism it names cannot run as
written.

## 1. What is missing or wrong (checked against the code)

### 1.1 Two capacities, and only one of them scales by adding boxes (R1)

The owner's words (72b5ed23) are "spawn new hardware resources and add them
to the spawn hub": boxes joined to one hub. The draft's section 2 mixes the
box fleet's CPU/RAM with the hub's own DB pool, as if both grew together.
They do not:

- **The hub is one Cloud Run instance by design.**
  `git grep -n -A2 'OQ-05' origin/master -- csi-spl-cnf/csi-spl/all.env.yaml`
  -> line 325 "max 1 in M1 so every box WS lands on one instance", and lines
  329-330 `min_instances: 1` / `max_instances: 1`. Adding boxes adds load to
  that one instance; it never adds hub capacity.
- **The DB is `db-f1-micro`** (`all.env.yaml:179`, `tier: db-f1-micro`) with
  a hub pool of 8 (`csi-spl-api/src/go/spool-hub-api/internal/config/config.go:268`,
  `envDefault:"8"`). 047 section 4.3 lists both as the ceiling
  (`deployability-analysis.md`, table "Capacity ceilings").
- So **"capacity" must be two numbers with two different responses**:
  - **box capacity** (CPU, RAM, agent seats on the boxes): answered by
    scale-out, a new box (the owner's mechanism);
  - **hub capacity** (one Cloud Run instance's CPU, DB connections out of
    25): answered by a vertical step (Cloud Run CPU, the 040 tier), each one
    an owner cost decision (spec 027 D5), never automatic. Raising
    `max_instances` above 1 needs the cross-instance WS fan-out first (047
    4.3: "max instances >= 2 with the WS fan-out proven across instances").
- Proposal: section 2 splits into 2.1 box capacity (scale-out) and 2.2 hub
  capacity (alert at 80 %, owner step). The hub fixed cost of section 9 is
  then exactly the 2.2 estate; the per-workspace cost is 2.1 plus tokens.

### 1.2 Isolation: a pooled box contradicts spec 108 and spec 073 (R2)

The draft assumes a new box joins a shared pool and is "marked ready to
receive new agents and workspaces" (line 24). On trunk:

- `git grep -n 'One box = one workspace' origin/master -- csi-spl-doc/specs/108-workspace-owned-boxes/spec.md`
  -> line 28: "an operator-run box never hosts another workspace's agents".
  108's owner question 1 ("Is a second workspace on one machine allowed?")
  is still open (108 section 7).
- The join token is per workspace: 073 line 81, `spj1.<tenant>.<secret>`.
  One token seats a box into ONE tenant; a pool box serving many workspaces
  has no join path today.
- So the unit of scale-out is open, and it decides everything downstream
  (the measurement, the price slice, the drain): **one box per workspace**
  (108 as written: a paying workspace gets its own box; "80 %" is then the
  fleet of free capacity across those boxes) or **a shared box with one OS
  user + spool root per workspace** (needs 108 Q1 = yes). Owner question
  Q-4 below. The spec must not pick it silently.

### 1.3 The provisioning path the draft names cannot run from the hub (R3)

Draft section 4 step 1: "The hub orchestrator invokes ... `do_tf_apply_target`
... to provision a new VM". Checked:

- `do_tf_apply_target` exists (`csi-spl-iac/src/bash/run/tf-apply-target.func.sh:6`)
  but runs inside the tf-runner container, reached by `docker exec ...
  con-$ORG-$APP-tf-runner ./run -a do_tf_apply_target`
  (`csi-spl-orc/src/make/tf-tasks.func.mk:80-90`). The hub is a Cloud Run
  container with no docker and no tf-runner; it cannot call it.
- The only VM step is a **singleton**: `060-gcp-vm-satellite/03-vm.tf:31`
  `resource "google_compute_instance" "satellite"`, fixed `vm_name` from cnf
  (`prd.env.yaml`, `vm_name: csi-spl-all-satellite`), no `count` or
  `for_each` (`git grep -n 'count\|for_each' origin/master -- csi-spl-iac/src/terraform/060-gcp-vm-satellite/03-vm.tf`
  -> no line). A second box needs a new step (or a `for_each` over a cnf map)
  and its own state key per box.
- It lives in project `csi-spl-all` (`prd.env.yaml`, `tf_key_project:
  csi-spl-all`), run as the csi-spl-all SA; the hub runs as the per-env SA.
  A hub that applies terraform needs compute-admin rights in csi-spl-all:
  a large grant for an internet-facing service.
- The repo rule: CLAUDE.md line 66, "Nothing mutates GCP without the owner
  ... `terraform apply` each need an explicit go". Automatic scale-out is a
  standing exception to that rule; only the owner can grant it (Q-5 below).
- `do_satellite_playbook` installs the OWNER's box: 057 lines 205-209,
  `do_satellite_creds_push` copies the prd/dev SA keys and the GitHub token,
  and the AI CLIs are logged in by hand ("paste-the-code login"). A customer
  box built from it would carry the owner's credentials, and a hand login
  cannot be automated. A customer box needs its own role set: no estate
  keys, model access by pay-per-token API key (121 Q-M3 A), joined with a
  073 token.

Proposal (buildable, no automatic apply in v1): a new terraform step
`061-gcp-vm-pool` with `for_each` over `steps.061-gcp-vm-pool.boxes` (cnf
map box_id -> machine_type), labels `box=pool`, `pool_box=<id>`; a
`do_spl_pool_scale_out` action (dry run by default) that adds one entry,
renders tfvars, runs `make do-tf-plan` and prints the plan; the apply runs on
the owner's go (v1) or, after Q-5 = B, by a box-side cron holding a fleet
lease (0094, like the other side-effect crons), never by the hub. The hub
only **decides and records** (a `scale_requests` row); a box-side worker
acts.

### 1.4 The signals named in section 2 do not exist yet

- `usage_events` and `agent_seconds`:
  `git grep -c usage_events origin/master -- csi-spl-api csi-spl-rdb` -> no
  match; they are spec 121 section 7 (`spec.md:219-245`), not built.
- `do_gcp_list_monitoring` lists uptime checks, alert policies and channels
  (`csi-spl-iac/src/bash/run/gcp-list-monitoring.func.sh:2-6`); it reads no
  metric, and the boxes are in csi-spl-all, not in the env projects it
  lists.
- Box CPU/RAM is not reported to the hub at all; the roster has no capacity
  or state column (`csi-spl-rdb/src/sql/postgres/spool-hub/0001_hub_core.sql:47-54`:
  tenant_id, box_id, agent_id, announced_at).
- Proposal: boxes report a capacity sample on the existing heartbeat
  (`load1`, `mem_used/total`, `seats_used/seats_max`) into a new
  `box_capacity` table (DDL first, dev+prd, then code); the hub capacity is
  read from Cloud Monitoring by a named read-only action
  `do_spl_capacity_read` (env SA, `--account`), 1-min samples.

### 1.5 Smaller corrections

- Line 34: `embed_full` is 503 in 121 (`spec.md:205`), not 429; and
  `token_quota` is a token budget refusal, not a capacity one. A full fleet
  needs its own code: 503 `capacity_full` with `Retry-After`.
- Line 4 "funded by the customers' prepaid cards, ensuring the scaling is
  profitable": a prepaid balance covers tokens (121 section 8); nothing in
  the draft ties a new box's monthly cost to balances. See 1.6.
- Section 3's "billing state ensures we only scale when prepaid customer
  balances cover the cost" has no data source: the SAs cannot read billing
  (121 line 242, "Cloud cost: allocated, not measured").
- Section 8 "verified against reasonable bounds in CI": a CI load test on a
  shared runner measures the runner. The measurement belongs on a dedicated
  box (see 3); CI checks only the shape of its output.

### 1.6 The budget guard (section 3) is an alert, not a guard

`csi-spl-iac/src/terraform/059-gcp-satellite-budget/03-budget.tf:4`:
"Alerts mail the billing account's admins ...; nothing is ever stopped".
`prd.env.yaml:180` `budget_amount_month: 170`. So the "budget guard" must be
code on our side, before the plan: `boxes_running x box_month_cost(machine_type)
+ new box <= pool_budget_month` (cnf), and `sum(prepaid balances) >= N months
of the new box` if the owner wants the card link (Q-6). The 059 alert stays as
the out-of-band backstop.

## 2. "USD 60/month fixed hub cost" is an estimate

Source: 047 `deployability-analysis.md:279`, "**total per env** ~$60-65",
section heading "Monthly running cost (estimate, list prices, 730 h)",
measured 2026-09-28. Not an invoice; the env SAs cannot read billing.

- The spec must say "estimate (047 4.2, list prices, 2026-09-28)" until
  measured, and must count dev too: dev pays the same always-on CPU (047 4.2
  point 1), so the fixed estate behind prd sales is ~$120-130/month (dev +
  prd) plus the satellite/pool project, unless the owner rules dev out of
  the slice (Q-7).
- How to measure: the **GCP billing export to BigQuery** (121 line 242
  already names it as a one-time owner bootstrap). Build it as
  `do_gcp_billing_export_setup` (owner, once; dry run by default) and
  `do_spl_estate_cost_read` (read-only, a reader SA with
  `roles/bigquery.dataViewer` on the export dataset only): monthly cost per
  project and per label (`box=satellite`, `box=pool`), written into
  `estate_cost_months (month, project, label, usd_micros, source)`.
  `source = estimate | billing_export`; the price gate (section 4) accepts
  only `billing_export` rows of a closed month.

## 3. Q-2 option A needs measurements first, in this order

Option A (fixed cost / theoretical max workspaces) is only as good as the
"max". Order:

1. **Hub fixed cost, per month, measured** (section 2 above): one full
   billing month from the export.
2. **The hub's ceiling per resource**, on a lab copy of the prd shape (1
   vCPU / 512Mi, db-f1-micro, pool 8): ramp synthetic workspaces (each: 1
   private channel, the 10-turn baseline of draft section 8, its WS) until
   the first of: p95 post latency > a cnf bound, DB connections > 80 % of
   (25 - 5 reserved), hub CPU > 80 %, memory > 80 %. Record which one bit
   first. That is **max_workspaces_hub**.
3. **Per-workspace and per-private-channel box cost** (draft section 8, on a
   dedicated pool-shaped box, not CI): CPU-seconds, peak RSS, DB connections
   held, bytes stored, per baseline workspace; then the delta of one extra
   private channel in the same workspace. n >= 5 runs, median and spread
   reported (the CLAUDE.md three fields: version, sha, n).
4. **Token gap** (owner add f5c0e3c7, section 4.1): our count vs the
   provider's.
5. Only then: slice = fixed_month / (max_workspaces_hub x a planning
   utilisation, e.g. 0.8 to match the trigger), not / max: pricing at 100 %
   of a ceiling never recovers the fixed cost before the next vertical step.

The action is `do_measure_workspace_capacity` (draft name kept), dry run by
default, writing `capacity_measurements (run_id, sha, version, n, resource,
per_workspace, per_channel, ceiling, bottleneck, measured_at)`.

## 4. Owner add 55309d31: fixed slice, per workspace, per private channel, gate

- **Fixed slice**: one row per month, `hub_fixed_slice_usd_micros =
  estate_cost_month / (max_workspaces_hub x planning_util)`, from 2 and 3.
  The invoice line is `cloud_share` (121 section 7), labelled "allocation".
- **Per workspace** and **per private channel**: from step 3, as two
  separate unit costs, because 121 section 10 sells the private channel
  later as its own line (`channel_seat`).
- **The gate** (buildable, with its control): a hub check
  `pricingReady(month)` = an `estate_cost_months` row with
  `source=billing_export` AND a `capacity_measurements` row with n >= 5
  newer than the last hub shape change (Cloud Run CPU/memory, 040 tier, pool
  size: those cnf keys hashed into the row). The `/services` page (121
  section 9) and the checkout's `metered` plan both read it; false -> no
  price shown, checkout 409 `pricing_not_ready`. Control test: a store test
  that deletes the measurement row and asserts the checkout refuses; it
  fails if the check is removed. A shape change (e.g. db tier) invalidates
  the measurement automatically via the hash.

### 4.1 Owner add f5c0e3c7: the token margin of error, measured

The buffer VALUE is spec 121's (c-002 asked the owner, post 1099c002). Spec
122's part is the measurement that sets it from data:

- **Action** `do_spl_token_gap_measure` (read-only): for one calendar day
  (UTC) and per provider, our metered tokens (sum of 121 `usage_events`
  `llm_tokens_*` rows by provider + model, plus the `unmetered` turn count)
  vs the provider's own usage report for the same API key and day (the
  provider's usage API or its invoice CSV, read with a read-only key that
  never reaches a box). Output: `gap_pct = (provider - ours) / provider` per
  provider, model, kind.
- **Where the gap comes from** (each listed so a gap is explained, not just
  padded): turns with no usage record (`unmetered`), retries the seat makes
  inside one turn, tool-call and system-prompt tokens the CLI adds, cache
  write vs read pricing, sub-agent turns the seat runs on its own.
- **Use**: the price buffer (121) = the measured p95 of daily `gap_pct` over
  >= 14 days, rounded up to the next 5 %; until 14 days exist, the owner's
  10-20 % stands, labelled "estimate". A daily gap above the buffer alerts
  the owner (we are under-billing).
- **Control test**: feed the action a fixture with a 30 % provider excess
  against a 20 % buffer; it must alert. Removing the comparison makes the
  test fail.

## 5. Trigger, hysteresis, budget guard, drain, failures: each with a control

All thresholds in cnf (`env.capacity.*`), none in code.

| rule | proposal | control test (fails when the guard is removed) |
|---|---|---|
| trigger | box capacity = max over CPU, RAM, seats of `used / max` across ready pool boxes; > 80 % for every 1-min sample in 5 min | samples 81 % x 4 then 79 %: no request; 81 % x 5: one `scale_requests` row |
| hysteresis | out at 80 % / in at 40 %, and a **cool-down** after any scale action (no opposite action for 30 min); one request in flight at a time | out then in within 10 min: second refused `cooldown`; two triggers while one pending: one row |
| budget guard | 1.6 formula before any request is written; max boxes cnf (the draft's 20) | budget exactly full: no row, reason `budget`; remove the check and the test sees a row |
| scale-in drain | `boxes.state` (`ready`, `draining`, `gone`; DDL first); draining = no new seat or workspace; destroy only when 0 seats AND no queued deliveries AND >= 24 h since drain began, or the owner forces | seat assignment to a draining box refused; destroy with one queued delivery refused |
| drain of a workspace's box (108 model) | a workspace box is never scaled in while the workspace is paid; only spare pool boxes are | scale-in picks a paid workspace's box: refused |
| failures | provisioning: 1 attempt, then alert + `scale_paused` until the owner clears it (no auto-retry loop, which spends money); join failure: destroy, alert, paused; hub capacity > 80 %: alert only | fake tf failure: second attempt not made; paused flag set |
| fleet full | 503 `capacity_full` + `Retry-After` for new workspaces / channels only; existing traffic is never refused for capacity | new workspace at full: 503; existing post at full: 200 |
| runaway | max 1 scale-out per 30 min and max N per day (cnf), independent of the trigger | 10 triggers in a day with N=3: 3 rows |

The draft's "Join Token Failure ... a new attempt is queued with exponential
backoff" (line 33) contradicts its own "does not infinitely retry" (line 32)
and spends money on each attempt: one rule, paused after the first failure.

## 6. Buildable lanes (ordered, disjoint files)

1. Spec text: split capacity (1.1), the isolation choice (1.2), the gate
   (4), the table (5). Docs only.
2. DDL: `box_capacity`, `boxes.state`, `scale_requests`, `estate_cost_months`,
   `capacity_measurements`, dev+prd first.
3. Hub: capacity sample on the heartbeat, trigger + hysteresis + budget
   guard writing `scale_requests` (decides only), with the section 5 tests.
4. IaC: step `061-gcp-vm-pool` (`for_each`), the customer box role set (no
   estate keys), `do_spl_pool_scale_out` dry run.
5. Measure: `do_measure_workspace_capacity`, `do_gcp_billing_export_setup`,
   `do_spl_estate_cost_read`, `do_spl_token_gap_measure`.
6. Gate: `pricingReady` in checkout and `/services`.

## 7. Owner questions (options, my recommendation, one-line reason)

- **Q-1 (draft) unit of capacity.** A: hardware (CPU/RAM/seats) on boxes.
  B: token rate / agent_seconds. **Recommend A, plus hub capacity as a
  separate alert** (1.1): tokens cost money but do not fill a box; the
  bottleneck that needs a new machine is hardware.
- **Q-2 (draft) fixed slice.** A: fixed / max workspaces. B: fixed / active
  workspaces. C: A, but divided by max x 0.8 and only from measured numbers.
  **Recommend C**: A's stability without pricing at a ceiling we never reach.
- **Q-3 (draft) scale-in delay.** A: 60 min below 40 %. B: 24 h. C: 60 min
  below 40 % to START a drain, destroy only after 24 h drained and empty.
  **Recommend C**: quick to stop new work, slow to destroy (a box rebuild
  runs a playbook allowed up to 60 min, `07-ansible.tf` `timeout 60m`).
- **Q-4 the unit of scale-out.** A: one box per paying workspace (108 as
  written). B: shared pool boxes, one OS user + spool root per workspace
  (108 Q1 = yes). **Recommend A for v1**: it is what 108 and 073 already
  guarantee; B waits for 108 Q1.
- **Q-5 who applies terraform.** A: the owner, per scale-out (today's rule;
  the hub only proposes). B: a box-side worker with a lease, automatically,
  within the budget guard. **Recommend A first, B after 4 weeks of A**: the
  first plans are reviewed before "nothing mutates GCP without the owner"
  gets a standing exception.
- **Q-6 the money guard.** A: a fixed monthly pool budget in cnf. B: A and
  prepaid balances >= 2 months of the new box. **Recommend B**: it is the
  owner's "people plug in their credit cards" made checkable.
- **Q-7 dev in the fixed cost.** A: the slice counts prd only. B: dev + prd.
  **Recommend B**: dev is paid every month and exists only to ship prd.
