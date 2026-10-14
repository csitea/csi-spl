# The GC agent: a garbage collector on every box

Owner HUM-10, t1 91a36ace (issue SPL-1733), in order:

- 2135b302: "we should have a \"garbage collector\""
- e0f04358, aaf5e4e0, 7269bcee: poke each running agent that seems stuck,
  "try" to wake it, see what it should be doing, kill it if nothing happens,
  and restart it.
- 5b2b16c9: "started with the same prompt by the watcher service every 30 min"
- 45a1cb8e, f316f140: after one pass over the agents of a box "he should just
  close itself" (or ask the orchestrator to close it).
- 5b224da1: help a stuck agent first ("check its issues"), "but not spent
  more than 3 minutes on an agent".
- 9c595541: "each box should have its own GC, for now on round hours the
  Claude and on the 30th minute the grok agents could be running".

## 1. What runs, and when

### 1.1 One GC per box, two slots an hour

Every box runs its own GC. The box cron row `gc`
(`csi-spl-orc/cnf/box-crons/box-crons.manifest`, tag
`# csi-spl:box-cron:gc`) calls `csi-spl-orc/src/bash/scripts/gc-cron.sh`
every minute; at a minute that is no slot it exits before `./run`, so the
cost is one `awk`. At a slot it runs `GC_CMD=start ./run -a do_spl_gc`.

The slots and their vendor live in ONE place, `csi-spl-orc/cnf/gc/gc.conf`:

| line | meaning |
|---|---|
| `slot 00 claude` | at :00 the GC is a claude session |
| `slot 30 grok` | at :30 the GC is a grok session |
| `fallback claude` | the vendor when the slot's CLI is not installed on the box |
| `GC_AGENT_CAP=180` | the owner's 3 minutes per agent |
| `GC_MAX_AGE=1500` | a GC older than this is ended by the next start |
| `GC_POKE_WAIT=1200` | a restart needs a poke from an earlier pass, at least this old |

### 1.2 No overlap

`start` keeps `<spool root>/dispatch/gc/run` (`<epoch> <pane> <vendor>
<run id>`). A live window `gc@<box>` younger than `GC_MAX_AGE` means the
start is a `SKIP` (logged); an older one is ended first (`END-STALE`).
Counting test: `csi-spl-orc/src/bash/tests/gc-agent.tst.sh` case 2 (two
starts = one window; its control: the window gone, the next start opens a
second).

### 1.3 The session

The window runs `csi-spl-orc/src/bash/features/gc/gc-session.sh`: the CLI
as the agent user, bypass flags from `spool_claude_perm_flags`, the fixed
prompt `csi-spl-orc/src/bash/features/gc/gc-prompt.md`. The window keeps no
shell after the CLI: when the pass ends, the window is gone. The GC carries
no agent id: it is not counted against the 40-window ceiling and the
watchdog does not judge it.

## 2. One pass

### 2.1 The agent judges, the action acts

Every step is `do_spl_gc` (`csi-spl-orc/src/bash/run/spl-gc.func.sh`); the
GC session only decides which one to call:

| `GC_CMD` | does |
|---|---|
| `scan` | one block per agent of this box: issue, brief, heartbeat silence, last commit, last post, unread inbox, an earlier GC poke, pane tail, a hint (`working`, `silent`, `accepted`) |
| `begin` | starts the agent's 3-minute clock, prints its issue and last errors |
| `poke` | `GC_HINT` as a spool note on task `gc-<id>` (the send rings the pane) |
| `restart` | only after a poke from an earlier pass and no heartbeat progress since: `do_spl_agent_restart CAUSE=gc`, detached, with its own guards |
| `close-ask` | `GC_WHY` to the report addressee (2.3): close this finished lane (once a day per id); the orch lease holder gets a cc |
| `done` | `GC_SUMMARY`: one log line, one note to the report addressee (2.3) on task `gc-<box>`, then the GC window closes |
| `status` | the last pass and the log tail |

### 2.2 Guards

- **3 minutes per agent**: `poke`, `restart` and `close-ask` refuse (exit 4,
  `CAP`) past `GC_AGENT_CAP` on the agent begun last; the next `begin` logs
  the time spent, `OVER` past the cap.
- **Role seats (001..003)** are scanned only: rotation and the watchdog own
  them.
- **A human hold** (`<id>/.human-hold`) refuses every step; the restart also
  applies the watchdog's human-activity gate.
- **Never kill by pattern**: the restart is the fleet's one restart path.

### 2.3 Who reads the report

Owner HUM-10, form 84d604dd (msg 1c446016, 2026-10-14): the GC report goes
to whoever holds the lease, not a fixed orchestrator seat. On the 10-13 night
every sat pass sent its summary to c-001, which sat on a limit dialog, and
nobody acted on the findings (SPL-1768, SPL-1803).

- The summary and every close-ask go to the **dispatch lease holder**, read
  at send time (`do_spl_dispatch_lease` `LEASE_CMD=show`), as `<ID>@<box>`
  (a bare id is this box's).
- A close-ask also sends a **cc to the orch lease holder** when that is
  another seat.
- A **stale** (older than `LEASE_STALE`, 180 s) or **missing** lease falls
  back to the orch lease holder (`lease.orch` while fresh, else lease.conf
  `LEASE_ORCH` at this box); the line ends with why, and `gc.log` gets a
  `REPORT-TO` line.
- `GC_REPORT_TO` pins one addressee instead (no cc, no fallback).

## 3. Operations

### 3.1 Install the cron row on a box

From the box's main checkout, as the box user:

```bash
cd csi-spl-orc && BOX_CRONS_ONLY=gc DRY_RUN=0 ./run -a do_install_box_crons
```

### 3.2 See the last pass

```bash
cd csi-spl-orc && GC_CMD=status ./run -a do_spl_gc
```

### 3.3 Change a slot's vendor

Edit `csi-spl-orc/cnf/gc/gc.conf` and land it; the next slot reads it.
