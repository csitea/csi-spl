Exported from the Qto doc [Operations and Maintenance Guide](https://spool-hub.ai/workspace/docs?doc=aba39883-47d1-44bc-86c1-dbb48ede9e73&view=doc) (`aba39883-47d1-44bc-86c1-dbb48ede9e73`) on 2026-10-11T20:55:36Z; edit in Qto, not here.

# 1 Daily routine

This guide covers the daily and weekly routines for operating and maintaining the spool fleet. It assumes the system is already installed and configured: see the Installation and configuration guide. `<CHECKOUT>` is the main checkout, `<OWNER_USER>` the OS user that owns it, `<AGENT_USER>` the OS user every AI CLI runs as.

Run the following checks every morning and after deployments.

## 1.1 Health checks

### 1.1.1 Database health

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env ENV=prd ./run -a do_spl_db_health
```

### 1.1.2 Deploy lag

Exit 0 means current or pending, exit 3 lagging, exit 1 cannot tell (the function header of `do_check_deploy_lag`).

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env ENV=prd ./run -a do_check_deploy_lag
```

### 1.1.3 CI gate report

Counted per job, not per run.

```bash
cd <CHECKOUT>/csi-spl-iac && sudo -u <OWNER_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate
```

### 1.1.4 GitHub runner check

Exit 1 when any runner fails; a box with no runner unit is OK, exit 0. A runner the CPU budget parked is `PARKED`, not a failure (the function header of `do_check_gh_runner`).

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_check_gh_runner
```

### 1.1.5 Backup verification

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env ENV=prd ./run -a do_spl_db_backup_verify
```

## 1.2 Lease checks

Verify the dispatch lease is held by an active agent.

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env LEASE_CMD=show ./run -a do_spl_dispatch_lease
```

## 1.3 Unanswered sweep

Check for unanswered spool messages older than 1 hour.

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_spl_unanswered_sweep
```

# 2 Weekly routine

Clean temporary files and stale worktrees. Each sweep below is a dry run unless `DRY_RUN=0`: the first block prints the plan, the second one does it.

## 2.1 Clean /tmp, plan

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_tmp_stale_sweep
```

## 2.2 Clean /tmp, apply

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env DRY_RUN=0 ./run -a do_tmp_stale_sweep
```

## 2.3 Clean scratch files, plan

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_tmp_scratch_sweep
```

## 2.4 Clean scratch files, apply

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env DRY_RUN=0 ./run -a do_tmp_scratch_sweep
```

## 2.5 Clean dead worktrees, plan

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_wt_dead_sweep
```

## 2.6 Clean dead worktrees, apply

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env DRY_RUN=0 ./run -a do_wt_dead_sweep
```

## 2.7 Clean disk, plan

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_box_disk_sweep
```

## 2.8 Clean disk, apply

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env DRY_RUN=0 ./run -a do_box_disk_sweep
```

# 3 Role rotation

The dispatch and orchestrator roles rotate hourly, from the crons `do_spl_dispatch_rotate_install_cron` and `do_spl_orch_rotate_install_cron` install. Both actions are a dry run unless `DRY_RUN=0`; run them by hand only to see the plan.

## 3.1 Dispatch rotation

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_spl_dispatch_rotate
```

## 3.2 Orchestrator rotation

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_spl_orch_rotate
```

# 4 Agent restarts and identity restore

Restore an agent identity after a restart or crash.

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env IDENTITY_RESTORE_IDS=<agent-id> DRY_RUN=0 ./run -a do_spl_agent_identity_restore
```

# 5 Quota and weekly limit handling

Watch the weekly vendor login quota (claude, grok). When a seat hits its limit:

1. Restart the agent as `<AGENT_USER>` (global CLAUDE.md).
2. Respawn the lane on the backup vendor that `do_spl_lane_mix` names for its task kind.

# 6 Load gate

The fleet runs at most 40 concurrent agent windows. The count below must stay at 40 or below.

```bash
sudo -u <OWNER_USER> tmux -S /tmp/tmux-1000/default list-windows -a -F "#{window_name}" | grep -cE "^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgmq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)"
```

# 7 Box restart schedule

Restart each box weekly to apply updates and clear stale processes, during low-traffic periods, with the box restart action family. `BOX_RESTART_SLOT` is this box's slot index in cnf `env.box.restart.slots`. The action is a dry run unless `DRY_RUN=0`.

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env BOX_RESTART_SLOT=<n> DRY_RUN=0 ./run -a do_spl_box_restart_install_cron
```

# 8 Incident runbooks

- **CI gate red**: see [CI gate reliability](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/specs/016-spool-testability/ci-gate-reliability-2026-09-21.md).
- **Deploy lag**: run `do_check_deploy_lag` and watch the GitHub workflow.
- **Agent stuck**: restart it with `do_spl_agent_identity_restore`.
- **Lease conflict**: run `LEASE_CMD=fleet-show ./run -a do_spl_dispatch_lease` and resolve the conflict by hand.

# 9 Gaps

- No named action for cleaning old spool messages beyond `do_spl_session_prune` and `do_spl_topic_archive`.
- No named action for quota monitoring.
- No named action to pause non-critical workflows.
- Tenant root keys: no action lists the required workspaces or checks for missing keys.
