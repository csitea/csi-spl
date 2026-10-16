# Disk hygiene round: claude seat verdict

Seat: **c-282@sat** (claude, expert panel seat), task `dispatch-37349c9b`,
issue SPL-2111 (seat record SPL-2185).
Review of: [the disk hygiene round plan](../disk-hygiene-round-plan.md) v0.1 draft (78cf22b2c).
Measured on: **sat** only, 2026-10-16 ~10:30..10:45Z, read-only, n=1 per
number unless a count is given. The PC numbers below are the plan's; this seat
could not re-measure them (no shell on PC from sat).

**Tally: 0 agree / 6 agree with changes / 4 disagree / 2 proposals.**

The headline: SPL-2053's box sweep (`csi-spl-orc/src/bash/scripts/box-disk-sweep.sh`,
on sat in the box user's crontab every 15 min, tag `# csi-spl:box-disk-sweep`)
already runs ten steps that cover most of what rows 01, 02, 03, 04, 06 and 07
propose. Measured: its log holds 776 `START` lines since 2026-10-08. The plan
should plan only the gaps; each verdict below names the existing script.

## 1. Verdict per row

| Row | Slug | Verdict | Duplicates | One-line reason |
|---|---|---|---|---|
| 01 | `hyg-01-utl-harness` | **disagree** | `csi-spl-utl/run` (8cf803b0d) | the harness is on master already |
| 02 | `hyg-02-journald-caps` | agree with changes | `journal-sweep.sh` | default is 4G, not 88G; drop-in name 60-90 |
| 03 | `hyg-03-logrotate-maxsize` | agree with changes | `log-sweep.sh` (low/crit only) | `maxsize` needs an hourly logrotate run |
| 04 | `hyg-04-docker-prune-policy` | agree with changes | `prune-docker-images.sh` (builder, images) | keep only the anonymous-volume prune |
| 05 | `hyg-05-shell-snapshot-retention` | **disagree** | none | 220 KB measured, 0 files over 7 days |
| 06 | `hyg-06-cache-caps` | **disagree** | `log-sweep.sh`, `do_prune_go_build_cache`, `tmp-stale-sweep.sh` | done already; `Clean-Installed` is misread |
| 07 | `hyg-07-stale-lane-leftovers` | agree with changes | `tmp-stale-sweep.sh` (`vartmp` step) | the gap is one gate line, not a new action |
| 08 | `hyg-08-human-forgotten-report` | agree with changes | none | real gap; add the measured kinds and the tick action |
| 09 | `hyg-09-disk-growth-tracker` | agree with changes | none (the data is in the sweep log) | real gap; per-disk threshold, no deletion text |
| 10 | `hyg-10-guides-and-doctree` | **disagree** (as written) | none | both md guides are qto exports: edit the qto docs |

### 1.1 Row 01: disagree

- `git ls-tree -r --name-only origin/master csi-spl-utl` -> `run`,
  `src/bash/run/run.sh`, `src/bash/run/help/print-help.func.sh`,
  `src/bash/run/sweep-workdirs.func.sh`, `src/bash/scripts/workdir-sweep.sh`,
  `lib/bash/funcs/*`. Landed by 8cf803b0d (SPL-2110). The plan's "Currently
  `csi-spl-utl` holds only a README.md" is no longer true.
- What is missing is only a `src/bash/tests/` dir for utl, which the first
  real row creates with its own test. Drop the row; its slot can go to
  proposal 2.1.

### 1.2 Row 02: agree with changes

- `man journald.conf`: "The first pair defaults to 10% and the second to 15% of
  the size of the respective file system, but each of the calculated default
  values is capped to 4G." So the uncapped worst case on PC is **4G, not
  ~88 GB**. Fix the "why" in sections 1.1 and 4.
- Already done: `journal-sweep.sh` (`journalctl --vacuum-size`, default
  `BOX_SWEEP_JOURNAL_MAX=500M`) runs in every box sweep. The real gap is that
  journald itself holds the cap between sweeps, which a drop-in gives. Keep the
  row for that only; drop the "initial vacuum" (the sweep does it).
- Drop-in name: `man journald.conf` recommends "the range 60-90 for drop-ins in
  /etc/ and /run/". Use `/etc/systemd/journald.conf.d/60-disk-hygiene.conf`,
  not `10-`.
- `MaxRetentionSec=`: the man page says time-based deletion "should not be
  required as size-based deletion with options such as SystemMaxUse= should be
  sufficient". Keep it only for a retention policy; it is not a disk control.
- One value on both boxes is simpler: the sweep already vacuums to 500M on
  both, so `SystemMaxUse=500M` everywhere avoids two code paths.
- The action writes a file under `/etc`: its test must use a planted root dir
  (no sudo), and its red control is a planted drop-in with a wrong value.

### 1.3 Row 03: agree with changes

- `man logrotate`, `maxsize`: "Log files are rotated when they grow bigger than
  size bytes even before the additionally specified time interval". That check
  happens only when logrotate runs. `man logrotate`, `hourly`: "usually
  logrotate is configured to be run by cron daily (or by logrotate.timer when
  using systemd(1)). You have to change this configuration and run logrotate
  hourly to be able to really rotate logs hourly."
- Measured on sat: `systemctl cat logrotate.timer` -> `OnCalendar=daily`;
  `/var/log/auth.log` = 202,492,740 bytes at 13:27 local, last rotated 00:58,
  so ~16 MB/h, ~390 MB/day. With `maxsize 100M` and the daily timer, auth.log
  still reaches ~390 MB. The target "no single log exceeds 100 MB" needs a
  `logrotate.timer` drop-in with `OnCalendar=hourly` as part of the row.
- No custom post-rotation gzip script: `/etc/logrotate.d/rsyslog` has
  `delaycompress` (measured, its line 13). `man logrotate`, `delaycompress`:
  "Postpone compression of the previous log file to the next rotation cycle."
  Removing that one line is the documented way to compress the `.1` at once
  (rsyslog's `postrotate` already makes rsyslog reopen its files).
- The edit must be in `/etc/logrotate.d/rsyslog` itself: `man logrotate`
  documents `ignoreduplicates` ("Ignore any following matches of a log file"),
  so a second stanza for the same log is not the default. That file is a
  package config file, so a package upgrade may ask about the local edit (I
  believe, unchecked).
- Already done under pressure: `log-sweep.sh` forces a rotation over
  `LOG_SWEEP_MAX` (256M), but only at level low/crit
  (`box-disk-sweep.sh` line 168: `SKIP step $s: level normal`). Name it in the
  row so the two do not fight.

### 1.4 Row 04: agree with changes

- The builder half duplicates `prune-docker-images.sh`: it already runs
  `docker builder prune` with `--filter until=` and then caps the build cache
  at `PRUNE_BUILDER_CAP_PCT` (10) % of the docker disk. Drop the builder half;
  if 10% (~89 GB on an 889 GB disk) is too much on PC, lowering
  `BOX_SWEEP_BUILDER_CAP_PCT` there is a cnf change, not a row.
- The image half duplicates it too: the low/crit level already prunes images.
- The volume half is the real gap: `prune-docker-images.sh` says "Never a
  container, never a volume". `man docker-volume-prune`: `-a, --all` "Remove
  all unused volumes, not just anonymous ones", so plain
  `docker volume prune -f` removes unused anonymous volumes only. Keep that,
  **never `-a`** (a named volume can be a test DB someone wants back).
  Measured on sat: `docker volume ls -q -f dangling=true` -> 37 anonymous,
  0 named; `docker system df` -> Local Volumes 9.114 GB, 6.024 GB reclaimable.
- Put it as a step in `prune-docker-images.sh`, after its BUSY wait (a CI job
  can hold a briefly unattached anonymous volume), not as a new action.
- Fact fix: on sat docker is not on the root disk.
  `docker info --format '{{.DockerRootDir}}'` -> `/mnt/data/docker`. The
  plan's "more than 50% of the entire 30 GB root disk" is wrong; it is on the
  98 GB data disk. Measured now: Build Cache 5.534 GB (the plan's 9.229 GB
  was before a sweep).

### 1.5 Row 05: disagree

- Measured on sat: the agent user's `~/.claude/shell-snapshots/` -> 27 files,
  220 KB, `find -mtime +7` -> 0; the box user has no such dir. 0 bytes to win,
  and nothing older than 7 days, so something already prunes them (which
  part, unchecked).
- A sweep in another tool's private dir is a risk for no gain. If wanted, list
  the dir's size in row 08's report; no deleting action.

### 1.6 Row 06: disagree

- `man apt.conf`, `Clean-Installed`: "Defaults to on. When turned on the
  autoclean feature will remove any packages which can no longer be downloaded
  from the cache." It is about `autoclean`, it is already on, and it does not
  empty the cache after an install. The row's main setting does nothing.
- `apt-get clean` already runs in `log-sweep.sh` (its step 2). Measured on
  sat: `du -sh /var/cache/apt/archives` -> 64K.
- Go: `do_prune_go_build_cache` already deletes entries older than
  `GO_CACHE_MAX_AGE_MIN` (1440) and caps each cache at `GO_CACHE_CAP_GB` (8).
  Measured on sat: box user 8.2G (at the cap), agent user 4.7G. `go help
  cache`: "Running 'go clean -cache' deletes all cached data", so the row's
  "entries older than 14 days (`go clean -cache`)" contradicts itself.
- `/tmp/*-gocache` is `tmp-stale-sweep.sh`'s; `/var/tmp/gocache-*` is the
  `vartmp` step's (row 07). Nothing is left for this row.

### 1.7 Row 07: agree with changes

- Already exists: `tmp-stale-sweep.sh` with `TMP_STALE_ANY=1` is the box
  sweep's `vartmp` step: idle check by `/proc/<pid>/cwd` and open fds, a live
  lane's id kept, age 72 h (low) / 24 h (crit). The worktree half is SPL-2110's
  `workdirs` step (the table). The one gap is the gate:
  `box-disk-sweep.sh` line 168 skips `vartmp` and `logs` at level normal.
- Change: let `vartmp` run at level normal with a 72 h age, in the existing
  script and its test `csi-spl-orc/src/bash/tests/box-disk-sweep.tst.sh`; red
  control = a planted 80 h idle dir that a normal-level run keeps today. No
  new action.
- Measured on sat: `/var/tmp` 5.0G, 441 top-level entries, 92 of them
  unchanged for over 3 days.
- Two PC items the row misses: `tmp-stale-sweep.sh` never takes `claude-*`
  (by design), and the plan lists `/var/tmp/claude` at 9.5 GB on PC: say which
  action owns it. And `/var/tmp/chrome-*` (4.1 GB on PC) looks like a
  person's browser profile: that belongs to row 08 (report only), never to
  this sweep.

### 1.8 Row 08: agree with changes

- Report-only with deletion on the human's tick is right, and the plan says
  so. Make it testable: the deletion is a separate action that takes only the
  ticked item ids from the poll answer; the red control is a run without a
  tick that must remove 0 files.
- The poll is the WUI `poll` form, one form per post.
- Add the measured kinds a person may not know they made: browser profiles in
  `/var/tmp` (row 07), named docker volumes no container uses (row 04 never
  touches them), and the fleet's own unrotated logs (proposal 2.1).
- The report lives in `dispatch/work/` (outside git): good. It must never be
  copied into this public repo (a person's file names).

### 1.9 Row 09: agree with changes

- Real gap: `check-disk-headroom.sh` is a static threshold (85% / 92%).
- The data already exists: every box sweep `START` line carries free MB per
  mount. Last line per day on sat, `/`:

  | day | free MB | used % |
  |---|---|---|
  | 10-08 | 13992 | 52 |
  | 10-09 | 8606 | 70 |
  | 10-11 | 6068 | 79 |
  | 10-12 | 9252 | 68 |
  | 10-14 | 4887 | 83 |
  | 10-16 | 7584 | 74 |

  So sat's root lost ~5.4 GB in one day (10-08 to 10-09): a 1.5 GB/day alert
  would have fired. A fixed 1.5 GB/day is ~5% of sat's 30 GB root but 0.2% of
  PC's 889 GB: make the threshold a percent of the disk per mount (cnf), and
  track `/mnt/data` too.
- Alert once per crossing, with the same state-file rule as
  `check-disk-headroom.sh`, or a growing disk sends a note every tick.
- The TSV grows too: one line per day per box is fine, but say so.
- Drop the bullet about the 24 h workdir table and the worktree invariant: the
  tracker deletes nothing, and the table is SPL-2110's.

### 1.10 Row 10: disagree as written

- `csi-spl-doc/doc/md/developer-guide.md` line 3: "Generated from qto doc
  `c65bbfbd-...`; edit it there." `csi-spl-doc/doc/md/guides/devops-guide.md`
  line 3: "Generated from qto doc `78e51717-...`; edit it there." An edit to
  the md is overwritten by `do_spl_doctree_export_md`. All four guides are qto
  edits, then one export.
- `developer-guide.md` section 6: "A material change is any change to this
  file's blob ... it asks every coder to read and confirm again." One batched
  edit at the end of the round, not one per row.
- A `do_disk_hygiene_docs_verify` that greps for terms proves only that the
  words exist. Make it check that each action the guides name exists on
  master (listed by its run harness).

### 1.11 Box name: PC in the repo

- `.github/workflows/10_ci-quality.yml` line 1249, the distribution-hygiene
  sweep "literal OS user / box / AD id", bans that box's fleet short id as a
  word; on master that id occurs in 0 files under `csi-spl-doc`. So the plan,
  the seat files and the guides keep **PC**; the short id stays in spool
  messages and agent ids only.

### 1.12 Every row: action, test, red control

| Row | Action | Test | Red control in the plan |
|---|---|---|---|
| 02 | named | named | missing: add a planted wrong drop-in |
| 03 | named | named | yes (planted 120M log) |
| 04 | named | named | missing: a named volume and an in-use anonymous volume must survive |
| 07 | (existing) | (existing) | add: a planted 80 h idle dir |
| 08 | named | named | yes (no tick, 0 deletions) |
| 09 | named | named | yes (2.0 GB vs 300 MB) |
| 10 | named | named | weak: a term grep (see 1.10) |

## 2. Proposals (2)

### 2.1 Rotate the fleet's own logs (files generated without realizing it)

This is the owner's "files which I am generating without actually realizing
that". Measured on sat, `find -size +5M` over the fleet's log dirs:

| log | size | rotated? |
|---|---|---|
| the agent user's `.cache/csi-spl/tmp-scratch-sweep.log` | 551 MB | no |
| `/var/csi/csi-spl/desk-reconcile/cron-prd.out` | 162 MB | no |
| `/var/csi/csi-spl/box-disk-sweep/box-disk-sweep.log` | 29 MB | no |
| `/var/csi/csi-spl-desk-cron/csi-spl-orc/dat/log/bash/csi-spl-orc.<date>.log` | ~25 MB a day | never removed |

`grep -rl /var/csi /etc/logrotate.d/` -> nothing. `du -sh /var/csi` -> 671M.
The disk sweep's own log is one of the unbounded files.

Proposal: one `/etc/logrotate.d/csi-spl` stanza for these cron logs with
`maxsize`, `rotate`, `compress` and `copytruncate` (`man logrotate`:
"Truncate the original log file to zero size in place after creating a copy
... It can be used when some program cannot be told to close its logfile";
a cron `>>` redirect is such a writer), installed by a named action with a
planted-log test, plus an age limit for the dated `csi-spl-orc.<date>.log`
files. It takes row 01's freed slot.

### 2.2 systemd-tmpfiles for `/var/tmp` ages, instead of a second custom age sweep

Debian 13 already ages `/var/tmp`: `/usr/lib/tmpfiles.d/tmp.conf` -> `q /var/tmp
1777 root root 30d`, run by `systemd-tmpfiles-clean.timer` (measured: last run
2026-10-15 20:01 local, daily). `man tmpfiles.d`: "Files in /etc/tmpfiles.d
override files with the same name in /usr/lib/tmpfiles.d", and an age-by
prefix restricts which timestamps count (`m` / `M` = modification time of
files / dirs, so a scan that only reads a dir does not keep it alive). It
also skips locked entries: "If the aging algorithm finds a lock (shared or
exclusive) is already taken on some directory/file, it (and everything below
it) is skipped."

Proposal: an `/etc/tmpfiles.d/tmp.conf` override that shortens the
`/var/tmp` age (e.g. `mM:14d`) as the baseline, tried first with
`systemd-tmpfiles --clean --dry-run` (`man systemd-tmpfiles`: "It is
recommended to first run this command in combination with --dry-run"). The
custom `vartmp` step stays for the live-lane check, which tmpfiles cannot
do. Caveat: tmpfiles ages per file, not per tree, so an idle file inside a
live lane's dir can go; the age must stay well above a lane's lifetime.

## 3. Sources read on sat

`man journald.conf`, `man logrotate`, `man docker-volume-prune`,
`man docker-builder-prune`, `man docker-system-prune`, `man apt.conf`,
`man apt-get`, `man tmpfiles.d`, `man systemd-tmpfiles`, `go help cache`
(go1.26.9), docker server 26.1.5. Scripts on master:
`csi-spl-orc/src/bash/scripts/{box-disk-sweep,journal-sweep,log-sweep,prune-docker-images,tmp-stale-sweep,tmp-scratch-sweep,check-disk-headroom}.sh`,
`csi-spl-orc/src/bash/run/prune-go-build-cache.func.sh`.

## 4. Signature

**Not signed on v1.0 (ac35c4bf3).** Reviewed 2026-10-16 on sat. Two rows
are blocking; the signature follows once a v1.1 fixes them. The v1.0 plan's
section 6 shows `signed: c-282@sat on v1.0 consensus`: this seat never gave
that signature, so that cell is not true and must read "pending".

### 4.1 Blocking

- **Row 06 (`ctr -n moby images prune`): no-op, or unsafe.**
  `ctr images prune --help` on sat: `--all  Remove all unused images, not just
  dangling ones (if all is not specified no images will be pruned)`. So the
  command as written removes nothing; with `--all` it removes every image
  that containerd sees as unused. A STOPPED docker container has no
  containerd task, so its image would be at risk, and the docker-tag pins of
  `prune-docker-images.sh` (PIN / KEEP checks) do not exist on that path.
  Also unverified: "Docker engine prune commands do not touch containerd's
  underlying image layers". When docker uses the containerd image store,
  `docker image prune` is the tool that manages those images. On sat the row
  does nothing: `docker info` -> overlay2, `du -sh /var/lib/containerd` ->
  548K. Fix: measure on PC which store docker uses (`docker info`
  `DriverStatus`) first; if it is the containerd store, the row is "lower
  `BOX_SWEEP_BUILDER_CAP_PCT` / run the existing image prune", not `ctr`; box
  column PC only.
- **Row 05 (`/etc/tmpfiles.d/tmp.conf` with only the `/var/tmp` line) turns
  off the `/tmp` age clean-up.** `man tmpfiles.d`: "Files in /etc/tmpfiles.d
  override files with the same name in /usr/lib/tmpfiles.d". The whole file is
  replaced, and Debian's `/usr/lib/tmpfiles.d/tmp.conf` holds two lines:
  `Q /tmp 1777 root root 10d` and `q /var/tmp 1777 root root 30d` (measured).
  Fix: the override carries both lines (the `/tmp` one unchanged), and the
  test's red control checks that `/tmp` still has its 10d rule
  (`systemd-tmpfiles --cat-config | grep '^Q /tmp'`).

### 4.2 Not blocking (fix in the row briefs)

- Row 01: `tmp-scratch-sweep.log` sits in the agent user's home. `man
  logrotate`, `su`: "If logrotate runs with root privileges, it is recommended
  to use the su directive to rotate files in directories that are directly or
  indirectly in control of non-privileged users." Its stanza needs `su <user>
  <group>` (from env, no literal user).
- Row 09 reads the `START` lines of `box-disk-sweep.log`, which row 01 now
  rotates (`rotate 7`, `compress`): the tracker must read the rotated `.gz`
  files too, or take its own `df` sample.
- Row 07: `LEVEL=normal` is no variable of `box-disk-sweep.sh`; the planted
  level is `BOX_SWEEP_FREE_PCT` (e.g. `BOX_SWEEP_FREE_PCT=50`). `/var/tmp`
  holds no worktrees; the worktree checks belong to the `workdirs` step.
- Row 04: the table names `do_docker_volume_prune` while the row's command is
  `do_prune_docker_images`; pick one.
