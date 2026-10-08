# Drill: the reboot path (spec 102 10.1, T014), 2026-10-07

The lane wrote the checklist; the orchestrator runs it on one box and fills in
the results. The owner's go is needed for the reboot itself (step 3.1) only.

## 1. What the drill proves

The box's own watchdog brings back, after a reboot, every agent that ran on
the box when it went down: cause `reboot`, through `do_spl_agent_restart`,
a new session seeded from the handoff (never a `--resume`), once per agent
per boot.

How it works (`csi-spl-orc/src/bash/run/spl-watchdog.func.sh`, `spl_wd_boot*`):

| step | what |
|---|---|
| detect | `/proc/stat` `btime` differs from `<spool root>/dispatch/wd/boot.seen` (60 s either way) |
| witness | `dispatch/wd/boot.<btime>.seen`: every `dispatch/wd.<id>` verdict written before the boot, taken on the first tick after it |
| wait | `WD_START_GRACE` (180 s) after the boot and after the watchdog's resume |
| pick | an open `registry.tsv` row; not done (workdir gone, or `lifetime/done` newer than the session); not held out; `running_box` this box; its verdict at most `WD_BOOT_SEEN` (900 s) before the box's last verdict; no window and no process yet |
| start | `do_spl_agent_restart ID=<id> CAUSE=reboot` detached (`WD_BOOT_ID` lists the windowless id for its gate); `boot.d/<id>` = the btime |
| done | `boot.seen` = the btime once no id waits for its judge lock |

### 1.1 What it does NOT prove without T017 and T018

- **No fence (T017).** The boot branch calls `spl_wd_box_fenced` only when the
  function exists. Until T017 lands it never does: a box that cannot reach the
  hub still restarts its agents after a boot.
- **`running_box` is local (T018).** Until T018's `spl_lane_running_box`
  exists, the box reads `<spool root>/<id>/lifetime/running_box`, else the
  `box` of `lifetime/session.json`, else this box. Nothing writes
  `running_box` yet, so the drill exercises the "this box" case only; the
  "guest elsewhere" case is proven by the test (`wd-reboot.tst.sh` 1 and 2),
  not live.
- **The first run of the code is a baseline.** With no `boot.seen` the boot is
  handled only when it is younger than `WD_BOOT_RECENT` (1800 s) and a verdict
  predates it. A watchdog that first loads this code long after a boot records
  the baseline and starts nothing.

## 2. Before the reboot

### 2.1 The desk-cron checkout is on the T014 sha

One action does 2.1 and 2.3 and asks every live lane to push its WIP: `cd csi-spl-orc && DRY_RUN=0 BOX_RESTART_FROM=<your id> ./run -a do_spl_box_restart_prepare` (dry run without `DRY_RUN=0`).

The watchdog instances run from `/opt/csi/csi-spl-desk-cron`. Its `@reboot`
starter (`csi-spl:wd-inst-start-boot`) does not fetch, so pull it first.

```bash
git -C /opt/csi/csi-spl-desk-cron fetch -q origin master && git -C /opt/csi/csi-spl-desk-cron checkout -q --detach origin/master && git -C /opt/csi/csi-spl-desk-cron log --oneline -1
```

Record: sha `____`. It must contain the T014 commit (`grep -c spl_wd_boot_pass /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/run/spl-watchdog.func.sh` -> at least 2).

### 2.2 The old boot path: decide

The `@reboot` line `csi-spl:agent-boot-restore` (the `--resume` identity
restore) is still installed. With it in place, both paths run after the
reboot: the old one usually brings the agents back first, and the watchdog
then logs `left alone: it runs` for them. That is safe (the id lock and the
"it runs" check keep it to one session) but it does not prove the new path.

- To prove the new path, take the line out before the reboot (reversible):
  `BOOT_CRON_ACTION=remove DRY_RUN=0 ./run -a do_spl_agent_boot_restore_install_cron`;
  if the drill fails, `DRY_RUN=0 ./run -a do_spl_agent_boot_restore_install_cron`
  puts it back.
- The retirement for good (`BOOT_CRON_ACTION=retire`, step 5) runs only after
  the drill passed.

Record: old line `kept` / `removed` `____`.

### 2.3 Snapshot the agents

Done by `do_spl_box_restart_prepare` (2.1): its snapshot is `<spool root>/dispatch/box-restart/<utc>.before`.

```bash
bash /opt/csi/csi-spl/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh 2>/dev/null | head -60; awk '/^btime/' /proc/stat
```

Record: the agents running now (ids, n) `____`; btime before `____`.

The watchdog's own view of who runs (these are the ids it will restart):

```bash
now=$(date +%s); for f in /var/spool-hub/dispatch/wd.[acgq]-*; do m=$(stat -c %Y "$f"); (( now - m < 300 )) && echo "${f##*/wd.}"; done | sort | paste -sd' ' -
```

Record: `____`.

### 2.4 The watchdog runs the new code

The instances loaded their code when they started. Either the reboot restarts
them from desk-cron (enough), or check a dry tick of the new code first:

```bash
cd /opt/csi/csi-spl-desk-cron/csi-spl-orc && WD_TICKS=1 WD_STATE_DIR=/var/tmp/wd-drill-boot ./run -a do_spl_watchdog | grep -c .
```

## 3. The reboot

### 3.1 Reboot (owner's go)

Record the UTC time of the command: `____`.

## 4. After the reboot

### 4.1 The watchdogs are up

```bash
ls -l /var/spool-hub/dispatch/wd/run.*.pid; cat /var/spool-hub/dispatch/wd/heartbeat.*.json | jq -c '{instance, ts, git_sha}'
```

Expect: 3 instances, `git_sha` = the sha of 2.1.

### 4.2 The boot branch ran

```bash
grep -E ' BOOT ' /var/spool-hub/dispatch/wd.log | tail -40
```

Expect, about 3..4 min after the boot: one `left alone: <why>` line per open
row that did not run, one `<id>: restart started (cause reboot)` per agent of
2.3, then `BOOT <btime> done: <n> restart(s) started (cause reboot)`.

### 4.3 The restarts

```bash
grep -E 'cause=reboot|-rs-' /var/spool-hub/dispatch/rotate.log | tail -60
```

Expect per agent: `RS-GATE OK ... cause=reboot`, `RS-SPAWN OK`, `DONE OK`; and
one `REBORN <id>@<box> #<n> cause=reboot` note to the orchestrator each.

### 4.4 No --resume, one session each

After the boot, `cd csi-spl-orc && ./run -a do_spl_box_restart_check` compares 4.2 and 4.4 against that snapshot (exit 1: an id missing or doubled).

```bash
ps -eo pid,etimes,args | awk '$3 ~ /(^|\/)claude$/' | grep -c -- '--resume'
```

Expect 0 when the old line was removed (2.2). And per id one process:

```bash
for i in $(ls /var/spool-hub/dispatch/wd/boot.d); do echo "$i $(sudo grep -l "SPOOL_AGENT_ID=$i" /proc/[0-9]*/environ 2>/dev/null | wc -l)"; done
```

### 4.5 Once

Wait two more ticks (1 min), then:

```bash
grep -c 'restart started (cause reboot)' /var/spool-hub/dispatch/wd.log; cat /var/spool-hub/dispatch/wd/boot.seen; awk '/^btime/' /proc/stat
```

Expect: the count unchanged after the wait; `boot.seen` = the new btime.

## 5. Results (the orchestrator fills these in)

| field | value |
|---|---|
| box | |
| desk-cron sha | |
| old boot line | kept / removed |
| reboot command (UTC) | |
| btime after | |
| agents running before (n, ids) | |
| restarted by the watchdog (n, ids) | |
| left alone (id: why) | |
| first `RS-SPAWN OK` after the boot (s) | |
| last `DONE OK` after the boot (s) | |
| `--resume` processes after | |
| second restart of any id | yes / no |
| verdict | pass / fail |

## 6. After a pass: retire the old boot path

Only after the drill passed (spec 102 10.1, C18):

```bash
cd /opt/csi/csi-spl-desk-cron/csi-spl-orc && BOOT_CRON_ACTION=retire DRY_RUN=0 ./run -a do_spl_agent_boot_restore_install_cron
```

```bash
cd /opt/csi/csi-spl-desk-cron/csi-spl-orc && BOOT_CRON_ACTION=check ./run -a do_spl_agent_boot_restore_install_cron
```

Expect `OK the boot restore is retired`. From then on a re-provision's
`install` skips the line (`BOOT_CRON_FORCE=1` installs it anyway); the
`do_spl_agent_boot_restore` and identity restore scripts stay as manual tools.
