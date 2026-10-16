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
