# OS Settings and Tweaks Analysis for the Fleet Boxes

- **Version:** `v1.1` (folds the codex seat's FAIL on `v1.0`: the I/O and swap rows were observations, not before/after measurements, and move to 2.6; see 6.1 and 6.2)
- **Status:** Final. Analysis only: nothing was changed on any box.
- **Signed:** `v1.0`: claude (editor), grok (g-631), mistral (m-634). `v1.1`: pending codex (o-805). Queued: agy; to be folded as v1.x.
- **Issue:** `SPL-5393` (Epic `SPL-45`)
- **Spec:** `csi-spl-doc/specs/027-spool-performance` ([spec.md](spec.md))
- **Discussion:** `/t/fe92baa1-eb3e-4174-a52d-54b200bb02a8`, asked from `/t/fc3b7ac3-54cd-4ac4-84b4-5528647fca12`
- **Input:** [rust-candidates-analysis.md](../011-spool-project-refactor/rust-candidates-analysis.md) `v1.0` (`SPL-5274`), section 2
- **Tree:** `78225e997` (`origin/master` at draft time)
- **Box and window of every measurement in this draft:** the satellite box `sat`
  (GCE `e2-standard-16`, 16 vCPU AMD EPYC 7B12, 62 GiB RAM, Debian 13, kernel
  `6.12.115+deb13.1-cloud-amd64`), `2026-11-13T01:14Z..01:22Z`, 1-minute load
  `27..38`, unless a row says otherwise. Every probe was read-only or ran in the
  editor's own scratch directory; per-process A/B switches (`prctl`, env vars)
  changed only the probe process.

## 0. Summary

The kernel time on the satellite box is a **per-process-start cost**, and no
sysctl makes a process start cheap. Over 11 days of `sysstat` history
(`n = 1,583` ten-minute samples) the box ran a mean `1,443` process starts a
second, `41.7%` `sys` against `39.8%` `user` CPU, and `sys` tracks process
starts with Pearson `r = 0.88`: each start costs about `2.9` core-ms of kernel
time. Disk is not the bottleneck (`iowait` `0.34%`, `steal` `0.11%`); the CPU is
(`idle < 5%` in `647` of `1,583` samples, CPU pressure `some avg300 = 36%`).

The largest measured lever is not an OS setting: a `$( )` subshell forked from
a Bash that has sourced the 644 `orc` action files (`68 MB` RSS) costs
`5.6 ms` of `sys` against `0.3 ms` from a plain Bash, `19x`. That is the Rust
analysis's rank #3 (`./run` lazy action index), now with its kernel cost
measured. The cause is page-table work: the Bash heap sits on 4 KiB pages
(`AnonHugePages: 0 kB`), and a fork's kernel cost grows with 4 KiB-mapped memory
(2.5). One env-level setting, `GLIBC_TUNABLES=glibc.malloc.top_pad=134217728`
on the `./run` Bash, puts part of that heap on huge pages and cuts `sys` per
fork by `41%` (measured, no reboot). The other OS-side candidates are boot parameters
(the CPU vulnerability mitigations `retbleed` and `SRSO`, and `init_on_alloc`);
their gain is unknown until a throwaway VM measures it, so they rank below
every measured row. Two popular tweaks were measured here and **do not help**:
transparent huge pages off and `LC_ALL=C` (2.4). Others (I/O scheduler,
`noatime`, `/tmp` placement, dirty ratios, swap, zram) were **not measured
before/after**: the box shows low I/O and memory pressure, so they are low
priority, but their gain is untested (2.6).

## 1. What the box setup sets today

### 1.1 Where the setup lives in the repo

| what | where | sets OS tuning? |
|---|---|---|
| Satellite VM (machine type, image, disks) | `csi-spl-iac/src/terraform/060-gcp-vm-satellite/` (`03-vm.tf`), cnf `env.*.machine_type` (`prd.env.yaml:225` -> `e2-standard-16`) | machine type only |
| Satellite OS setup | ansible `060-gcp-vm-satellite/box-playbook.yaml`, roles `01_data_disk` .. `11_boot_restore` | users and sudoers (`05_users`), timezone, ssh hardening, harness, crons; **no sysctl, kernel command line, THP, limits or cgroup role** |
| Box packages | `csi-spl-iac/cnf/box-pkgs/` (`base-satellite.txt`, `satellite.tsv`), `do_box_pkg_install` | packages only |
| Agent harness | `csi-spl-orc/src/bash/features/spool-install/` (`install.sh`, steps `y1..y20`) | Claude Code settings, guards, hooks; no OS tuning |
| journald cap | `csi-spl-utl` `do_disk_journal_cap` -> `/etc/systemd/journald.conf.d/60-disk-hygiene.conf` (`SystemMaxUse=500M`, `SystemMaxFileSize=100M`) | yes, size only |
| CI runner CPU share | `csi-spl-orc` `do_apply_gh_runner_cpu_budget` (`CPUQuota`/`CPUWeight` `--runtime` on the runner user's slice), `do_gh_runner_add` (`GH_RUNNER_CPU_WEIGHT`) | yes, the only cgroup tuning |
| Crons | `csi-spl-orc/cnf/box-crons/box-crons.manifest` (`45` data rows, `14` every minute) | `70` active lines installed in the two user crontabs (`66` box user, `4` agent user; `20` every minute), so `25` installed lines are not in the manifest. Twenty every-minute jobs are `~0.02%` of the `~106k` starts a minute: thinning crons does not touch this tax (grok seat) |

`git grep -lE 'sysctl\|transparent_hugepage\|limits\.d\|TasksMax\|vm\.swappiness' -- ':!*.md'`
on `78225e997` finds no file that writes a host kernel setting: the hits read
`/proc`, set the runner slice, or test those. One write exists inside a
namespace: `do_gh_runner_add` sets `net.ipv4.ip_local_port_range` in the
rootless dockerd's network namespace (`csi-spl-orc/src/bash/run/gh-runner-add.func.sh:255`),
not on the host, and it does not touch process-start cost (grok seat).

### 1.2 What the box runs with (all defaults unless noted)

Read with `cat /proc/sys/<key>`, `/sys/...`, `findmnt`, `systemctl show`
(`sysctl` is not on `PATH` on the box).

| area | value on the box | set by |
|---|---|---|
| kernel command line | `console=... intel_iommu=off`; no `mitigations=`, `init_on_alloc=`, `nohz_full=` | Debian cloud image |
| CPU mitigations | `retbleed: untrained return thunk`, `spec_rstack_overflow: Safe RET`, `spectre_v2: Retpolines` (`/sys/devices/system/cpu/vulnerabilities/*`) | kernel default for Zen 2 |
| kernel config | `CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y`, `PREEMPT_VOLUNTARY` + `PREEMPT_DYNAMIC`, `HZ=250`, `SCHED_AUTOGROUP=y`, `DEBUG_LIST=y` (`/boot/config-$(uname -r)`) | Debian cloud kernel |
| LSMs | `lockdown,capability,landlock,yama,apparmor,tomoyo,bpf,ipe,ima,evm`; AppArmor `112` profile lines; `auditd` not installed | image |
| THP | `enabled = [always]`, `defrag = [madvise]`; KSM off | kernel default |
| swap | none; `vm.swappiness = 60` | default |
| overcommit | `vm.overcommit_memory = 1`; `Committed_AS 45,234,276 kB` > `CommitLimit 32,924,440 kB` (`01:35Z`), so mode `0`/`2` could fail allocations: leave it | runtime value; no file sets it (`sudo grep -RlsE overcommit /etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d /run/sysctl.d /etc/systemd /usr/lib/systemd /etc/docker /etc/default` -> none) |
| `/tmp` | tmpfs, `32 G`, `18 G` used (`df -h /tmp`), `nr_inodes=1048576`; no swap behind it | systemd `tmp.mount` (static) |
| data disks | `/` ext4 `relatime,discard` on `sdb`; `/mnt/data`, `/opt`, `/var/csi`, `/var/spool-hub` ext4 `relatime,discard` on `sda` (bind mounts); `fstrim.timer` also active | image + role `01_data_disk` |
| I/O scheduler | `none` on `sda`, `sdb` (virtio SCSI) | kernel default |
| limits | `nofile` hard `524288`; soft depends on how the process started: per-process census (grok seat, `01:44Z`, `/proc/<pid>/limits`): box user soft `1024` x `259`, `524288` x `79`, `524287` x `4`, `1073741816` x `6`; agent user soft `1024` x `42`, `524288` x `47`, `524287` x `2`, `65536` x `10` (`27` unread). `1024` matches cron's own limit; a fresh `bash -lc 'ulimit -Sn'` inherits its caller (`65536` from the grok seat, `524288` from the editor's), so where the `524288` group comes from is not identified; `ulimit -u 256960`; `kernel.pid_max = 4194304`, `threads-max = 513920`; `TasksMax` per user slice `169593`; `/etc/security/limits.d` holds only the Debian coredump file | defaults |
| inotify | `max_user_instances = 128`, `max_user_watches = 507546`; in use: `15` instances (agent user), `13` (box user) | default |
| sysctl drop-ins | `/etc/sysctl.d/60-gce-network-security.conf` (network hardening, `kernel.randomize_va_space=2`, `kernel.panic=10`), `/usr/lib/sysctl.d/50-pid-max.conf` | GCE image |
| cgroups | v2; user slices of the box user and the agent user: `CPUWeight` unset (100), `MemoryMax=infinity`; runner user slice `CPUWeight=25` | `do_gh_runner_add` for the runner only |
| sudo | `Defaults env_reset, mail_badpass, secure_path, use_pty`; `sudo 1.9.16p2`; NOPASSWD per user in `/etc/sudoers.d/90-<user>-nopasswd` | Debian + role `05_users` |
| journald | `SystemMaxUse=500M`; `40M` in use | `do_disk_journal_cap` |
| timers | `sysstat-collect` (10 min), `apt-daily*`, `logrotate`, `fstrim`, `e2scrub_all`, `man-db`, `dpkg-db-backup`, `google-oslogin-cache` | image |
| tuned, irqbalance, earlyoom, systemd-oomd | not installed or inactive | - |
| locale | `LANG=C.UTF-8` for both users | image |

## 2. What fits the load

### 2.1 The load, measured

| measure | value | `n` | command |
|---|---|---:|---|
| process starts / s, 11 days | mean `1,443`, median `1,443`, p90 `2,118`, max `3,141` | `1,583` samples | `sadf -d /var/log/sysstat/saNN -- -w -u`, `2026-11-01T22:10Z..11-12T22:00Z` |
| CPU split, 11 days | `user 39.8%`, `sys 41.7%`, `iowait 0.34%`, `steal 0.11%`, `idle 16.9%` (median `7.9%`) | `1,583` | same |
| `sys` vs starts | Pearson `r = 0.88`; slope `18.3` `%sys` per `1,000` starts/s = **`2.93` core-ms `sys` per start**; intercept `15.3%` | `1,583` | least squares over the same rows |
| `user` vs starts | `r = 0.40`; `1.62` core-ms `user` per start | `1,583` | same |
| context switches / s | mean `37,881` | `1,583` | same |
| pressure (PSI) | CPU `some avg300 36.23`, memory `0.00`, I/O `some avg300 4.20` | 1 | `cat /proc/pressure/{cpu,memory,io}` at `01:16Z` |
| new pids in 30 s | `58,096` kernel starts; by `comm` of `30,578` seen: `bash 13,037`, `run 6,551`, `dirname 927`, `sed 798`, `grep 772`, `jq 723`, `awk 619`, `tail 324`, `cat 312`, `sort 243`, `timeout 230`, `sleep 195`, `yq 165`, `git 161`, `sudo 142`, `python3 128` | 1 (30 s, load `38`) | `pidscan.py` (scan `/proc` every 10 ms; a lower bound, `2,960` exited before read) |
| sudo calls | `3,594` `COMMAND=` lines in 10 min (`~6 /s`), `11,484` sudo journal lines | 1 | `sudo journalctl --since -10min _COMM=sudo` |
| journald CPU | `34` ticks in 30 s = `1.1%` of one core | 1 | `/proc/$(pidof systemd-journald)/stat` fields 14+15 |

Reading: the box is CPU-bound, about half of the CPU is kernel time, and the
kernel time follows process starts. Most starts are Bash forks (`bash`, `run`:
`19,588` of `30,578` seen) rather than new programs.

### 2.2 Per-start cost, measured on the box

Probe: `bench.py` forks, `exec`s the command `40` times, `getrusage(RUSAGE_CHILDREN)`
for CPU and minor faults; the `thp off` arm sets `prctl(PR_SET_THP_DISABLE)` in
the child before `exec` (inherited, so the child runs with THP off; nothing
outside the probe changes). Load `29`, `01:15Z`.

| command | wall med (ms) | usr (ms) | sys (ms) | minor faults | THP off: wall / sys / faults |
|---|---:|---:|---:|---:|---|
| `/bin/true` | 3.7 | 1.29 | 1.49 | 314 | 3.7 / 1.77 / 345 |
| `bash -c :` | 6.8 | 1.67 | 3.10 | 449 | 5.8 / 3.86 / 476 |
| `awk 'BEGIN{}'` | 5.0 | 1.23 | 2.78 | 400 | 5.0 / 2.95 / 426 |
| `jq -n .` | 8.5 | 2.71 | 3.83 | 601 | 7.5 / 3.65 / 627 |
| `git --version` | 5.6 | 1.57 | 2.82 | 445 | 5.7 / 2.87 / 471 |
| `python3 -c pass` | 21.6 | 11.79 | 7.40 | 1,119 | 23.4 / 7.09 / 1,144 |
| `python3 -I -S -c pass` | 17.3 | 8.23 | 6.32 | 967 | 18.0 / 5.52 / 993 |
| `spool` (Go CLI, error path) | 57.0 | 31.50 | 18.89 | 1,980 | 58.4 / 24.78 / 4,057 |
| `sudo -n -u <box-user> true` | 20.7 | 8.03 | 10.31 | 1,197 | 22.5 / 10.17 / 1,223 |

C probe `syscall.c` (`2,000,000` `getppid()` calls, `n = 3`, load `26..29`):
`236..255 ns` per call (grok seat: `255.1 ns`, `252.6 ns` pinned, load `43`).
C probe `fk.c` (`gcc -O2`, `3,000` iterations, `n = 3` runs, load `27..29`):
`fork()` + `_exit` + `wait` costs `595..633 us` wall, `~140 us` kernel; pinned
to one CPU with `taskset -c 3` it is `258..272 us` wall. The unpinned excess
is cross-CPU wake-up and migration, and it grows with load: about half at
load `27..29`, `69%` at load `50` (grok seat: `869` vs `267 us`).

### 2.3 The fork from a big Bash (the dominant kernel cost)

Probe: `forkbash.sh` runs `500` `x=$(:)` subshells, either in a plain Bash or
after `source`-ing every `csi-spl-orc/src/bash/run/*.func.sh` (`644` files, what
`./run` does on every start), under the same `prctl` THP arms. Source-only
cost subtracted (`src-only.sh`, `n = 3`: `0.32..0.36 s` `sys`). Load `32..34`,
`01:19Z`, `n = 2` per arm.

| parent Bash | RSS / page tables | wall per fork | `sys` per fork | THP off |
|---|---|---:|---:|---|
| plain | `3.1 MB` / `48 kB` | `0.9..1.6 ms` | `0.3 ms` | same |
| after sourcing 644 `orc` action files | `68.7 MB` / `172 kB` | `7.3..7.8 ms` | **`5.6 ms`** | `8.1..8.7 ms`, `4.9..6.0 ms` |

Each `$( )`, pipeline stage or `( )` in a script that runs inside `./run`
pays this. It explains why the box-wide figure (`2.9` core-ms per start) sits
far above the cost of starting a small program (`1.5..3.9 ms` `sys` in 2.2).

### 2.5 Why the big-Bash fork is expensive, and a per-process fix

Probe `fkheap.c`: a C parent fills a heap of the given size, then forks `300`
children that `_exit` at once (or first write one byte every 64 pages). The
`thp off` arm calls `madvise(MADV_NOHUGEPAGE)` on that heap only. Load `24`,
`01:27Z`, `n = 1` per row.

| parent heap | huge pages | parent `sys` + child `sys` per fork | wall per fork |
|---|---|---:|---:|
| `0 MB` | - | `153 us` | `443 us` |
| `64 MB` | yes (THP `always`) | `301 us` | `843 us` |
| `64 MB` | no (4 KiB pages) | `4,519 us` | `5,667 us` |
| `256 MB` | yes | `465 us` | `1,369 us` |
| `256 MB` | no | `23,278 us` | `28,970 us` |
| `64 MB`, child writes 1 page in 64 | yes / no | `1,260` / `7,224 us` | `3,650` / `9,651 us` |

So a fork's kernel time grows with 4 KiB-mapped memory: `68 us` per MB from
`0` to `64 MB` and `98 us` per MB from `64` to `256 MB` in this table (`n = 1`
each); the grok seat's re-runs (load `57`) gave `59` and `78 us` per MB for
the first `64 MB`. On huge pages it is `15x` less at `64 MB`. The `./run` Bash (`thpcheck.sh`) has
`Rss 69,252 kB, AnonHugePages 0 kB`: its heap grows by small `sbrk` steps, so
no fault ever lands in a free, aligned 2 MiB range, and THP `always` never
applies. `GLIBC_TUNABLES=glibc.malloc.hugetlb=1` alone changes nothing
(`AnonHugePages 0 kB`; `sys` per run `2.86..3.08 s` vs `2.97..3.04 s`).

`glibc.malloc.top_pad` makes `malloc` grow the heap in large steps, which lets
THP back it. `forkbash.sh 1` (500 forks), `n = 3` per arm, interleaved, load
`25..28`, `01:29Z`; source-only cost subtracted per arm (`0.34 s` none,
`0.27 s` with the pad):

| `GLIBC_TUNABLES` | `AnonHugePages` | `sys` per fork | `usr + sys` per fork | wall per fork |
|---|---:|---:|---:|---:|
| none | `0 kB` | `5.1 ms` (`2.80..2.91 s` per run) | `5.8 ms` | `6.0..6.7 ms` |
| `glibc.malloc.top_pad=134217728` | `14,336 kB` | **`3.0 ms`** (`1.64..1.92 s`) | **`4.1 ms`** | **`4.0..4.8 ms`** |
| `glibc.malloc.hugetlb=1:glibc.malloc.top_pad=33554432` | `14,336 kB` | `2.9..3.3 ms` (`1.73..1.98 s`) | - | `4.7..5.4 ms` |

`-41%` `sys`, `-30%` CPU and `-33%` wall per fork, with RSS `+0.5..1.7 MB`. A
plain `bash -c :` under the same pad keeps `Rss 3,088 kB, AnonHugePages 0 kB`
(the pad reserves address space; pages are only used when touched). Only
`14 MB` of the `69 MB` lands on huge pages; the rest was allocated before the
heap crossed an aligned 2 MiB range, so a better placement may gain more
(open item 5.4).

The grok seat's Python probe agrees (`01:45Z`, load `49`, `n = 40`): a parent
that touched a `64 MB` `bytearray` had `AnonHugePages 63,488 kB` and forked
with `614 us` parent and `562 us` child `sys`, the huge-page arm of
`fkheap.c`. Its page tables still grew `128 kB`, so page-table size alone is
not the discriminator; 4 KiB-mapped memory is. The cost sits in memory on 4 KiB pages, which is what the
Bash heap is.

### 2.4 Candidates measured here that do not help

| candidate | measurement | verdict |
|---|---|---|
| THP `never` / `madvise` | 2.2 and 2.3: no gain for short programs or big-Bash forks (their heap is not on huge pages at all, 2.5); `spool` takes `2x` the faults and `+31%` `sys` with THP off | keep `always`; 2.5 shows huge pages help, so turning them off is the wrong direction |
| `LC_ALL=C` instead of `C.UTF-8` | `grep -ciE` over `2,323` tracked `.sh`, `n = 7` x 2: `C.UTF-8` `69..70 ms` CPU, `C` `81..82 ms` | no gain; keep |
| `pid_max`, `nofile`, `TasksMax`, inotify | `1,869` threads vs `513,920`; inotify `15` of `128` | far from every limit |
| `sudo` without `use_pty` / without syslog | `~6` sudo/s x `18.3 ms` CPU = `0.11` core (`0.7%` of the box); journald `1.1%` of one core | too small to trade a security default |

### 2.6 Candidates not measured before/after: untested, low priority

No setting in this table was changed and compared, on the box or in a
throwaway copy. The reading is an observation of low pressure, which says
the setting has little to act on; it is not a measured gain or a measured
absence of one (codex seat, 6.1).

| candidate | reading (observation, not a before/after) | verdict |
|---|---|---|
| I/O scheduler, `noatime`, `/tmp` placement, dirty ratios | `iowait 0.34%` over 11 days (`n = 1,583`); I/O PSI `some avg300 4.2%` (`n = 1`) | untested; low observed I/O pressure; low priority. A gain needs a controlled throwaway A/B first |
| swap / zram | memory PSI `0.00`; `38 G` available (`n = 1`) | untested; low observed memory pressure; low priority (see 4, the `/tmp` risk note) |

## 3. What the Rust analysis implies for the OS, and what only code fixes

| finding (Rust analysis section 2) | OS lever? | why |
|---|---|---|
| `90k..112k` starts/min, `45%` `sys` (`n = 1`) | Confirmed at scale: `1,443` starts/s mean, `41.7%` `sys`, `r = 0.88` (`n = 1,583`) | The kernel work is per start; only fewer starts, or cheaper starts, cut it |
| `./run` floor `1.0 s` CPU, `162` procs | **No; code** (rank #3 lazy index) | 2.3: a fork from the loaded Bash costs `19x` the `sys` of a plain one. The lazy index shrinks the parent, so every later fork in that action gets cheaper too, a gain the Rust analysis did not count |
| Test suites at `36k..40k` procs per file, `sys > user` | **No; code** | Same big-Bash fork cost; tests call `./run` and `$( )` in loops |
| `spool` CLI startup `155 ms` under load | Small env lever | `GOMAXPROCS=1` for short CLI calls: `48.4..49.9 ms` -> `32.2..34.9 ms` CPU per call (`-29%`), wall `50.7..55.2` -> `38.8..44.0 ms` (`spool version`, `n = 20` x 3 interleaved, load `37`). Total gain is small (`spool` was under the top-25 `comm` list in 30 s) |
| Python cold starts in guards (`29..38 ms`) | No | `-I -S` saves `~5 ms` CPU (2.2), already used where it matters |
| Wall time inflated by load `78..151` | Partly | Half of a fork's wall is migration on a saturated box (2.2); a scheduler setting cannot add cores. CPU weight per slice (as the runner slice has) can only move who waits |

## 4. Ranked list

Gain is a share of the box's kernel (`sys`) time unless the row says otherwise.
`est.` = not measured on this box: a before/after needs a reboot with a changed
kernel command line, which only a throwaway VM allows (a GCP change: the owner's
go first).

| # | setting | expected gain | risk | where it would be configured |
|---:|---|---|---|---|
| 1 | Not OS: `./run` lazy action index (Rust rank #3), so forks come from a small Bash | Measured `5.1..5.6` -> `0.3 ms` `sys` per fork inside `./run` (`n = 2..3` per arm). Box-wide lower bound: new pids named `run` (a directly executed `./run` and its subshells; `bash script` stays `bash`, so the `bash` band is not counted) whose RSS was `>= 60 MB` when read (`pidscan-rss.py`, 30 s, `n = 3`: `4,349` at `01:59Z`, load `24`, grok seat; `6,443` and `6,836` at `02:01Z`, load `33..35`, editor) = `>= 145 /s`; `145 x 4.8 ms` = `0.70` cores = `>= 10%` of the box's `6.7` cores of `sys` (`41.7% x 16`). Assumes those forks cost like the `69 MB` parent of 2.3; exited pids (`5,125..9,035` per run) not counted | Medium (Rust analysis rank #3) | `csi-spl-orc/run`, `csi-spl-iac/run` |
| 1b | `GLIBC_TUNABLES=glibc.malloc.top_pad=134217728` exported by `csi-spl-orc/run` and `csi-spl-iac/run` before they source the action files (also usable by the Bash test runners) | Measured `-41%` `sys`, `-33%` wall per fork inside `./run` (2.5, `n = 3` per arm); box-wide lower bound `145 /s x 2.1 ms` = `0.30` cores = `>= 4.5%` of `sys` (same count and assumption as row 1) until row 1 lands, less after | Low: per-process, no reboot, rollback = drop the export; RSS `+0.5..1.7 MB` per `./run`; children inherit it (programs that `malloc` a lot keep a larger free top) | `csi-spl-orc/run`, `csi-spl-iac/run` (a code change, not a box setting; a box-wide `/etc/environment` line would reach every glibc program and is not proposed) |
| 2 | Kernel command line `retbleed=off spec_rstack_overflow=off` (the two still active; `meltdown`, `mds`, `l1tf`, `mmio`, `tsx`, `srbds`, `tsa` read `Not affected`) | Unknown: not computed, not measured. Only a throwaway `e2-standard-16` A/B can give it; never on a fleet box | **High**: removes protection between processes of the same VM; agents run third-party code (npm, pip) | new ansible role `12_kernel_cmdline` in `060-gcp-vm-satellite/roles/` (`/etc/default/grub.d/*.cfg`, `update-grub`, reboot); terraform step `060`, owner go |
| 3 | Kernel command line `init_on_alloc=0` | Unknown: not measured (it zeroes kernel allocations such as page tables on each fork); same throwaway A/B | Medium: loses a hardening default against info leaks | same role as #2 |
| 4 | Machine family with a newer CPU (Zen 3/4 needs no `retbleed` return thunk) | Unknown: not measured; not an OS setting | Low technical, cost change | cnf `env.*.machine_type`, terraform `060` |
| 5 | `GOMAXPROCS=1` in the env of short `spool` CLI calls (never the hub server) | Measured `-29%` CPU per call (`n = 60` per arm); box share est. `< 0.5%` | Low (`spool` CLI calls that fan out goroutines lose parallelism) | `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh` |
| 6 | Test Postgres with `-c fsync=off -c synchronous_commit=off` (and data dir on tmpfs) | est. small: `iowait 0.34%`; unmeasured for the `hub-pg` suite | Low (throwaway DB) | `csi-spl-api/src/bash/tests/hub-pg.tst.sh:59`, `csi-spl-api/src/bash/hub-live-stack.sh:59` |
| 7 | `sudo` `Defaults !use_pty` and `!syslog` for the NOPASSWD users | Measured ceiling `0.7%` of the box (all sudo CPU) + `1.1%` of one core (journald) | Medium: `use_pty` guards against terminal injection | role `05_users` sudoers drop-in |
| - | THP off, `LC_ALL=C`, raised limits | Measured none (2.4) | - | do not change |
| - | I/O scheduler, `noatime`, `/tmp` placement, dirty ratios, swap, zram | Not measured before/after; low observed pressure (2.6) | - | untested, low priority; no change without a throwaway A/B |

Not a speed item, but a risk the measurement found: `/tmp` is a `32 G` tmpfs
with `18 G` used and **no swap** behind it, so a full `/tmp` competes with
every process for RAM (the CI workflow already moves job temp off it,
`.github/workflows/10_ci-quality.yml:280`).

## 5. Open for the panel

1. The desk box: the same probes (`fk.c`, `bench.py`, the `sadf` regression)
   on a different CPU and load, to separate mitigation cost from load.
2. A measured `hub-pg` suite run with and without `fsync=off` in a throwaway
   container (row 6).
3. Anything in section 1 that is wrong, or a setting missing from section 4.
4. Editor, v0.2: the cause in 2.3 is the 4 KiB page-table work on fork
   (2.5), and `glibc.malloc.top_pad` moves `14 MB` of `69 MB` onto huge pages.
   Open: a setting or allocation shape that puts more of the Bash heap on huge
   pages, still per process and without a reboot.

## 6. Panel and versions

| seat | vendor | version reviewed | verdict |
|---|---|---|---|
| `c-630@sat` | claude (editor) | `v0.1` .. `v0.5` | author; signs `v1.0` |
| `g-631@sat` | grok | `v0.1` (`411c67e4b`), `v0.3` (`3651b0aa7`), `v0.4` (`0a9a6cf35`), `v0.5` (`bf98fb3e7`) | CHANGES three times (6, 3, then 1 line), all folded in `v0.3`, `v0.4` and `v0.5`; SIGN `v0.5` (msg `f3da1b7b`) |
| `m-634@sat` | mistral | `v1.0` (`0a50cbb88`) | PASS, signs `v1.0`; its additions (`vm.min_free_kbytes`, soft `nofile`) are held by the dispatch holder for a later fold |
| agy seat (desk box) | agy | - | queued; folds as `v1.x` |
| `o-805` (desk box) | codex | `v1.0` (`0a50cbb88`) | FAIL (msg `0fef8e87`): 2.4 called observations measurements; folded in `v1.1` (6.1); desk box notes in 6.2 |

The probe scripts are in [os-tweaks-probes/](os-tweaks-probes/), so any seat
can re-run them on its own box.

### 6.1 Folds

- `v0.3`, grok seat `g-631@sat` (review of `v0.1`, msg `1a53dc83`): soft
  `nofile` is not `524288` for every process (the editor re-measured the
  per-process spread, 1.2); `overcommit_memory` has no file behind it; the
  rootless-netns port-range write is named (1.1); `getppid` has its own probe,
  `syscall.c`; the migration share depends on load (2.2); `mitigations=off`
  and every uncomputed gain are removed, and rows 1 and 1b carry their
  arithmetic (4); manifest vs installed crons (1.1); its Python fork probe
  corroborates 2.5. It also confirmed, independently: a `/proc/stat` window at
  `01:25Z` (`20 s`, `1,766` starts/s, `sys 54.7%`), THP fault and compaction
  counters (`thp_fault_alloc` `0.019%` of faults, `compact_stall 0`), the cgroup
  weights, the kernel config and the inotify counts.
- `v0.4`, grok seat (review of `v0.3`, msg `d1d8aaac`): the limits census
  replaces the editor's `bash -lc` claim (that command inherits its caller);
  the per-MB fork cost is stated per step, not as a flat `70 us`; rows 1 and
  1b counted forks by name only (`run` includes small processes: `48` of `181`
  live ones were `>= 60 MB`), so the editor re-counted with RSS
  (`pidscan-rss.py`) and the bounds fell from `16%` / `7%` to `11%` / `5%`.
  Its `fkheap` re-runs and the Python `AnonHugePages` check confirm 2.5.
- `v0.5`, grok seat (review of `v0.4`, msg `b3a04e26`): rows 1 and 1b added
  the `bash` `>= 60 MB` band to the `./run` gain, but `bash script` keeps comm
  `bash`, so that band is not the `./run` parent. Both rows now count the `run`
  band only: its scan (`4,349`, `01:59Z`) plus two editor re-runs (`6,443`,
  `6,836`, `02:01Z`), lowest taken, and the bounds fell from `11%` / `5%` to
  `10%` / `4.5%`. It confirmed the `v0.4` arithmetic and reproduced the scan's
  magnitude.
- `v1.0`: grok seat signed `v0.5` (msg `f3da1b7b`); the text is unchanged.
  Per the orchestrator's ruling (msg `98f598d3`), `v1.0` lands on two signatures
  of five. The mistral, codex and agy seats are still queued; each reviews `v1.0`
  and its findings fold as `v1.x` with credit.
- `v1.1`, codex seat `o-805` (review of `v1.0`, msg `0fef8e87`, FAIL): the
  2.4 rows for the I/O scheduler, `noatime`, `/tmp` placement, dirty ratios,
  swap and zram cited only observed `iowait`, I/O PSI and memory PSI, not a
  before/after of any setting. Those readings show low pressure, not "no
  speed gain". The rows move to 2.6 (untested, low priority), the summary (0)
  and the last row of section 4 say the same. The THP, `LC_ALL`, limits and
  `sudo` rows stay in 2.4: they rest on A/B probes or counts against the
  limit. No throwaway comparison was run for `v1.1`. The mistral seat's PASS
  on `v1.0` (msg `77953ee2`) is recorded in the table above.

### 6.2 v1.x notes: the desk box (codex seat)

Readings by the codex seat `o-805` on the desk box, a different box from the
satellite box every other row measures. One probe, `n = 1`,
`2026-11-13T06:25Z..06:26Z` (msg `0fef8e87`). Not re-measured by the editor;
they do not contradict the satellite box rows, they describe another box.

| area | desk box reading | satellite box (1.2) |
|---|---|---|
| THP | `enabled = [always]` | same |
| swap | active, `~11.8 GB` used, `~39.5 GB` `MemAvailable` | none |
| journald | `SystemMaxUse=2G`, `174.1M` in use | `SystemMaxUse=500M`, `40M` in use |

Finding for the dispatch holder, not fixed here: the desk box runs journald
with `SystemMaxUse=2G`, while the repo action that sets the cap,
`do_disk_journal_cap` (`csi-spl-utl/src/bash/run/disk-journal-cap.func.sh`),
describes and defaults to `500M` (`JOURNAL_CAP_MAX_USE`). Either the action
did not run there or something overrides it; which one is not established.
