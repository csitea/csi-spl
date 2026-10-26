> Generated from qto doc `d27e38ca-759a-45dd-8c6f-8a3220748599`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Exported from the Qto doc [Operations and Maintenance Guide](https://spool-hub.ai/workspace/docs?doc=aba39883-47d1-44bc-86c1-dbb48ede9e73&view=doc) (`aba39883-47d1-44bc-86c1-dbb48ede9e73`) on 2026-10-11T20:55:36Z; edit in Qto, not here.

<a id="ws-doc-2e48cf69-b990-4ea1-bcd9-4d38d207cdf3"></a>
# 1 Daily routine

This guide covers the daily and weekly routines for operating and maintaining the spool fleet. It assumes the system is already installed and configured: see the Installation and configuration guide. `<CHECKOUT>` is the main checkout, `<OWNER_USER>` the OS user that owns it, `<AGENT_USER>` the OS user every AI CLI runs as.

Run the following checks every morning and after deployments.

<a id="ws-doc-fc538359-34e1-4a50-92af-fdda3617dc0c"></a>
## 1.1 Health checks

<a id="ws-doc-7f0094cd-9cb9-4b75-8635-92a0bb36d344"></a>
### 1.1.1 Database health

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env ENV=prd ./run -a do_spl_db_health
```

<a id="ws-doc-9e9c30ca-e1d2-45f4-9c38-4cc996b5ede8"></a>
### 1.1.2 Deploy lag

Exit 0 means current or pending, exit 3 lagging, exit 1 cannot tell (the function header of `do_check_deploy_lag`).

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env ENV=prd ./run -a do_check_deploy_lag
```

<a id="ws-doc-1367551f-dc2d-4468-a239-895d699ef1c8"></a>
### 1.1.3 CI gate report

Counted per job, not per run.

```bash
cd <CHECKOUT>/csi-spl-iac && sudo -u <OWNER_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate
```

<a id="ws-doc-14fa4a3c-2023-4a41-a44d-f281ed5e20cf"></a>
### 1.1.4 GitHub runner check

Exit 1 when any runner fails; a box with no runner unit is OK, exit 0. A runner the CPU budget parked is `PARKED`, not a failure (the function header of `do_check_gh_runner`).

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_check_gh_runner
```

<a id="ws-doc-f095f62d-3ad3-4497-b50a-cc82ba8100bf"></a>
### 1.1.5 Backup verification

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env ENV=prd ./run -a do_spl_db_backup_verify
```

<a id="ws-doc-b1743345-ebde-4fec-a258-ec9726aa0644"></a>
## 1.2 Lease checks

Verify the dispatch lease is held by an active agent.

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env LEASE_CMD=show ./run -a do_spl_dispatch_lease
```

<a id="ws-doc-e7378d2c-9840-4394-86bc-043217216f79"></a>
## 1.3 Unanswered sweep

Check for unanswered spool messages older than 1 hour.

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_spl_unanswered_sweep
```

<a id="ws-doc-9452326f-9413-482f-af7e-9b6b5fcf57bb"></a>
# 2 Weekly routine

Clean temporary files and stale worktrees. Each sweep below is a dry run unless `DRY_RUN=0`: the first block prints the plan, the second one does it.

<a id="ws-doc-0607bae5-0ea3-4811-adcc-2ea37118f078"></a>
## 2.1 Clean /tmp, plan

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_tmp_stale_sweep
```

<a id="ws-doc-627d7196-1c0c-4126-abf6-37b253e83293"></a>
## 2.2 Clean /tmp, apply

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env DRY_RUN=0 ./run -a do_tmp_stale_sweep
```

<a id="ws-doc-1c4aa46c-880f-4eff-ae1e-0b697107ef9e"></a>
## 2.3 Clean scratch files, plan

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_tmp_scratch_sweep
```

<a id="ws-doc-5eaa56d5-fe7e-4f9e-afb4-8edf73abb575"></a>
## 2.4 Clean scratch files, apply

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env DRY_RUN=0 ./run -a do_tmp_scratch_sweep
```

<a id="ws-doc-1a457f14-c3b1-45e2-819e-e1fc2edafe37"></a>
## 2.5 Clean dead worktrees, plan

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_wt_dead_sweep
```

<a id="ws-doc-e340df65-98db-494d-8ab9-3771ae1fd030"></a>
## 2.6 Clean dead worktrees, apply

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env DRY_RUN=0 ./run -a do_wt_dead_sweep
```

<a id="ws-doc-8dfce578-8463-4743-aa2e-feeaa6dec071"></a>
## 2.7 Clean disk, plan

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_box_disk_sweep
```

<a id="ws-doc-d0437801-c564-4929-9b8e-6fa7caf7a4a0"></a>
## 2.8 Clean disk, apply

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env DRY_RUN=0 ./run -a do_box_disk_sweep
```

<a id="ws-doc-2f1d4764-fd9f-42e4-ad30-85c27e9a4712"></a>
## 2.9 Clean finished lane workdirs, plan

A finished lane keeps its worktree, its `/tmp` scratch and its `/var/tmp` leftovers for 24 hours: the retire lists them in `$SPOOL_ROOT/workdirs.tsv` (path, kind, agent, box, branch, finished_at). The box disk sweep runs this action every time it runs (its `workdirs` step); run it by hand to see what it would remove now. A dry run unless `DRY_RUN=0`.

```bash
cd <CHECKOUT>/csi-spl-utl && sudo -u <OWNER_USER> ./run -a do_sweep_workdirs
```

One line per row. `PLAN remove` or `REMOVE`: the directory is older than the limit and nothing holds it. `KEEP fresh`: younger than the limit. `KEEP in-use`: a process works in it. `KEEP dirty`: a worktree with uncommitted or untracked files; it stays until someone commits or removes them. `DROP gone`: the directory no longer exists, so the row goes. `DROP reused`: a new lane now holds the worktree, so the row goes and the directory stays.

An `ALERT critical disk` line means 8% or less of a disk is free: rows older than 6 hours go, oldest first. Check the disk with `df -h` and read the sweep's other steps in `box-disk-sweep.log`.

<a id="ws-doc-49e00f04-a42c-465e-98ae-7539af69267f"></a>
## 2.10 Clean finished lane workdirs, apply

Removes what the plan above listed as `PLAN remove`. A worktree goes through `git worktree remove`, never `rm -rf`; its branch goes only when it is merged.

```bash
cd <CHECKOUT>/csi-spl-utl && sudo -u <OWNER_USER> env DRY_RUN=0 ./run -a do_sweep_workdirs
```

<a id="ws-doc-d25a9f24-2c98-4999-9f34-87af2537eec7"></a>
## 2.11 A bad deploy: roll back

When a deploy breaks the hub or the WUI:

- A `prd` rollback is the owner's call, per incident.
- Roll `dev` back to the same `TO` first with `do_wui_rollback` / `do_hub_rollback` (DevOps guide, "Rollback"), then check `/version` and `build.json`.
- An older WUI ships the CSP `connect-src` of its own time, so a workspace host added since then fails in it.
- The rollback holds until the next deploy or the wf 21 catch-up; land the fix or a revert on master before that.

<a id="ws-doc-fe7fd6e5-02f7-4d1b-9c8e-b45d2c55015a"></a>
# 3 Role rotation

The dispatch and orchestrator roles rotate hourly, from the crons `do_spl_dispatch_rotate_install_cron` and `do_spl_orch_rotate_install_cron` install. Both actions are a dry run unless `DRY_RUN=0`; run them by hand only to see the plan.

<a id="ws-doc-736d1cb3-73d6-4cb9-b541-434f737ff5c2"></a>
## 3.1 Dispatch rotation

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_spl_dispatch_rotate
```

<a id="ws-doc-10de1047-5f9e-4177-a3b0-47437d6b5871"></a>
## 3.2 Orchestrator rotation

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> ./run -a do_spl_orch_rotate
```

<a id="ws-doc-d2a86996-e12d-4b2d-bef3-d486c1771d53"></a>
# 4 Agent restarts and identity restore

Restore an agent identity after a restart or crash.

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env IDENTITY_RESTORE_IDS=<agent-id> DRY_RUN=0 ./run -a do_spl_agent_identity_restore
```

<a id="ws-doc-d6bd7929-e839-4d3b-bfca-6ad92730a982"></a>
# 5 Quota and weekly limit handling

Watch the weekly vendor login quota (claude, grok). When a seat hits its limit:

1. Restart the agent as `<AGENT_USER>` (global CLAUDE.md).
2. Respawn the lane on the backup vendor that `do_spl_lane_mix` names for its task kind.

<a id="ws-doc-d76939b6-20d6-4f52-829f-0b9bb867bfdf"></a>
# 6 Load gate

The fleet runs at most 40 concurrent agent windows. The count below must stay at 40 or below.

```bash
sudo -u <OWNER_USER> tmux -S /tmp/tmux-1000/default list-windows -a -F "#{window_name}" | grep -cE "^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgmq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)"
```

<a id="ws-doc-a6110ade-6c65-43dc-a31b-d7f07cd01422"></a>
# 7 Box restart schedule

Restart each box weekly to apply updates and clear stale processes, during low-traffic periods, with the box restart action family. `BOX_RESTART_SLOT` is this box's slot index in cnf `env.box.restart.slots`. The action is a dry run unless `DRY_RUN=0`.

```bash
cd <CHECKOUT>/csi-spl-orc && sudo -u <OWNER_USER> env BOX_RESTART_SLOT=<n> DRY_RUN=0 ./run -a do_spl_box_restart_install_cron
```

<a id="ws-doc-f4cc500c-5338-4541-b604-6be49678133d"></a>
# 8 Incident runbooks

- **CI gate red**: see [CI gate reliability](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/specs/016-spool-testability/ci-gate-reliability-2026-09-21.md).
- **Deploy lag**: run `do_check_deploy_lag` and watch the GitHub workflow.
- **Agent stuck**: restart it with `do_spl_agent_identity_restore`.
- **Lease conflict**: run `LEASE_CMD=fleet-show ./run -a do_spl_dispatch_lease` and resolve the conflict by hand.

<a id="ws-doc-764988da-b58a-4fae-843d-60302ca38bab"></a>
# 9 Purge a listed set of messages

`do_spl_msg_purge` (SPL-1641) deletes an exact list of messages, any sender, and archives their topics, in a cloud env. The list file holds one `<tenant> <msg_id> <task_id>` per line. It deletes the way the hub deletes a message (a hard delete; the revisions, reactions, deliveries and the other `ON DELETE CASCADE` rows go with it) and archives each topic the way the hub does (`archived_at` / `archived_by` on the topic's first remaining opening card and its DM mirrors), so the web UI lists the topic as archived and its link still opens it. An issue's discussion is skipped: it is archived with its issue.

It runs one transaction per tenant under that tenant's row-level security, as the env's project service account, and refuses unless every listed id exists in its task and the file holds `EXPECT_N` rows. Before each delete it writes the full rows to an undo journal, `<state dir>/msg-purge/<env>-<tenant>-<utc>.undo.tsv`. It is a dry run, counts only, unless `DRY_RUN=0`.

<a id="ws-doc-9aab74dd-e14f-4de2-9a5c-199dccc06ad4"></a>
## 9.1 Purge, plan

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=<env> LIST_FILE=<list.tsv> EXPECT_N=<rows> ARCHIVED_BY=<HUM-id> ./run -a do_spl_msg_purge
```

<a id="ws-doc-64f3a91e-09da-45a6-b771-9ff9e2fdcf0c"></a>
## 9.2 Purge, apply

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=<env> LIST_FILE=<list.tsv> EXPECT_N=<rows> ARCHIVED_BY=<HUM-id> DRY_RUN=0 ./run -a do_spl_msg_purge
```

<a id="ws-doc-9c533794-ca52-4d36-b147-045733d44103"></a>
## 9.3 Undo one tenant's purge

Puts the journaled rows back with every column they had and clears the archive stamps that run set where they still hold. Refused when any journaled message exists again.

```bash
cd <CHECKOUT>/csi-spl-orc && ENV=<env> JOURNAL=<file.undo.tsv> DRY_RUN=0 ./run -a do_spl_msg_purge_undo
```

<a id="ws-doc-ef327e69-7c29-4904-8f06-25665a12395a"></a>
# 10 Gaps

- No named action for cleaning old spool messages by age or sender beyond `do_spl_session_prune` and `do_spl_topic_archive`; `do_spl_msg_purge` takes an exact list.
- No named action for quota monitoring.
- No named action to pause non-critical workflows.
- Tenant root keys: no action lists the required workspaces or checks for missing keys.
