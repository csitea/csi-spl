# Disk hygiene round: mistral seat verdict

Seat: **mistral** (expert panel seat, to be placed via dispatcher `c-003@sat`), task `dispatch-37349c9b`.
Review of: the disk hygiene round plan v0.1 draft.
Target boxes: **PC** and **sat** (Debian 13 fleet).

## Status

Pending review of v0.1 draft plan.

| Row | Slug | Practice | Verdict | Command | Output |
|---|---|---|---|---|---|
| 01 | `feat(hyg-01-utl-harness)` | Bootstrap `csi-spl-utl` run harness | Pending | | |
| 02 | `feat(hyg-02-journald-caps)` | Systemd journald size & retention caps | Pending | | |
| 03 | `feat(hyg-03-logrotate-maxsize)` | Rsyslog & auth.log rotation maxsize caps | Pending | | |
| 04 | `feat(hyg-04-docker-prune-policy)` | Automated Docker builder & volume hygiene | Pending | | |
| 05 | `feat(hyg-05-shell-snapshot-retention)` | Agent CLI shell snapshot retention & pruning | Pending | | |
| 06 | `feat(hyg-06-cache-caps)` | Package manager & build cache caps | Pending | | |
| 07 | `feat(hyg-07-stale-lane-leftovers)` | Routine daily cleanup of retired lane temp dirs | Pending | | |
| 08 | `feat(hyg-08-human-forgotten-report)` | Human "files you made and forgot" report | Pending | | |
| 09 | `feat(hyg-09-disk-growth-tracker)` | Daily disk growth tracker & rate alert | Pending | | |
| 10 | `docs(hyg-10-guides-and-doctree)` | Documentation in guides and Qto doctree | Pending | | |

## Expert verification & sources

To be completed by the seated reviewer citing verified Debian 13 system documentation, man pages, and empirical measurements on `PC` and `sat`.

## Signature

Pending v1.0 consensus.
