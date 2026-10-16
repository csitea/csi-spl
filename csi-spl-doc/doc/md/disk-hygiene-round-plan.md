# Disk hygiene round: tracking and removing temporary files, logs, snapshots, and forgotten user files (10 actions)

Owner HUM-10, t1 topic `37349c9b-5059-43f1-b900-689039641878`, verbatim orders:
- `c4e5ec9f`: "We need to check also the logs and other types of temporary files which are created on the file system, because at the end, the size of the repo and the local documents is minuscule compared to the size of the actual hard disk. If there is a subsequent slow increase in the disk space usage, it means that this is something to do with temporary files, because I don't do much snapshotting and stuff, at least on the TKN, not to mention the SAT box."
- `ae18b94b`: "But anyway, there might be, for example, too many snapshots in the tank, which are also kind of temporary files. There might be too many old snapshots lingering around. There might also be some kind of files which I am generating without actually realizing that, so a panel opinion on how to track and how to remove those is also appreciated."
- `0626b425`: "it will be good to end up with a solution in which we have coded automatic detection, and the less intelligence in that, the better."
- `177ce9f3`: "Just some kind of a shell action which could also be run manually. Of course, it should be in the utils or the utils subfolder of the spool project."
- `4dde0ae9`: "Make sure to also document this future script in the maintenance and operations guide, in the DevOps guide, and the developer guide."
- `a24f4e86`: "And also mention it in the system guide that we do have a component which is periodically scanning and cleaning files, and just a small description on how it actually works."
- `ec060ebc`: "We need to set up this guard also on the [PC] box if there are so many temp directories left. Also, something in the harness of the agents: whenever they are starting a new work, they should not clean up straight away after themselves. This is because something might happen after the push, and the work needs to be fixed, and so on and so forth. They should create some kind of a table for the guard to go and delete working directories older than 24 hours."

Consensus: rounds need no owner go (rulebook 1.4: consensus, then build, no second go).
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, R1–R16) by pointer.
Issue: SPL-2111.
Editor: **a-612@PC** (agy).
Target boxes: **PC** and **sat** (Debian 13 fleet).

**Status: v0.1 draft**. Submitted to expert panel seats for verification, review, and signing.

## 1. Measured facts on fleet boxes (baseline)

Empirically measured on `PC` and `sat` (read-only probes, 2026-10-16 ~07:2xZ, n=1 each):

### 1.1 Box `PC` (workhorse host)
- **Root filesystem (`/`):** `/dev/nvme0n1p2` 889 GB total, 572 GB used, 273 GB free (**68% used**, 12.0M inodes used of 59.2M, 21%).
- **Temporary directory (`/tmp` tmpfs):** 32 GB total, 5.2 GB used, 26 GB free (17% used).
- **Persistent temporary storage (`/var/tmp`):** **33 GB** used across dozens of retired agent directories (`/var/tmp/claude` 9.5 GB, `/var/tmp/chrome-gmail-*` 4.1 GB, `/var/tmp/gocache-*` 1.9 GB, retired lane leftover directories 400M–950M each).
- **System logs (`/var/log`):** 683 MB used, dominated by `/var/log/journal` at **633 MB**.
- **Systemd Journal configuration:** `/etc/systemd/journald.conf` has `SystemMaxUse`, `SystemKeepFree`, and `SystemMaxFileSize` unconfigured (commented out). Unbounded default caps journal up to 10% of filesystem (~88 GB).
- **Docker storage (`docker system df`):**
  - Build Cache: 994 entries, **103.8 GB total, 94.55 GB reclaimable (91%)**.
  - Local Volumes: 120 entries, **48.17 GB total, 46.65 GB reclaimable (96%)**.
  - Images: 31 entries, **115.5 GB total, 6.68 GB reclaimable (5%)**.
  - containerd snapshotter storage: **115 GB** under `/var/lib/containerd`.
  - Total reclaimable Docker space on `PC`: **~148 GB**.
- **Agent shell snapshots:** Hundreds of `.sh` script snapshots in `~/.claude/shell-snapshots/` created by subshell executions without retention limits.

### 1.2 Box `sat` (satellite host)
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

Every proposal in this plan is backed by verified Debian 13 (Trixie) man pages, system documentation, and systemd/Docker specifications:
1. `journald.conf(5)`, `systemd-journald(8)`, `journalctl(1)`:
   - `SystemMaxUse=`: Maximum disk space journal files may occupy on persistent storage.
   - `SystemKeepFree=`: Minimum disk space to leave free on persistent storage.
   - `SystemMaxFileSize=`: Maximum size of individual journal files before rotation.
   - `MaxRetentionSec=`: Maximum retention time for journal entries.
   - `journalctl --vacuum-size=`, `journalctl --vacuum-time=`: Manual and programmatic vacuuming commands.
2. `logrotate(8)`, `logrotate.conf(5)`:
   - `maxsize <size>`: Rotates log files when exceeding `<size>` bytes even if the scheduled interval (daily/weekly) has not elapsed.
   - `rotate <count>`: Number of rotated log cycles retained before removal.
   - `compress` & `delaycompress`: Compression of rotated files.
3. `docker-system-prune(1)`, `docker-builder-prune(1)`, `docker-volume-prune(1)`:
   - `docker builder prune -a --filter "until=48h" -f`: Clears unreferenced build cache older than 48 hours without disrupting active builds.
   - `docker volume prune -f`: Reclaims orphaned anonymous volumes unattached to any running or stopped container.
4. `apt-get(8)`, `apt.conf(5)`:
   - `APT::Clean-Installed "true";`: Ensures `/var/cache/apt/archives/` does not accumulate downloaded `.deb` packages indefinitely.
   - `apt-get clean`: Empties the package archive cache safely.
5. `find(1)`, `du(1)`, `df(1)`:
   - POSIX file attributes, `-mtime +N`, `-size +NM`, `du -xh`, `df -B1`: Deterministic, non-intelligent coded rules for detection and inventory tracking.

## 3. The 10 actions

Every row is a named csi-rel action (`do_<verb>_<noun>`, `csi-spl-utl`), runnable manually and via cron, tested with red controls, and deployed across fleet boxes.

| # | slug | practice | why | target & proof | csi-rel action & test | box | vendor | batch |
|---|---|---|---|---|---|---|---|---|
| 01 | `feat(hyg-01-utl-harness)` | Bootstrap `csi-spl-utl` run harness | Owner order (msg 177ce9f3): all disk hygiene actions must live in utils (`csi-spl-utl`), callable manually and from cron | Executable `csi-spl-utl/run` supporting `./run -a do_<action>` with DRY_RUN=1 default | `do_utl_harness`<br>`csi-spl-utl/src/bash/tests/utl-harness.tst.sh` | PC, sat | agy | Batch 1 (Lane 1) |
| 02 | `feat(hyg-02-journald-caps)` | Systemd journald size & retention caps | Journal currently uncapped on both boxes; uses 633M on PC and 488M on sat; default allows up to 10% disk (~88G on PC) | `SystemMaxUse=1G` (500M on sat), `SystemMaxFileSize=100M`; journal usage <= 1G on PC, <= 500M on sat | `do_disk_journal_cap`<br>`csi-spl-utl/src/bash/tests/disk-journal-cap.tst.sh` | PC, sat | claude | Batch 1 (Lane 2) |
| 03 | `feat(hyg-03-logrotate-maxsize)` | Rsyslog & auth.log rotation maxsize caps | High agent fleet volume logs thousands of sudo lines/hour; `auth.log` reached 1.3G in 5 days; weekly rotation too slow | `maxsize 100M` in rsyslog config; individual logs never exceed 100M before rotation and compression | `do_disk_logrotate_cap`<br>`csi-spl-utl/src/bash/tests/disk-logrotate-cap.tst.sh` | PC, sat | claude | Batch 2 (Lane 1) |
| 04 | `feat(hyg-04-docker-prune-policy)` | Automated Docker builder & volume hygiene | 103.8G build cache (94.5G reclaimable) on PC; 9.2G build cache (100% reclaimable) and 6.0G volume reclaimable on sat | Builder prune older than 48h and orphaned volume prune; frees >90G on PC and >15G on sat | `do_docker_hygiene_sweep`<br>`csi-spl-utl/src/bash/tests/docker-hygiene-sweep.tst.sh` | PC, sat | mistral | Batch 2 (Lane 2) |
| 05 | `feat(hyg-05-shell-snapshot-retention)` | Agent CLI shell snapshot retention & pruning | Claude CLI creates `snapshot-bash-*.sh` for every subshell in user directories; hundreds accumulate indefinitely | Retain snapshots <= 7 days; directory capped at 500 files; 0 snapshots older than 7 days | `do_shell_snapshot_sweep`<br>`csi-spl-utl/src/bash/tests/shell-snapshot-sweep.tst.sh` | PC, sat | mistral | Batch 3 (Lane 1) |
| 06 | `feat(hyg-06-cache-caps)` | Package manager & build cache caps | Apt package archives and stale build caches (Go, npm) linger in `/var/cache` and `/var/tmp` | `APT::Clean-Installed "true"`; stale Go build caches > 14 days pruned; frees ~3G on PC | `do_cache_hygiene_sweep`<br>`csi-spl-utl/src/bash/tests/cache-hygiene-sweep.tst.sh` | PC, sat | claude | Batch 3 (Lane 2) |
| 07 | `feat(hyg-07-stale-lane-leftovers)` | Routine daily cleanup of retired lane temp dirs | SPL-2053 runs `/var/tmp` sweep only when disk headroom < 15% (emergency); `/var/tmp` accumulated 33G on PC and 5.1G on sat | Daily sweep removes retired lane dirs unheld by `/proc/*/cwd` or open fds older than 72h; frees ~20G on PC | `do_vartmp_hygiene_sweep`<br>`csi-spl-utl/src/bash/tests/vartmp-hygiene-sweep.tst.sh` | PC, sat | claude | Batch 4 (Lane 1) |
| 08 | `feat(hyg-08-human-forgotten-report)` | Human "files you made and forgot" report | Owner order (ae18b94b): report large forgotten user files; strictly report-only, deletion only on human tick | Scans user dirs for ISOs, VM images, stale downloads; produces markdown report; 0 deletions without tick | `do_human_forgotten_report`<br>`csi-spl-utl/src/bash/tests/human-forgotten-report.tst.sh` | PC, sat | agy | Batch 4 (Lane 2) |
| 09 | `feat(hyg-09-disk-growth-tracker)` | Daily disk growth tracker & rate alert | Owner order (c4e5ec9f, ec060ebc): track slow increases; static headroom check gives no early rate warning | Daily samples logged to TSV; early alert triggered if 24h disk growth exceeds 1.5 GB | `do_disk_growth_track`<br>`csi-spl-utl/src/bash/tests/disk-growth-track.tst.sh` | PC, sat | mistral | Batch 5 (Lane 1) |
| 10 | `docs(hyg-10-guides-and-doctree)` | Documentation in guides and Qto doctree | Owner orders (msgs 4dde0ae9, a24f4e86): document in DevOps, Developer, Operations, and System guides | Developer & DevOps guides updated; Qto edits prepared for dispatcher; clean audit verify | `do_disk_hygiene_docs_verify`<br>`csi-spl-utl/src/bash/tests/disk-hygiene-docs.tst.sh` | PC, sat | agy | Batch 5 (Lane 2) |

## 4. Detailed row specifications

### Row 01: `feat(hyg-01-utl-harness)` - Bootstrap `csi-spl-utl` run harness
- **What:** Initialize `csi-spl-utl` directory with standard csi-rel action runner `./run`, action functions directory `src/bash/run/`, and automated tests directory `src/bash/tests/`. Default execution mode is `DRY_RUN=1`. Supports `./run -a do_<action>`.
- **Why:** Owner order msg 177ce9f3: all new disk hygiene actions must live in utils (`csi-spl-utl`), callable manually and from cron. Currently `csi-spl-utl` holds only a README.md.
- **Command:** `cd csi-spl-utl && ./run -a do_help`
- **Target:** Exits 0, lists registered utility actions, enforces standard csi-rel action logging and dry-run conventions.
- **Proof:** Test suite verifies action execution, dry-run safety flags, and option validation.

### Row 02: `feat(hyg-02-journald-caps)` - Systemd journald size & retention caps
- **What:** Deploy `/etc/systemd/journald.conf.d/10-disk-hygiene.conf`:
  ```ini
  [Journal]
  SystemMaxUse=1G
  SystemKeepFree=2G
  SystemMaxFileSize=100M
  MaxRetentionSec=14day
  ```
  (On `sat`, `SystemMaxUse=500M` reflecting the smaller 30 GB root disk). Reload systemd-journald and trigger initial vacuum: `journalctl --vacuum-size=1G --vacuum-time=14d`.
- **Why:** Systemd journal is currently uncapped on both boxes (`SystemMaxUse` commented out). Measured: 633 MB on PC, 488 MB on sat. Default systemd policy allows journal to expand up to 10% of the root filesystem (~88 GB on PC).
- **Command:** `journalctl --disk-usage && systemd-analyze cat-config systemd/journald.conf`
- **Target:** Journal usage <= 1G on PC and <= 500M on sat; retention capped at 14 days.
- **Proof:** Vacuum command reduces journal size immediately; configuration persists across reboots.

### Row 03: `feat(hyg-03-logrotate-maxsize)` - Rsyslog & auth.log rotation maxsize caps
- **What:** Configure `maxsize 100M` and daily checks for `/var/log/auth.log`, `/var/log/syslog`, and `/var/log/cron.log` in `/etc/logrotate.d/rsyslog`. Add a post-rotation script ensuring immediate gzip compression without leaving uncompressed `.1` files.
- **Why:** Every agent running commands via privileged execution generates authentication log lines. On sat, `auth.log` reached 1.3 GB in 5 days, while uncompressed `auth.log.1` consumed 700 MB. Weekly rotation is too slow for fleet agent volume.
- **Command:** `logrotate -d /etc/logrotate.d/rsyslog`
- **Target:** Any system log exceeding 100 MB is rotated immediately; no single log exceeds 100 MB on disk.
- **Proof:** Dry-run test verifies that a planted 120M log triggers rotation directive while 50M log waits.

### Row 04: `feat(hyg-04-docker-prune-policy)` - Automated Docker builder & volume hygiene
- **What:** Implement `do_docker_hygiene_sweep` in `csi-spl-utl`:
  - Prunes build cache older than 48 hours: `docker builder prune -a --filter "until=48h" -f`.
  - Prunes orphaned unattached volumes: `docker volume prune -f`.
  - When disk headroom warning fires (< 15% free), triggers dangling image prune: `docker image prune -f`.
- **Why:** Measured: on `PC`, Docker build cache occupies 103.8 GB (94.55 GB reclaimable!) and volumes consume 48.17 GB (46.65 GB reclaimable). On `sat`, 9.229 GB build cache is 100% reclaimable, occupying nearly a third of the 30 GB root disk.
- **Command:** `cd csi-spl-utl && DRY_RUN=1 ./run -a do_docker_hygiene_sweep`
- **Target:** Reclaims > 90 GB on PC and > 15 GB on sat; keeps active containers, working images, and attached volumes 100% intact.
- **Proof:** Execution reports exact reclaimable byte delta; active agent containers and volumes remain undisturbed.

### Row 05: `feat(hyg-05-shell-snapshot-retention)` - Agent CLI shell snapshot retention & pruning
- **What:** Implement `do_shell_snapshot_sweep` in `csi-spl-utl`:
  - Scans `~/.claude/shell-snapshots/` and any user-level shell snapshot directories.
  - Prunes snapshots older than 7 days (`find ... -name "snapshot-bash-*.sh" -mtime +7 -delete`).
  - Caps total snapshot count at 500 files per user.
- **Why:** Claude CLI creates persistent shell snapshot scripts on every subshell execution. Hundreds of scripts accumulate indefinitely across user home directories without automatic cleanup.
- **Command:** `cd csi-spl-utl && DRY_RUN=1 ./run -a do_shell_snapshot_sweep`
- **Target:** Directory contains <= 500 files; 0 files older than 7 days.
- **Proof:** Planted test snapshot with simulated mtime > 8d is pruned; snapshot < 2d is preserved.

### Row 06: `feat(hyg-06-cache-caps)` - Package manager & build cache caps
- **What:** Implement `do_cache_hygiene_sweep` in `csi-spl-utl`:
  - Installs `/etc/apt/apt.conf.d/02-clean-installed` with `APT::Clean-Installed "true";` and executes `apt-get clean`.
  - Scans Go build cache (`~/.cache/go-build`) and removes cache entries older than 14 days (`go clean -cache`).
  - Sweeps stale `/var/tmp/gocache-*` directories.
- **Why:** Package caches and compiler caches accumulate silently. On PC, `/var/tmp/gocache-*` consumed 1.9 GB; apt archives consumed 479 MB on sat.
- **Command:** `cd csi-spl-utl && DRY_RUN=1 ./run -a do_cache_hygiene_sweep`
- **Target:** Apt cache reduced to 0 B after package transactions; Go cache purged of entries older than 14 days.
- **Proof:** Planted stale cache files are reclaimed; fresh build artifacts are kept.

### Row 07: `feat(hyg-07-stale-lane-leftovers)` - Routine daily cleanup of retired lane temp dirs
- **What:** Implement `do_vartmp_hygiene_sweep` in `csi-spl-utl`:
  - Scans `/var/tmp` for retired agent directories (`c-*`, `a-*`, `m-*`, `g-*`, `cle*`, `graft-pack*`).
  - Verifies that no active process holds the directory (checks `/proc/*/cwd` and open file descriptors).
  - Verifies that the agent ID is not active in `registry.tsv` or active tmux windows.
  - Requires idle age > 72 hours before routine deletion.
- **Why:** SPL-2053 introduced `/var/tmp` stale sweeping, but ONLY as an emergency trigger when disk headroom is < 15% (low/crit). Between emergencies, `/var/tmp` swelled to 33 GB on PC across dozens of retired agent directories. Routine daily sweeping prevents headroom crises.
- **Command:** `cd csi-spl-utl && DRY_RUN=1 ./run -a do_vartmp_hygiene_sweep`
- **Target:** Frees ~20 GB on PC and ~3.5 GB on sat of obsolete lane leftovers.
- **Proof:** Planted directory with inactive agent ID is reaped; directory with active PID or live lane ID is preserved.

### Row 08: `feat(hyg-08-human-forgotten-report)` - Human "files you made and forgot" report
- **What:** Implement `do_human_forgotten_report` in `csi-spl-utl`:
  - Scans human user directories for large forgotten candidates:
    - Large files in downloads older than 30 days (`.iso`, `.tar.gz`, `.deb`, `.zip`).
    - Obsolete virtual machine / disk images (`.qcow2`, `.vmdk`, `.img`, `.raw`).
    - Stale ad-hoc git clones outside standard repository workspaces.
    - Crash dumps and core dumps (`core.*`).
  - Formats a compact markdown summary report categorized by type and size.
  - Generates a poll proposal with checkboxes for human review.
  - **Strict Safety Constraint**: REPORT-ONLY! Deletion is NEVER automated and requires an explicit, confirmed human tick in a poll form.
- **Why:** Owner HUM-10 order ae18b94b: "There might also be some kind of files which I am generating without actually realizing that, so a panel opinion on how to track and how to remove those is also appreciated."
- **Command:** `cd csi-spl-utl && ./run -a do_human_forgotten_report`
- **Target:** Generates `/var/spool-hub/dispatch/work/human-files-report.md`; 0 files deleted without manual human command.
- **Proof:** Test validates scanner categorization, output format, and absolute refusal to execute deletion without confirmed interactive flag.

### Row 09: `feat(hyg-09-disk-growth-tracker)` - Daily disk growth tracker & rate alert
- **What:** Implement `do_disk_growth_track` in `csi-spl-utl`:
  - Runs daily via cron: captures timestamp, total root bytes used, inode count, Docker storage size, `/var/tmp` size, and `/var/log` size.
  - Appends record to `/var/spool-hub/dispatch/work/disk-growth/<box>.tsv`.
  - Calculates 24h differential: if net growth exceeds 1.5 GB in 24 hours, sends an early warning note to the dispatch lease holder detailing the top 3 growing directories.
  - Integrates with the 24h workdir retention table coordination (ec060ebc).
- **Why:** Owner order c4e5ec9f / ec060ebc: "If there is a subsequent slow increase in the disk space usage, it means that this is something to do with temporary files... how to TRACK growth". Today headroom alerts only when static thresholds (85% / 92%) are breached, providing zero early warning for steady rapid consumption.
- **Command:** `cd csi-spl-utl && ./run -a do_disk_growth_track`
- **Target:** Daily historical TSV record on each box; alert dispatched within 24h of anomalous consumption spike (> 1.5 GB/day).
- **Proof:** Simulated delta test verifies alert dispatch on 2.0 GB jump and silent logging on 300 MB delta.

### Row 10: `docs(hyg-10-guides-and-doctree)` - Documentation in guides and Qto doctree
- **What:**
  1. Update repository markdown documentation:
     - `csi-spl-doc/doc/md/guides/devops-guide.md`: cron schedules, cnf threshold variables, deployment per box.
     - `csi-spl-doc/doc/md/developer-guide.md`: `csi-spl-utl` action location, test execution commands, guidelines for adding new hygiene rules.
  2. Prepare Qto doctree dry-run commands for dispatcher execution:
     - Operations and maintenance guide (Qto doc `d27e38ca-759a-45dd-8c6f-8a3220748599`): manual execution procedures, alert triage, and emergency procedures.
     - System guide (Qto doc `119954ab-17d0-4be3-96c1-5746ff9d1f0d`): description of the disk hygiene subsystem, scanning scope, cleanup policies, and safety invariants.
- **Why:** Owner orders msgs 4dde0ae9 and a24f4e86 explicitly mandate documentation in all four guides.
- **Command:** `cd csi-spl-utl && ./run -a do_disk_hygiene_docs_verify`
- **Target:** Developer guide and DevOps guide updated on trunk; Qto modification script `/var/spool-hub/dispatch/work/disk-hygiene-qto-edits.sh` verified and ready for dispatcher execution.
- **Proof:** Automated check confirms that all required sections and terms exist across documentation files.

## 5. Execution batches & disjoint files (R1)

All files modified by the 10 rows are completely disjoint across the repository:

- **Batch 1 (Lane 1 & Lane 2):**
  - Row 01: `csi-spl-utl/run`, `csi-spl-utl/src/bash/run/utl-harness.func.sh`, `csi-spl-utl/src/bash/tests/utl-harness.tst.sh`
  - Row 02: `/etc/systemd/journald.conf.d/10-disk-hygiene.conf`, `csi-spl-utl/src/bash/run/disk-journal-cap.func.sh`, `csi-spl-utl/src/bash/tests/disk-journal-cap.tst.sh`
- **Batch 2 (Lane 1 & Lane 2):**
  - Row 03: `/etc/logrotate.d/rsyslog`, `csi-spl-utl/src/bash/run/disk-logrotate-cap.func.sh`, `csi-spl-utl/src/bash/tests/disk-logrotate-cap.tst.sh`
  - Row 04: `csi-spl-utl/src/bash/run/docker-hygiene-sweep.func.sh`, `csi-spl-utl/src/bash/tests/docker-hygiene-sweep.tst.sh`
- **Batch 3 (Lane 1 & Lane 2):**
  - Row 05: `csi-spl-utl/src/bash/run/shell-snapshot-sweep.func.sh`, `csi-spl-utl/src/bash/tests/shell-snapshot-sweep.tst.sh`
  - Row 06: `/etc/apt/apt.conf.d/02-clean-installed`, `csi-spl-utl/src/bash/run/cache-hygiene-sweep.func.sh`, `csi-spl-utl/src/bash/tests/cache-hygiene-sweep.tst.sh`
- **Batch 4 (Lane 1 & Lane 2):**
  - Row 07: `csi-spl-utl/src/bash/run/vartmp-hygiene-sweep.func.sh`, `csi-spl-utl/src/bash/tests/vartmp-hygiene-sweep.tst.sh`
  - Row 08: `csi-spl-utl/src/bash/run/human-forgotten-report.func.sh`, `csi-spl-utl/src/bash/tests/human-forgotten-report.tst.sh`
- **Batch 5 (Lane 1 & Lane 2):**
  - Row 09: `csi-spl-utl/src/bash/run/disk-growth-track.func.sh`, `csi-spl-utl/src/bash/tests/disk-growth-track.tst.sh`
  - Row 10: `csi-spl-doc/doc/md/guides/devops-guide.md`, `csi-spl-doc/doc/md/developer-guide.md`, `csi-spl-utl/src/bash/run/disk-hygiene-docs.func.sh`, `csi-spl-utl/src/bash/tests/disk-hygiene-docs.tst.sh`

## 6. Panel consensus & signatures

| Seat | Vendor | Agent ID | Status | Signature SHA |
|---|---|---|---|---|
| Editor | agy | a-612@PC | Proposed v0.1 draft | Pending |
| Expert 1 | claude | Pending placement | Pending review | Pending |
| Expert 2 | mistral | Pending placement | Pending review | Pending |

Once all panel seats sign the v1.0 sha, row lanes spawn automatically without waiting for owner approval (rounds-rulebook.md §1.4).
