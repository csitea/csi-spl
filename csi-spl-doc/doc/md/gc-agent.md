# The GC agent: a garbage collector on every box

> Generated from qto doc `929c5253-d577-4313-9257-1d9369218944`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

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

<a id="ws-doc-34bfd118-b132-42b8-941e-98b5a9ffcb0c"></a>
## 1. What runs, and when

<a id="ws-doc-6275b073-933f-486b-966f-db50767d13d6"></a>
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

<a id="ws-doc-e879545c-7434-478d-82b2-0300d465ff28"></a>
### 1.2 No overlap

`start` keeps `<spool root>/dispatch/gc/run` (`<epoch> <pane> <vendor>
<run id>`). A live window `gc@<box>` younger than `GC_MAX_AGE` means the
start is a `SKIP` (logged); an older one is ended first (`END-STALE`).
Counting test: `csi-spl-orc/src/bash/tests/gc-agent.tst.sh` case 2 (two
starts = one window; its control: the window gone, the next start opens a
second).

<a id="ws-doc-102a63bb-4406-4087-a496-a2e2fd3b0c81"></a>
### 1.3 The session

The window runs `csi-spl-orc/src/bash/features/gc/gc-session.sh`: the CLI
as the agent user, bypass flags from `spool_claude_perm_flags`, the fixed
prompt `csi-spl-orc/src/bash/features/gc/gc-prompt.md`. The window keeps no
shell after the CLI: when the pass ends, the window is gone. The GC carries
no agent id: it is not counted against the 40-window ceiling and the
watchdog does not judge it.

<a id="ws-doc-e714280c-d137-43f3-ac2e-da30d6ae28a3"></a>
### 1.4 Not the GC: the night zombie sweep

The GC does not archive discussions. The night sweep of zombie discussions (spec 166 row B6, SPL-4519) is its own box cron row `zombie-topics` (`csi-spl-orc/src/bash/scripts/zombie-topics-cron.sh`, `*/15`, `csi-spl-orc/src/bash/run/spl-zombie-topics.func.sh`): at night only, on the dispatch holder's box, it archives idle topics that no open ask, live lane, lane brief or open issue names, at most `ZOMBIE_MAX` a night. It runs `DRY_RUN=1` until the orch holder sets `ZOMBIE_DRY_RUN=0` in the dispatch `lease.conf` after reading a night's planned list.

<a id="ws-doc-4c8572a8-021b-4ee6-a7e6-54b8a8f5d1ab"></a>
## 2. One pass

<a id="ws-doc-b951c120-be00-4600-bb37-feb819c0d8e5"></a>
### 2.1 The agent judges, the action acts

Every step is `do_spl_gc` (`csi-spl-orc/src/bash/run/spl-gc.func.sh`); the
GC session only decides which one to call:

| `GC_CMD` | does |
|---|---|
| `scan` | one block per agent of this box: issue, brief, heartbeat silence, last commit, last post, unread inbox, an earlier GC poke, pane tail, a hint (`working`, `silent`, `accepted`) |
| `begin` | starts the agent's 3-minute clock, prints its issue and last errors |
| `poke` | `GC_HINT` as a spool note on task `gc-<id>` (the send rings the pane) |
| `restart` | only after a poke from an earlier pass and no heartbeat progress since; progress unknown (`-`, an agy seat) is never "no progress" (the poke records the pane and a hash of its last 30 lines; the restart reads `MOVED`, exit 3, no restart, when the pane changed, the agent is in another pane, or an outbox, archive or `lifetime/session.json` file is newer than the poke): otherwise `do_spl_agent_restart CAUSE=gc`, detached, with its own guards, its evidence saying "progress unknown (-)" when that is the case |
| `close-ask` | `GC_WHY` to the report addressee (2.3): close this finished lane (once a day per id); the orch lease holder gets a cc |
| `done` | `GC_SUMMARY`: one log line, one note to the report addressee (2.3) on task `gc-<box>`, then the GC window closes |
| `status` | the last pass and the log tail |

An id with 2+ panes is judged in the pane whose process carries `SPOOL_AGENT_ID=<id>`.

<a id="ws-doc-f09f01f7-4c9c-46ba-a201-7b5dc25b7e82"></a>
### 2.2 Guards

- **3 minutes per agent**: `poke`, `restart` and `close-ask` refuse (exit 4,
  `CAP`) past `GC_AGENT_CAP` on the agent begun last; the next `begin` logs
  the time spent, `OVER` past the cap.
- **Role seats (001..003)** are scanned only: rotation and the watchdog own
  them.
- **A human hold** (`<id>/.human-hold`) refuses every step; the restart also
  applies the watchdog's human-activity gate.
- **Never kill by pattern**: the restart is the fleet's one restart path.

<a id="ws-doc-560b258f-ba09-42fe-92fa-652c9b3a7a9f"></a>
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

<a id="ws-doc-300ce962-2954-4924-93b3-f6d7703f6c77"></a>
### 2.4 The work share in the summary

Owner HUM-10, t1 3209f8b8, msg ad816f96: the GC "must know something" about
the work-class bands of the spawn queue (the rule:
[fleet-rules-index.md](fleet-rules-index.md), row "spawn queue: work classes
and bands"). Before `done` the GC runs the read-only
`SPAWN_SHARE_FORMAT=line ./run -a do_spl_spawn_share` and puts its line in
`GC_SUMMARY`, flagging a class whose verdict is `UNDER` or `OVER` and the lanes
with no class (placed outside the queue: an unrecorded placement or bypass).
It never re-classes or places anything itself.

<a id="ws-doc-a34c27ea-d28a-4687-a1c5-3cc0e2dac185"></a>
## 3. Operations

<a id="ws-doc-720c7566-1d5a-4e5b-9e71-5622bac678e1"></a>
### 3.1 Install the cron row on a box

From the box's main checkout, as the box user:

```bash
cd csi-spl-orc && BOX_CRONS_ONLY=gc DRY_RUN=0 ./run -a do_install_box_crons
```

<a id="ws-doc-5bfb03c9-a247-4af8-8a1a-d08f23edb71f"></a>
### 3.2 See the last pass

```bash
cd csi-spl-orc && GC_CMD=status ./run -a do_spl_gc
```

<a id="ws-doc-5fb7c227-21e7-493c-8852-ecffe83b8247"></a>
### 3.3 Change a slot's vendor

Edit `csi-spl-orc/cnf/gc/gc.conf` and land it; the next slot reads it.
