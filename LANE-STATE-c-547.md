# c-547 lane state (SPL-1960), written 2026-10-15 for the 08:22Z rotation

Brief: /var/spool-hub/spawn-remote/briefs/88c40db9-4de6-45f8-b1e8-edc8c4e28f54.md (security round 1 prep, tnk rows 2, 3, 10).
Dev guide acked. This file is untracked: delete it before `worktree remove`.

## Done
- Branch review/sec-r1-tnk-box = 22463ea46 (pushed, pre-push all PASS). NOT on master; it lands only in the
  Fri 2026-10-16 15:00Z session after the owner's go.
- Actions: do_spl_sshd_harden, do_spl_box_ports_loopback, do_spl_docker_swarm_leave, do_spl_dormant_user_revoke
  (+ 4 tests, n=67 checks, each with a control) + csi-spl-doc/doc/md/box-hardening-round-1.md.
- Prep file: /var/spool-hub/dispatch/work/security-round/2026-10-16/prep-tnk-box.md (0640): DRY_RUN outputs,
  measurements, the session command table.
- Report sent: c-002@sat (dispatch holder) result msg 1ab7a5e0 on --task dispatch-3d0675ba; note to c-001 e05013d1.

## Next
1. Fri 2026-10-16 after 11:00Z (BEFORE 12:00Z): the sampler (/var/spool-hub/c-547/lifetime/port-peers-sampler.sh <raw> <until epoch>; it stops itself at 11:00Z.
   At 08:08Z a second copy was started while the first (old scratch dir) was still alive; the 08:18Z session stopped
   the scratch copy (pid 2647772) and a 'note' line marks it: samples 08:08Z..08:18Z are doubled, the peer set is not. If `pgrep -f port-peers-sampler.sh`
   is empty, restart it with setsid nohup and add a gap line) writes
   work/security-round/2026-10-16/row3-port-peers.raw. Summarise the 'ct' lines (unique src -> dst:dport, sample
   count, first/last ts), update the 'Who uses the ports' block in prep-tnk-box.md (keep 0640), and send the final
   count to the CURRENT dispatch lease holder on --task dispatch-3d0675ba. The old session's cron reminder died with it.
   Count at 07:55Z: 0 peers on :5432/:3333; the only connection seen is 127.0.0.1 -> 127.0.0.1:2377 (dockerd itself).
2. In the session, on the owner's go: rebase onto origin/master, ADD the six release-note trailers
   (Lay-What/How/Why, Tech-What/How/Why; csi-spl-doc/doc/help/release-notes.md) to the commit message,
   land via do_spl_push_master, then run the DRY_RUN=0 commands of the prep file's table in its order.
3. Open point for the owner: the :3333 (csi-web WUI) recreate is refused (12 Makefile path vars); options are in the prep file.
4. /exit-clean only on an ACCEPTED message; never on your own done.

## Dispatch verdicts
- 2026-10-15 c-002@sat msg 4df1227f: interim GOOD on result 1ab7a5e0, NOT an exit. :3333 stays OPEN for the session; do not touch csi-web. Trailers go in the landing rebase. Refresh the peer counts before 12:00Z.
- 2026-10-15T09:1xZ session: nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 1811883 alive (lifetime copy only).
- 2026-10-15T10:1xZ session (pre-10:19Z rotation): nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box, nothing unpushed; sampler pid 1811883 alive; inbox empty. Next = Next step 1 on Fri 11:00Z.
- 2026-10-15T10:12Z restore (tmux restart): sampler had died after 10:09:47Z; gap line added, restarted as pid 50997 (setsid). Not landed on master: brief says land only in Fri 16 15:00Z session on owner go, so no rebase/push/teardown now.
- 2026-10-15T11:0xZ session (pre-11:12Z rotation): nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; c-198 SPL-1981 overlap note: no overlap, not answered (as asked).
- 2026-10-15T11:1xZ session (post-11:08Z rotation): acked; nothing new; HEAD 22463ea46; sampler pid 50997 alive; inbox empty.
- 2026-10-15T12:0xZ session (pre-12:08Z rotation, c-001 note 342b94c7): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-15T12:1xZ session (post-12:09Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-15T13:0xZ session (pre-13:09Z rotation, c-001 note c8fe7c67): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-15T13:1xZ session (post-13:10Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-15T14:0xZ session (pre-14:10Z rotation, c-001 note 205d43a0): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-15T14:1xZ session (post-14:11Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-15T15:0xZ session (pre-15:11Z rotation, c-001 note 1c451895): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-15T15:1xZ session (post-15:12Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-15T16:0xZ session (pre-16:12Z rotation, c-001 note fb682dfb): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-15T16:1xZ session (post-16:13Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-15T17:0xZ session (pre-17:13Z rotation, c-001 note b393714f): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-15T17:1xZ session (post-17:14Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-15T18:0xZ session (pre-18:14Z rotation, c-001 note ebe088f4): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-15T18:1xZ session (post-18:15Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-15T19:0xZ session (pre-19:15Z rotation, c-001 note 8f8ea051): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-15T19:1xZ session (post-19:16Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-15T20:0xZ session (pre-20:16Z rotation, c-001 note f42a3996): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; overlap notes c-231 (SPL-2040) and c-232 (SPL-2041): no overlap, not answered (as asked); inbox empty.
- 2026-10-15T21:5xZ session (restored after tmux restart; pre-22:02Z rotation, c-001 note 5948ff25): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go; kick.txt said land, brief overrides); sampler pid 50997 alive; orch lease moved c-001@sat -> c-001@tnk 21:02:57Z (sat + both c-002 on weekly limit); inbox empty.
- 2026-10-15T21:5xZ session (post-21:58Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-15T22:5xZ session (pre-22:58Z rotation, c-001 note ca1b2321): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-15T22:5xZ session (post-22:59Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-15T23:5xZ session (pre-23:59Z rotation, c-001 note 0002e378): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-16T00:0xZ session (post-00:00Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-16T00:5xZ session (pre-01:00Z rotation, c-001 note f30b283d): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-16T01:0xZ session (post-01:01Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-16T01:5xZ session (pre-02:01Z rotation, c-001 note 080ab3ca): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-16T02:0xZ session (post-02:02Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-16T02:5xZ session (pre-03:02Z rotation, c-001 note 1276a45b): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-16T03:0xZ session (post-03:03Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-16T03:5xZ session (pre-04:03Z rotation, c-001 note 04be356d): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-16T04:0xZ session (post-04:04Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-16T05:0xZ session (pre-05:04Z rotation, c-001 note c264ed6d): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-16T05:0xZ session (post-05:05Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-16T06:0xZ session (pre-06:05Z rotation, c-001 note cddcd2a6): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-16T06:0xZ session (post-06:06Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-16T07:0xZ session (pre-07:06Z rotation, c-001 note 36e473f1): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-16T07:0xZ session (post-07:07Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-16T07:5xZ session (pre-08:07Z rotation, c-001 note 3127095c): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-16T08:0xZ session (post-08:08Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-16T09:0xZ session (pre-09:08Z rotation, c-001 note b320f6cb): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-16T09:1xZ session (post-09:09Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive; inbox empty.
- 2026-10-16T10:0xZ session (pre-10:09Z rotation, c-001 note 59d10d3a): nothing unpushed (HEAD 22463ea46 = origin/review/sec-r1-tnk-box; not for master before Fri 15:00Z owner go); sampler pid 50997 alive; inbox empty.
- 2026-10-16T10:1xZ session (post-10:10Z rotation): acked; nothing new; HEAD 22463ea46 = origin/review/sec-r1-tnk-box; sampler pid 50997 alive (stops 11:00Z); inbox empty.
- 2026-10-16T10:4xZ: c-001@sat note 33f1470b (tnk fenced 10:21:38Z-10:42:09Z, 'your 10:21Z wip push failed'): this session started no push (PUSH_CMD=status = NONE); nothing to push, branch stays off master until the Fri 15:00Z owner go; sampler pid 50997 survived the fence. No reply (none needed).
