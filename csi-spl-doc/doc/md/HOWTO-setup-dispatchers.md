# Set up the master/failover dispatchers on a machine

> Generated from qto doc `6bca1500-a011-4541-92f5-51a717536a27`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

This is the setup prompt: an agent (or a person) on a NEW machine follows it
from top to bottom. The design is in
[SPEC-spool-fleet-roles.md](SPEC-spool-fleet-roles.md); this page is only the
steps. Every step is a named action under `csi-spl-orc`, and every action is
idempotent, so re-running a step that is already done changes nothing.

<a id="ws-doc-e613cb04-4575-4e7f-a2fe-56026a6c759a"></a>
## 1. What you end up with

| piece | what it is |
|---|---|
| master dispatcher | a Claude Code session with a fixed agent id (default `CLE-002`), auto permission mode, its own worktree |
| failover dispatcher | the same, default `CLE-003`; it stays on standby until the lease promotes it |
| desks | each dispatcher is seated in every workspace, so web UI posts reach it |
| desk-reply permission | each dispatcher's worktree allows `do_spl_desk_reply` as itself (`DESK_AGENT=<id>`) and nothing else beyond auto mode; its brief teaches the one command that rule matches (run from its own worktree, body in `DESK_BODY_FILE`) |
| post-drop dir | where a dispatcher leaves a post its harness refused, for the orchestrator to post |
| heartbeat lease | the renew + watch loops of `do_spl_dispatch_lease`, kept running by the desk reconcile cron |

<a id="ws-doc-0e17d216-62c0-41d9-9490-4add236e0495"></a>
## 2. Before you start

<a id="ws-doc-113f9cec-58ad-4624-80ff-7e4f03a36355"></a>
### 2.1 Requirements

- A checkout of this repository on trunk, up to date, that is NOT an agent
  worktree. The desk reconcile cron must already be installed from it
  (`do_spl_desk_install_service`), because that cron keeps the lease loops
  alive after a reboot.
- The spool root exists (`do_provision_spool_root`) and the orchestrator agent
  runs in a tmux window of the box user's session.
- Each workspace's desk box is pinned, or you hold the workspace root keys as
  `<workspace>.json` files in one directory.

<a id="ws-doc-3d3080dd-a328-47e0-ad4b-e5fb18eeef66"></a>
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

<a id="ws-doc-a85261ab-092a-413d-a770-8de71134485b"></a>
## 3. Set up

<a id="ws-doc-1d4b8eda-a867-4eb1-b3c9-8552fcb50cdf"></a>
### 3.1 Read the plan

The dry run prints one `PLAN <step> <what>` line per missing piece and one
`OK <step>` line per piece already in place. It writes nothing.

```bash
cd "$CHECKOUT/csi-spl-orc" && ./run -a do_spl_dispatch_setup
```

<a id="ws-doc-595b1d9f-d9ec-4f9b-8ba5-985fea48f031"></a>
### 3.2 Apply it

```bash
cd "$CHECKOUT/csi-spl-orc" && DRY_RUN=0 ./run -a do_spl_dispatch_setup
```

The steps, in the order the action runs them:

| step | does |
|---|---|
| `posts-dir` | creates the post-drop dir, mode 2777 |
| `lease-conf` | writes `<spool root>/dispatch/lease.conf`; this file is what turns the lease on for this box. A re-run keeps every key it does not set and leaves `lease.conf.bak-<UTC>-setup` (section 7.2) |
| `brief` | renders each dispatcher's brief from `csi-spl-orc/src/bash/features/dispatch/brief-dispatcher.tpl.md` |
| `worktree` | creates `<checkout>-wt/<id>` BEFORE the spawn, so the session starts with its settings |
| `settings` / `exclude` | writes `.claude/settings.local.json` (desk replies only) and keeps it out of git |
| `spawn` | starts the dispatcher with its fixed id when no live session carries that id |
| `desk` | seats the dispatcher in each workspace where it has no seat |
| `legacy-registry` | copies the registry row when `DISPATCH_LEGACY_REGISTRY` is set |
| `lease-loops` | starts the renew and watch loops when they are not running |
| channel subscriptions | `do_spl_dispatch_subscribe`: every OD seat (orchestrator, master, failover) of every fleet box in every channel of every workspace (default channels included; owner 2026-10-03, SPEC-spool-fleet-roles.md 2.1). The hub delivers a web UI post to a channel's SUBSCRIBED agents and uses the fallback list only when none is online. An OD seat the workspace does not seat is reported `UNSEATED` (seat it with `do_spl_desk_up`). It reads the hub DB even in the dry run; `DISPATCH_SUBSCRIBE=0` skips it. Dead subscriptions (no live process) are reported as `DEAD`, never removed |
| unanswered sweep | `do_spl_unanswered_sweep_install_cron`: one crontab line (`# csi-spl:unanswered-sweep`) running the unanswered-post sweep every 10 min, which sends the lease holder the topics in every workspace whose last message is a human's ([SPEC section 3.2](SPEC-spool-fleet-roles.md)). The dry run prints the crontab diff; `DISPATCH_SWEEP=0` skips it |

<a id="ws-doc-ea361a55-e5a6-4f60-86ed-516f0005f2ca"></a>
### 3.3 Relaunch a session that started before its settings

A running session does not load a settings file created after it started. When
the setup prints `RELAUNCH <id> ...`, have the orchestrator relaunch that
session (resume it, so it keeps its conversation). The setup never kills or
restarts a session itself.

<a id="ws-doc-d4896a5d-9ecc-4386-b38f-b289fa06f812"></a>
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

You rarely need it by hand: the desk reconcile cron runs it with `DRY_RUN=0`
on every tick (`do_spl_dispatch_tick`, while `lease.conf` exists) and logs
only the `DISPATCH` lines of a tick that changed something.

<a id="ws-doc-52af151a-cabc-421f-a573-7309a8f7fc90"></a>
### 3.5 Install the unanswered sweep only

The same step 11 on its own. The dry run prints the crontab diff.

```bash
cd "$CHECKOUT/csi-spl-orc" && ./run -a do_spl_unanswered_sweep_install_cron
```

Apply it.

```bash
cd "$CHECKOUT/csi-spl-orc" && DRY_RUN=0 ./run -a do_spl_unanswered_sweep_install_cron
```

See the current list without sending anything.

```bash
cd "$CHECKOUT/csi-spl-orc" && ./run -a do_spl_unanswered_sweep
```

<a id="ws-doc-4c84ef5b-3d18-4c6f-b925-3f873a1988b9"></a>
## 4. Verify

<a id="ws-doc-dae54fa9-99ed-4d8e-8814-6a8bcc36110b"></a>
### 4.1 Run the check

It prints one table and exits non-zero on any gap.

```bash
cd "$CHECKOUT/csi-spl-orc" && ./run -a do_spl_dispatch_check
```

| row | a gap means |
|---|---|
| `<id> process` | no live session carries that id: run the setup again |
| `<id> permission mode` | the session lacks its vendor's launch flags: a claude seat `--dangerously-skip-permissions` and no `--permission-mode`, a grok, mistral, agy or qwen seat the flags `spool_claude_perm_flags` gives its vendor (SPL-1714; the vendor is the process's, not the id's): respawn it |
| `<id> model` | with `DISPATCH_MODEL` set, the session runs another model |
| `<id> desk-reply permission` | claude seats only (another vendor's seat reads `ok`, its launch flags allow the commands): the settings file is missing, its allow rule does not match the command the brief teaches, or its desk rules were written after the session started: the file's birth time, as setup writes a new file only when the desk rules change and rewrites it in place otherwise (3.3) |
| `<id> desks` | the workspaces it has no seat in |
| `<id> unread` | more than `DISPATCH_UNREAD_MAX` (default 20) messages wait in its inbox |
| `lease` | the holder is not a dispatcher, or the lease is older than 180 s (fleet mode: a fresh holder on the other machine is `ok`, this one stands by) |
| `lease renew loop` / `lease watch loop` (fleet mode: `lease fleet loop`) | that loop is not running: `LEASE_CMD=ensure` (4.3) |
| `<workspace> #<channel>` | a dispatcher is not subscribed there, or the orchestrator is: run 3.4 (`DISPATCH_CHECK_SUBS=0` skips these rows) |

<a id="ws-doc-92d570b0-797e-4320-a666-cd271fa611ee"></a>
### 4.2 Show the lease

Prints `<holder> <age-seconds>`.

```bash
cd "$CHECKOUT/csi-spl-orc" && LEASE_CMD=show ./run -a do_spl_dispatch_lease
```

<a id="ws-doc-0114b33f-c8dc-48e0-8abe-1298c0d60097"></a>
### 4.3 Start the lease loops by hand

The cron does this every tick; run it yourself to avoid waiting.

```bash
cd "$CHECKOUT/csi-spl-orc" && LEASE_CMD=ensure ./run -a do_spl_dispatch_lease
```

<a id="ws-doc-a15f180c-bc53-4074-970c-74fdc3e70679"></a>
### 4.4 Read the transitions

Every start, bind, failover and handback is one line.

```bash
tail -20 "${SPOOL_ROOT:-/var/spool-hub}/dispatch/lease.log"
```

<a id="ws-doc-96b47efb-9ce4-4424-9ddb-9e9377e68c94"></a>
## 5. Prove the failover once

Run this with the orchestrator watching, on a quiet moment: stop only the renew
loop, wait for the promotion, then let the cron (or 4.3) bring it back.

<a id="ws-doc-38bf154b-3123-46e7-887e-bf2f14844f0c"></a>
### 5.1 Stop the lease loops

```bash
cd "$CHECKOUT/csi-spl-orc" && LEASE_CMD=stop ./run -a do_spl_dispatch_lease
```

<a id="ws-doc-252bcc83-c417-4f68-8718-80eb8ff5ea8a"></a>
### 5.2 Start only the watch loop

```bash
cd "$CHECKOUT/csi-spl-orc" && setsid nohup env LEASE_CMD=watch ./run -a do_spl_dispatch_lease >/dev/null 2>&1 < /dev/null &
```

<a id="ws-doc-ea23868b-58db-4d32-992c-f2ef2c7b218e"></a>
### 5.3 Wait for the promotion

After 180 to 240 s the log shows `FAILOVER: ... -> <failover> active` and the
failover receives `DISPATCH LEASE: you are now ACTIVE`. Then bring the renew
loop back; the next watch tick logs `handback` and sends `STANDBY`.

```bash
cd "$CHECKOUT/csi-spl-orc" && LEASE_CMD=ensure ./run -a do_spl_dispatch_lease
```

<a id="ws-doc-708418cc-8456-4ce1-a0dc-fcec741dc9a6"></a>
## 6. Two machines: one fleet lease

Do this when a second machine (the satellite) runs its own trio and only ONE
orchestrator and ONE master dispatcher may act across both. The design is
[SPEC section 4.1](SPEC-spool-fleet-roles.md). Run 6.1 and 6.2 on EACH
machine, with that machine's own ids and name; the fleet name, the priority
list and the workspace are the same on both.

<a id="ws-doc-6aeb0e3f-33de-4406-8b21-8246480aa367"></a>
### 6.1 Requirements

- Every step of sections 2 to 4 is done on this machine.
- This machine's desk box (`box-desk`, or `LEASE_DESK_BOX`) is pinned in the
  workspace that holds the lease row (`DISPATCH_LEASE_TENANT`). The two
  machines need different desk box ids in that workspace.
- `jq` is installed.

<a id="ws-doc-e42dbf31-90e2-4dc3-b21e-356f9520367e"></a>
### 6.2 Write the fleet lines into lease.conf

A machine's name is its desk box id, the `<box>` of `<ID>@<box>` (box.env
`SPOOL_DESK_BOX`). `DISPATCH_MACHINE` defaults to it. `DISPATCH_PRIORITY` lists
both machines' boxes, the preferred one first. Both machines run
`CLE-001/002/003`, because those ids are reserved on every box. The example
makes the box PC (box `pc`) lead and the satellite (box `sat`) stand by.

```bash
cd "$CHECKOUT/csi-spl-orc" && DRY_RUN=0 DISPATCH_FLEET=main DISPATCH_MACHINE=pc DISPATCH_PRIORITY=pc,sat DISPATCH_LEASE_TENANT=<workspace> ./run -a do_spl_dispatch_setup
```

From the next cron tick, `ensure` runs the fleet loop instead of renew +
watch. A later re-run of `do_spl_dispatch_setup` without `DISPATCH_FLEET`
keeps the fleet lines, so this machine never leaves fleet mode silently.

<a id="ws-doc-a116c789-e670-45ed-b33f-47c881a151ee"></a>
### 6.3 Show the fleet lease

Prints one `<role> <holder> <age-seconds> <gen>` line per role, read from the
hub.

```bash
cd "$CHECKOUT/csi-spl-orc" && LEASE_CMD=fleet-show ./run -a do_spl_dispatch_lease
```

<a id="ws-doc-a5cb4198-8735-4368-b34d-d6bc54ba2e65"></a>
### 6.4 Flip the priority

To make the satellite lead, set `LEASE_PRIORITY=sat,pc` in BOTH machines'
`<spool root>/dispatch/lease.conf`, or re-run 6.2 on both with
`DISPATCH_PRIORITY=sat,pc`. The satellite takes both roles on its next tick.

<a id="ws-doc-1af947f7-2d20-469f-a516-2d1e359c7671"></a>
### 6.5 The drill: takeover and handback

On the box PC, stop its fleet loop. Within 180 to 240 s the satellite's log
shows `takes over from CLE-002@pc`, and its orchestrator and master hear `you are
now ACTIVE`. Post one test message in each channel, and check that each one is
answered once, by the satellite.

```bash
cd "$CHECKOUT/csi-spl-orc" && LEASE_CMD=stop ./run -a do_spl_dispatch_lease
```

Then start it again. On its first tick, the PC takes both roles back, and the
satellite's agents hear `STANDBY`. The next test post is answered once, by the
PC.

```bash
cd "$CHECKOUT/csi-spl-orc" && LEASE_CMD=ensure ./run -a do_spl_dispatch_lease
```

<a id="ws-doc-2f749d55-4829-49b2-b222-d6be884b51f3"></a>
## 7. Undo

<a id="ws-doc-3850c3c7-edbb-46cb-a20f-8f373bbe8792"></a>
### 7.1 Stop the lease on this box

Stops both loops by their pid files; removing `lease.conf` keeps the cron from
starting them again. Never stop them with `pkill -f <pattern>`: the pattern
also matches the shell that runs it, and kills that shell.

```bash
cd "$CHECKOUT/csi-spl-orc" && LEASE_CMD=stop ./run -a do_spl_dispatch_lease && rm "${SPOOL_ROOT:-/var/spool-hub}/dispatch/lease.conf"
```

<a id="ws-doc-3d35918d-9e54-486b-b778-98a006808bc2"></a>
### 7.2 lease.conf has one writer; never edit it from a test shell

Every action that changes `lease.conf` (setup, the orch and dispatch
rotations, the role switch, `do_spl_lease_rank`, `do_spl_box_leave`) writes it
through `spl_lease_conf_write` (`csi-spl-orc/lib/bash/funcs/spl-lease-conf.func.sh`):
a key the writer does not name is kept, and the old file is left as
`lease.conf.bak-<UTC>[-<tag>]` first. The test
`csi-spl-orc/src/bash/tests/lease-conf-write.tst.sh` fails on any other
write to it in the orc code (SPL-1713).

So a `lease.conf` with fewer keys than its newest backup and no backup of
that change was cut by hand. On 2026-10-13 a lane pasted the lines of
`test-spool-notify-orch.sh` into a plain `sudo -u <box user> bash -c '...'`: with
no sandbox, `spool_env_resolve` put `SPOOL_ROOT` on the live
`/var/spool-hub`, its `printf` left three lines (20:05Z) and its `rm -f`
removed the file (20:07Z). Run a test file whole, never its lines: only its
sandbox keeps it off the live root. `spool_env_resolve` now refuses the live
root (exit 96, `spool-env: REFUSED`) when a test file is on the call stack,
when the test lib (`t_sandbox`) is loaded, or when a shell that runs no
script file (`bash -c`, `bash -s`, a prompt) loaded `spool-env.inc.sh` from a
lane worktree (`<repo>-wt/<id>`). A real caller of that last shape sets
`SPOOL_LIVE_OK=1` (the lane restart and handover launchers do).

`LEASE_CMD=ensure` now refuses to leave fleet mode while the fleet loop runs
and the newest backup still has `LEASE_FLEET`: it logs `ensure REFUSED` in
`lease.log` and the loop keeps running. Restore the file from that backup,
then ensure again. To leave fleet mode on purpose, stop the loops first
(`LEASE_CMD=stop`), then edit the file and ensure.

<!-- version: 0.3.2 · updated: 2026-10-13 · last-edit: 2026-10-13T20:30:00Z -->
