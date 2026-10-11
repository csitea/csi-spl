# Exported from the Qto doc [Operations and Maintenance Guide](https://spool-hub.ai/workspace/docs?doc=87383949-8cc5-4a82-aa62-e444d74e0eee&view=doc) on 2026-10-11T20:45:00Z; edit in Qto, not here.

---

# Operations and Maintenance Guide

This guide covers the daily and weekly routines for operating and maintaining the spool fleet. It assumes the system is already installed and configured (see [Installation and Configuration Guide](https://spool-hub.ai/workspace/docs?doc=1a3900ac-774d-4a47-9ecd-4fc716542aa3&view=doc)).

## Table of Contents
1. [Daily Routine](#1-daily-routine)
2. [Weekly Routine](#2-weekly-routine)
3. [Role Rotation](#3-role-rotation)
4. [Agent Restarts and Identity Restore](#4-agent-restarts-and-identity-restore)
5. [Quota and Weekly Limit Handling](#5-quota-and-weekly-limit-handling)
6. [Load Gate](#6-load-gate)
7. [Box Restart Schedule](#7-box-restart-schedule)
8. [Incident Runbooks](#8-incident-runbooks)
9. [Gaps](#9-gaps)

## 1. Daily Routine
Run the following checks every morning and after deployments:

### 1.1 Health Checks

#### 1.1.1 Database Health
```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env ENV=prd ./run -a do_spl_db_health
# Exit 0: healthy. Exit 1: failed.
```

#### 1.1.2 Deploy Lag
```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env ENV=prd ./run -a do_check_deploy_lag
# Exit 0: no lag. Exit 1: lag detected.
```

#### 1.1.3 CI Gate Report
```bash
cd <CHECKOUT>/csi-spl-iac && sudo -u <OWNER_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate
# Exit 0: no reds. Exit 1: reds detected.
```

#### 1.1.4 GitHub Runner Check
```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_check_gh_runner
# Exit 0: runner budget OK. Exit 1: budget exceeded.
```

#### 1.1.5 Backup Verification
```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env ENV=prd ./run -a do_spl_db_backup_verify
# Exit 0: backup verified. Exit 1: backup failed.
```

### 1.2 Lease Checks
Verify the dispatch lease is held by an active agent:

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env LEASE_CMD=show ./run -a do_spl_dispatch_lease
# Exit 0: lease held. Exit 1: no lease.
```

### 1.3 Unanswered Sweep
Check for unanswered spool messages older than 1 hour:

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_spl_unanswered_sweep
# Exit 0: sweep completed. Exit 1: sweep failed.
```

## 2. Weekly Routine
Clean temporary files and stale worktrees:

### 2.1 Clean /tmp
```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_tmp_stale_sweep
# Exit 0: sweep completed. Exit 1: sweep failed.
```

### 2.2 Clean Scratch Files
```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_tmp_scratch_sweep
# Exit 0: sweep completed. Exit 1: sweep failed.
```

### 2.3 Clean Dead Worktrees
```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_wt_dead_sweep
# Exit 0: sweep completed. Exit 1: sweep failed.
```

### 2.4 Clean Disk
```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_box_disk_sweep
# Exit 0: sweep completed. Exit 1: sweep failed.
```

## 3. Role Rotation
Rotate the dispatch and orchestrator leases hourly to ensure redundancy:

### 3.1 Dispatch Lease Rotation
```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_spl_dispatch_rotate
# Exit 0: rotation completed. Exit 1: rotation failed.
```

### 3.2 Orchestrator Lease Rotation
```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_spl_orch_rotate
# Exit 0: rotation completed. Exit 1: rotation failed.
```

## 4. Agent Restarts and Identity Restore
Restore an agent identity after a restart or crash:

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env IDENTITY_RESTORE_IDS=<agent-id> DRY_RUN=0 ./run -a do_spl_agent_identity_restore
# Exit 0: restore completed. Exit 1: restore failed.
```

## 5. Quota and Weekly Limit Handling
Monitor the weekly vendor login quota (claude/grok). If the limit is reached:

1. Restart the agent on `<AGENT_USER>` (global CLAUDE.md).
2. Respawn the lane on the backup vendor per `do_spl_lane_mix`.

## 6. Load Gate
The load gate ensures the fleet does not exceed 40 concurrent agents. Monitor the agent count with:

```bash
sudo -u <OWNER_USER> tmux -S /tmp/tmux-1000/default list-windows -a -F "#{window_name}" | grep -cE "^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgmq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)"
# Exit 0: count <= 40. Exit 1: count > 40.
```

## 7. Box Restart Schedule
Restart each box weekly to apply updates and clear stale processes. Schedule restarts during low-traffic periods using the box restart action family:

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> BOX_RESTART_SLOT=<n> ./run -a do_spl_box_restart_install_cron
# Exit 0: cron installed. Exit 1: cron failed.
```

## 8. Incident Runbooks

### 8.1 Common Incidents
- **CI Gate Red**: See [CI Gate Reliability](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/specs/016-spool-testability/ci-gate-reliability-2026-09-21.md).
- **Deploy Lag**: Run `do_check_deploy_lag` and watch the GitHub workflow.
- **Agent Stuck**: Restart with `do_spl_agent_identity_restore`.
- **Lease Conflict**: Run `do_spl_dispatch_lease fleet-show` and resolve conflicts manually.

## 9. Gaps
- No named action for cleaning old spool messages beyond `do_spl_session_prune` and `do_spl_topic_archive`.
- No named action for quota monitoring.
- No named action to pause non-critical workflows.
- Tenant root keys: no action lists required workspaces or checks for missing keys.
- Self-hosted CI runners: no named action to re-register.