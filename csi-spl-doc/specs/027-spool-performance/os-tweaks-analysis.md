# OS Settings and Tweaks Analysis for the Fleet Boxes

- **Version:** `v0.1` (editor draft, not yet reviewed by the panel)
- **Status:** Draft. Analysis only: nothing was changed on any box.
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
measured. The OS-side candidates are smaller and mostly unmeasurable without a
throwaway VM: the CPU vulnerability mitigations (`retbleed`, `SRSO`) and
`init_on_alloc`, both boot parameters. Several popular tweaks were measured
here and **do not help**: transparent huge pages off, `LC_ALL=C`, I/O
scheduler, `noatime`, swap.

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
| Crons | `csi-spl-orc/cnf/box-crons/box-crons.manifest` | `70` active lines in the two user crontabs (`sudo crontab -u <user> -l \| grep -vcE '^\s*(#\|$)'`) |

`git grep -lE 'sysctl\|transparent_hugepage\|limits\.d\|TasksMax\|vm\.swappiness' -- ':!*.md'`
on `78225e997` finds no file that writes a kernel setting: the hits read
`/proc`, set the runner slice, or test those.

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
| swap | none; `vm.swappiness = 60`, `vm.overcommit_memory = 1` | image |
| `/tmp` | tmpfs, `32 G`, `18 G` used (`df -h /tmp`), `nr_inodes=1048576`; no swap behind it | systemd `tmp.mount` (static) |
| data disks | `/` ext4 `relatime,discard` on `sdb`; `/mnt/data`, `/opt`, `/var/csi`, `/var/spool-hub` ext4 `relatime,discard` on `sda` (bind mounts); `fstrim.timer` also active | image + role `01_data_disk` |
| I/O scheduler | `none` on `sda`, `sdb` (virtio SCSI) | kernel default |
| limits | `ulimit -n 524288`, `-u 256960`; `kernel.pid_max = 4194304`, `threads-max = 513920`; `TasksMax` per user slice `169593`; `/etc/security/limits.d` holds only the Debian coredump file | defaults |
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

C probe `fk.c` (`gcc -O2`, `3,000` iterations, `n = 3` runs, load `27..29`):
`getppid()` costs `236..255 ns`; `fork()` + `_exit` + `wait` costs
`595..633 us` wall, `~140 us` kernel; pinned to one CPU with `taskset -c 3` it
is `258..272 us` wall, so about half the unpinned wall is cross-CPU wake-up
and migration on a saturated box.

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

### 2.4 Candidates measured here that do not help

| candidate | measurement | verdict |
|---|---|---|
| THP `never` / `madvise` | 2.2 and 2.3: no gain for short programs or big-Bash forks; `spool` takes `2x` the faults and `+31%` `sys` with THP off | keep `always` |
| `LC_ALL=C` instead of `C.UTF-8` | `grep -ciE` over `2,323` tracked `.sh`, `n = 7` x 2: `C.UTF-8` `69..70 ms` CPU, `C` `81..82 ms` | no gain; keep |
| I/O scheduler, `noatime`, `/tmp` placement, dirty ratios | `iowait 0.34%` over 11 days; I/O PSI `some avg300 4.2%` | below noise; not worth a change |
| swap / zram | memory PSI `0.00`; `38 G` available | no speed gain (see 4, risk row) |
| `pid_max`, `nofile`, `TasksMax`, inotify | `1,869` threads vs `513,920`; inotify `15` of `128` | far from every limit |
| `sudo` without `use_pty` / without syslog | `~6` sudo/s x `18.3 ms` CPU = `0.11` core (`0.7%` of the box); journald `1.1%` of one core | too small to trade a security default |

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
| 1 | Not OS: `./run` lazy action index (Rust rank #3), so forks come from a small Bash | Measured `5.6` -> `0.3 ms` `sys` per fork inside `./run` (`19x`); box-wide est. `20..40%` of `sys` | Medium (Rust analysis rank #3) | `csi-spl-orc/run`, `csi-spl-iac/run` |
| 2 | Kernel command line `retbleed=off spec_rstack_overflow=off` (or `mitigations=off`) | est. `5..20%` of `sys` (Zen 2 return-thunk mitigations sit on every kernel return; `getppid` is `~240 ns` here); A/B on a throwaway `e2-standard-16` | **High**: removes protection between processes of the same VM; agents run third-party code (npm, pip) | new ansible role `12_kernel_cmdline` in `060-gcp-vm-satellite/roles/` (`/etc/default/grub.d/*.cfg`, `update-grub`, reboot); terraform step `060`, owner go |
| 3 | Kernel command line `init_on_alloc=0` | est. `1..5%` of `sys` (zeroing of kernel allocations such as page tables on each fork) | Medium: loses a hardening default against info leaks | same role as #2 |
| 4 | Machine family with a newer CPU (Zen 3/4 needs no `retbleed` return thunk) | est. same order as #2, plus faster cores; not an OS setting | Low technical, cost change | cnf `env.*.machine_type`, terraform `060` |
| 5 | `GOMAXPROCS=1` in the env of short `spool` CLI calls (never the hub server) | Measured `-29%` CPU per call (`n = 60` per arm); box share est. `< 0.5%` | Low (`spool` CLI calls that fan out goroutines lose parallelism) | `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh` |
| 6 | Test Postgres with `-c fsync=off -c synchronous_commit=off` (and data dir on tmpfs) | est. small: `iowait 0.34%`; unmeasured for the `hub-pg` suite | Low (throwaway DB) | `csi-spl-api/src/bash/tests/hub-pg.tst.sh:59`, `csi-spl-api/src/bash/hub-live-stack.sh:59` |
| 7 | `sudo` `Defaults !use_pty` and `!syslog` for the NOPASSWD users | Measured ceiling `0.7%` of the box (all sudo CPU) + `1.1%` of one core (journald) | Medium: `use_pty` guards against terminal injection | role `05_users` sudoers drop-in |
| - | THP off, `LC_ALL=C`, I/O scheduler, `noatime`, swap, raised limits | Measured none (2.4) | - | do not change |

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
4. Whether the `sys` per fork in 2.3 has a kernel-side cause worth a setting
   (cgroup memory accounting, page-table zeroing) that a probe can isolate
   without a reboot.

## 6. Panel and versions

| seat | vendor | version reviewed | verdict |
|---|---|---|---|
| `c-630@sat` | claude (editor) | `v0.1` | author |
| `g-631@sat` | grok | - | - |
| mistral seat | mistral | - | - |
| agy seat (desk box) | agy | - | - |
| codex seat (desk box) | codex | - | - |

The probe scripts are in [os-tweaks-probes/](os-tweaks-probes/), so any seat
can re-run them on its own box.
