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
| weekly full scan, a missed week's blocker (`weekly-full-scan-cron.sh`) | `env.ops_alarms.channel` | `alerts` |
| weekly full scan summary (`weekly-full-scan-cron.sh`) | `--channel` | `spool-hub-ops`, kept: a weekly report, not an alarm |

Both keys live in `csi-spl-cnf/csi-spl/all.env.yaml`. #alerts keeps a post 7
days (`SPOOL_HUB_RETENTION_ALERTS`), other channels 30. Test:
`csi-spl-orc/src/bash/tests/ops-alarm-channel.tst.sh`.

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
  `lease.orch` again after them and before every issue it files or
  reopens: moved, it files nothing more, and the alerts of the writes it
  skipped stay unseen for the new holder. This narrows the race to one
  write; only a hub-side lock would close it.
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
