# Exported from the Qto doc [Operations and Maintenance Guide](https://spool-hub.ai/workspace/docs?doc=b59327b1-2057-4ab7-b33a-0acc2bf5083b&view=doc) on 2026-10-11T20:30:00Z; edit in Qto, not here.

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

### 1.1 Health Checks
Run the following checks every morning and after deployments:

#### 1.1.1 Database Health
```bash
cd /opt/csi/csi-spl-orc && sudo -u <OWNER_USER> env ENV=prd ./run -a do_spl_db_health
```

#### 1.1.2 Deploy Lag
```bash
cd /opt/csi/csi-spl-orc && sudo -u <OWNER_USER> env ENV=prd ./run -a do_check_deploy_lag
```

#### 1.1.3 CI Gate Report
```bash
cd /opt/csi/csi-spl-iac && sudo -u <OWNER_USER> ./run -a do_report_ci_gate
```

### 1.2 Lease Checks
Verify the dispatch lease is held by an active agent:

```bash
cd /opt/csi/csi-spl-orc && sudo -u <OWNER_USER> env LEASE_CMD=show ./run -a do_spl_dispatch_lease
```

### 1.3 Unanswered Sweep
Check for unanswered spool messages older than 1 hour:

```bash
cd /opt/csi/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_spl_unanswered_sweep
```

## 2. Weekly Routine
Clean temporary files:

### 2.1 Clean /tmp
```bash
find /tmp -type f -mtime +7 -delete
```

## 3. Role Rotation
Rotate the dispatch and orchestrator leases every 24 hours to ensure redundancy:

### 3.1 Dispatch Lease Rotation
```bash
cd /opt/csi/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_spl_dispatch_rotate
```

### 3.2 Orchestrator Lease Rotation
```bash
cd /opt/csi/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_spl_orch_rotate
```

## 4. Agent Restarts and Identity Restore
Restore an agent identity after a restart or crash:

```bash
cd /opt/csi/csi-spl-orc && sudo -u <OWNER_USER> env IDENTITY_RESTORE_IDS=<agent-id> DRY_RUN=0 ./run -a do_spl_agent_identity_restore
```

## 5. Quota and Weekly Limit Handling
Monitor the weekly quota for GCP and third-party services. If the limit is reached, follow these steps:

1. Notify the owner via spool message.
2. Pause non-critical workflows.
3. Request a quota increase if needed.

## 6. Load Gate
The load gate ensures the fleet does not exceed 40 concurrent agents. Monitor the agent count with:

```bash
sudo -u <OWNER_USER> tmux -S /tmp/tmux-1000/default list-windows -a -F "#{window_name}" | grep -cE "^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgmq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)"
```

## 7. Box Restart Schedule
Restart each box weekly to apply updates and clear stale processes. Schedule restarts during low-traffic periods.

## 8. Incident Runbooks

### 8.1 Common Incidents
- **CI Gate Red**: See [CI Gate Reliability](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/pre-push-gate.md).
- **Deploy Lag**: Run `do_check_deploy_lag` and watch the GitHub workflow.
- **Agent Stuck**: Restart with `do_spl_agent_identity_restore`.
- **Lease Conflict**: Run `do_spl_dispatch_lease fleet-show` and resolve conflicts manually.

## 9. Gaps
- No named action for cleaning old spool messages.
- No automated lease rotation (use `do_spl_dispatch_rotate_install_cron` and `do_spl_orch_rotate_install_cron`).
- No centralized quota dashboard.
- Worktree cleaning requires manual `git worktree remove` per lane.
- No named action for quota monitoring.