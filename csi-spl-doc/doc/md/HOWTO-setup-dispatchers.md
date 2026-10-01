# Set up the master/failover dispatchers on a machine

This is the setup prompt: an agent (or a person) on a NEW machine follows it
from top to bottom. The design is in
[SPEC-spool-fleet-roles.md](SPEC-spool-fleet-roles.md); this page is only the
steps. Every step is a named action under `csi-spl-orc`, and every action is
idempotent, so re-running a step that is already done changes nothing.

## 1. What you end up with

| piece | what it is |
|---|---|
| master dispatcher | a Claude Code session with a fixed agent id (default `CLE-002`), auto permission mode, its own worktree |
| failover dispatcher | the same, default `CLE-003`; it stays on standby until the lease promotes it |
| desks | each dispatcher is seated in every workspace, so web UI posts reach it |
| desk-reply permission | each dispatcher's worktree allows `do_spl_desk_reply` and nothing else beyond auto mode |
| post-drop dir | where a dispatcher leaves a post its harness refused, for the orchestrator to post |
| heartbeat lease | the renew + watch loops of `do_spl_dispatch_lease`, kept running by the desk reconcile cron |

## 2. Before you start

### 2.1 Requirements

- A checkout of this repository on trunk, up to date, that is NOT an agent
  worktree. The desk reconcile cron must already be installed from it
  (`do_spl_desk_install_service`), because that cron keeps the lease loops
  alive after a reboot.
- The spool root exists (`do_provision_spool_root`) and the orchestrator agent
  runs in a tmux window of the box user's session.
- Each workspace's desk box is pinned, or you hold the workspace root keys as
  `<workspace>.json` files in one directory.

### 2.2 Set the variables for this shell

Every placeholder below is one of these. Pick your own values.

```bash
export ENV=prd CHECKOUT=/path/to/your/checkout DISPATCH_MASTER=CLE-002 DISPATCH_FAILOVER=CLE-003 DISPATCH_ORCH=CLE-001
```

Optional: limit the workspaces (the default is every workspace with a pinned
desk box on this machine, except the `e2e` probe workspace).

```bash
export DISPATCH_TENANTS="<workspace-1> <workspace-2>"
```

Optional: the directory with the workspace root keys, needed only for a desk
box that is not pinned yet.

```bash
export DISPATCH_ROOT_KEY_DIR=/path/to/tenant/keys
```

## 3. Set up

### 3.1 Read the plan

The dry run prints one `PLAN <step> <what>` line per missing piece and one
`OK <step>` line per piece already in place. It writes nothing.

```bash
cd "$CHECKOUT/csi-spl-orc" && ./run -a do_spl_dispatch_setup
```

### 3.2 Apply it

```bash
cd "$CHECKOUT/csi-spl-orc" && DRY_RUN=0 ./run -a do_spl_dispatch_setup
```

The steps, in the order the action runs them:

| step | does |
|---|---|
| `posts-dir` | creates the post-drop dir, mode 2777 |
| `lease-conf` | writes `<spool root>/dispatch/lease.conf`; this file is what turns the lease on for this box |
| `brief` | renders each dispatcher's brief from `csi-spl-orc/src/bash/features/dispatch/brief-dispatcher.tpl.md` |
| `worktree` | creates `<checkout>-wt/<id>` BEFORE the spawn, so the session starts with its settings |
| `settings` / `exclude` | writes `.claude/settings.local.json` (desk replies only) and keeps it out of git |
| `spawn` | starts the dispatcher with its fixed id when no live session carries that id |
| `desk` | seats the dispatcher in each workspace where it has no seat |
| `legacy-registry` | copies the registry row when `DISPATCH_LEGACY_REGISTRY` is set |
| `lease-loops` | starts the renew and watch loops when they are not running |
| channel subscriptions | `do_spl_dispatch_subscribe`: both dispatchers in every channel of every workspace (default channels included), the orchestrator in none. The hub delivers a web UI post to a channel's SUBSCRIBED agents and uses the fallback list only when none is online, so a channel the orchestrator sits in and the dispatchers do not reaches the orchestrator alone. It reads the hub DB even in the dry run; `DISPATCH_SUBSCRIBE=0` skips it. Dead subscriptions (no live process) are reported as `DEAD`, never removed |

### 3.3 Relaunch a session that started before its settings

A running session does not load a settings file created after it started. When
the setup prints `RELAUNCH <id> ...`, have the orchestrator relaunch that
session (resume it, so it keeps its conversation). The setup never kills or
restarts a session itself.

### 3.4 Fix the channel subscriptions only

The same step 10 on its own: the dry run prints `PLAN add`, `PLAN remove`,
`DEAD` and one `SUM` line per workspace.

```bash
cd "$CHECKOUT/csi-spl-orc" && ./run -a do_spl_dispatch_subscribe
```

Apply it.

```bash
cd "$CHECKOUT/csi-spl-orc" && DRY_RUN=0 ./run -a do_spl_dispatch_subscribe
```

## 4. Verify

### 4.1 Run the check

It prints one table and exits non-zero on any gap.

```bash
cd "$CHECKOUT/csi-spl-orc" && ./run -a do_spl_dispatch_check
```

| row | a gap means |
|---|---|
| `<id> process` | no live session carries that id: run the setup again |
| `<id> permission mode` | the session is not in auto mode: respawn it |
| `<id> model` | with `DISPATCH_MODEL` set, the session runs another model |
| `<id> desk-reply permission` | the settings file is missing, or newer than the session (3.3) |
| `<id> desks` | the workspaces it has no seat in |
| `<id> unread` | more than `DISPATCH_UNREAD_MAX` (default 20) messages wait in its inbox |
| `lease` | the holder is not a dispatcher, or the lease is older than 180 s |
| `lease renew loop` / `lease watch loop` | that loop is not running: `LEASE_CMD=ensure` (4.3) |
| `<workspace> #<channel>` | a dispatcher is not subscribed there, or the orchestrator is: run 3.4 (`DISPATCH_CHECK_SUBS=0` skips these rows) |

### 4.2 Show the lease

Prints `<holder> <age-seconds>`.

```bash
cd "$CHECKOUT/csi-spl-orc" && LEASE_CMD=show ./run -a do_spl_dispatch_lease
```

### 4.3 Start the lease loops by hand

The cron does this every tick; run it yourself to avoid waiting.

```bash
cd "$CHECKOUT/csi-spl-orc" && LEASE_CMD=ensure ./run -a do_spl_dispatch_lease
```

### 4.4 Read the transitions

Every start, bind, failover and handback is one line.

```bash
tail -20 "${SPOOL_ROOT:-/var/spool-hub}/dispatch/lease.log"
```

## 5. Prove the failover once

Run this with the orchestrator watching, on a quiet moment: stop only the renew
loop, wait for the promotion, then let the cron (or 4.3) bring it back.

### 5.1 Stop the lease loops

```bash
cd "$CHECKOUT/csi-spl-orc" && LEASE_CMD=stop ./run -a do_spl_dispatch_lease
```

### 5.2 Start only the watch loop

```bash
cd "$CHECKOUT/csi-spl-orc" && setsid nohup env LEASE_CMD=watch ./run -a do_spl_dispatch_lease >/dev/null 2>&1 < /dev/null &
```

### 5.3 Wait for the promotion

After 180 to 240 s the log shows `FAILOVER: ... -> <failover> active` and the
failover receives `DISPATCH LEASE: you are now ACTIVE`. Then bring the renew
loop back; the next watch tick logs `handback` and sends `STANDBY`.

```bash
cd "$CHECKOUT/csi-spl-orc" && LEASE_CMD=ensure ./run -a do_spl_dispatch_lease
```

## 6. Undo

### 6.1 Stop the lease on this box

Stops both loops by their pid files; removing `lease.conf` keeps the cron from
starting them again. Never stop them with `pkill -f <pattern>`: the pattern
also matches the shell that runs it, and kills that shell.

```bash
cd "$CHECKOUT/csi-spl-orc" && LEASE_CMD=stop ./run -a do_spl_dispatch_lease && rm "${SPOOL_ROOT:-/var/spool-hub}/dispatch/lease.conf"
```

<!-- version: 0.2.0 · updated: 2026-10-01 · last-edit: 2026-10-01T08:45:00Z -->
