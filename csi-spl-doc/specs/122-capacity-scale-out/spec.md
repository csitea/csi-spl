# Spec 122: Capacity Scale-Out

Status: **v1.1** (2026-10-10; the owner's answers to Q-1..Q-7 and S1..S6
folded into v1.0 569aac7a8 by the c-815 editor lane). v1.0 = rc1 fbb4f582a
signed by all four seats and the drafter. Draft by a-809 (15e4e5479). The
panel's reviews are in `reviews/`: s122-claude (editor), s122-claude-2,
s122-mistral and s122-agy. The seats and the drafter have retired, so v1.1
carries no seat signatures; the dispatch holder decides whether it needs a
fresh sign-off panel. Every owner question of v1.0 is answered (section 13);
what is still open is in section 14.2.

Owner words (csitea topic e001c851, HUM-10), verbatim:

- msg 72b5ed23: "The idea is that the service should be scalable. People are
  basically plugging in their credit cards, and as soon as we find out that
  we have more than 80% capacity filled in, we will spawn new hardware
  resources and we will add them to the spawn hub."
- msg 55309d31: "It is a bit tricky because we need to calculate how much the
  running of the spool hub costs as well, and how much capacity a single
  workspace channel would take. A gate to justify some slice for the whole
  spool hub infra as a fixed cost for the price of a workspace and a private
  channel"
- msg f5c0e3c7: "Yeah, we need to have some kind of margin error for the
  tokens as well, because my gut feeling is that there should be some kind
  of +10%, +20% overall on the token count (because of how the spool hub
  works and overall, not being able to measure the total amount of tokens)."

Owner answers to the v1.0 questions (same topic), verbatim, each with the
question list it answered (c-002's posts on dispatch-e001c851):

- msg b7ff5f4a, against the Q-1..Q-7 list (post 0cb1a488): "Q1a, c, q4 let's
  discuss that."
- msg b6a56949, against Q-5: "The production environment and the hosts on
  which the workspace runs"
- msg 72ce6ccc, against Q-3: "In the beginning, we will add the boxes
  manually."
- msg 0cbf4386: "Ask me more questions to iterate that. By scaling, I meant
  that as soon as we get more than 5 paying workspaces and channels, we will
  start the automation of the actual automatic scaling of hosts as well."
- msg 7b047d69, against S1..S6 (post 229c0612): "S1A, s2a, s3a"
- msg 2d9490e7, against S4..S6, Q-6, Q-7 (post 362657fe): "S4b, s5,s6a,
  q6yes, q7 yes,"
- msg e95a0695, against "was your 'c' Q-2 C?" (post 66ff86aa): "Yes"

## 1. Introduction

This spec defines how the spool estate grows when it fills up. When the
agent boxes reach 80% capacity, a new box is provisioned and joined to the
hub. Two limits bound it: a box count ceiling and a money ceiling. The price
of a workspace carries a measured slice of the fixed hub cost, and no price
is published until the numbers behind it are measured (section 9).

**Manual first, automatic after more than 5 paying customers** (owner
Q-3, msgs 72ce6ccc, 0cbf4386; section 3.1). At launch the hub only files
the request and a person with the owner's go adds the box. Once paying
workspaces and paying private channels together number more than 5, a
box-side worker adds and removes boxes within the guards.

**Capacity is two numbers, and only one of them scales out** (panel R1,
all four seats). The hub is ONE Cloud Run instance by design. Adding a box
adds load to the hub; it never adds hub capacity. So the box fleet scales
out (section 3), and the hub gets an alert and a vertical step that the
owner decides (section 2.2).

## 2. What "Capacity" Measures

### 2.1 Box capacity: scales out

- Measured per box as `used / max` of CPU (load5 / cpus), RAM and agent
  seats. The fleet already reports a load band per box: % of cores,
  `csi-spl-api/src/go/spool-hub-api/internal/store/fleet_load.go:15-33`
  (rdb 0118, 0134). rdb 0152 records the owner's "there will be always some
  20% extra capacity" (t1 338e5258); the 80% trigger is that headroom.
- What is missing: RAM and seats are not reported to the hub. The roster has
  no capacity or state column
  (`csi-spl-rdb/src/sql/postgres/spool-hub/0001_hub_core.sql:47-54`).
  Boxes add a capacity sample to the existing heartbeat (`load1`,
  `mem_used/mem_total`, `seats_used/seats_max`) into a new `box_capacity`
  table (section 10).

### 2.2 Hub capacity: alert and an owner step, never automatic

| limit | value today | where |
|---|---|---|
| Cloud Run | 1 vCPU / 512Mi, `min_instances 1`, `max_instances 1` (OQ-05), concurrency 1000 | `csi-spl-cnf/csi-spl/all.env.yaml:323-324,329-330,338` |
| hub process | GOMAXPROCS 1, GOMEMLIMIT 460MiB, 900 WebSockets in total | `all.env.yaml:354-355,390` |
| DB | `db-f1-micro`, max_connections 25 (3 superuser-reserved, 2 held by cloudsqladmin), hub pool 8 | `all.env.yaml:179,362-367` |
| per workspace | messages 100000/month, pins 256, files 10 GiB (429 `quota`) | `all.env.yaml:422-424`; `internal/billing/billing.go:28` |

- `max_instances 1` is deliberate: every box socket ends on the one
  instance, so delivery needs no cross-instance fan-out
  (`csi-spl-iac/src/terraform/030-cloud-run-hub/04-cloud-run-service.tf:8-9`).
  Raising it is a hub design change (047 section 4.3, "WS fan-out proven
  across instances"). It is out of scope here.
- Response: at 80% of hub CPU, of DB connections or of the 900 sockets, an
  ALERT goes to the owner (070 monitoring). The vertical step is the owner's
  cost decision (spec 027 D5): more Cloud Run CPU or memory, or the next
  040 tier.
- Each new box adds hub sockets. A box scale-out that would push the hub
  past 80% is refused, and the hub alert is raised instead.

### 2.3 Signals the draft named, and what they are

| name | what it really is | command |
|---|---|---|
| `do_gcp_list_monitoring` | lists uptime checks, alert policies and channels; reads no metric | `sed -n 1,20p csi-spl-iac/src/bash/run/gcp-list-monitoring.func.sh` |
| `usage_events`, `agent_seconds` | planned in spec 121 section 7; no table, no Go | `git grep -l usage_events origin/master` -> spec files only |

The hub metrics are read by a new read-only named action,
`do_spl_capacity_read`. It runs as the env SA with `--account`, reads 1-min
samples of `run.googleapis.com/container/cpu/utilizations` and
`cloudsql.googleapis.com/database/postgresql/num_backends`, and writes
`capacity_samples` rows.

## 3. Scale-Out: 80% Trigger, Hysteresis, and Budget Guard

All thresholds live in cnf (`env.capacity.*`), none in code.

- **Trigger**: the fleet box capacity (max over CPU, RAM and seats, across
  `ready` boxes) is above 80% for every 1-min sample in 5 min, AND the hub
  check of 2.2 passes. The hub then writes ONE `scale_requests` row; it
  decides and records, it never acts (section 4).
- **Hysteresis**:
  - out at 80%, in at 40% (section 5);
  - a cool-down of 30 min after any scale action, with no opposite action
    inside it;
  - one request in flight at a time;
  - a runaway cap: max N scale-outs per day (cnf), whatever the trigger says.
- **Ceilings**:
  - `scale.max_boxes`, the draft's 20;
  - `scale.max_month_eur`: (running boxes x the monthly cost of their
    machine type) + the new box must stay within it.
  - Both are checked before a row is written.
- **Money guard** (owner Q-4 / S5, msg 2d9490e7 "s5", the recommended row
  of post 229c0612):
  - **now (manual phase): A**, the monthly budget `scale.max_month_eur`
    and the box limit `scale.max_boxes` in cnf, as hard caps. While a
    person adds every box, that person is the money guard too (c-002's
    reading, post 7ad35e2f).
  - **from the start of automation: A plus B**, the sum of prepaid
    balances must also be at least 2 months of the new box's cost. The
    check runs only when `scale.mode = auto` (3.1).
- **Notification** (owner S2 = A, msg 7b047d69): every `scale_requests`
  row with `kind=out` reaches the owner as a post in a spool channel plus
  an email. In the manual phase that post is the request to add a box.
- **Box size** (owner S3 = A, msg 7b047d69): one standard machine type for
  every new box, `scale.box_machine_type` in cnf. Other sizes are decided
  once the measurements of section 8 exist. Which type is the standard is
  still open (14.2, RQ-3).
- **Region** (owner S6 = A, msg 2d9490e7): one region, the hub's,
  `europe-north1`. A box is never placed by the customer's location.

### 3.1 Manual, then automatic (owner Q-3, S1, S4)

| phase | when | who applies | source |
|---|---|---|---|
| manual (`scale.mode = manual`) | at launch, while paying workspaces + paying private channels <= 5 | the owner, or someone with the owner's go, per box (Q-3 A); the hub only files the request | msgs 72ce6ccc, 0cbf4386 |
| automatic (`scale.mode = auto`) | once that count is more than 5 | a box-side worker within the guards of section 3, using our own scripts (S4 = B), never a managed instance group | msgs 0cbf4386, 2d9490e7 |

- **The count** (S1 = A, msg 7b047d69): paying workspaces and paying
  private channels counted together. The hub computes it from the paid
  plans of spec 121 and shows it beside every scale request, so the owner
  sees when it passes 5.
- **The switch** from manual to automatic is a cnf value, not code. Who
  flips it when the count passes 5 is still open (14.2, RQ-1).
- In both phases the hub decides and records only; the terraform apply
  runs through the operator path of section 4, never in the hub.
- **The GCP budget is a backstop, not the guard.** 059 only alerts:
  `csi-spl-iac/src/terraform/059-gcp-satellite-budget/03-budget.tf:1-4`,
  "nothing is ever stopped". Every new box carries a `box=<name>` label and
  its own budget line, as 059 does. The satellite's budget is 170
  (`prd.env.yaml:180`), set for e2-highmem-4 (057 L112), but the machine is
  now `e2-standard-16` (`prd.env.yaml:197`). Re-check that amount (an
  estimate, unchecked by the panel).

## 4. Provisioning a New Box

The draft had the hub call `do_tf_apply_target`, mint a join token and run
`do_satellite_playbook`. None of that can run as written (panel R3):

- `do_tf_apply_target` runs inside the tf-runner container through
  `docker exec` (`csi-spl-orc/src/make/tf-tasks.func.mk:80-90`). The hub is
  a Cloud Run container with neither.
- Repo CLAUDE.md: terraform runs only in the tf-runner, and "Nothing mutates
  GCP without the owner".
- 060 is a single fixed VM: `resource "google_compute_instance" "satellite"`
  (`060-gcp-vm-satellite/03-vm.tf:31`), with no `count`/`for_each`, in
  project csi-spl-all. A second box needs new terraform, not `-target`.
- `do_satellite_playbook` builds the OWNER's box: estate SA keys and the
  GitHub token are pushed (057 L205-209), and the AI CLIs are logged in by
  hand. A customer box must never get those.
- Join tokens are minted by a workspace admin, per seat, valid 1 h, single
  use, with the tenant inside: `spj1.<tenant>.<secret>` (073 L44-46, L81-82;
  built in `internal/hub/join_tokens.go:55,148`). The hub has no minter of
  its own.

The path, buildable:

1. The hub writes a `scale_requests` row (section 3).
2. A new terraform step `061-gcp-vm-pool` with `for_each` over
   `steps.061-gcp-vm-pool.boxes` (cnf map box_id -> machine_type), labels
   `box=pool`, `pool_box=<id>`, one state key per box.
3. `do_spl_pool_scale_out` (dry run by default) adds one cnf entry, renders
   the tfvars, runs `make do-tf-plan` and prints the plan. The apply runs as
   owner Q-3 decided (3.1): in the manual phase, the owner's go per
   scale-out; in the automatic phase, the box-side worker within the
   guards (S4 = B).
4. A customer box role set (`do_spl_pool_box_playbook`): no estate keys,
   model access by a pay-per-token API key (121 Q-M3), joined with a 073
   token.
5. The token comes from a new operator-only mint path: an `asOperator`
   caller, named in `TestOperatorScopeCallers` (108 section 3.6), audited,
   with the token bound to the box's VM name.
   - **Whose box** (owner Q-2 = C, msgs b7ff5f4a "c" and e95a0695 "Yes"):
     a pool box is shared. Each workspace placed on it gets its own OS user
     and its own spool root on that box, so one box serves several
     workspaces.
   - **Conflict with spec 108**: 108 section 3 says "One box = one
     workspace", and its open section 7 question 1 asks "Is a second
     workspace on one machine allowed, as a second OS user + spool root?".
     Q-2 = C answers that question with yes. Spec 108 is not changed here; its follow-up
     belongs to the dispatch holder (reported on dispatch-e001c851). Until
     108 is updated, the pool box role set and the mint path wait for it.
     Resolved 2026-10-10 by 5ced76397: 108 section 3.5 now allows several
     workspaces per box; nothing here waits for 108 any more.
6. The box says hello, its key is pinned, and its state goes `ready`
   (section 10).

## 5. Scale-In: Draining and Removal

- **State**: a new `boxes.state` column (`ready`, `draining`, `gone`), with
  the DDL landing first, dev and prd before the code. Today the only drain
  is box-local: `dispatch/box.leave` from `do_spl_box_leave`
  (`csi-spl-orc/src/bash/run/spl-box-leave.func.sh`), and the spawn refuses
  on it with exit 6 (`spawn-agents/scripts/spawn-window.sh:129`). The hub
  state mirrors it. `git grep -n draining origin/master -- csi-spl-rdb`
  returns 0 hits.
- **Trigger** (owner Q-7 = C, msg 2d9490e7 "q7 yes"): the fleet below 40%
  for 60 min starts the drain of one box. It stops new work fast and
  destroys slowly.
- **Drain**: the least-used spare pool box goes `draining`, and gets no new
  seat or workspace.
  - Never a candidate: the box of a paid workspace while that workspace is
    paid, and the operator's own box `sat`. With a shared pool (Q-2 = C) a
    box can carry several workspaces, paid and unpaid; how this rule reads
    then is still open (14.2, RQ-2).
- **Remove**: only when the box has been `draining` for 24 h, is empty
  (0 running lanes, `roster.running`, rdb 0153; no workspace left on it)
  and has no queued deliveries. Then
  the pin is revoked (108 section 3.7) and the removal runs through the
  same operator path as section 4. The hub never destroys anything.

## 6. Failure Modes

- **Provisioning fails** (plan, apply or playbook): there is ONE attempt.
  The failure raises an alert and sets `scale_paused`, and no scale-out
  runs until an operator clears it. There is no automatic retry: every
  attempt costs money. The draft's line 33 (exponential backoff)
  contradicted its line 32 ("does not infinitely retry"). The panel took
  line 32.
- **The box never says hello within 20 min**: the box is flagged, the
  alert is raised and `scale_paused` is set. The hub does not destroy it;
  the operator's removal does.
- **Box fleet full** (both ceilings reached): new workspaces and new
  channels get **503 `capacity_full`** with `Retry-After`. Existing traffic
  is never refused for capacity. (The draft's 429 `embed_full` is a
  sales-embed limit, answered 503 in 121 L205, and `token_quota` is a token
  budget, so neither fits.)
- **Hub at 80%**: an alert to the owner only (2.2).

## 7. Tests and Controls

Every rule has a test and a control that fails when the guard is removed.

| rule | test | control |
|---|---|---|
| trigger | 81% x 5 samples -> one `scale_requests` row | 81% x 4 then 79% -> no row; with the window check removed, the first sample makes a row |
| cool-down | out, then in within 10 min -> the second is refused `cooldown` | with no cool-down, both rows are written |
| one in flight | two triggers while one is pending -> one row | without the check, two rows |
| ceilings | at `max_boxes` or `max_month_eur` -> refused, reason `budget` | with the check removed, a row is written |
| money guard (S5, `auto`) | `scale.mode = auto`, zero balances -> refused | with the balance check removed, a row is written |
| money guard (S5, `manual`) | `scale.mode = manual`, zero balances, within the caps -> a row is written | with the mode check removed, it is refused |
| manual phase (Q-3 A) | `scale.mode = manual` -> the row stays `pending` until an operator applies it; nothing calls the apply | with the mode check removed, the worker applies it |
| notification (S2) | an `out` row -> one channel post and one email | with the email hook removed, only the post goes |
| scale-in delay (Q-7 C) | 59 min below 40% -> no drain; 60 min -> drain; removal at 23 h 59 drained -> refused | with the 24 h check removed, the removal is allowed |
| hub headroom | hub at 80% -> box refused and hub alert raised | with the check removed, the box is requested |
| runaway | 10 triggers in a day with N=3 -> 3 rows | with no cap, 10 rows |
| drain | a draining box gets no new lane | with the state ignored, it gets one |
| remove | removal with one queued delivery is refused | with the check removed, it is allowed |
| paid box | scale-in picks a paid workspace's box -> refused | with the check removed, it is picked |
| failure | a fake tf failure -> no second attempt, `scale_paused` set | with the halt removed, it retries |
| fleet full | new workspace at full -> 503; existing post -> 200 | with the check removed, the workspace is made |
| price gate | empty measurements -> checkout refuses | with seeded rows -> a price is shown |
| token gap | a 30% provider excess against a 20% buffer -> alert | with the comparison removed, no alert |

The hub tests are Go store/hub tests on Postgres. The action tests are
`.tst.sh` files with a fake cloud. A CI load test on a shared runner
measures the runner, so CI checks only the SHAPE of the measurement output,
never its values.

## 8. Measurements, in Order

Q-6 = A (owner, msg 2d9490e7 "q6yes": fixed cost / max workspaces) needs
the max measured first.
Each step writes `capacity_measurements` rows (run_id, sha, version, n,
resource, value, bottleneck, measured_at), so the gate in section 9 can
check that they exist and how old they are.

1. **M0, the hub fixed cost per month**: one full billing month from the
   GCP billing export (section 9).
2. **M1, the hub idle baseline**: hub CPU-seconds, RSS, DB connections and
   DB CPU with 0 active desks (`do_spl_capacity_read`).
3. **M2, one workspace**: `do_measure_workspace_capacity` (dry run by
   default) on a lab copy of the prd shape (1 vCPU / 512Mi, db-f1-micro,
   pool 8), never on prd. It runs one workspace with one public and one
   private channel and the 10-turn baseline, and measures the delta over M1
   for the hub and the DB, plus box CPU-seconds and peak RSS per turn.
   - n >= 5 runs, median and spread reported.
   - The same run with N private channels gives the per-channel slope. If
     the slope is below the noise (n stated), a private channel is priced
     by its tokens only.
4. **M3, the knee**: synthetic workspaces in steps (1, 5, 10, 25, 50) until
   the first of these hits:
   - p95 post latency above a cnf bound;
   - DB connections above 80% of (25 - 5);
   - hub CPU or memory above 80%;
   - 900 sockets.
   The step before the knee is `W_max`, and the limit that hit first is
   recorded. A shape change (Cloud Run CPU or memory, the 040 tier, the pool
   size) is hashed into the row, and that hash makes the old rows stale.
5. **M4, the token gap** (owner add f5c0e3c7): `do_spl_token_gap_measure`,
   read-only.
   - For one UTC day, per provider, model and kind, it compares our metered
     tokens (121 `usage_events` `llm_tokens_*` plus the `unmetered` turns,
     121 L229-231) with the provider's own usage report for the same key
     and day: `gap_pct = (provider - ours) / provider`.
   - The provider report is read with a read-only key that never reaches a
     box.
   - Known sources of the gap: turns with no usage record, retries inside
     one turn, tool-call and system-prompt tokens the CLI adds, cache write
     vs read, and sub-agent turns.
   - Use: the buffer (owner pick A, msg 9e0c0dba) is +20% at launch. After
     >= 14 days it is lowered to the measured p95 of the daily `gap_pct`,
     rounded up to the next 5%. A daily gap above the buffer alerts the
     owner, because it means under-billing.
6. Only then is the slice (section 9) computable.

## 9. Hub Fixed Cost and Pricing Gate

- **The fixed cost is an estimate until measured.** "USD 60/month" comes
  from 047 `deployability-analysis.md` section 4.2: "estimate, list prices,
  730 h", 2026-09-28, ~$60-65 PER ENV, ~$120-130 for dev + prd (L279). It
  leaves out the satellite (072 `research/03-04.review-g-169.md:225`) and
  the LLM tokens. The per-env SAs cannot read billing. Until a closed month
  of export data exists, the spec and every price carry
  `source=estimate (047 4.2)`.
- **Measure it** (121 L242 already names the export):
  - `do_gcp_billing_export_setup`: owner, once, dry run by default. It
    turns on the GCP billing export to BigQuery.
  - `do_spl_estate_cost_read`: read-only, as a reader SA with
    `roles/bigquery.dataViewer` on the export dataset only, never the owner
    account. Monthly, it writes
    `estate_cost_months (month, project, label, usd_micros, source)` per
    project and per label (`box=satellite`, `box=pool`), with
    `source = estimate | billing_export`.
- **Which costs count** (owner Q-5, msg b6a56949: "The production
  environment and the hosts on which the workspace runs"; neither panel
  option):
  - counted: the prd project (hub, database, hosting), plus the hosts
    (boxes) the workspace runs on;
  - not counted: dev, and the satellite, unless it hosts customer
    workspaces.
  - With the shared pool (Q-2 = C), a host's cost is split among the
    workspaces on it, and the prd cost over all workspaces (c-002's
    reading, post 1af7fc7d). `estate_cost_months` keeps per-project and
    per-`box` label rows, so both parts are readable apart.
- **Slice** = `estate_fixed_month / W_max` (owner Q-6 = A, msg 2d9490e7;
  `W_max` measured in M3). It is its own invoice line, beside the per-workspace cost from M2 and the
  tokens. It REPLACES 121's `agent_seconds` split of the shared cost for the
  fixed part, so one cost is never charged twice. A private channel gets
  its own unit cost when M2's slope is above the noise (121 section 10
  `channel_seat`).
- **Formula** = (measured own cost + fixed-cost slice + tokens x (1 + token
  buffer)) x 1.29. The 29% margin is the owner's (msg cd2d25e3, "based on
  the margin and 29% on top"), and it is the value of 121's
  `price_plans.margin_pct`. Spec 121 v1.1 (4772552ba) carries it.
- **The gate**: `pricingReady(month)` holds only when all of these exist:
  - an `estate_cost_months` row with `source=billing_export` for a closed
    month;
  - M2 and M3 rows with n >= 5, newer than the last shape hash;
  - an M4 row of at most 35 days old (cnf), or the launch buffer flagged as
    the owner's estimate.
  The `/services` page (121 section 9) and the `metered` checkout (121
  section 8) read it. When it is false, no price is shown and the checkout
  answers 409 `pricing_not_ready`.

## 10. Data Model (DDL first, dev and prd before the code)

| table / column | holds |
|---|---|
| `box_capacity` | per box sample: load1, cpus, mem_used, mem_total, seats_used, seats_max, at |
| `boxes.state` | `ready` / `draining` / `gone`, plus `drain_started_at` |
| `scale_requests` | id, kind (out/in), reason, box_id, state (pending/applied/failed/refused), refused_reason, at |
| `capacity_samples` | hub metric samples from `do_spl_capacity_read` |
| `capacity_measurements` | M1-M4 results with sha, version, n, shape hash |
| `estate_cost_months` | month, project, label, usd_micros, source |
| `scale_paused` | an instance setting on the operator row (as rdb 0116), set by a failure and cleared by an operator |

All rows are operator scope (RLS: the operator workspace), except
`box_capacity`, which is keyed by the box's tenant.

## 11. Build Lanes (ordered, disjoint files)

1. DDL: the tables of section 10.
2. Hub: the capacity sample on the heartbeat; trigger, hysteresis and
   guards writing `scale_requests` (decides only); 503 `capacity_full`; the
   tests of section 7.
3. Measure: `do_spl_capacity_read`, `do_measure_workspace_capacity`,
   `do_gcp_billing_export_setup`, `do_spl_estate_cost_read`,
   `do_spl_token_gap_measure`, each with its `.tst.sh`.
4. Gate: `pricingReady` in the checkout and on `/services`.
5. IaC (Q-2 = C and Q-3 = A answered): step `061-gcp-vm-pool` in the
   hub's region with the one standard machine type (S3, S6), the customer
   box role set with one OS user and spool root per workspace (after spec
   108 takes Q1 = yes), `do_spl_pool_scale_out` (dry run), the
   operator-only mint path, the S2 channel post + email.
6. Automation (only when the paying count passes 5, 3.1): the box-side
   worker (S4 = B) and the prepaid-balance guard (S5).

## 12. Panel and Consensus

Seats, each with its own file in `reviews/`, all signed against 15e4e5479:

| seat | agent | commit | verdict at the draft |
|---|---|---|---|
| s122-claude (editor) | c-810 | 1ae21b20d | NO, YES after the fold |
| s122-claude-2 | c-811 | f7a97df8b | NO, YES once R1..R3 folded |
| s122-mistral | m-812 | 8bef99c6e, 0ea51c746 | gaps listed; keeps the draft's Q-1..Q-3; 0ea51c746 adds the token gap |
| s122-agy | a-813 | a3f72641c, 3b0a5e2f1 | gaps listed; keeps the draft's Q-1..Q-3 (3b0a5e2f1 changed only the section 4 heading) |

What every seat agreed on:

- the USD 60 is a list-price estimate, measured through a billing export;
- the measurement order is hub max first, then per workspace, then the
  divisor;
- per private channel = the delta of one more channel;
- no price is published before the numbers exist;
- a control test for the trigger, the ceiling, the drain and the failures;
- Q-1 A.

What three seats agreed on (claude, claude-2, mistral): the token gap
measured against the provider's own usage report (M4).

What three or four seats agreed on:

- `do_tf_apply_target` and `do_satellite_playbook` do not do what the draft
  says (claude, claude-2, agy);
- a shared box breaks 108's "one box = one workspace" (claude, claude-2,
  agy).

What the two claude seats agreed on, with no seat against:

- R1: two capacities; the hub gets an alert only;
- R3: the hub decides, an operator path applies;
- 503 `capacity_full`, not 429 `embed_full`;
- one attempt, then paused;
- the money guard;
- dev in the fixed cost;

Where the seats differ, folded as owner questions:

- Q-6 slice divisor: A 3 (claude, mistral, agy), C 1 (claude-2).
- Q-7 scale-in: A 2 (mistral, agy), C 2 (claude-2; the editor's seat moved
  from B to C, since C keeps its point: destroy slowly).

Draft text the panel corrected: the 429 codes, "the hub mints",
`do_gcp_list_monitoring` as telemetry, exponential backoff, and "verified
against reasonable bounds in CI". The draft's "29% (per Spec 121)" is kept,
with the owner's msg cd2d25e3 as its source.

Signatures on v1.0-rc1 (fbb4f582a), each sent on dispatch-e001c851:

| signer | agent | answer |
|---|---|---|
| s122-claude (editor) | c-810 | signed (folded it) |
| s122-claude-2 | c-811 | signed fbb4f582a, no objection; keeps C on Q-6 and Q-7 |
| s122-mistral | m-812 | signed fbb4f582a |
| s122-agy | a-813 | signed fbb4f582a |
| drafter | a-809 | signed fbb4f582a |

Result: 5 of 5 signed, 0 objections. v1.0 = rc1 plus this table.

## 13. Owner Decisions Already Made

- Margin 29% on top (msg cd2d25e3).
- The price carries a fixed-cost slice of the hub (msg 55309d31).
- Token buffer: A, +20% at launch, lowered to the measured gap
  (msg 9e0c0dba).

Answers to the v1.0 questions of section 14.1 (verbatim words at the top of
this spec):

| # | owner answer | panel had | msg | folded in |
|---|---|---|---|---|
| Q-1 | A: box hardware (CPU, RAM, seats); the hub is a separate alert | A | b7ff5f4a "Q1a" | 2 |
| Q-2 | C: a shared pool, one OS user and spool root per workspace on a box; answers 108 Q1 with yes | A | b7ff5f4a "c", confirmed e95a0695 "Yes" | 4 |
| Q-3 | A at launch (manual: the owner or someone with the owner's go applies; the hub only files the request), until paying workspaces + paying private channels are more than 5; then automatic | A for 4 weeks, then B | 72ce6ccc, 0cbf4386 | 3.1, 4 |
| Q-4 / S5 | A now (monthly budget + box limit in cnf); add B (prepaid balances >= 2 months of the new box) when automation starts | B | b7ff5f4a "q4 let's discuss that", then 2d9490e7 "s5" (the recommended row of post 229c0612) | 3 |
| Q-5 | prd + the hosts the workspace runs on; not dev; the satellite only if it hosts | B | b6a56949 | 9 |
| Q-6 | A: fixed cost / `W_max` | A | 2d9490e7 "q6yes" | 8, 9 |
| Q-7 | C: 60 min below 40% stops new work; removal after 24 h drained and empty | split A / C | 2d9490e7 "q7 yes" | 5 |
| S1 | A: paying workspaces and paying private channels count together toward "more than 5" | (new) | 7b047d69 "S1A" | 3.1 |
| S2 | A: "above 80%, add a box" reaches the owner as a spool channel post plus an email | (new) | 7b047d69 "s2a" | 3 |
| S3 | A: one standard box size for now | (new) | 7b047d69 "s3a" | 3 |
| S4 | B: once automation starts, a box-side worker within the guards, our own scripts | (new) | 2d9490e7 "S4b" | 3.1 |
| S6 | A: one region, the hub's (`europe-north1`) | (new) | 2d9490e7 "s6a" | 3 |

Readings to know: "c" in b7ff5f4a had no question number; c-002 read it as
Q-2 C and asked, and "Yes" (e95a0695) is taken as that confirmation (post
51f088b6 also read it as spec 121 T1 = A). "s5" in 2d9490e7 has no letter;
it is taken as the recommended S5 row. Each reading was posted to the owner
for correction; none was corrected (last owner post in the topic at this
fold: a798a19b, a new cost-tracking request, not a correction).

## 14. Owner Questions

### 14.1 The v1.0 questions (all answered, section 13)

Kept as asked, for the record; the panel's recommendation is not the
decision where section 13 differs.

- **Q-1 What does "80% capacity" measure?**
  - A: box hardware (CPU, RAM, seats; the load band the fleet already
    reports), with hub capacity as a separate alert.
  - B: token rate / `agent_seconds`.
  - C: the number of workspaces against `W_max`.
  - **Panel: A (4 of 4).** The bottleneck that needs a new machine is
    hardware, and the owner already set its 20% headroom (rdb 0152).
- **Q-2 Whose is a new box?**
  - A: one box per paying workspace (108 as written).
  - B: the operator workspace's own pool, serving Csitea's own lanes only.
  - C: a shared pool, one OS user and spool root per workspace (needs 108
    Q1 = yes).
  - **Panel: A** (claude-2 A, claude B then A; agy flagged the conflict).
    It is what 108 and 073 already guarantee; C waits for 108 Q1.
- **Q-3 Who applies terraform for a new box?**
  - A: the owner (or an operator with the owner's go), per scale-out,
    through the tf-runner; the hub only writes the request.
  - B: a box-side worker holding a fleet lease, automatically, within the
    guards.
  - C: a managed instance group whose size the hub sets through an SA.
  - **Panel: A first, B after 4 weeks of A** (claude, claude-2). It keeps
    "nothing mutates GCP without the owner" until the plans have been seen
    working.
- **Q-4 The money guard.**
  - A: a fixed monthly pool budget and a box count in cnf.
  - B: A, plus prepaid balances of at least 2 months of the new box.
  - **Panel: B** (claude, claude-2). It is the owner's "people plug in
    their credit cards" made checkable.
- **Q-5 Which fixed cost is sliced?**
  - A: prd only.
  - B: dev + prd + csi-spl-all (the satellite and the pool).
  - **Panel: B** (claude, claude-2). Dev is paid every month and exists
    only to ship prd, so leaving it out under-prices every workspace.
- **Q-6 The slice divisor.**
  - A: the fixed cost / `W_max` (measured, M3).
  - B: the fixed cost / the active workspaces.
  - C: the fixed cost / (`W_max` x 0.8).
  - **Panel: A (3 of 4), C 1.** A gives a stable price for early customers.
    C's point: with the trigger at 80%, a price set at 100% of the ceiling
    never recovers the fixed cost.
- **Q-7 The scale-in delay.**
  - A: 60 min below 40%, then remove.
  - B: 24 h below 40%.
  - C: 60 min below 40% starts the drain; removal only after 24 h drained
    and empty.
  - **Panel: split, A 2 and C 2. The editor recommends C.** It stops new
    work quickly and destroys slowly: a box rebuild runs a playbook allowed
    up to 60 min (060 `07-ansible.tf`).

### 14.2 Still open after the v1.1 fold

None blocks build lanes 1 to 4 (section 11). Lane 5 needs RQ-3, RQ-4 and
spec 108's update (met 2026-10-10 by 5ced76397); lane 6 needs RQ-1. RQ-2 is needed before the first scale-in.

- **RQ-1 Who switches to automatic when the paying count passes 5?**
  (0cbf4386 says automation starts then, not who turns it on.)
  - A: the hub posts "count is now 6" to the owner (S2 path); the owner, or
    someone with the owner's go, sets `scale.mode = auto`.
  - B: the hub switches by itself when the count passes 5.
  - **Recommended: A.** It keeps "nothing mutates GCP without the owner"
    for the one step that hands the apply to a worker, and costs one reply.
- **RQ-2 Scale-in with a shared pool: which box may drain?** v1.0 never
  drains the box of a paid workspace; with Q-2 = C most pool boxes will
  carry at least one paid workspace.
  - A: a box carrying any paid workspace is never drained; only boxes with
    no paid workspace are candidates.
  - B: any pool box may drain; draining only stops new work there, and the
    box is removed only once empty (Q-7 C): a paid workspace's running
    lanes finish on that box and its new work starts on another one.
  - **Recommended: B.** Under A a shared pool rarely shrinks, and Q-7 C
    already protects running work: nothing is removed before 24 h drained
    and empty.
- **RQ-3 Which machine type is the one standard box (S3)?**
  - A: the satellite's type (`e2-standard-16`, `prd.env.yaml:197`) until
    M2 measures one workspace.
  - B: a smaller type, chosen from M2 (one workspace) before the first
    pool box.
  - **Recommended: B.** M2 runs before any customer box exists (section 8),
    and a box sized for the operator's whole fleet over-prices a
    shared pool's first customers.
- **RQ-4 The two cnf caps of the money guard (Q-4 A): what values?**
  `scale.max_boxes` (the draft's 20) and `scale.max_month_eur` (no value
  yet).
  - A: the owner names both numbers before lane 5 ships.
  - B: start with `scale.max_boxes = 20` and a budget of 20 x the standard
    box's monthly list price.
  - **Recommended: A.** The money cap is the owner's guard in the manual
    phase, and no value for it exists in any answer so far.
