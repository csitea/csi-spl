# The orc `./run` start, split into its parts

Issue: SPL-5984. Epic: SPL-2402. Discussion: `/t/100cf095-2329-4ce7-a2de-8427eda7d463`
(owner answer A, msg 4de3e6b3: "Measure first: one lane splits the 1.20 s of
the orc ./run start (n >= 3), names the biggest part, and files ONE issue for
its Rust replacement").

Rust issue filed from this split: **SPL-5985**.

## 1. Method

- Tree: `origin/master` `23864a224`, `git archive` into a scratch copy that
  keeps the layout (`<base>/csi/csi-spl/csi-spl-orc`). Nothing here was
  committed to the repo except this file.
- Box: the satellite box (16 vCPU), the one `os-tweaks-analysis.md` 4.1
  measured on. The runs started at `2026-11-19T17:46:58Z` and ended at
  `17:47:21Z`, with a 1-minute load of `5.6..6.3`.
- Probe: the method of `os-tweaks-analysis.md` 4.1, with one action file
  added to the copy (`probe-start.func.sh`, `do_probe_start() { return 0; }`,
  which forks nothing). The command was `./run -a do_probe_start >/dev/null 2>&1`,
  with stdout not a terminal (compact log mode, as an agent runs it). The
  index cache was warmed by one run first, so every measured run is a cache hit.
- Total: wall time from the driver's `$EPOCHREALTIME` before the fork to the
  same clock after `./run` returned.
- Split: a second copy of `run.sh` with 32 timestamp marks added
  (`printf ... "$EPOCHREALTIME" >>"$RUN_T_FILE"`, a builtin, no fork) at
  every step of `main`, `do_set_vars`, `main_exec`, `do_load_functions`,
  `_rl_index`, `execute_step` and `do_wait_tees`, plus one mark after each
  eager `source`. A part is the time between two marks.
- n: 25 runs (5 rounds of 5). The plain and the marked copy alternated by
  round. Values are min..max (median).
- Fork count of the eager step: one more copy with `set -x` and
  `PS4='+${BASHPID} '` around that loop only (n = 3, used for counting only,
  never for timing).

## 2. Total

| copy | n | load | wall ms |
|---|---|---|---|
| plain `run.sh` (the total) | 25 | `5.6..6.3` | `347..459` (`375`) |
| marked `run.sh` (the split) | 25 | `5.6..6.2` | `357..505` (`377`) |

The marks add about 2 ms to the median.

**The 1.20 s does not reproduce: the start is now 0.38 s.** The spec's
`1144..1298 (1204)` ms was measured on 2026-11-13 at a load of `31..46`,
before the per-user index cache (row 1c, `os-tweaks-analysis.md` 4.1)
existed. A cache miss, measured here with an empty `XDG_CACHE_HOME` per run
(n = 15, load `5.1..5.3`), is `476..509` (`491`) ms: the `awk` index pass
costs `168` ms where a hit costs `41`. I did not measure the rest of the gap
to 1.20 s at a load of 31..46, and the box was not loaded on purpose for
this. The cost of a fork grows with load (`os-tweaks-analysis.md` 2.2), so
the shares below are the better guide.

## 3. The parts

The line numbers are for `csi-spl-orc/src/bash/run/run.sh` at `23864a224`.
The share is the part's median over the total's median (`377` ms).

| part | where | ms | share |
|---|---|---|---|
| fork + exec of `./run`, Bash start | (kernel, `bash`) | `1.8..3.1` (`2.4`) | 0.6% |
| parse `run.sh` up to `main` | `run.sh:1-1020` | `3.8..5.2` (`4.1`) | 1.1% |
| `do_root_dispatch` | `run.sh:271-298` | `0.2..0.3` (`0.3`) | 0.1% |
| re-exec for `GLIBC_TUNABLES` (row 1b) | `run.sh:246-255` | `1.6..2.8` (`1.8`) | 0.5% |
| parse `run.sh` again, after the re-exec | `run.sh:1-1020` | `3.7..5.1` (`4.0`) | 1.1% |
| `do_root_dispatch` again | `run.sh:271-298` | `0.2..0.5` (`0.3`) | 0.1% |
| stdout and log mode | `run.sh:203-233` | `0.1..0.2` (`0.1`) | 0.0% |
| `do_set_vars`: `perl` that resolves `$0` | `run.sh:783-787` | `10.1..14.8` (`11.1`) | 2.9% |
| `do_set_vars`: four `$(cd .. && pwd)` | `run.sh:792-796` | `4.1..5.8` (`4.8`) | 1.3% |
| `do_set_vars`: the rest, `$(hostname -s)` | `run.sh:797-815` | `2.6..4.8` (`3.1`) | 0.8% |
| `ts=$(date ...)` | `run.sh:412` | `2.7..7.7` (`3.1`) | 0.8% |
| `mkdir -p` of the log dir | `run.sh:414` | `1.9..3.0` (`2.4`) | 0.6% |
| the two tees | `run.sh:420-429` | `0.8..1.2` (`1.0`) | 0.3% |
| index cache key (`find`, `sort`, `md5sum`) | `run.sh:953-958` | `8.0..21.6` (`9.0`) | 2.4% |
| source the cached index (stubs) | `run.sh:959-961` | `37.6..64.2` (`41.1`) | 10.9% |
| **source the 88 eager `*.func.sh`** | `run.sh:985-988` | `178.9..261.4` (`188.2`) | **49.9%** |
| `_func_to_file` map (`declare -F` loop) | `run.sh:989-992` | `19.1..30.4` (`20.1`) | 5.3% |
| `do_detect_base_paths` (lazy load + write probe) | `lib/bash/funcs/detect-base-paths.func.sh` | `8.0..15.2` (`9.0`) | 2.4% |
| `do_load_config` | `lib/bash/funcs/load-config.func.sh` | `0.7..1.2` (`0.9`) | 0.2% |
| `do_require_bins` | `run.sh:490-493` | `1.0..2.2` (`1.5`) | 0.4% |
| `do_verify_symlinks` | `lib/bash/funcs/verify-symlinks.func.sh` | `0.3..0.5` (`0.3`) | 0.1% |
| `do_run_actions` up to `execute_step` (2 `do_log`) | `run.sh:523-586` | `13.2..20.7` (`16.2`) | 4.3% |
| `execute_step`: PRE hook, START log, flag parse | `run.sh:138-156` | `6.6..11.2` (`8.3`) | 2.2% |
| `execute_step`: `do_validate_params` | `run.sh:157-167` | `8.2..14.8` (`9.3`) | 2.5% |
| the probe action itself | `probe-start.func.sh` | `0.2..0.3` (`0.3`) | 0.1% |
| `execute_step`: STOP log, POST hook | `run.sh:168-188` | `7.8..10.2` (`8.8`) | 2.3% |
| `do_finalize` (1 `do_log`) | `run.sh:824-828` | `5.1..7.0` (`6.0`) | 1.6% |
| `do_wait_tees` (EXIT trap, `sleep 0.01` poll) | `run.sh:463-473` | `14.2..15.6` (`15.0`) | 4.0% |
| exit back to the caller | (kernel) | `3.3..5.1` (`3.8`) | 1.0% |
| **sum of the parts** | | `357.1..504.9` (`376.9`) | **99.9%** |

What is left: the gap between `do_verify_symlinks` and `do_run_actions`, under
0.1 ms per run, which no mark covers.

### 3.1 Inside the biggest part

The eager step sources 91 files: the 88 `*.func.sh` that the lazy loader
cannot defer (they run code at top level) and two `.inc.sh` files they pull
in (`spawn-agents/lib/spool-env.inc.sh`, `proc-owner.inc.sh`). Together that
is 27,998 lines, or 1.55 MB of Bash, parsed on every start. The `set -x`
copy saw 17 subshell forks in this step (n = 3, the same each time), from
`$(dirname ...)`, `$(readlink -f ...)` and `$(cd ... && pwd)` at top level.
At about 3 ms per fork plus exec (the `date` part above), they are roughly
40..50 ms of the 188. This is an estimate, not a measurement. The rest of
the step is the parse itself. The slowest files, median ms:
`spl-agent-settings-check` `20.3` (it sources `spool-env.inc.sh`),
`spl-box-restart-prepare` `14.7`, `spl-dispatch-lease` `11.8` (3,082
lines), `spl-wd-peers` `9.8`, `spl-asks-open` `9.7`, `spl-wd-ensure` `9.3`.

## 4. The biggest part, and the Rust issue

- **The biggest part is the eager source step (50%), and no binary can
  replace it.** It is Bash reading function definitions into the running
  shell, and no other process can do that work for it. The second-biggest
  part, sourcing the cached index (11%), is the same kind of work. Their fix
  is in Bash: make the eager files lazy (the "Still eager" follow-up in
  `os-tweaks-analysis.md` 4.1), and drop the top-level `$(...)` forks.
- **The biggest part a binary can replace** is the path step of
  `do_set_vars`: `perl`, the four subshells and `hostname`, `17.1..24.6`
  (`19.1`) ms, 5.1% (n = 25). One Rust exec would print the same values.
  Using the `date` part above as a proxy, one fork plus exec of the loaded
  `./run` costs `3.1` ms, so the gain would be about 16 ms per start, about
  4%. This is an estimate, not a measurement. The issue (SPL-5985) carries
  the dispatcher's fallback table: the Bash path stays and is tested both
  ways.
- Smaller Bash-only items the split shows, not filed: `do_log` forks
  `$(printf ...)` on every call (`do_run_actions`, `execute_step` and
  `do_finalize`, the parts that hold its 5 calls, are 39 ms together; not split further), the `sleep 0.01`
  poll in `do_wait_tees` (15 ms), and the `_func_to_file` loop (20 ms), which
  the index cache could hold instead.
