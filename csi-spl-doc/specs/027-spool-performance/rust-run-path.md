# The `./run` path step as one Rust exec (spl-run-path)

Issue: SPL-5985. Epic: SPL-2402. Measured first by SPL-5984
([run-start-split.md](run-start-split.md) section 4: the path step of
`do_set_vars` is `17.1..24.6` (`19.1`) ms, 5.1% of the orc start, n = 25).
Discussion: `/t/100cf095-2329-4ce7-a2de-8427eda7d463` (owner answer A, msg
4de3e6b3, holds the fallback rule; owner poll answer 326f5622: build it).

## 1. What it replaces

`do_set_vars` in `run.sh` (orc, iac, utl and the repo root, byte-identical)
set seven values with one `perl`, four `$(cd ... && pwd)` and one
`$(hostname -s)`. That step is now `do_set_vars_paths`: one exec of the
binary, or, when the binary cannot be used, the unchanged Bash code
(`do_set_vars_paths_bash`).

## 2. The interface

| | |
|---|---|
| crate | `csi-spl-orc/src/rust/spl-run-path` (no dependencies, static musl, the same pinned toolchain as `spl-cmd-guard`) |
| path | `<dir of $0>/../bin/spl-run-path`: for a module's `./run` that is `<repo>/bin/spl-run-path` (git-ignored). Any other spelling of `$0` (`bash run.sh`, a `./run` on `PATH`) finds no binary there and takes the Bash path. |
| build | `cd csi-spl-orc && DRY_RUN=0 ./run -a do_build_spl_run_path` (cargo in the crate dir; or `SPL_RUN_PATH_BIN=<built>` installs a built one). Checked before the swap: `--version` and this module's `./run` resolved to `PROJ_PATH`. |
| call | `spl-run-path -- "$0"`, cwd = the caller's |
| version | `spl-run-path --version` prints `spl-run-path <Cargo version>`; run.sh pins it as `RUN_PATH_BIN_VERSION`. Bump both for any change of what the binary prints; `run-path-bin.tst.sh` case 13 holds them equal. |

Output on rc 0, one `KEY=value` per line, in this order; the version is the
first line of the SAME exec (a separate `--version` exec would eat the gain):

```
SPL_RUN_PATH_VERSION=<version>
unit_run_dir=<the resolved src/bash/run dir>
RUN_UNIT=<basename of unit_run_dir>.sh
PROJ_PATH=<unit_run_dir>/../../..
APP_PATH=<unit_run_dir>/../../../..
ORG_PATH=<unit_run_dir>/../../../../..
BASE_PATH=<unit_run_dir>/../../../../../..
HOST_NAME=<hostname -s>
```

run.sh reads it with one `mapfile`, checks all 8 lines (the version, then
every key in order) before it sets any value, and never `eval`s it. The
values that follow from these (`ORG_APP_PATH`, `VAR_DIR`, `FRW_PATH`, `ORG`,
`APP`, `PROJ`, `PROJ_KIND`, `USER`) stay in Bash: they are parameter
expansions with no fork.

Exit codes: `0` the values; `2` `abs_path` is undef (the `perl` would die);
`3` a case the port does not prove equal (a newline in a path, a path of
1024 bytes or more, more than 16 links inside one `abs_path`, a dir `cd`
cannot enter, no `/proc/sys/kernel/hostname`): run.sh then runs the `perl`
itself, which decides; `64` a bad call.

## 3. How it resolves `$0`

The `perl` ported step by step (`src/resolve.rs`): `dirname` is
File::Basename's (Unix), `abs_path` is Cwd's XS `bsd_realpath` (a missing
LAST component is forgiven, an earlier one is undef; `..` is lexical on the
already-resolved prefix). Follow `$0` one link at a time and stop at the
first file whose dir resolves to `*/src/bash/run`, or at a non-link, or
after 40 hops, exactly as the `perl` does. The four parents are the lexical
parents of that dir (it holds no link, so bash's logical `cd ..` is the
same), `/` staying `/`. `HOST_NAME` is the kernel's node name cut at the
first dot, what `hostname -s` prints.

## 4. The fallback (owner answer A, the dispatcher's table)

| step | what happens |
|---|---|
| 1 | `run` looks for the binary at the one path above and runs it once |
| 2 | rc 0 and the first line is `SPL_RUN_PATH_VERSION=<RUN_PATH_BIN_VERSION>`: `run` uses its values |
| 3 | missing, any other rc, or another version: today's Bash path; `RUN_PATH_NOTE` says why and `main_exec` logs it as ONE `DEBUG` line (`run path: <why>; took the Bash path`) in the module's run log; the action still runs |
| 4 | `csi-spl-orc/src/bash/tests/run-path-bin.tst.sh` runs every case both ways and requires the same values |

`DEBUG`, so the line reaches the log file always and the screen only in the
full (terminal) mode or with `RUN_LOG=debug`: an agent's piped `./run` and
every test that reads `./run`'s output are unchanged.

## 5. The test

`run-path-bin.tst.sh` (orc suite; CI's `rust-suite` job runs it again with
the binary it just built and `SPL_RUN_PATH_TEST_REQUIRE=1`). Each of cases
1..9 runs with the binary in place (the note must be empty) and without it
(the note must name the missing binary), and the 11 printed values must be
equal: an absolute `$0`, `./run`, a relative path from the repo root,
`../<module>/run`, a bin link to module B whose `run.sh` links to module A's
(SPL-5536), a linked ancestor, `bash run.sh`, a link dir that only spells
`src/bash/run`, a 3-link relative chain. Then: a wrong-version and a failing
binary give the Bash values and a note (10), one log line (11), a dangling
`$0` fails both ways (12), the version pin and the four copies (13), and the
build action with stubs (15..17). Without a binary (no cargo on the runner)
the orc suite prints `SKIP: the binary half` and runs the rest.

Red controls, both run on 2026-11-23:

- in the test (case 14): a binary that follows every link to the end
  (`readlink -f`) instead of stopping at the first `src/bash/run` dir fails
  case 5, `binary and Bash differ`.
- by hand: the crate rebuilt with ONE wrong hop (a relative link read
  against the cwd instead of the link's own dir,
  `let mut q = b".".to_vec();` for `let mut q = dirname(&p);`) fails 7 cases:
  4 `../<module>/run from another module: binary and Bash differ` (it
  resolved module B for module A), and 1, 3, 5, 6, 8, 9 `the binary was not
  taken` (it exited 2 where the `perl` resolves). Cases 2 and 7 pass, as they
  must: there the cwd IS the link's dir.

## 6. Measured

Box: the satellite box (16 vCPU), 2026-11-23. Tree: this lane's head on
`origin/master` `a7b5ae564`, `git archive` into three scratch copies with the
probe action of run-start-split.md 1 (`do_probe_start`, forks nothing):
`before` (master's run.sh), `after-bin` (this run.sh, the binary in
`<repo>/bin`), `after-nobin` (this run.sh, no binary). Index cache warm, stdout
not a terminal, wall time by `$EPOCHREALTIME` around the fork. The arms
alternate by round; 5 rounds of 5 per arm. Values: min..max (median), ms.

| measure | n per arm | 1-min load | before | after, binary | after, no binary |
|---|---|---|---|---|---|
| total, batch 1 (15:45:13Z) | 25 | `7.3..7.9` | `310.5..353.3` (`324.4`) | `300.8..426.0` (`313.5`) | `320.8..419.0` (`332.9`) |
| total, batch 2 (15:45:49Z) | 25 | `5.9..6.6` | `307.1..400.2` (`351.4`) | `306.2..499.3` (`336.0`) | `327.7..506.3` (`367.0`) |
| the path step alone (15:46:36Z) | 25 | `6.1` | `14.90..20.77` (`15.80`), the Bash code | `2.21..2.81` (`2.48`), exec + parse | |
| the fallback's `do_log` line alone | 25 | `6.2` | | | `7.84..14.89` (`9.49`) |
| total, batch 3, fallback without its log line | 25 | `5.3..5.9` | `308.4..373.5` (`337.3`) | | `327.7..491.7` (`352.0`); without the line `313.6..368.0` (`331.3`) |

- **The gain is the step: `15.8 -> 2.5` ms median, `-13.3` ms** (n = 25 each,
  measured inside one Bash, same tree, alternating). The issue estimated
  `16` from the proxy; this is what was measured.
- On the whole start the medians moved `-10.9` and `-15.4` ms (about 3..4%);
  the start's own spread at this load (`300..500` ms) is larger than the gain,
  so these two are consistent with the step, not a separate proof of it.
- **The fallback costs more than today**: `+8.5` and `+15.6` ms on the
  total medians, of which the `DEBUG` line is `9.5` ms (one `do_log`: its
  `$(printf)` fork and the log-file setup it does first). Without that line
  the fallback measured `331.3` against `337.3` before (n = 25, load
  `5.3..5.9`): free. So a tree without the binary (every new lane worktree,
  CI) pays the log line until `do_build_spl_run_path` runs there.
