signed against 15e4e5479

# Spec 122 review, seat s122-claude (also the EDITOR)

Target: `git show 15e4e5479:csi-spl-doc/specs/122-capacity-scale-out/spec.md`
(66 lines). Every code claim below was read on origin/master
`7b718de5415c428e7beb6ebe530cac56e3927f47` and carries its command or
path:line. Owner words: 72b5ed23, 55309d31, and the add f5c0e3c7 (relayed by
c-002, msg 2b550a8b) on the token count margin.

## 0. Verdict

**NO at 15e4e5479, YES after the 10 proposals in section 7 are folded.**
The goal is right and the section list is right. The draft has three problems:

1. It does not say WHAT scales. "Capacity" mixes the hub (one Cloud Run
   instance plus one micro DB) with the agent boxes (VMs). Adding a box does
   not add hub capacity (section 1).
2. Half of the names it treats as existing are plans or do something else
   (section 2).
3. It makes the hub run terraform and mint join tokens. Repo CLAUDE.md, spec
   073 and spec 108 all forbid that (section 3).

## 1. Two capacities, not one

| layer | what it is today | limit that fills first | evidence |
|---|---|---|---|
| hub | Cloud Run, 1 vCPU / 512Mi, **min 1 = max 1** instance, concurrency 1000 | the instance: GOMAXPROCS 1, GOMEMLIMIT 460MiB, 900 WS sockets total | `csi-spl-cnf/csi-spl/all.env.yaml:323-324,329-330,338,354-355,390` |
| hub DB | Cloud SQL `db-f1-micro`, max_connections 25 (3 superuser + 2 cloudsqladmin), hub pool 8 | connections and the micro CPU | `all.env.yaml:179,362-367` |
| per workspace | messages 100000/month, pins 256, files 10 GiB | the quota, answered 429 `quota` | `all.env.yaml:422-424`; `csi-spl-api/src/go/spool-hub-api/internal/billing/billing.go:28` |
| agent box | one VM, `csi-spl-all-satellite`, `e2-standard-16`, always on | cores: the fleet load band (% of cores, load5/cpus) | `csi-spl-cnf/csi-spl/prd.env.yaml:190,197`; `internal/store/fleet_load.go:15-33` (rdb 0118, 0134, 0152) |

- The hub is one instance on purpose. OQ-05: every box socket terminates on
  the one instance, so delivery needs no cross-instance fan-out
  (`csi-spl-iac/src/terraform/030-cloud-run-hub/04-cloud-run-service.tf:8-9`).
  Raising `max_instances` is a hub design change, not a scale-out knob. I
  believe, unchecked on prd, that more than one instance has not been proven
  live.
- The DB tier is an owner cost decision (spec 027 D5; `all.env.yaml:179`).
  The pool cannot grow without the tier.
- Boxes already report a capacity signal: the load band in `fleet_load.go`.
  rdb 0152 records the owner's "there will be always some 20% extra capacity"
  (t1 338e5258). That is the owner's 80% in the code already: the band's
  ceiling, per box.

**Proposal P1:** spec 122 names the two scale units separately.
**(a) Box scale-out** (more VMs) is driven by the box load band.
**(b) Hub scale-up** (a bigger instance or DB tier) is a step change, raised
by an alert and decided by the owner. **(c) Hub scale-out** (more than one
instance) is out of scope until OQ-05 fan-out is proven, and the spec says
so. The owner's "spawn new hardware" maps to (a); "add them to the spool hub"
is the box join. Q-1 in the draft (CPU+RAM vs tokens) becomes Q-A below.

## 2. Names in the draft vs origin/master

| draft name | draft line | reality | command |
|---|---|---|---|
| `do_gcp_list_monitoring` as telemetry | 13 | lists uptime checks, alert policies and channels only; reads no CPU, RAM or connection metric | `sed -n 1,20p csi-spl-iac/src/bash/run/gcp-list-monitoring.func.sh` |
| `usage_events`, `agent_seconds` | 9, 13 | planned in spec 121 only; no table, no Go | `git grep -l usage_events origin/master` -> 3 files, all under `csi-spl-doc/specs/12[12]` |
| `do_tf_apply_target` to make a new VM | 19 | `terraform apply -target` on an EXISTING step; 060 has exactly one `google_compute_instance` with no `count`/`for_each`, so a second VM is new terraform, not a target | `csi-spl-iac/src/bash/run/tf-apply-target.func.sh:6-10`; `csi-spl-iac/src/terraform/060-gcp-vm-satellite/03-vm.tf:31-34` |
| `do_satellite_playbook` "passing the join token" | 21 | runs 060's Ansible inside the tf-runner against the one satellite; no token argument | `sed -n 1,21p csi-spl-iac/src/bash/run/satellite-playbook.func.sh` |
| `do_tf_destroy_target` from the hub | 27 | operator action in the tf-runner | `tf-destroy-target.func.sh:4-11` |
| roster `ready` / `draining` | 22, 26 | no box lifecycle state in the hub; the only drain is box-local `dispatch/box.leave` | `git grep -n draining origin/master -- csi-spl-rdb` -> 0; `csi-spl-orc/src/bash/run/spl-box-leave.func.sh` |
| 429 `embed_full` | 34 | spec 121 says **503** `embed_full`, and it is a sales-embed limit, not a capacity one | `csi-spl-doc/specs/121-sales-channel/spec.md:205` |
| 429 `token_quota` | 34 | a per-workspace token budget (121), not capacity; 0 hits in Go | `git grep -n token_quota origin/master -- csi-spl-api` -> 0 |
| `do_measure_workspace_capacity` | 43 | new in 122 (fine, it is the proposal) | `git grep -n do_measure_workspace_capacity origin/master` -> 2, both 122 |
| "29% margin (per Spec 121)" | 48 | 121 has no 29%; the margin is `price_plans.margin_pct`, its value open as Q-M1 | `git grep -nE "29 ?%" origin/master -- csi-spl-doc/specs/121-sales-channel/spec.md` -> 0; `121/spec.md:247-249,352` |

**P2:** fix each row: cite the real action, mark planned names "(planned,
spec 121)", replace 429 `embed_full` with a new code of its own
(`capacity_full`, 503 + `Retry-After`), and drop the 29% (it reads the 121
margin setting).

## 3. Conflicts with the existing specs and repo rules

1. **The hub cannot run terraform.** Repo CLAUDE.md: "Terraform runs only in
   the tf-runner container, never on the host", and "Nothing mutates GCP
   without the owner ... `terraform apply` each need an explicit go". Draft
   lines 19 and 27 have the hub (a Cloud Run service) invoke apply and
   destroy. Two ways out, an owner question (Q-B):
   - **A.** The hub only DECIDES. It writes a `scale_requests` row and alerts.
     An operator-side named action in the tf-runner applies it, with the
     owner's standing go for a bounded count.
   - **B.** A managed instance group (MIG) with a fixed template: terraform
     creates the MIG once, and the hub only sets its target size through the
     compute API, as a dedicated SA.
2. **Join tokens are minted by a workspace admin, per seat, 1 h, single use,
   tenant inside** (073 L44-46, L81-82; built: `internal/hub/join_tokens.go:55,148`,
   TTL `all.env.yaml:378`). Draft line 20 ("the hub mints") has no minter.
   **P3:** a new operator-only mint path: an `asOperator` caller, named and
   added to `TestOperatorScopeCallers` (108 §3.6), audited, the token bound to
   the box's VM name.
3. **One box = one workspace** (108 §3.5 L28; owner Q1 and Q2 still open,
   L65-66). A shared auto-provisioned box that "receives new agents and
   workspaces" (draft line 22) breaks it. Either the new box belongs to the
   operator workspace and serves only Csitea's own lanes, or it is a
   per-workspace box the customer pays for. That is Q-C, and 122 cannot be
   built before 108 Q1 is answered.
4. **Who pays for a box.** 057 R17 caps the one satellite at $170/month
   (057 L58). Budget step 059 still alerts at 170 (`prd.env.yaml:180`), but
   the machine is now `e2-standard-16` (`prd.env.yaml:197`, owner go
   2026-10-02). I believe, unchecked, that its list price is above 170, so
   the existing budget alert is not a real guard for that box.
   **P4:** each new box carries a label (`box=<name>`) and its own budget
   line, as 059 does (`059-gcp-satellite-budget/03-budget.tf`). The scale
   ceiling is a cnf money amount, not only a box count.
5. **A 059 budget only alerts, never stops** (`03-budget.tf:1-4`: "nothing is
   ever stopped"). Draft line 16 "the billing state ensures we only scale
   when prepaid balances cover the cost" has no mechanism. See section 6.

## 4. The "USD 60/month" fixed cost (check 2)

- Its source is 047 `deployability-analysis.md` §4.2: **"estimate, list
  prices, 730 h"**. Cloud Run CPU ~$47, SQL ~$10-11, total "~$60-65" PER ENV,
  ~$120-130 for dev+prd. It is not an invoice; the per-env SAs cannot read
  billing.
- It leaves out the satellite (072 `research/03-04.review-g-169.md:225`) and
  the LLM tokens.
- **P5:** spec 122 §9 says "estimate (047 §4.2, list prices, 2026-09-28)"
  until it is measured. The measurement is spec 121's GCP billing export to
  BigQuery (121 L242), a one-time owner bootstrap. Name the actions:
  `do_gcp_billing_export_setup` (owner, once) and `do_spl_estate_cost`
  (monthly, read as a billing-reader SA the owner grants, never the owner
  account). It writes one row per (env, month, service) in a new
  `estate_costs` table. Until a full month exists, the fixed cost is the
  047 figure, flagged `estimate=true`.
- The fixed cost per sold workspace must include dev, because dev exists to
  serve prd: (prd + dev + shared csi-spl-all) per month. This is an owner
  question (Q-D).

## 5. Measurement order (check 3) and the token gap (owner add f5c0e3c7)

Q-2 option A (fixed cost / theoretical max workspaces) is not computable
today: nobody knows the max. The order:

1. **M1 hub idle baseline**: hub CPU-seconds, RSS, DB connections and DB CPU
   with 0 active desks, from Cloud Monitoring metrics
   (`run.googleapis.com/container/cpu/utilizations`,
   `cloudsql.googleapis.com/database/postgresql/num_backends`). This is a NEW
   read action, `do_gcp_read_metrics`; the list action does not read metrics.
2. **M2 one workspace, one public and one private channel, standard
   traffic** (`do_measure_workspace_capacity`, as the draft says, run on
   **dev**). It measures the delta over M1 for the hub and the DB, plus box
   CPU-seconds and RAM per agent turn.
3. **M3 the knee**: add synthetic workspaces in steps (1, 5, 10, 25, 50)
   until the first hub limit hits: p95 latency doubles, the pool waits, 900
   sockets, or GOMEMLIMIT. The step before the knee is the measured max,
   `W_max`. It runs on a throwaway dev hub or in lde, never on prd.
4. **M4 the token gap**: for each turn, compare our counted tokens with the
   provider's reported usage for the same period: per provider and model,
   (provider - ours) / provider. The provider's number comes from its usage
   or billing API, read by a named action (`do_spl_token_gap`). Turns with
   no usage report are `unmetered` (121 L229-231) and count fully into the
   gap. The output is the measured gap with n (turns) and the window. The
   owner's +10/+20% buffer (f5c0e3c7) is then set from it in spec 121; 122
   only produces the number. Control: a fake provider that reports 15% more
   than the seat must give 15% ± the rounding.
5. Only then does Q-2 have inputs: A uses `W_max` from M3, B uses the live
   count.

Each M step writes its result to a table (`capacity_samples`: kind, env,
sha, n, value, at), so the price gate in section 6 can check that the
inputs exist and how old they are.

## 6. Owner add 55309d31: the slice, the per-unit capacity, the gate

- **Fixed slice per workspace** = `estate_fixed_month / W_basis`, where
  `W_basis` follows Q-2: `W_max` (A) or the active count (B). Show it as its
  own line on the invoice, beside 121's `cloud_share`. 121 L242-246 already
  splits shared cost by `agent_seconds`. Spec 122 must say whether the slice
  REPLACES that split or comes before it. I recommend that it replaces it
  for the fixed part, so one cost is never charged twice.
- **Per private channel**: M2 measures a workspace with one private channel
  and then with N. The marginal cost of a private channel is the slope. If it
  is below the noise (n stated), the spec says "a private channel is priced
  by its tokens only" and the slice is per workspace.
- **The gate**, for the WUI pricing page and the checkout of a `metered`
  plan (121 §8):
  - Refuse while any of `estate_fixed_month`, `W_basis`, the M2 per-workspace
    cost or the M4 token gap is missing or older than a cnf age (e.g. 35 days).
  - The answer is 503 `price_unavailable`, and the page says "pricing not yet
    published".
  - Test: an empty `capacity_samples` table makes the checkout refuse.
    Control: seeded rows make it answer with a price.
- **Budget guard**, on top of the box count:
  - New boxes are allowed only while the projected monthly cost of the fleet
    plus the new box is at most the prepaid balances held, minus the 121
    token budgets reserved, minus a cnf safety margin.
  - It is computed in one function with a unit test.
  - Control: removing the balance check lets a scale-out through with zero
    balances, and the test catches it.

## 7. Trigger, hysteresis, drain, failure modes (check 5), each with a control

| item | proposal | test | control (fails when the guard is removed) |
|---|---|---|---|
| P6 trigger | box scale-out when the fleet's mean load band is above 80% of cores for 10 min AND no box is below its band low; hub: an ALERT only (070 monitoring) at 80% CPU or 80% of `max_connections` | feed a fake sample series; assert one `scale_requests` row | the same series with the window check removed queues on the first sample |
| P7 hysteresis | at most one scale request per cooldown (cnf, 30 min), one in flight at a time; scale-in needs under 40% for 60 min (Q-E) | two crossings inside the cooldown give 1 row | with no cooldown they give 2 rows |
| P8 ceilings | cnf `scale.max_boxes` AND `scale.max_month_eur` (section 6), both checked | at max -> refused, logged, alerted once | with the check removed, the request passes at max |
| P9 drain | new hub-side `pins.state` (`ready`, `draining`, `retired`; an rdb migration, DDL first, dev and prd before the code) mirrors the box-local `box.leave` (`spl-box-leave.func.sh`); the spawn refuses on draining (as `spawn-window.sh:129`, exit 6); a box is retired only at 0 running lanes (`roster.running`, rdb 0153) for 15 min; the operator workspace's own box `sat` is never a candidate | a draining box gets no new lane | the same with the state ignored places one |
| P10 failure modes | apply failure: no retry, alert, scale halted until an operator clears it (the draft's line 32 is right). A new box that never says hello within 20 min is NOT auto-destroyed by the hub (no hub destroy, section 3.1): it is flagged and the operator action removes it. Hub at capacity: new desks get 503 `capacity_full` + `Retry-After`; existing ones keep working | each mode has a fake-cloud test in the action's `.tst.sh` | with the halt flag removed, the second failure retries |

Note that 058 reports one socket per (tenant, box) and that adding boxes adds
hub sockets. Each box scale-out moves the hub toward its 900-socket edge cap
(`all.env.yaml:390`). So P6's box trigger must also check the hub headroom.
A box that would push the hub over 80% is refused, and the hub alert goes to
the owner.

## 8. Owner questions (A/B(/C), recommendation and why)

- **Q-A What does "80% capacity" measure?**
  - A: the box load band (% of cores, already reported) for boxes, and hub
    CPU / DB connections for the hub, as an alert only.
  - B: tokens or `agent_seconds` throughput.
  - C: the number of workspaces against `W_max`.
  - **Recommend A**: it is the signal the fleet already measures, and the
    owner already set its 20% headroom (rdb 0152).
- **Q-B Who runs terraform for a new box?**
  - A: the hub writes a request; an operator-side named action in the
    tf-runner applies it under a standing bounded go.
  - B: a MIG whose target size the hub sets through an SA.
  - **Recommend A**: it keeps "terraform only in the tf-runner" and "nothing
    mutates GCP without the owner". B is the later step once A has run.
- **Q-C Whose is an auto-provisioned box?**
  - A: the operator workspace's (Csitea's own lanes only).
  - B: a per-workspace box that the customer pays for (108).
  - C: shared across workspaces (needs 108 Q1 = yes).
  - **Recommend A first, B next**: C breaks 108 §3.5 while its Q1 is open.
- **Q-D Which fixed cost is sliced?**
  - A: prd only.
  - B: prd + dev + csi-spl-all (the satellite).
  - **Recommend B**: dev and the satellite exist only to serve prd, and
    leaving them out under-prices every workspace.
- **Q-2 (draft) The slice divisor.**
  - A: `W_max` measured (M3).
  - B: the active count.
  - **Recommend A, only after M3 has run**, with the gate in section 6
    keeping the price unpublished until then. It gives a stable price; the
    unsold capacity is Csitea's cost.
- **Q-E (draft Q-3) The scale-in delay.**
  - A: 60 min under 40%.
  - B: 24 h.
  - **Recommend B for boxes**: a box is monthly-ish money, and churn of a
    VM plus its Ansible run (minutes, a playbook) costs more than one idle
    night. The 60 min of the draft fits a MIG (Q-B B), not terraform plus
    Ansible.
- **Q-F How large is the token buffer (owner add f5c0e3c7)?** This is spec
  121's question, already asked (c-002 post 1099c002). Spec 122 only adds
  M4 (section 5), which measures the gap so the value is set from data.
  No new question here.

## 9. Fold list for the editor (what goes into spec.md)

- §1: the two capacities (P1).
- §2 rows fixed (P2).
- New §3a: conflicts and the operator-only mint (P3) and box ownership (Q-C).
- §6: the budget guard in money (P4, section 6).
- §9: the estimate label and the billing export (P5).
- §8: replaced by M1-M4 with the token gap.
- §7: the trigger, drain and failure table (P6-P10) with controls.
- Owner questions: Q-A..Q-F.
