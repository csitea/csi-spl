# Exported from the Qto doc [Operations and Maintenance Guide](https://hub.csitea.net/t1/doctree/73097455-6384-4819-99c6-e10eead08c0d) on 2026-10-11T20:00:00Z; edit in Qto, not here.

---

# Operations and Maintenance Guide

This guide covers the daily and weekly routines for operating and maintaining the spool fleet. It assumes the system is already installed and configured (see [Installation and Configuration Guide](https://hub.csitea.net/t1/doctree/1a3900ac-774d-4a47-9ecd-4fc716542aa3)).

## Table of Contents
1. [Daily Routine](#1-daily-routine)
2. [Weekly Routine](#2-weekly-routine)
3. [Role Rotation](#3-role-rotation)
4. [Agent Restarts and Identity Restore](#4-agent-restarts-and-identity-restore)
5. [Quota and Weekly Limit Handling](#5-quota-and-weekly-limit-handling)
6. [Incident Runbooks](#6-incident-runbooks)
7. [Gaps](#7-gaps)

## 1. Daily Routine

### 1.1 Health Checks
Run the following checks every morning and after deployments:

#### 1.1.1 Database Health
```bash
cd /opt/csi/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_spl_db_health
```

#### 1.1.2 Deploy Lag
```bash
cd /opt/csi/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_check_deploy_lag
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
cd /opt/csi/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_spl_sweep_unanswered
```

## 2. Weekly Routine

### 2.1 Cleaning /tmp and Worktrees
Remove stale files and worktrees older than 7 days:

#### 2.1.1 Clean /tmp
```bash
find /tmp -type f -mtime +7 -delete
```

#### 2.1.2 Clean Worktrees
```bash
find /opt/csi/csi-spl-wt -type d -name "*" -mtime +7 -exec rm -rf {} +
```

### 2.2 Agent Restarts
Restart agents to apply updates or clear stuck sessions:

```bash
cd /opt/csi/csi-spl-orc && sudo -u <OWNER_USER> env IDENTITY_RESTORE_IDS=<agent-id> DRY_RUN=0 ./run -a do_spl_agent_identity_restore
```

## 3. Role Rotation

### 3.1 Dispatch Lease Rotation
Rotate the dispatch lease every 24 hours to ensure redundancy:

```bash
cd /opt/csi/csi-spl-orc && sudo -u <OWNER_USER> env LEASE_CMD=rotate ./run -a do_spl_dispatch_lease
```

## 4. Agent Restarts and Identity Restore

### 4.1 Identity Restore
Restore an agent identity after a restart or crash:

```bash
cd /opt/csi/csi-spl-orc && sudo -u <OWNER_USER> env IDENTITY_RESTORE_IDS=<agent-id> DRY_RUN=0 ./run -a do_spl_agent_identity_restore
```

## 5. Quota and Weekly Limit Handling

### 5.1 Weekly Limit Handling
Monitor the weekly quota for GCP and third-party services. If the limit is reached:

1. Notify the owner via spool message.
2. Pause non-critical workflows.
3. Request a quota increase if needed.

## 6. Incident Runbooks

### 6.1 Common Incidents
- **CI Gate Red**: See [CI Gate Reliability](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/pre-push-gate.md).
- **Deploy Lag**: Run `do_check_deploy_lag` and watch the GitHub workflow.
- **Agent Stuck**: Restart with `do_spl_agent_identity_restore`.

## 7. Gaps
- No named action for cleaning old spool messages.
- No automated lease rotation.
- No centralized quota dashboard.