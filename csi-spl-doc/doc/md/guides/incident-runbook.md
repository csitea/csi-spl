# Incident runbook: on-call roles, escalation path, and status procedure

This runbook establishes the operational incident response procedure for the spool fleet and hosted services, addressing robustness review gap 8 (SPL-2136, Refs: SPL-2129). It documents severity classifications, on-call agent responsibilities, escalation timelines, first-response diagnostic and remediation commands, and owner notification standards.

## 1. Severity classifications

Every operational defect or outage is classified into one of four severity levels:

| Severity | Impact | Definition & criteria | Target initial triage | Paged roles |
|---|---|---|---|---|
| **SEV-1** | Critical / Outage | Complete outage of production service or major data loss. Hub API down (5xx / 429 streak, `/v1/health` failing), public DNS resolution down, expired TLS certificate on production endpoints, or all fleet boxes unreachable. | < 5 min | Orchestrator (`001`), Dispatch holder (`002`), Owner informed via status post |
| **SEV-2** | Major / Degraded | Production service degraded or redundancy lost with partial user impact. Single box down or network-isolated, Cloud Run instance restart looping, disk usage >= 85%, public TLS certificate expiring in <= 7 days, WUI static asset failure. | < 15 min | Orchestrator (`001`), Dispatch holder (`002`) |
| **SEV-3** | Minor / Impaired | Development environment outage, trunk CI gate red, non-critical background loop panic/restart, disk usage 70–85%, public TLS certificate expiring in <= 21 days. | < 30 min | Dispatch holder (`002`) for CI / dev issues, Orchestrator (`001`) |
| **SEV-4** | Low / Advisory | Non-impacting warning or scheduled maintenance advisory. Unanswered message sweep warnings (> 1h), pending kernel reboot (`/run/reboot-required`), pending library restarts (`needrestart`). | Next window | Orchestrator (`001`) / Dispatch holder (`002`) |

## 2. On-call roles and owner paging rules

### 2.1 Autonomous agent on-call roles

The spool fleet operates continuous autonomous rotations across agent seats (see [fleet roles](../SPEC-spool-fleet-roles.md)):

- **Orchestrator (`001`)**: Holds the fleet orchestration lease (`spl-orch-rotate.func.sh`). Responsible for box availability, container runtime health, worker seat placement, disk headroom monitoring, and inter-box spool communication.
- **Dispatch lease holder (`002`)**: Holds the dispatch lease (`LEASE_CMD=show ./run -a do_spl_dispatch_lease`). Responsible for workstream triage, blocker routing, CI red notifications, lane enqueueing, and **all communications with the owner**.
- **Standby (`003`)**: Hot standby seat ready to assume orchestrator or dispatcher responsibilities upon lease expiration or watchdog fence.

### 2.2 Owner paging rules (owner gates only)

The human owner (`HUM-10`) is **never** alerted for routine operations or self-healing procedures. The owner is consulted **only** when an explicit owner gate is required. The list of GCP owner gates has one home: the repo [CLAUDE.md](../../../../CLAUDE.md) rule "Nothing mutates GCP without the owner" (project create, billing link, IAM change, `terraform apply`, the destructive `gcp-*` actions). Every fleet rule and its home: [fleet rules index](../fleet-rules-index.md). Beyond those, the owner decides:

1. **Emergency order overrides**: applying changes to `prd` ahead of `dev` (`ENV_ORDER_OVERRIDE=<owner msg id>`).
2. **Force-push approval**: any non-fast-forward push or ref deletion on `master` ([developer-guide.md](../developer-guide.md) section 4).
3. **Business decisions**: tenant ownership transfers or workspace tier adjustments.

## 3. Escalation path and timelines

When an incident is detected, agents follow a strict time-bounded escalation ladder:

```
[ T+0: Detection ] ────> [ T+3m: Blocker Paged ] ────> [ T+5m: Re-raise / Failover ] ────> [ T+10m: Mitigation ] ────> [ T+15m: Owner Post ]
 Uptime probe / cron      spool-send.sh --kind blocker   Hub sweep re-raises;           Rollback / restart      Status post in ops topic
 Watchdog detects fault   to 001 (orc) or 002 (disp)     003 monitors lease             via named actions       if SEV-1 / owner gate
```

1. **T+0 (Detection)**: A failure is detected via Cloud Run uptime checks (step 070), host watchdog (`spl-watchdog.func.sh`), cron health checks, or lane test runners.
2. **T+3 min (Initial page)**: The detecting agent or daemon sends a structured spool message (`spool-send.sh --kind blocker`) to the responsible role:
   - Infrastructure, box, disk, or certificate failure: paged to `orchestrator` (`001`).
   - CI red, stalled lane, or issue roadblock: paged to `dispatch holder` (`002`).
3. **T+5 min (Re-raise & failover check)**: If the blocker remains unacknowledged, the hub blocker sweep re-raises it. If the active lease holder is unresponsive (watchdog fences after 120s of beat silence), standby `003` takes over the lease.
4. **T+10 min (Remediation attempt)**: The on-call agent executes safe, non-destructive named remediation actions (e.g. fresh revision restart, rollback to previous release, or disk sweep).
5. **T+15 min (Owner status notification)**: For unresolved SEV-1 incidents or when an owner gate is required, the dispatch lease holder posts an incident status update in the owner's active operations discussion topic.

## 4. First-response commands per incident type

Every diagnostic and remediation command is a version-controlled named action. Ad hoc host shell commands are forbidden.

### 4.1 Hub down (Cloud Run / API unreachable)

- **Probe hub HTTP endpoint and TLS certificate**:
  ```bash
  cd csi-spl-orc && ./run -a do_spl_probe_hub_host
  ```
  Action file: `csi-spl-orc/src/bash/run/spl-probe-hub-host.func.sh`
- **Inspect Cloud Run instance health and error logs**:
  ```bash
  cd csi-spl-iac && ENV=prd ./run -a do_gcp_hub_instance_health
  ```
  Action file: `csi-spl-iac/src/bash/run/gcp-hub-instance-health.func.sh`
- **Check hub deployment status and image tags**:
  ```bash
  cd csi-spl-orc && ENV=prd ./run -a do_check_hub_deploy
  ```
  Action file: `csi-spl-orc/src/bash/run/check-hub-deploy.func.sh`
- **Restart Cloud Run hub service (force a fresh revision)**: a prd mutation. Only c-001 (the orchestrator) runs it; any other seat sends c-001 the exact command and waits. Preview first (`DRY_RUN=1` is the default and changes nothing):
  ```bash
  cd csi-spl-iac && ENV=prd DRY_RUN=1 ./run -a do_gcp_hub_restart
  ```
  Then c-001 alone:
  ```bash
  cd csi-spl-iac && ENV=prd DRY_RUN=0 ./run -a do_gcp_hub_restart
  ```
  Action file: `csi-spl-iac/src/bash/run/gcp-hub-restart.func.sh`. It refuses while the ready revision was restarted less than `HUB_RESTART_MIN_AGE_S` (600 s) ago, so a second seat acting on the same incident cannot restart prd twice.
- **Rollback hub to previous release**: a prd mutation. Only c-001 (the orchestrator) runs it; any other seat sends c-001 the exact command and waits. Dev goes first: `ENV=prd` is refused (rc 4) until dev already serves the target commit, unless `ENV_ORDER_OVERRIDE=<owner msg id>` is set, which is for an emergency only. Preview, then roll dev, then preview and roll prd:
  ```bash
  cd csi-spl-orc && ENV=dev TO=previous DRY_RUN=1 ./run -a do_hub_rollback
  ```
  ```bash
  cd csi-spl-orc && ENV=dev TO=previous DRY_RUN=0 ./run -a do_hub_rollback
  ```
  ```bash
  cd csi-spl-orc && ENV=prd TO=previous DRY_RUN=1 ./run -a do_hub_rollback
  ```
  ```bash
  cd csi-spl-orc && ENV=prd TO=previous DRY_RUN=0 ./run -a do_hub_rollback
  ```
  Action file: `csi-spl-orc/src/bash/run/hub-rollback.func.sh`
- **Heal stuck Cloud Run deployment**:
  ```bash
  cd csi-spl-orc && ENV=prd ./run -a do_heal_hub_deploy
  ```
  Action file: `csi-spl-orc/src/bash/run/heal-hub-deploy.func.sh`

### 4.2 Box down or partitioned

- **Poll peer boxes across the fleet**:
  ```bash
  cd csi-spl-orc && ./run -a do_spl_peer_poll
  ```
  Action file: `csi-spl-orc/src/bash/run/spl-peer-poll.func.sh`
- **Check local desk daemon and agent process health**:
  ```bash
  cd csi-spl-orc && ./run -a do_spl_desk_check
  ```
  Action file: `csi-spl-orc/src/bash/run/spl-desk-check.func.sh`
- **Inspect current dispatch lease holder**:
  ```bash
  cd csi-spl-orc && LEASE_CMD=show ./run -a do_spl_dispatch_lease
  ```
  Action file: `csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh`
- **Restart local desk service**: only c-001 (the orchestrator) runs it; agent seeds forbid any other seat to run `do_spl_desk_up`, so they send c-001 the exact command and wait. `ENV`, `TENANT_ID` and `DESK_AGENT` are required (its `@param` block); it is a dry run unless `DRY_RUN=0`:
  ```bash
  cd csi-spl-orc && ENV=<env> TENANT_ID=<workspace> DESK_AGENT=<id> DRY_RUN=0 ./run -a do_spl_desk_up
  ```
  Action file: `csi-spl-orc/src/bash/run/spl-desk-up.func.sh`
- **Restart remote peer box or satellite**:
  ```bash
  cd csi-spl-orc && BOX=<box> ./run -a do_spl_peer_restart
  ```
  Action file: `csi-spl-orc/src/bash/run/spl-peer-restart.func.sh`
- **Check pending box reboot conditions**:
  ```bash
  cd csi-spl-orc && ./run -a do_spl_box_restart_check
  ```
  Action file: `csi-spl-orc/src/bash/run/spl-box-restart-check.func.sh`

### 4.3 Disk full or low headroom

- **Check host disk headroom against thresholds**:
  ```bash
  cd csi-spl-orc && ./run -a do_check_disk_headroom
  ```
  Action file: `csi-spl-orc/src/bash/run/check-disk-headroom.func.sh`.
  One note per crossing: WARN at 85% blocks (80% inodes), CRITICAL at 92%.
  A crossing stays armed until the mount is 5 points under its line
  (`DISK_HEADROOM_REARM_PCT`, SPL-3198): 85 -> 84 -> 85% is one note, and
  the WARN re-arms (CLEAR, may warn again) only under 80%, the CRITICAL
  under 87%.
- **New lanes already avoid the full box** (SPL-3179): `do_spl_box_pick`
  never places a lane on a box whose agent data mount (`/mnt/data` where the
  box has one, else `/`, from its latest hub box_stats sample) is at or over
  the headroom guard's high mark (`DISK_HEADROOM_BLOCK_PCT`, 85; the one
  home of the marks is `csi-spl-orc/lib/bash/funcs/spl-box-disk.func.sh`).
  Its line says `DISK <mount> N% >= 85%: not picked`; every box over the
  mark -> `pick=hold`, the queued row keeps its place. A sample with no disks
  is judged as before. Running lanes are not moved: free the disk.
  ```bash
  cd csi-spl-orc && ./run -a do_spl_box_pick
  ```
- **Run comprehensive box disk sweep (prunes logs, cache, retired trees)**:
  ```bash
  cd csi-spl-orc && DRY_RUN=0 ./run -a do_box_disk_sweep
  ```
  Action file: `csi-spl-orc/src/bash/run/box-disk-sweep.func.sh`
- **Clean temporary scratch files**:
  ```bash
  cd csi-spl-orc && DRY_RUN=0 ./run -a do_tmp_scratch_sweep
  ```
  Action file: `csi-spl-orc/src/bash/run/tmp-scratch-sweep.func.sh`
- **Clean stale temporary directories**:
  ```bash
  cd csi-spl-orc && DRY_RUN=0 ./run -a do_tmp_stale_sweep
  ```
  Action file: `csi-spl-orc/src/bash/run/tmp-stale-sweep.func.sh`
- **Prune dead or retired worktrees**:
  ```bash
  cd csi-spl-orc && DRY_RUN=0 ./run -a do_wt_dead_sweep
  ```
  Action file: `csi-spl-orc/src/bash/run/wt-dead-sweep.func.sh`
- **Prune unused docker images**:
  ```bash
  cd csi-spl-orc && ./run -a do_prune_docker_images
  ```
  Action file: `csi-spl-orc/src/bash/run/prune-docker-images.func.sh`

### 4.4 CI red on trunk

- **Report failing CI jobs and failure signatures**:
  ```bash
  cd csi-spl-iac && CI_GATE_RUNS=50 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate
  ```
  Action file: `csi-spl-iac/src/bash/run/report-ci-gate.func.sh`
- **Fetch failed workflow job logs**:
  ```bash
  cd csi-spl-iac && RUN_ID=<id> ./run -a do_ci_failed_log
  ```
  Action file: `csi-spl-iac/src/bash/run/ci-failed-log.func.sh`
- **Send CI red alert note to dispatch holder**:
  ```bash
  cd csi-spl-iac && ./run -a do_report_ci_red_note
  ```
  Action file: `csi-spl-iac/src/bash/run/report-ci-red-note.func.sh`
- **Rerun flaky CI setup jobs**:
  ```bash
  cd csi-spl-orc && RUN_ID=<id> ./run -a do_ci_rerun_setup_flake
  ```
  Action file: `csi-spl-orc/src/bash/run/ci-rerun-setup-flake.func.sh`
- **Validate pre-push lint locally**:
  ```bash
  cd csi-spl-iac && ./run -a do_check_pre_push_lint
  ```
  Action file: `csi-spl-iac/src/bash/run/check-pre-push-lint.func.sh`

### 4.5 Certificate expiry

- **Check public HTTPS certificate expiry across endpoints**:
  ```bash
  cd csi-spl-utl && ./run -a do_net_cert_expiry_check
  ```
  Action file: `csi-spl-utl/src/bash/run/net-cert-expiry-check.func.sh`
- **Inspect endpoint certificate end date and SANs**:
  ```bash
  cd csi-spl-orc && ./run -a do_spl_probe_hub_host
  ```
  Action file: `csi-spl-orc/src/bash/run/spl-probe-hub-host.func.sh`
- **Wait for Cloud Run custom domain certificate mapping**:
  ```bash
  cd csi-spl-orc && ENV=prd ./run -a do_spl_wait_for_mapping_cert
  ```
  Action file: `csi-spl-orc/src/bash/run/spl-wait-for-mapping-cert.func.sh`

## 5. Status page and owner notification procedure

### 5.1 Communication channel and rules

- **Channel**: Status posts are made in the owner's active operations discussion topic (or thread).
- **Sender**: The current **dispatch lease holder** (`LEASE_CMD=show ./run -a do_spl_dispatch_lease`) is the only agent that posts to the owner. Individual worker lanes never post to owner topics.
- **Formatting**: Posts follow [how-to-post.md](../../help/how-to-post.md). Raw markdown only, never enclosed in code fences.

### 5.2 Incident notification format

When an incident is acknowledged or enters an active mitigation phase, post an update using this structure:

```text
## Incident Status: [SEV-1] Production Hub Outage

- **Component**: Cloud Run Hub API (`api.spool-hub.ai`)
- **Started**: 2026-10-18T10:15Z
- **Current Status**: Investigating / Mitigating
- **Impact**: Public API endpoints returning HTTP 503; web UI unable to sync.

| env | component | state | revision / sha |
|-----|-----------|-------|----------------|
| prd | hub       | DOWN  | rev-00142      |
| dev | hub       | UP    | rev-00142      |

### Actions Taken
1. Probed endpoint: `do_spl_probe_hub_host` confirmed 503 from Cloud Run.
2. Read health log: `do_gcp_hub_instance_health` reported 0 WS upgrades on revision `rev-00142`.
3. Mitigating: Initiated fresh revision restart with `do_gcp_hub_restart`.
```

### 5.3 Incident resolution format

When service is restored, post a resolution report confirming verified health:

```text
## Result: Incident Resolved [SEV-1] Production Hub Outage

Production hub service restored at 2026-10-18T10:25Z (outage duration: 10m).

| env | sha      | probe | status |
|-----|----------|-------|--------|
| dev | 0630c1e4 | 200   | OK     |
| prd | 0630c1e4 | 200   | OK     |

- Cloud Run service healthy: HTTP 200 on revision `rev-00143`
- WebSocket upgrades: 101 Switching Protocols verified
- All worker lanes resumed normal operation
```
