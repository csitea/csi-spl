# Disk hygiene round: agy seat proposal (a-612@PC)

Seat: **a-612@PC** (agy), editor seat, task `dispatch-37349c9b`, issue SPL-2111.
Plan: the disk hygiene round plan v1.1 consensus.
Target boxes: **PC** and **sat** (Debian 13 fleet).

## 1. Measured facts & context (fleet baseline)

Empirically measured on `PC` and `sat` (read-only baseline probes, 2026-10-16):

### Box `PC` (workhorse host)
- **Root filesystem (`/`):** `/dev/nvme0n1p2` 889 GB total, 572 GB used, 273 GB free (**68% used**, 12.0M inodes used of 59.2M, 21%).
- **Temporary directory (`/tmp` tmpfs):** 32 GB total, 5.2 GB used, 26 GB free (17% used).
- **Persistent temporary storage (`/var/tmp`):** **33 GB** used across dozens of retired agent directories (`/var/tmp/claude` 9.5 GB, `/var/tmp/chrome-gmail-*` 4.1 GB, `/var/tmp/gocache-*` 1.9 GB, retired lane leftovers 400M–950M each).
- **System logs (`/var/log`):** 683 MB used, dominated by `/var/log/journal` at **633 MB**. Default journald calculated cap is 4 GB (`man journald.conf`).
- **Docker storage (`docker system df`):**
  - Build Cache: 1026 entries, **108.2 GB total, 99.06 GB reclaimable**.
  - Local Volumes: 122 entries, **50.64 GB total, 46.65 GB reclaimable (92%)**.
  - Images: 22 entries, **117.3 GB total, 3.98 GB reclaimable (3%)**.
  - Containers: 19 entries, 2.52 GB total, 25.24 MB reclaimable.
  - Total reclaimable Docker space on `PC`: **~148 GB**.
- **Unbounded fleet cron logs:** `/var/csi/csi-spl/desk-reconcile/cron-prd.out` (162 MB), `/var/csi/csi-spl/box-disk-sweep/box-disk-sweep.log` (29 MB), agent user's `.cache/csi-spl/tmp-scratch-sweep.log` (551 MB), dated `csi-spl-orc.<date>.log` (~25 MB/day).

### Box `sat` (satellite host)
- **Root filesystem (`/`):** `/dev/sda1` 30 GB total, 21 GB used, 7.4 GB free (**74% used**).
- **Data mount (`/mnt/data`):** `/dev/sdb` 98 GB total, 83 GB used, 15 GB free (**85% used**): home 33 GB, docker 31 GB, gh-runner 8 GB. Docker root is `/mnt/data/docker` (data mount), not root.
- **Temporary storage (`/tmp` tmpfs):** 32 GB total, 9.7 GB used. `/var/tmp`: 5.1 GB used (441 top-level entries, 92 unchanged > 72h).
- **System logs (`/var/log`):** **850 MB** used (`auth.log` + rotations ~390 MB/day).
- **Docker storage on `sat`:** Local Volumes 9.1 GB (6.0 GB reclaimable across 37 anonymous dangling volumes; 0 named dangling volumes).

## 2. Technical sources (Debian 13 / Linux system standards)

Proposals are grounded in verified Debian 13 (Trixie) man pages, system documentation, and specifications:
- `journald.conf(5)`, `systemd-journald(8)`: `SystemMaxUse=500M`, `SystemMaxFileSize=100M`.
- `logrotate(8)`, `logrotate.conf(5)`, `systemd.timer(5)`: `copytruncate`, `maxsize`, hourly timer, `su`.
- `docker-volume-prune(1)`, `docker-builder-prune(1)`: anonymous volume prune, builder cache fixed cap.
- `tmpfiles.d(5)`, `systemd-tmpfiles(8)`: declarative 14d age override for `/var/tmp` preserving `/tmp` 10d rule.
- POSIX file utilities: deterministic threshold rules with `find`, `du`, `df`.

## 3. The 10 actions consensus proposal

| # | slug | practice | sites | target | csi-rel action & test |
|---|---|---|---|---|---|
| 01 | `feat(hyg-01-fleet-logrotate)` | Automated rotation for fleet cron logs | `/etc/logrotate.d/csi-spl` | Fleet cron logs capped at 50M; dated logs > 14d removed | `do_fleet_logrotate_install`<br>`csi-spl-utl/src/bash/tests/fleet-logrotate.tst.sh` |
| 02 | `feat(hyg-02-journald-caps)` | Systemd journald size cap drop-in | `/etc/systemd/journald.conf.d/60-disk-hygiene.conf` | Journal <= 500M on both boxes | `do_disk_journal_cap`<br>`csi-spl-utl/src/bash/tests/disk-journal-cap.tst.sh` |
| 03 | `feat(hyg-03-logrotate-maxsize)` | Hourly logrotate timer & auth.log rotation cap | `/etc/systemd/system/logrotate.timer.d/hourly.conf`, `/etc/logrotate.d/rsyslog` | Hourly timer active; no single log > 100M; immediate compression | `do_disk_logrotate_cap`<br>`csi-spl-utl/src/bash/tests/disk-logrotate-cap.tst.sh` |
| 04 | `feat(hyg-04-docker-volume-prune)` | Automated anonymous Docker volume hygiene | `csi-spl-orc/src/bash/scripts/prune-docker-images.sh` | `docker volume prune -f` in sweep; reclaims >45G PC, >6G sat | `do_prune_docker_images`<br>`csi-spl-orc/src/bash/tests/docker-volume-prune.tst.sh` |
| 05 | `feat(hyg-05-tmpfiles-var-tmp-age)` | Systemd-tmpfiles declarative age override for `/var/tmp` | `/etc/tmpfiles.d/tmp.conf` | `q /var/tmp 1777 root root 14d` and `Q /tmp 1777 root root 10d` | `do_tmpfiles_config_install`<br>`csi-spl-utl/src/bash/tests/tmpfiles-config.tst.sh` |
| 06 | `feat(hyg-06-docker-builder-cap)` | Docker builder cache absolute size cap | `prune-docker-images.sh` cnf/cron | Fixed cap `PRUNE_BUILDER_CAP_BYTES=26843545600` on PC; reclaims >70 GB | `do_docker_builder_cap`<br>`csi-spl-orc/src/bash/tests/docker-builder-cap.tst.sh` |
| 07 | `feat(hyg-07-stale-lane-leftovers)` | Routine daily cleanup of retired lane temp dirs at normal level | `csi-spl-orc/src/bash/scripts/box-disk-sweep.sh` | Unskip `vartmp` in normal sweep (72h age); Worktree Safety Invariant | `do_vartmp_sweep_normal`<br>`csi-spl-orc/src/bash/tests/box-disk-sweep.tst.sh` |
| 08 | `feat(hyg-08-human-forgotten-report)` | Human "files you made and forgot" report & tick deletion | `csi-spl-utl` actions, WUI poll | Report generated; 0 deletions without explicit human poll tick | `do_human_forgotten_report`<br>`csi-spl-utl/src/bash/tests/human-forgotten-report.tst.sh` |
| 09 | `feat(hyg-09-disk-growth-tracker)` | Daily disk growth tracker & mount rate alert | `csi-spl-utl` action, TSV | Daily samples (incl. `.gz`); rate alert on > 5% 24h mount spike; latch | `do_disk_growth_track`<br>`csi-spl-utl/src/bash/tests/disk-growth-track.tst.sh` |
| 10 | `docs(hyg-10-guides-and-doctree)` | Documentation in 4 guides via Qto doctree batch | `/var/spool-hub/dispatch/work/disk-hygiene-qto-edits.sh` | All 4 guides updated via Qto script; action verify clean | `do_disk_hygiene_docs_verify`<br>`csi-spl-utl/src/bash/tests/disk-hygiene-docs.tst.sh` |

## 4. Adherence to owner rules

1. **Coded automatic detection (msg 0626b425):** Every rule uses deterministic, fixed thresholds (sizes, ages, counts) with zero LLM/agent judgement in the loop.
2. **Harness in `csi-spl-utl` (msg 177ce9f3):** Actions live in `csi-spl-utl` (or existing sweep scripts in `csi-spl-orc`), callable manually (`./run -a do_<action>`) and from cron.
3. **Four guides documented (msgs 4dde0ae9, a24f4e86):** Row 10 prepares Qto doctree dry-run commands for System, Operations, DevOps, and Developer guides.
4. **Human user safety (msg ae18b94b):** Row 08 scans and reports forgotten files for the human user, with zero automated deletions. Deletion requires an explicit, confirmed tick in a human poll form.
5. **Growth tracking & coordination (msg ec060ebc):** Row 09 logs daily disk consumption samples, alerts on > 5%/day mount spikes, and respects the Worktree Safety Invariant.

## 5. Signature

`signed: a-612@PC on v1.1 consensus`
