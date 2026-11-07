# 146: Reliability round - 12 permanent checks that keep the boxes and the hub up

Epic SPL-2364.
Status: Implemented (all 12 checks landed on master: dadff1744, b9d73435a, 377c36205, a3024b410, 27f6c86c7, 81840b7e4, 1da66fe29, e4fb9bc6b, f63906046, 6752317a0, 5947f748a, 9329c596e).

## Scope

The reliability round establishes 12 permanent software and monitoring solutions for system continuity across the fleet layers: Operating System (Debian 13), Networking & Certificates, Agent Fleet & Execution Harness, Docker & CI Runners, Cloud Estate (Cloud Run and Cloud SQL), and Meta-Monitoring. Every check runs in `csi-spl-utl` as a named action and test, executable both manually and via host cron with non-zero measured thresholds, report-first or advisory defaults (`DRY_RUN=1` where applicable), and zero destructive automated interventions.

## Requirements

The requirements, measured baseline facts across fleet layers, inventory of existing detectors, row specifications, and owner approval records are defined in the signed plan document: [reliability-round-plan.md](../../doc/md/reliability-round-plan.md). The plan document is the requirement by pointer; this specification anchors the round and its 12 execution tasks.

## Where the automatic notices go (SPL-4700)

Owner HUM-10, t1 3a18a0b5 msg 6a43f1a2 (2026-11-03): "the failover flips and
automated msgs should go to the alerts channel and not t othe ops channel".

| poster | cnf key | channel |
|---|---|---|
| `do_spl_fleet_notice`: orchestrator failover, ROTATION FAILED, recovered, a hung watchdog | `env.fleet_notices.channel` | `alerts` |
| `do_spl_deploy_lag_alarm`, `do_spl_deploy_failure_post` / `_poll` (`spl-ops-alarm-cron.sh`) | `env.ops_alarms.channel` | `alerts` |
| NO-LOCAL-AGENT, box benched / back, weekly limit (`spl_fleet_alert_post`) | none, already `alerts` | `alerts` |
| `do_spl_fleet_stopped_alarm` (`fleet-stopped-alarm-cron.sh`), section below | `env.ops_alarms.channel` | `alerts` |
| weekly full scan, a missed week's blocker (`weekly-full-scan-cron.sh`) | `env.ops_alarms.channel` | `alerts` |
| weekly full scan summary (`weekly-full-scan-cron.sh`) | `--channel` | `spool-hub-ops`, kept: a weekly report, not an alarm |

Both keys live in `csi-spl-cnf/csi-spl/all.env.yaml`. #alerts keeps a post 7
days (`SPOOL_HUB_RETENTION_ALERTS`), other channels 30. Test:
`csi-spl-orc/src/bash/tests/ops-alarm-channel.tst.sh`.

## An alarm when the fleet has stopped with work waiting (SPL-4964)

[What broke on 2026-11-06](what-broke-20261106/consensus.md), section 7 item 1:
the placer held every new lane from 09:05Z and nothing said the whole fleet had
stopped. `do_spl_fleet_stopped_alarm` (box-crons row `fleet-stopped-alarm`, every
5 min) posts ONE blocker in #alerts, naming the hold, when all three are true:

- the spawn queue is above 0;
- every box with a fresh sample (15 min) is under
  `env.ops_alarms.fleet_stopped.load_max_pct` of its cores, by load5 / cpus. No
  fresh sample on any box is no verdict, never "all idle";
- nothing landed for `env.ops_alarms.fleet_stopped.quiet_min`. Landed is the
  later of the head's committer time and when this box first saw that head.

**One post per episode.** An episode ends only when master moves or the queue
empties, never when the load moves. Only the orch holder's machine posts; a new
holder reads #alerts first, so a move of the role does not post again.

**Why 40% and not the consensus's 25%** (dispatch holder c-003, msg 11e3b858).
The consensus asks for 25% and for a fire by about 11:30Z; on the real samples
those cannot both hold. Replaying `box_stats` from 2026-11-03T03:50Z (n=2106
samples, 16 cores on both boxes, committer dates as the landing, the queue
assumed above 0):

| each box under, load5 | first fire on 11-06 | other fires |
|---|---|---|
| 25% | never, 0 of 108 ticks 09:30-18:30Z | 11-03 05:40, 07:40 |
| 30% | 12:25Z | 11-03 05:40, 07:30 |
| 40% | 11:35Z | 11-03 05:30, 07:10 |
| 50% | 10:50Z | 11-03 04:45, 05:20, 07:05 |
| 75% | 10:40Z | those of 50%, moved, and 11-04 23:40 |

The other fires at 40% fall inside the claude hold dated 11-02 22Z to 11-03 08Z.
Limit: 4 days is thin evidence against false alarms; a longer read
(`SINCE=7d`, 14d) failed with `hub unreachable: socket closed`, cause not read.

An alarm also files its prio 1 issue and one read-only lane, like any #alerts
post (next section). Test, with the replay of 11-06 and its red control:
`csi-spl-orc/src/bash/tests/fleet-stopped-alarm.tst.sh`.

## An alert files its issue and one lane (SPL-4828)

Owner HUM-10, t1 6c9aa54b msg 84726fdc (2026-11-04): "BUILD — Yes, build it
as proposed", on the c-002 proposal f520f8bb (from the SPL-4622 triage).

`cd csi-spl-orc && ./run -a do_spl_alert_issue_tick` (code, no model) reads,
since its last tick, the #alerts topics, `do_gcp_list_alert_incidents` and
the disk notes (task `disk-headroom`), and folds them by fingerprint
(`csi-spl-orc/src/bash/scripts/alert-issue-fold.py`):

- **Fingerprint**: the text with digits, times, ids, the severity word and
  any `(bracketed detail)` stripped, plus the box; a disk note is box +
  mount + blocks or inodes, a GCP incident env + policy. The WARN and the
  CRITICAL of one mount are one fingerprint. A filed issue's title ends
  `[fp:<8 hex>]`. A recovery notice ("back after", "recovered", "cleared",
  `ALERT_ISSUE_IGNORE_RX`) is not an alert and files nothing.
- **Open issue**: one comment with the count; no lane.
- **No issue**: filed prio 1 (`todo`, epic SPL-2364, this spec), then ONE
  read-only investigator lane: `do_spl_ask_put` + `do_spl_spawn_enqueue
  SPAWN_CLASS=bug SPAWN_PLACE=claude:alert-<hash>-<time>`, with a generated
  brief in `<spool root>/dispatch/briefs/` (no edits, no prd writes, no
  installs; it names the alert text, source, fingerprint and issue). The
  brief names the alert issue as `Origin-Issue:`, never `Issue:`, so the
  placer files the lane its own issue and the alert issue stays open for the
  fix lane; the ask topic is the #alerts topic uuid (else
  `ALERT_ISSUE_DISCUSSION`), so the lane row gets its discussion link.
- **Done issue**: reopened (`todo`, a comment, a lane) only for an alert newer
  than the fix: the committer time of the newest origin/master commit that
  closes the key by the closer's rule (`issue-close-landed.py --keys`). An
  older alert is held.
- **Caps**: one lane per fingerprint per 24 h (`ALERT_ISSUE_LANE_GAP_S`), 3
  lanes in any 24 h fleet-wide (`ALERT_ISSUE_LANES_PER_DAY`); over a cap the
  issue is still filed or reopened, with no lane. The 11-02 replay (8 alerts,
  4 fingerprints) therefore files 4 issues and places 3 lanes; the 4th
  fingerprint gets its issue only (dispatch holder ruling, SPL-4828).
- **Who runs it**: `do_spl_asks_tick` starts it on the machine whose agent
  holds the orch role (`dispatch/lease.orch`) only, so the fleet files once;
  at most one tick per `ALERT_ISSUE_EVERY_S` (300 s). Its log:
  `<spool root>/dispatch/alert-issue/tick.out`. The role can move during
  the reads (minutes: GCP 180 s, each hub read 120 s), so a live tick reads
  `lease.orch` again after them and before every issue it files,
  reopens or comments on: moved, it writes nothing more, and the alerts of
  the writes it skipped stay unseen for the new holder. This narrows the
  race, it does not close it: the re-check reads this box's mirror of the
  hub lease (`lease.orch`), which the lease loop refreshes once every
  `LEASE_PERIOD` (60 s). So a move can go unseen here for one
  `LEASE_PERIOD` while this box's lease loop reaches the hub, up to
  `LEASE_STALE` (180 s) while its hub calls fail, and with no bound if the
  loop itself is stalled (the re-check does not read the mirror's epoch),
  plus the write in flight; only a hub-side lock would close it.
- **Dry run by default**: it prints one `PLAN` line per fingerprint and files
  nothing. Live needs `ALERT_ISSUE_DRY_RUN=0` and `ALERT_ISSUE_DISCUSSION=<topic
  uuid>` (the discussion a disk or GCP alert's issue links) in
  `dispatch/lease.conf`, set on the dispatch holder's go.
- **Off switch**: `ALERT_ISSUE=0` in `dispatch/lease.conf` (or the env).
- **State**: one file, `jq . /var/spool-hub/dispatch/alert-issue/state.json`
  (a dry run keeps `state.dry.json`): per fingerprint its key, count, first
  and last alert, last lane; the lanes of the last 24 h; the alert refs seen
  (7 days). A holder that moves to another box starts with an empty or stale
  file there (last tick older than 2 x `ALERT_ISSUE_EVERY_S`): it reads back
  `ALERT_ISSUE_FIRST_SINCE_S` at most, and the hub's prio 1 `[fp:<hash>]`
  issues of every status, so an open one gets the comment, a done one the
  done path, and the lanes they record (`alert-lane-at: <epoch>` in the
  description of an issue filed or reopened with a lane) count toward both
  caps, fleet-wide. A failed write leaves its alerts unseen and the
  read window unmoved, so the next tick retries. A re-fire posted as a
  reply in an #alerts topic already seen (within the 7 days of its ref) is
  not counted again; a reply after those 7 days counts once under the old
  fingerprint, within both caps.
- **Limit**: it sees only the alerts that get posted (the all-boxes-silent
  gap is SPL-4632).

Test: `csi-spl-orc/src/bash/tests/alert-issue-tick.tst.sh`.

## A review seat under a capacity hold (SPL-4966)

On 11-06 three R7 seats waited 320-406 min under the claude weekly hold (n=3)
and their authors sat on written work (`what-broke-20261106/consensus.md`
section 3.2, section 7 item 3). All three asks are in the bypass log:
`grep -E 'SPL-49(09|11|12)' <asks dir>/bypass.tsv` -> `41de5270`, `d68a50cf`,
`5ef12b51`. The rule, in `do_spl_spawn_place` and `do_spl_box_pick`:

- **Who**: a logged review seat: placement slug ending in `-reviewer`, its ask
  in the local bypass log on the standing review-seat GO
  (`spl_spawn_place_seats`). A row with neither is an ordinary lane. The slug
  alone earns that log row, so the pass also needs the brief's first heading to
  say review, reviewer or R7 (`spl_spawn_place_seat_pass`): all 984 `*-reviewer.md`
  briefs on sat do (11-07). A logged seat without it keeps its place in the line
  and its alarm, and launches on `weekly_max_pct`. This stops a wrong name, not a
  forged heading: nothing proves a seat only reads.
- **The pass, and its limit**: such a seat holds on the vendor's weekly usage
  only at cnf `env.box.quota.review_seat_max_pct` (95), not at `weekly_max_pct`
  (90). Why 95: usage rose 1.4 points an hour on 11-06 (81 at 02:25, 97 at 13:55,
  n=1 day, the weekly-limit-alert cron log), so 95 leaves about 3.5 h. The three
  asks of 11-06 were raised at 09:26, 10:12 and 11:00, while the reading was 90 (it
  stood at 90 from 09:00 to 12:40): they would have passed. Under the kept 97 from
  13:58 they would not; the alarm covers that case.
- **The mark is no guarantee**: after a reading of 90 or more the next one came
  0.83, 1.25, 2.75, 3.67, 4.92 and 5.92 h later (sat, 10-27..11-07, n=6), so 3.5 h
  fits 3 of the 6, and a seat can reach the limit on an old reading. What seats burn
  is not measured.
- **At 100%**: nothing is placed by a pick; a pin (`SPAWN_BOX`) skips the pick, for
  every lane. The code clamps the mark to at most 99 whatever the cnf says, also
  when `weekly_max_pct` is higher (`spl_box_quota_seat_max`), so a seat never starts on a
  login that answers no turn. It stays queued, with the reason in `.place.wait`.
  A seat already running when the limit comes stalls like any lane (the watchdog's
  S2 kind=limit). An unset mark means no pass.
- **What is not passed**: every other hold: the window ceiling, the load mark,
  disk, a cordon, a pin to a full box, agy out of quota. Those protect a real
  limit too.
- **The alarm**: a logged seat 30 min or more in line (`enqueued_at`) that a
  hold stops gets ONE alarm per ask, whatever the hold: a blocker to the dispatch
  lease holder naming the seat and the hold, and a post in #alerts with ask id8,
  minutes and count only. Every human of the tenant reads #alerts (t1 has a
  `biz_customer`), a slug can name a customer, and a hold line can hold the slug, a
  brief path or a box, so neither goes there. The gap between launches is a pace,
  no hold. At most one alarm per 30 min; a seat due meanwhile
  goes in the next. `SPAWN_PLACE_SEAT_ALARM_MIN`, `SPAWN_PLACE_SEAT_ALARM_GAP_MIN`.
- **Limit of the alarm**: it needs the placer's tick, so it runs on the box
  holding the orch role, and the bypass log is local to the box where the seat was
  queued: a seat queued on another box is no logged seat here, neither for the
  pass nor the alarm. A launcher hold is known only after one launch try, so the
  alarm can come one tick after 30 min.

Test: `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh` (case 40),
`spl-box-pick.tst.sh` (case 16d), `spawn-agents/tests/test-spawn-load-target.sh`
(case 6c).
