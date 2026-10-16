# Disk hygiene round: agy seat proposal (a-612@PC)

Seat: **a-612@PC** (agy), editor seat, task `dispatch-37349c9b`, issue SPL-2111.
Plan: the disk hygiene round plan v0.1 draft.
Target boxes: **PC** and **sat** (Debian 13 fleet).

## 1. Measured facts & context (fleet baseline)

Empirically measured on `PC` and `sat` (read-only baseline probes, 2026-10-16 ~07:2xZ, n=1 each):

### Box `PC` (workhorse host)
- **Root filesystem (`/`):** `/dev/nvme0n1p2` 889 GB total, 572 GB used, 273 GB free (**68% used**, 12.0M inodes used of 59.2M, 21%).
- **Temporary directory (`/tmp` tmpfs):** 32 GB total, 5.2 GB used, 26 GB free (17% used).
- **Persistent temporary storage (`/var/tmp`):** **33 GB** used across dozens of retired agent directories (`/var/tmp/claude` 9.5 GB, `/var/tmp/chrome-gmail-*` 4.1 GB, `/var/tmp/gocache-*` 1.9 GB, retired lane leftovers 400M–950M each).
- **System logs (`/var/log`):** 683 MB used, dominated by `/var/log/journal` at **633 MB**.
- **Systemd Journal configuration:** `/etc/systemd/journald.conf` has `SystemMaxUse`, `SystemKeepFree`, and `SystemMaxFileSize` unconfigured (commented out). Unbounded default caps journal up to 10% of filesystem (~88 GB).
- **Docker storage (`docker system df`):**
  - Build Cache: 994 entries, **103.8 GB total, 94.55 GB reclaimable (91%)**.
  - Local Volumes: 120 entries, **48.17 GB total, 46.65 GB reclaimable (96%)**.
  - Images: 31 entries, **115.5 GB total, 6.68 GB reclaimable (5%)**.
  - containerd snapshotter storage: **115 GB** under `/var/lib/containerd`.
  - Total reclaimable Docker space on `PC`: **~148 GB**.
- **Agent shell snapshots:** Hundreds of `.sh` script snapshots in `~/.claude/shell-snapshots/` created by subshell executions without retention limits.

### Box `sat` (satellite host)
- **Root filesystem (`/`):** `/dev/sda1` 30 GB total, 21 GB used, 7.4 GB free (**74% used**, previously reached 88% / 3.5 GB free before SPL-2053 emergency sweep).
- **Data mount (`/mnt/data`):** `/dev/sdb` 98 GB total, 78 GB used, 21 GB free (80% used).
- **Temporary storage (`/tmp` tmpfs):** 32 GB total, 9.7 GB used, 22 GB free (31% used).
- **Persistent temporary storage (`/var/tmp`):** **5.1 GB** used.
- **System logs (`/var/log`):** **850 MB** used, dominated by `/var/log/journal` at 488 MB and high-velocity authentication logs (`auth.log` 138 MB, plus compressed rotations `auth.log.2.gz` 92 MB and `auth.log.3.gz` 56 MB).
- **Docker storage (`docker system df`):**
  - Build Cache: 172 entries, **9.229 GB total, 9.229 GB reclaimable (100%)**.
  - Local Volumes: 49 entries, **9.802 GB total, 6.024 GB reclaimable (61%)**.
  - Images: 11 entries, **3.512 GB total, 581.5 MB reclaimable (16%)**.
  - Total reclaimable Docker space on `sat`: **~15.8 GB** (more than 50% of the entire 30 GB root disk).

## 2. Technical sources (Debian 13 / Linux system standards)

Proposals are grounded in verified Debian 13 (Trixie) man pages, system documentation, and specifications:
- `journald.conf(5)`, `systemd-journald(8)`: `SystemMaxUse`, `SystemKeepFree`, `SystemMaxFileSize`, `MaxRetentionSec`.
- `logrotate(8)`, `logrotate.conf(5)`: `maxsize`, `rotate`, `compress`, `delaycompress`.
- `docker-system-prune(1)`, `docker-builder-prune(1)`, `docker-volume-prune(1)`: automated build cache and volume reclamation.
- `apt-get(8)`, `apt.conf(5)`: `APT::Clean-Installed "true";`, `apt-get clean`.
- POSIX file utilities: deterministic threshold rules with `find`, `du`, `df`.

## 3. The 10 actions proposal

| # | slug | practice | sites | target | csi-rel action & test |
|---|---|---|---|---|---|
| 01 | `feat(hyg-01-utl-harness)` | Bootstrap `csi-spl-utl` run harness | `csi-spl-utl/` | `./run -a do_help` exits 0 with standard csi-rel harness | `do_utl_harness`<br>`csi-spl-utl/src/bash/tests/utl-harness.tst.sh` |
| 02 | `feat(hyg-02-journald-caps)` | Systemd journald size & retention caps | `/etc/systemd/journald.conf.d/10-disk-hygiene.conf` | Journal <= 1G on PC, <= 500M on sat; 14-day TTL | `do_disk_journal_cap`<br>`csi-spl-utl/src/bash/tests/disk-journal-cap.tst.sh` |
| 03 | `feat(hyg-03-logrotate-maxsize)` | Rsyslog & auth.log rotation maxsize caps | `/etc/logrotate.d/rsyslog` | `maxsize 100M`; no single log > 100M | `do_disk_logrotate_cap`<br>`csi-spl-utl/src/bash/tests/disk-logrotate-cap.tst.sh` |
| 04 | `feat(hyg-04-docker-prune-policy)` | Automated Docker builder & volume hygiene | `csi-spl-utl` sweep action | Builder cache > 48h and orphaned volumes reclaimed; frees > 90G on PC, > 15G on sat | `do_docker_hygiene_sweep`<br>`csi-spl-utl/src/bash/tests/docker-hygiene-sweep.tst.sh` |
| 05 | `feat(hyg-05-shell-snapshot-retention)` | Agent CLI shell snapshot retention & pruning | `~/.claude/shell-snapshots/` | Retention <= 7 days, max 500 files; 0 files > 7 days | `do_shell_snapshot_sweep`<br>`csi-spl-utl/src/bash/tests/shell-snapshot-sweep.tst.sh` |
| 06 | `feat(hyg-06-cache-caps)` | Package manager & build cache caps | `/etc/apt/apt.conf.d/02-clean-installed`, `~/.cache/go-build` | Apt clean installed; Go caches > 14 days pruned | `do_cache_hygiene_sweep`<br>`csi-spl-utl/src/bash/tests/cache-hygiene-sweep.tst.sh` |
| 07 | `feat(hyg-07-stale-lane-leftovers)` | Routine daily cleanup of retired lane temp dirs | `/var/tmp/` | Retired lane dirs > 72h unheld by active PID removed; frees ~20G on PC, ~3.5G on sat | `do_vartmp_hygiene_sweep`<br>`csi-spl-utl/src/bash/tests/vartmp-hygiene-sweep.tst.sh` |
| 08 | `feat(hyg-08-human-forgotten-report)` | Human "files you made and forgot" report | human user directories (`~/`) | Report generated; 0 deletions without explicit human poll tick | `do_human_forgotten_report`<br>`csi-spl-utl/src/bash/tests/human-forgotten-report.tst.sh` |
| 09 | `feat(hyg-09-disk-growth-tracker)` | Daily disk growth tracker & rate alert | `/var/spool-hub/dispatch/work/disk-growth/` | Daily TSV samples; early warning alert if 24h growth > 1.5 GB | `do_disk_growth_track`<br>`csi-spl-utl/src/bash/tests/disk-growth-track.tst.sh` |
| 10 | `docs(hyg-10-guides-and-doctree)` | Documentation in guides and Qto doctree | Developer & DevOps guides, Qto script | All 4 guides documented; clean verification | `do_disk_hygiene_docs_verify`<br>`csi-spl-utl/src/bash/tests/disk-hygiene-docs.tst.sh` |

## 4. Adherence to owner rules

1. **Coded automatic detection (msg 0626b425):** Every rule uses deterministic, fixed thresholds (sizes, ages, counts) with zero LLM/agent judgement in the loop.
2. **Harness in `csi-spl-utl` (msg 177ce9f3):** Row 01 bootstraps `csi-spl-utl/run`. Every new action runs via `cd csi-spl-utl && ./run -a do_<action>` (DRY_RUN=1 default) and from cron with the same command.
3. **Four guides documented (msgs 4dde0ae9, a24f4e86):** Row 10 updates the Developer guide and DevOps guide in repo, and prepares Qto doctree dry-run commands for Operations and System guides.
4. **Human user safety (msg ae18b94b):** Row 08 scans and reports forgotten files for the human user, with zero automated deletions. Deletion requires an explicit, confirmed tick in a human poll form.
5. **Growth tracking & coordination (msg ec060ebc):** Row 09 logs daily disk consumption samples, alerts on > 1.5 GB/day spikes, and respects the 24h workdir retention table.

## 5. Signature

`signed: a-612@PC on v0.1 draft`
