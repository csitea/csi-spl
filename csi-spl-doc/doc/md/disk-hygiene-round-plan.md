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

**Status: v1.1 consensus draft**. Revised to resolve expert panel review points from Claude seat `c-282@sat` (`seat-claude.md` §4, commit `cba1e7178`) and Mistral seat `m-283@sat` (commit `07d40602a`).

## 1. Measured facts on fleet boxes (baseline)

Empirically measured on `PC` and `sat` (read-only baseline probes, 2026-10-16):

### 1.1 Box `PC` (workhorse host)
- **Root filesystem (`/`):** `/dev/nvme0n1p2` 889 GB total, 572 GB used, 273 GB free (**68% used**, 12.0M inodes used of 59.2M, 21%).
- **Temporary directory (`/tmp` tmpfs):** 32 GB total, 5.2 GB used, 26 GB free (17% used).
- **Persistent temporary storage (`/var/tmp`):** **33 GB** used across dozens of retired agent directories (`/var/tmp/claude` 9.5 GB, `/var/tmp/chrome-gmail-*` 4.1 GB [browser profile, human candidate], `/var/tmp/gocache-*` 1.9 GB, retired lane leftovers 400M–950M each).
- **System logs (`/var/log`):** 683 MB used, dominated by `/var/log/journal` at **633 MB**.
- **Systemd Journal configuration:** `/etc/systemd/journald.conf` has `SystemMaxUse` unconfigured. Uncapped systemd default caps journal at 10% of filesystem but is bounded by systemd upstream to a **calculated default cap of 4 GB, not ~88 GB** (`man journald.conf`).
- **Docker storage (`docker system df`):**
  - Build Cache: 1026 entries, **108.2 GB total, 99.06 GB reclaimable**. Default 10% disk cap on 889 GB disk allows ~89 GB of cache to accumulate.
  - Local Volumes: 122 entries, **50.64 GB total, 46.65 GB reclaimable (92%)**.
  - Images: 22 entries, **117.3 GB total, 3.98 GB reclaimable (3%)**.
  - Containers: 19 entries, 2.52 GB total, 25.24 MB reclaimable.
  - Storage driver: `overlayfs` under `/var/lib/docker`.
- **Unbounded fleet cron logs:** `/var/csi/csi-spl/desk-reconcile/cron-prd.out` (162 MB), `/var/csi/csi-spl/box-disk-sweep/box-disk-sweep.log` (29 MB), agent user's `.cache/csi-spl/tmp-scratch-sweep.log` (551 MB), and dated `csi-spl-orc.<date>.log` (~25 MB/day, never cleaned).
- **Agent retirement reaper baseline (dry run 2026-10-16T08:44:00Z by `c-001@PC`):** 372 agent IDs identified for retirement under `/var/spool-hub/.reap/reap.log`.

### 1.2 Box `sat` (satellite host)
- **Root filesystem (`/`):** `/dev/sda1` 30 GB total, 21 GB used, 7.4 GB free (**74% used**, previously reached 88% / 3.5 GB free before SPL-2053 emergency sweep).
- **Data mount (`/mnt/data`):** `/dev/sdb` 98 GB total, 83 GB used, 15 GB free (**85% used**, measured 2026-10-16T08:41Z by `c-001@sat`): home 33 GB, docker 31 GB (overlay2 21 GB), gh-runner 8 GB.
- **Docker storage on `sat`:** Located on `/mnt/data/docker` (data mount), **not on the 30 GB root disk** (`docker info --format '{{.DockerRootDir}}'`). Reclaimable: Build Cache 5.5 GB, Local Volumes 9.1 GB (6.0 GB reclaimable across 37 anonymous dangling volumes; 0 named dangling volumes).
- **Agent retirement reaper & worktree audit (dry run 2026-10-16T08:30Z by `c-001@sat`):** 137 agent IDs eligible for retirement. 7 candidate old worktrees evaluated for 24h disk-sweep removal: `c-089`, `c-402`, `c-403`, `c-409`, `c-410` each hold 1 unlanded commit not on `origin/master` (`git cherry +`), while `c-407` and `c-411` hold 0; all 7 have dirty files.
- **Critical Safety Invariant (Worktree Protection):** Turning live sweeping on worktrees without checking git state risks deleting unlanded work (the `m-261` precedent where a local branch was the sole surviving copy). **Rule:** A worktree with unlanded commits (`git cherry origin/master`) or dirty files (`git status --porcelain`) is NEVER swept or pruned without explicit, confirmed named owner approval.
- **Temporary storage:** `/tmp` tmpfs 32 GB total, 9.7 GB used. `/var/tmp`: 5.1 GB used (441 top-level entries, 92 unchanged > 72h).
- **System logs (`/var/log`):** **850 MB** used, dominated by `/var/log/journal` at 488 MB and high-velocity authentication logs (`auth.log` 138 MB, plus compressed rotations `auth.log.2.gz` 92 MB and `auth.log.3.gz` 56 MB; generating ~16 MB/h, ~390 MB/day).
- **Agent CLI shell snapshots:** Measured 27 files, 220 KB, 0 files older than 7 days in `~/.claude/shell-snapshots/`. Minimal footprint; monitored via human forgotten report rather than active prune script.

## 2. Technical sources (Debian 13 / Linux system standards)

Every proposal in this plan is grounded in verified Debian 13 (Trixie) man pages, system documentation, and specifications:
1. `journald.conf(5)`, `systemd-journald(8)`, `journalctl(1)`:
   - Drop-ins in range 60-90: `/etc/systemd/journald.conf.d/60-disk-hygiene.conf`.
   - `SystemMaxUse=500M`, `SystemMaxFileSize=100M`.
   - Journald default calculated cap is 4 GB (10% of filesystem, capped at 4 GB).
2. `logrotate(8)`, `logrotate.conf(5)`, `systemd.timer(5)`:
   - `maxsize 100M`: Evaluated only when logrotate executes; requires hourly timer to cap ~390 MB/day growth.
   - `copytruncate`: Safely rotates unbounded append-only daemon logs without requiring daemon restart or fd tracking.
   - `su <user> <group>`: Mandatory directive when rotating log files residing in non-root user home directories.
   - `delaycompress` removal in rsyslog config: Compresses `.1` rotations immediately.
3. `docker-volume-prune(1)`, `docker-builder-prune(1)`:
   - `docker volume prune -f`: Removes unattached anonymous volumes safely without touching named test volumes.
   - `docker builder prune --max-used-space <bytes>`: Enforces an explicit byte-level ceiling on builder cache storage.
4. `tmpfiles.d(5)`, `systemd-tmpfiles(8)`:
   - Declarative age-based file lifecycle management via `/etc/tmpfiles.d/tmp.conf`.
   - Full override preserves Debian default `/tmp` cleanup while shortening `/var/tmp` retention:
     `Q /tmp 1777 root root 10d` and `q /var/tmp 1777 root root 14d`.
   - Supports age-by modifiers (`mM:14d`) and automatically respects directory locks.
5. `find(1)`, `du(1)`, `df(1)`:
   - POSIX file attributes, `-mtime +N`, `-size +NM`, `du -xh`, `df -B1`: Deterministic, non-intelligent coded rules for detection and inventory tracking.

## 3. The 10 actions

Every row is a named csi-rel action (`do_<verb>_<noun>`), runnable manually and via cron, tested with red controls, and deployed across fleet boxes.

| # | slug | practice | why | target & proof | csi-rel action & test | box | vendor | batch |
|---|---|---|---|---|---|---|---|---|
| 01 | `feat(hyg-01-fleet-logrotate)` | Automated rotation for fleet cron logs | Claude proposal 2.1; 551M `tmp-scratch-sweep.log`, 162M `cron-prd.out`, 29M `box-disk-sweep.log` unrotated on sat | `/etc/logrotate.d/csi-spl` with `copytruncate`, `maxsize 50M`, `rotate 7`, `compress`, `su`; logs <= 50M | `do_fleet_logrotate_install`<br>`csi-spl-utl/src/bash/tests/fleet-logrotate.tst.sh` | PC, sat | claude | Batch 1 (Lane 1) |
| 02 | `feat(hyg-02-journald-caps)` | Systemd journald size cap drop-in | Journal default cap 4G, currently 633M on PC and 488M on sat; drop-in ensures bounded retention | Drop-in `/etc/systemd/journald.conf.d/60-disk-hygiene.conf` with `SystemMaxUse=500M`, `SystemMaxFileSize=100M`; usage <= 500M | `do_disk_journal_cap`<br>`csi-spl-utl/src/bash/tests/disk-journal-cap.tst.sh` | PC, sat | claude | Batch 1 (Lane 2) |
| 03 | `feat(hyg-03-logrotate-maxsize)` | Hourly logrotate timer & auth.log rotation cap | `auth.log` grows ~390M/day on sat; daily timer defeats `maxsize 100M`; uncompressed `.1` consumes 700M | Hourly `logrotate.timer` drop-in; `maxsize 100M` & remove `delaycompress` in rsyslog; no single log > 100M | `do_disk_logrotate_cap`<br>`csi-spl-utl/src/bash/tests/disk-logrotate-cap.tst.sh` | PC, sat | claude | Batch 2 (Lane 1) |
| 04 | `feat(hyg-04-docker-volume-prune)` | Automated anonymous Docker volume hygiene | 46.6G reclaimable volumes on PC, 6.0G (37 dangling anonymous volumes) on sat; builder/image prune already in place | `docker volume prune -f` (without `-a`) in `prune-docker-images.sh` after BUSY wait; reclaims >45G on PC, >6G on sat | `do_prune_docker_images`<br>`csi-spl-orc/src/bash/tests/docker-volume-prune.tst.sh` | PC, sat | mistral | Batch 2 (Lane 2) |
| 05 | `feat(hyg-05-tmpfiles-var-tmp-age)` | Systemd-tmpfiles declarative age override for `/var/tmp` | Joint Claude+Mistral proposal; replaces custom script with declarative Debian standard `tmpfiles.d(5)` | `/etc/tmpfiles.d/tmp.conf` override with `q /var/tmp 1777 root root 14d` and `Q /tmp 1777 root root 10d`; skips locked entries | `do_tmpfiles_config_install`<br>`csi-spl-utl/src/bash/tests/tmpfiles-config.tst.sh` | PC, sat | claude | Batch 3 (Lane 1) |
| 06 | `feat(hyg-06-docker-builder-cap)` | Docker builder cache absolute size cap | Measured: 108.2 GB builder cache (99 GB reclaimable) on PC; 10% disk cap allows ~89 GB; sat has 5.5 GB | Configure fixed builder cap `PRUNE_BUILDER_CAP_BYTES=26843545600` (25 GB) in cnf/cron on PC; reclaims >70 GB on PC | `do_docker_builder_cap`<br>`csi-spl-orc/src/bash/tests/docker-builder-cap.tst.sh` | PC | mistral | Batch 3 (Lane 2) |
| 07 | `feat(hyg-07-stale-lane-leftovers)` | Routine daily cleanup of retired lane temp dirs at normal level | `tmp-stale-sweep.sh` currently skipped at level normal (`box-disk-sweep.sh` line 168); `/var/tmp` accumulated 33G on PC | Unskip `vartmp` in `box-disk-sweep.sh` at normal level with 72h age threshold; test via `BOX_SWEEP_FREE_PCT=50`; Worktree Safety Invariant | `do_vartmp_sweep_normal`<br>`csi-spl-orc/src/bash/tests/box-disk-sweep.tst.sh` | PC, sat | claude | Batch 4 (Lane 1) |
| 08 | `feat(hyg-08-human-forgotten-report)` | Human "files you made and forgot" report & tick deletion | Owner order (ae18b94b): report large forgotten user files; strictly report-only, deletion only on human tick | Report generated in `dispatch/work/`; separate action deletes only ticked IDs from WUI poll; 0 deletions without tick | `do_human_forgotten_report`<br>`csi-spl-utl/src/bash/tests/human-forgotten-report.tst.sh` | PC, sat | agy | Batch 4 (Lane 2) |
| 09 | `feat(hyg-09-disk-growth-tracker)` | Daily disk growth tracker & mount rate alert | Owner orders (c4e5ec9f, ec060ebc): early warning for steady growth; static headroom check gives no early rate warning | Daily TSV samples from sweep log (including rotated `.gz`); early alert if 24h net growth exceeds 5% of mount size; latched alert | `do_disk_growth_track`<br>`csi-spl-utl/src/bash/tests/disk-growth-track.tst.sh` | PC, sat | mistral | Batch 5 (Lane 1) |
| 10 | `docs(hyg-10-guides-and-doctree)` | Documentation in 4 guides via Qto doctree batch | Owner orders (msgs 4dde0ae9, a24f4e86): document all actions across Developer, DevOps, Operations, and System guides | Qto doctree dry-run script prepared for dispatcher; verification check confirms all actions registered in run harnesses | `do_disk_hygiene_docs_verify`<br>`csi-spl-utl/src/bash/tests/disk-hygiene-docs.tst.sh` | PC, sat | agy | Batch 5 (Lane 2) |

## 4. Detailed row specifications

### Row 01: `feat(hyg-01-fleet-logrotate)` - Automated rotation for fleet cron logs
- **What:** Deploy `/etc/logrotate.d/csi-spl` targeting unbounded fleet daemon and cron logs:
  - Agent user `.cache/csi-spl/tmp-scratch-sweep.log` (551 MB on sat), carrying `su <agent-user> <agent-group>`.
  - `/var/csi/csi-spl/desk-reconcile/cron-prd.out` (162 MB on sat).
  - `/var/csi/csi-spl/box-disk-sweep/box-disk-sweep.log` (29 MB on sat).
  - Directives: `copytruncate`, `maxsize 50M`, `rotate 7`, `compress`, `missingok`.
  - Add cleanup policy for dated log files `/var/csi/csi-spl-desk-cron/csi-spl-orc/dat/log/bash/csi-spl-orc.*.log` older than 14 days.
- **Why:** Owner HUM-10 order ae18b94b ("files which I am generating without actually realizing that") and Claude seat proposal 2.1. Fleet's own cron logs are completely unrotated and unbounded.
- **Command:** `logrotate -d /etc/logrotate.d/csi-spl`
- **Target:** Exits 0; active fleet cron logs capped at 50 MB; dated logs older than 14 days removed; user permissions honoured via `su`.
- **Proof:** Test verifies rotation of planted 60 MB mock log file and preserves fresh log.
- **Red Control:** Planted 60 MB mock log file is verified unrotated prior to config installation; rotated and truncated after config application.

### Row 02: `feat(hyg-02-journald-caps)` - Systemd journald size cap drop-in
- **What:** Deploy `/etc/systemd/journald.conf.d/60-disk-hygiene.conf`:
  ```ini
  [Journal]
  SystemMaxUse=500M
  SystemMaxFileSize=100M
  ```
  Reload `systemd-journald`. Drop initial vacuum from action because `journal-sweep.sh` already vacuums to 500 MB during regular box sweeps.
- **Why:** Systemd journal default calculated cap is 4 GB (`man journald.conf`). Measured: 633 MB on PC, 488 MB on sat. Drop-in standardizes drop-in naming in recommended 60-90 range and bounds journal usage continuously between sweeps.
- **Command:** `systemd-analyze cat-config systemd/journald.conf`
- **Target:** Drop-in active; system journal consumption <= 500 MB on both boxes.
- **Proof:** Config verification shows `SystemMaxUse=500M` active in drop-in list.
- **Red Control:** Planted drop-in with invalid cap value fails config validation test; valid drop-in passes.

### Row 03: `feat(hyg-03-logrotate-maxsize)` - Hourly logrotate timer & auth.log rotation cap
- **What:**
  1. Deploy hourly systemd timer override `/etc/systemd/system/logrotate.timer.d/hourly.conf` with `[Timer]` `OnCalendar=hourly`.
  2. Configure `maxsize 100M` and remove `delaycompress` in `/etc/logrotate.d/rsyslog` for `/var/log/auth.log`, `/var/log/syslog`, and `/var/log/cron.log`.
- **Why:** Measured on sat: `auth.log` grows at ~16 MB/h (~390 MB/day). Under standard daily timer, `maxsize 100M` is only evaluated daily, allowing the log to expand to ~390 MB. Removing `delaycompress` compresses `.1` immediately without waiting a full rotation cycle.
- **Command:** `systemctl cat logrotate.timer && logrotate -d /etc/logrotate.d/rsyslog`
- **Target:** `logrotate.timer` runs hourly; no system log exceeds 100 MB before rotation; `.1` rotations are compressed.
- **Proof:** Dry-run test verifies that a planted 120M log triggers rotation directive while 50M log waits.
- **Red Control:** Planted 120 MB log evaluated under daily timer is ignored between runs; triggers rotation immediately under hourly schedule.

### Row 04: `feat(hyg-04-docker-volume-prune)` - Automated anonymous Docker volume hygiene
- **What:** Extend `csi-spl-orc/src/bash/scripts/prune-docker-images.sh`:
  - Add anonymous volume prune: `docker volume prune -f` (strictly **without `-a`**).
  - Place step after existing BUSY wait to protect CI job volume operations.
  - Action name: `do_prune_docker_images` (existing csi-rel action extended with volume prune).
  - Retain existing builder cache prune and low/crit image pruning.
- **Why:** Measured: 50.64 GB local volumes on PC (46.65 GB reclaimable); 9.1 GB local volumes on sat (6.024 GB reclaimable across 37 dangling anonymous volumes). Builder prune and image prune are already handled by `prune-docker-images.sh`; anonymous volume pruning is the verified gap.
- **Command:** `cd csi-spl-orc && ./run -a do_prune_docker_images`
- **Target:** Reclaims > 45 GB on PC and > 6 GB on sat of orphaned anonymous volumes; preserves 100% of named volumes and active containers.
- **Proof:** Test verifies that an anonymous unattached volume is pruned while a named volume survives.
- **Red Control:** A dangling named volume and an in-use anonymous volume survive execution; only dangling anonymous volume is reaped.

### Row 05: `feat(hyg-05-tmpfiles-var-tmp-age)` - Systemd-tmpfiles declarative age override for `/var/tmp`
- **What:** Deploy `/etc/tmpfiles.d/tmp.conf` with:
  ```
  # Override Debian 13 30d default age for /var/tmp while preserving /tmp
  Q /tmp 1777 root root 10d
  q /var/tmp 1777 root root 14d
  ```
  Verify via `systemd-tmpfiles --clean --dry-run`.
- **Why:** Joint Claude seat proposal 2.2 and Mistral seat proposal 1. Debian 13 upstream defaults to 30 days (`/usr/lib/tmpfiles.d/tmp.conf`). A declarative 14-day override leverages systemd's built-in lock awareness and kernel timestamps without custom prune scripting. Crucially, the override must carry Debian's `Q /tmp 1777 root root 10d` line so `/tmp` age clean-up is not deactivated.
- **Command:** `systemd-tmpfiles --clean --dry-run`
- **Target:** Baseline age for unheld `/var/tmp` files reduced from 30d to 14d; `/tmp` 10d cleanup preserved; locked files respected.
- **Proof:** Dry-run reports planted 15d mock `/var/tmp` file as eligible for deletion while keeping 10d file.
- **Red Control:** Test verifies `systemd-tmpfiles --cat-config | grep '^Q /tmp'` confirms `/tmp` rule persists; planted file with active advisory lock is preserved.

### Row 06: `feat(hyg-06-docker-builder-cap)` - Docker builder cache absolute size cap
- **What:** Configure fixed builder cache size cap on PC:
  - Set `PRUNE_BUILDER_CAP_BYTES=26843545600` (25 GB) in PC's environment/cron configuration for `prune-docker-images.sh`.
  - Overrides the default 10% disk cap (`PRUNE_BUILDER_CAP_PCT`), which on PC's 889 GB disk permitted up to ~89 GB of cache to accumulate.
- **Why:** Measured on PC: Build Cache occupies **108.2 GB with 99.06 GB reclaimable**. Setting a fixed 25 GB cap reclaims over 70 GB on PC while leaving ample cache for fast CI builds. Safe: executed through Docker's native `docker builder prune --keep-storage` within `prune-docker-images.sh`, avoiding unsafe `ctr` wholesale image wipes.
- **Command:** `cd csi-spl-orc && ./run -a do_prune_docker_images`
- **Target:** Build cache on PC capped at 25 GB; reclaims > 70 GB of reclaimable cache; active container images unaffected.
- **Proof:** Test validates that planted build cache exceeding 25 GB is trimmed down to the cap while cache under 20 GB is preserved.
- **Red Control:** Planted build cache exceeding 25 GB is retained under default 89 GB cap; reaped down to 25 GB when `PRUNE_BUILDER_CAP_BYTES` is applied.

### Row 07: `feat(hyg-07-stale-lane-leftovers)` - Routine daily cleanup of retired lane temp dirs at normal level
- **What:** Update `csi-spl-orc/src/bash/scripts/box-disk-sweep.sh`:
  - Remove `SKIP step $s: level normal` at line 168 for the `vartmp` step, allowing `tmp-stale-sweep.sh` to run at level normal.
  - Set normal-level retention age to 72 hours (retaining 24 hours for emergency crit level).
  - Test via `BOX_SWEEP_FREE_PCT=50` (planted normal level).
  - Strictly enforce the **Worktree Safety Invariant**: verify `git cherry origin/master` and `git status --porcelain` before sweeping any worktree directory; refuse deletion if unlanded work exists.
  - Move browser profile directories (`/var/tmp/chrome-*`) to Row 08 human report.
- **Why:** SPL-2053 skips `vartmp` at level normal, allowing `/var/tmp` to swell to 33 GB on PC between headroom alerts. Running at normal level with a 72-hour threshold provides steady routine hygiene.
- **Command:** `cd csi-spl-orc && BOX_SWEEP_FREE_PCT=50 DRY_RUN=1 ./run -a do_box_disk_sweep`
- **Target:** Frees ~20 GB on PC and ~3.5 GB on sat of obsolete lane leftovers during normal operation.
- **Proof:** Test verifies that an idle 80-hour lane directory is swept at level normal while a dirty worktree is skipped.
- **Red Control:** Planted 80h idle lane directory is skipped under current master script (level normal); swept under updated script.

### Row 08: `feat(hyg-08-human-forgotten-report)` - Human "files you made and forgot" report & tick deletion
- **What:** Implement two actions in `csi-spl-utl`:
  1. `do_human_forgotten_report`: Scans human user directories for forgotten candidates (downloads > 30d, disk images `.qcow2`/`.vmdk`/`.iso`, core dumps, browser profiles in `/var/tmp/chrome-*`, unused named volumes, unrotated fleet logs, shell snapshot directory). Outputs markdown report to `/var/spool-hub/dispatch/work/human-files-report.md` and generates a WUI poll proposal.
  2. `do_human_forgotten_delete`: Takes ONLY explicit ticked item IDs from the confirmed human poll form response.
  - **Strict Safety Invariant:** REPORT-ONLY by default. Zero files deleted without an explicit, confirmed human tick.
- **Why:** Owner HUM-10 order ae18b94b: "files which I am generating without actually realizing that, so a panel opinion on how to track and how to remove those is also appreciated."
- **Command:** `cd csi-spl-utl && ./run -a do_human_forgotten_report`
- **Target:** Summary report produced; zero deletions executed without verified interactive human tick.
- **Proof:** Test verifies scanner categorization, poll formatting, and deletion refusal without confirmed ticket.
- **Red Control:** Execution of `do_human_forgotten_delete` without tick flags deletes 0 files; execution with ticked ID deletes only targeted item.

### Row 09: `feat(hyg-09-disk-growth-tracker)` - Daily disk growth tracker & mount rate alert
- **What:** Implement `do_disk_growth_track` in `csi-spl-utl`:
  - Parses free MB and percentage metrics from daily `box-disk-sweep.log` `START` records (including compressed `.gz` rotations), or captures direct `df` samples.
  - Appends daily sample to `/var/spool-hub/dispatch/work/disk-growth/<box>.tsv`.
  - Calculates 24h differential as a **percentage of mount size** (default threshold: 5% net growth in 24 hours).
  - Tracks both root (`/`) and data mount (`/mnt/data`).
  - Implements state-file latch (`/var/spool-hub/.state/growth-alert.state`) to alert once per threshold crossing, preventing repetitive hourly alerts.
- **Why:** Owner orders c4e5ec9f and ec060ebc. Static headroom checks provide no early warning for rapid continuous growth. A fixed 1.5 GB threshold represents 5% of sat's root disk but only 0.2% of PC's root disk.
- **Command:** `cd csi-spl-utl && ./run -a do_disk_growth_track`
- **Target:** Daily TSV record maintained; rate alert dispatched to dispatcher on > 5% 24h growth spike.
- **Proof:** Simulated delta test verifies alert dispatch on 6% consumption increase and silent logging on 2% delta.
- **Red Control:** Simulated 6% growth triggers alert on first evaluation; second evaluation on same day is suppressed by state latch.

### Row 10: `docs(hyg-10-guides-and-doctree)` - Documentation in 4 guides via Qto doctree batch
- **What:**
  1. Prepare batched Qto doctree modification script `/var/spool-hub/dispatch/work/disk-hygiene-qto-edits.sh`:
     - System Guide (Qto doc `119954ab-17d0-4be3-96c1-5746ff9d1f0d`): disk hygiene architecture, scan schedules, Worktree Safety Invariant.
     - Operations & Maintenance Guide (Qto doc `d27e38ca-759a-45dd-8c6f-8a3220748599`): manual execution, alert triage, logrotate emergency verification.
     - DevOps Guide (Qto doc `78e51717-3868-45e0-b6f2-bf14d8689531`): cron lines, timer overrides, drop-in paths.
     - Developer Guide (Qto doc `c65bbfbd-3759-4f7f-82ff-654c60018868`): utility action registration, test suite execution, adding hygiene rules.
  2. Implement `do_disk_hygiene_docs_verify` in `csi-spl-utl`: Verifies that all 10 actions are registered in their respective run harnesses (`./run -a do_<action>`).
- **Why:** Owner orders 4dde0ae9 and a24f4e86. All four guides are Qto doctree exports; direct repository markdown edits are overwritten on export. Batched Qto edits preserve developer guide ack stability.
- **Command:** `cd csi-spl-utl && ./run -a do_disk_hygiene_docs_verify`
- **Target:** All 10 actions verified registered; Qto script ready for dispatcher execution and markdown re-export.
- **Proof:** Verification action succeeds when all action functions exist; fails if any action is unregistered.
- **Red Control:** Unregistered mock action name triggers verification failure.

## 5. Execution batches & disjoint files (R1)

All files modified across the 10 rows are completely disjoint across the repository:

- **Batch 1 (Lane 1 & Lane 2):**
  - Row 01: `/etc/logrotate.d/csi-spl`, `csi-spl-utl/src/bash/run/fleet-logrotate.func.sh`, `csi-spl-utl/src/bash/tests/fleet-logrotate.tst.sh`
  - Row 02: `/etc/systemd/journald.conf.d/60-disk-hygiene.conf`, `csi-spl-utl/src/bash/run/disk-journal-cap.func.sh`, `csi-spl-utl/src/bash/tests/disk-journal-cap.tst.sh`
- **Batch 2 (Lane 1 & Lane 2):**
  - Row 03: `/etc/systemd/system/logrotate.timer.d/hourly.conf`, `/etc/logrotate.d/rsyslog`, `csi-spl-utl/src/bash/run/disk-logrotate-cap.func.sh`, `csi-spl-utl/src/bash/tests/disk-logrotate-cap.tst.sh`
  - Row 04: `csi-spl-orc/src/bash/scripts/prune-docker-images.sh`, `csi-spl-orc/src/bash/tests/docker-volume-prune.tst.sh`
- **Batch 3 (Lane 1 & Lane 2):**
  - Row 05: `/etc/tmpfiles.d/tmp.conf`, `csi-spl-utl/src/bash/run/tmpfiles-config.func.sh`, `csi-spl-utl/src/bash/tests/tmpfiles-config.tst.sh`
  - Row 06: `csi-spl-orc/cnf/cron/prune-docker-images.env`, `csi-spl-orc/src/bash/run/docker-builder-cap.func.sh`, `csi-spl-orc/src/bash/tests/docker-builder-cap.tst.sh`
- **Batch 4 (Lane 1 & Lane 2):**
  - Row 07: `csi-spl-orc/src/bash/scripts/box-disk-sweep.sh`, `csi-spl-orc/src/bash/tests/box-disk-sweep.tst.sh`
  - Row 08: `csi-spl-utl/src/bash/run/human-forgotten-report.func.sh`, `csi-spl-utl/src/bash/run/human-forgotten-delete.func.sh`, `csi-spl-utl/src/bash/tests/human-forgotten-report.tst.sh`
- **Batch 5 (Lane 1 & Lane 2):**
  - Row 09: `csi-spl-utl/src/bash/run/disk-growth-track.func.sh`, `csi-spl-utl/src/bash/tests/disk-growth-track.tst.sh`
  - Row 10: `/var/spool-hub/dispatch/work/disk-hygiene-qto-edits.sh`, `csi-spl-utl/src/bash/run/disk-hygiene-docs.func.sh`, `csi-spl-utl/src/bash/tests/disk-hygiene-docs.tst.sh`

## 6. Panel consensus & signatures

| Seat | Vendor | Agent ID | Status | Verdict Record | Signature |
|---|---|---|---|---|---|
| Editor | agy | a-612@PC | Signed v1.1 consensus | SPL-2111 | `signed: a-612@PC on v1.1 consensus` |
| Expert 1 | claude | c-282@sat | Pending review of v1.1 | SPL-2185 (`cba1e7178`) | Pending |
| Expert 2 | mistral | m-283@sat | Signed v1.0 consensus | SPL-2111 (`07d40602a`) | `signed: m-283@sat on v1.0 consensus` |

Once all panel seats sign the v1.1 sha, row lanes spawn automatically without waiting for owner approval (rounds-rulebook.md §1.4).
