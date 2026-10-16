# A push whose lane is gone (SPL-2264)

Owner HUM-10, t1 thread b61851fb (analysis msg 8b56951c, row D1 ticked in
poll answer c5c9687b): a lane's push refused after the lane closed went
unseen for 2.5 h. Plain coded checks, no AI in the loop.

## 1. The event

m-595 started `do_spl_push_master` at 01:27:48Z, closed itself at 01:29:05Z,
and its push was refused by the pre-push gate at 01:34:50Z. Its push log
(`<spool root>/.retired/m-595.<ts>/lifetime/push-master/log`) ends with
`END REFUSED push of e9fbcc642...`, but its status file still read
`RUNNING since=01:27:48Z`.

## 2. The verdict follows the moved dir

A lane that closes has its whole spool dir moved to
`<spool root>/.retired/<id>.<ts>/` (agent-id-retire). The push worker wrote
its verdict to the old path, which was gone, so the status stayed `RUNNING`.

The worker in `csi-spl-orc/src/bash/run/spl-push-master.func.sh` now holds
the state dir open on fd 8 and, before each write, re-points at the dir's
current path through `/proc/<pid>/fd/8` (`_spl_push_master_follow`). The log
says `the state dir moved: <old> -> <new>` when it happens.

Test: `csi-spl-orc/src/bash/tests/spl-push-master.tst.sh` case 9 (the hook
moves the state dir during a red and a green push; the moved dir reads
`REFUSED` / `PUSHED`). Red control: the same case on the code before the fix
reads `DIED` (the status stayed `RUNNING`).

## 3. The check: one blocker per orphaned push

`cd csi-spl-orc && ./run -a do_spl_push_orphan_check` (DRY_RUN=1 by default:
PLAN lines only; `DRY_RUN=0` sends), in
`csi-spl-orc/src/bash/run/spl-push-orphan-check.func.sh`. The box cron row
`push-orphan-check` (`csi-spl-orc/cnf/box-crons/box-crons.manifest`, every
minute, `src/bash/scripts/push-orphan-check-cron.sh`, log
`/var/csi/csi-spl/push-orphan-check/cron.log`) runs it with `DRY_RUN=0` on
every box. Install: `./run -a do_install_box_crons` from the shared checkout.

Per box, it reads every push state dir whose log changed in the last
`PUSH_ORPHAN_MAX_AGE_MIN` minutes (default 360): the live ones,
`<spool root>/<id>/lifetime/push-master`, and the retired ones,
`<spool root>/.retired/<id>.<ts>/lifetime/push-master`.

| the push | its agent | alert |
|---|---|---|
| `PUSHED`, or `RUNNING` with `END PUSHED` in its log | any | never |
| `REFUSED` / `GAVE-UP`, or `RUNNING` with that `END` in its log | live (process + pane in the identity map) | no: the lane polls its own verdict |
| the same | retired, or no live pane | ONE blocker |
| `RUNNING`, no `END` line, no worker holds the lock (`DIED`) | retired, or no live pane | ONE blocker |
| `RUNNING`, a worker holds the lock | any | no: still running |

The blocker goes to the dispatch lease holder (`<spool root>/dispatch/lease`)
from the box's orchestrator seat, on the brief's `dispatch-<hex8>` task
(else `dispatch-push-orphan`). It names the agent, the sha, the log's last
line, the brief's topic and task, the issue and the push dir.

Once per push: before sending, it writes the push's key (verdict, sha, the
log's first line, the status timestamp) to `orphan-alerted` in the push
dir. The marker moves with the dir when the lane is retired, and a new push
in the same dir has a new key.

Test: `csi-spl-orc/src/bash/tests/spl-push-orphan-check.tst.sh`. It covers
the m-595 sequence: no alert while the lane is live, one alert once its
pane is gone, none on the next tick, and none after the dir is retired. A
live lane's refusal and a landed push never alert. A dead worker alerts as
`DIED`. Red control: without the marker check, the m-595 sequence alerts on
every tick.
