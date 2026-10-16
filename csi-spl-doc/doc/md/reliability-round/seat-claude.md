# Reliability round: claude seat verdict

Seat: **claude** (expert panel seat, to be placed via dispatcher `c-002@sat`), task `dispatch-06ebfdd6`.
Review of: the reliability round plan v0.1 draft.
Target boxes: **PC**, **sat**, and **hub** (Debian 13 fleet & GCP Cloud Run / Cloud SQL).

## Status

Pending review of v0.1 draft plan.

| Row | Slug | Practice | Verdict | Command | Output |
|---|---|---|---|---|---|
| 01 | `feat(rel-01-systemd-unit-health)` | Systemd service failure & crash detector | Pending | | |
| 02 | `feat(rel-02-reboot-required-check)` | Kernel reboot-required & security update advisory | Pending | | |
| 03 | `feat(rel-03-tls-cert-expiry-check)` | Public HTTPS certificate expiry monitor | Pending | | |
| 04 | `feat(rel-04-external-api-health-check)` | Outbound model & external API health probe | Pending | | |
| 05 | `feat(rel-05-tmux-server-health-guard)` | Tmux server socket liveness guard | Pending | | |
| 06 | `feat(rel-06-orphan-process-reaper)` | Orphaned process & zombie task reaper | Pending | | |
| 07 | `feat(rel-07-docker-test-container-prune)` | Stale ephemeral test container pruner | Pending | | |
| 08 | `feat(rel-08-gh-runner-health-check)` | GitHub Actions runner health & job hang detector | Pending | | |
| 09 | `feat(rel-09-hub-synthetic-slo-monitor)` | Cloud Run hub synthetic probe & latency SLO monitor | Pending | | |
| 10 | `feat(rel-10-cloud-sql-backup-verify)` | Cloud SQL daily backup verification | Pending | | |
| 11 | `feat(rel-11-cron-heartbeat-snitch)` | Cron dead-man's snitch & heartbeat age monitor | Pending | | |
| 12 | `feat(rel-12-box-beat-telemetry)` | Box beat & watchdog fence early-warning telemetry | Pending | | |

## Expert verification & sources

To be completed by the seated reviewer citing verified Debian 13 system documentation, man pages, and empirical measurements on `PC`, `sat`, and the cloud hub.

## Signature

Pending v1.0 consensus.
