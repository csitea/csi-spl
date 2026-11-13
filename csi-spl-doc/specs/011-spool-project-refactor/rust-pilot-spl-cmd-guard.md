# The Rust pilot: `spl-cmd-guard` behind `force-push-guard-hook.sh`

- **Issue:** `SPL-5392` (Epic `SPL-2402`)
- **Analysis it implements:** [rust-candidates-analysis.md](rust-candidates-analysis.md) v1.0, section 6.1 (the first item of "Start Slowly at Once"), 6.2 (fallback) and the measurable parts of 6.3
- **Status:** landed with `SPL_CMD_GUARD_IMPL=py` (the default) on every box. Shadow mode is the owner's go (section 4).

## 1. What the binary covers

`spl-cmd-guard` replaces the two Python cold starts the hook pays on every
agent shell call, and only those two:

| Part of the hook | Python today | `spl-cmd-guard` |
|---|---|---|
| payload extractor (claude, grok, qwen, agy shapes) | inline `python3 -c` in the hook | `spl-cmd-guard hook` (src/payload.rs, src/json.rs) |
| force-push matcher (every form in the header of `force-push-guard.inc.sh`) | `_FORCE_PUSH_GUARD_PY` | the same walk, same reason text (src/guard.rs, src/lexer.rs, src/pytext.rs) |
| kill-target matcher | `kill-target-guard.inc.sh` | not covered (Phase 0 keeps it in Python) |
| heredoc-collision matcher | `heredoc-collision-guard.inc.sh` | not covered (Phase 0 keeps it in Python) |
| the deny JSON of a refusal | `refuse()` in the hook | not covered (only refusals pay it) |

The crate is `csi-spl-orc/src/rust/spl-cmd-guard`: pure Rust,
`#![forbid(unsafe_code)]`, no dependency at all (so no `-sys` or `cc` crate,
nothing to fetch: `--locked --offline` always builds), toolchain pinned to
`1.100.0` in `rust-toolchain.toml`. It builds a static musl binary linked by
the toolchain's own `rust-lld`, so neither a box nor a CI runner needs a C
compiler (measured: an `strace` of a clean build runs only `rustc` and
`rust-lld`). Stripped size: 494,584 bytes.

Where it departs from section 6.1 and why: the tokenizer is a port of
CPython's `shlex` (posix, `punctuation_chars`), not a POSIX shell lexer,
because parity with the Python verdict is the pilot's success criterion; a
better lexer is a later, separate change.

## 2. The modes

`SPL_CMD_GUARD_IMPL`, else the first line of `spl-cmd-guard.impl` next to the
installed hook, else `py`. Any other value is `py`.

| Mode | Who decides | What else happens |
|---|---|---|
| `py` | Python, exactly as before | nothing; the one-word rollback |
| `shadow` | Python alone | `spl-cmd-guard` runs beside it; one TSV line per call to `$XDG_STATE_HOME/csi-spl/spl-cmd-guard-shadow.tsv` (mode 600; `SPL_CMD_GUARD_SHADOW_LOG` overrides): time, harness, `match=0/1`, both verdicts, `py_ms`, `rust_ms`, and on a mismatch only, the command (`%q`, at most 2,000 chars) |
| `rust` | `spl-cmd-guard` | a missing or non-executable binary, a timeout (`SPL_CMD_GUARD_TIMEOUT`, default 2 s), an exit other than 0/2/3, or an rc-0 answer that is neither `NONE` nor `CMD:` falls back to the Python path, never to allow |

Verdict words in the log: `none` (not a shell call), `allow`,
`refuse:<reason>`, `unreadable`, `error` (the binary could not answer).

## 3. Tests

| Test | Runs in | Proves |
|---|---|---|
| `cargo test` (18 unit tests) | CI `rust-suite` | lexer, JSON, extractor, matcher pieces |
| `csi-spl-orc/src/bash/tests/force-push-guard-hook-impl.tst.sh` | orc suite (stub binaries, no Rust) | the three modes, the impl file, every fallback of 6.3 row 3, the shadow log; RED control: a planted Rust allow is logged `match=0` |
| `csi-spl-orc/src/bash/tests/spl-cmd-guard-mode.tst.sh` | orc suite (stub binary) | `do_spl_cmd_guard_mode`: dry run, install with `--self-test` and `.bak`, py rollback, refusals |
| `csi-spl-orc/src/rust/spl-cmd-guard/parity/parity.sh` | CI `rust-suite` (real binary) | `force-push-guard.tst.sh` asked of the binary; `kill-target-guard.tst.sh`, `heredoc-collision-guard.tst.sh`, `test-y13-force-push-guard.sh` through the hook in `rust` and `shadow` (every shadow line `match=1`); the differential below; RED controls: one flipped verdict and one misread payload are each caught |

The differential compares every verdict line, reason text included, between
the Python library (loaded in one process) and `spl-cmd-guard batch`:

| Corpus | n | refused | mismatches | where |
|---|---:|---:|---:|---|
| `force-push-guard.tst.sh` cases | 206 | 135 | 0 | `parity.sh`, every CI run |
| generated soup, seed 5392 | 20,000 | 3,595 | 0 | `parity.sh`, every CI run |
| generated struct, seed 5392 | 20,000 | 13,974 | 0 | `parity.sh`, every CI run |
| generated payloads, seed 5392 | 300 | - | 0 | `parity.sh`, every CI run |
| one-off: every distinct `Bash` command in the desk box's agent transcripts | 54,355 | 13 | 0 | measured once, 2026-11-13 (not in git: transcript content) |
| one-off: soup 300,000 + struct 200,000 | 500,000 | 191,442 | 0 | measured once, 2026-11-13 |
| one-off: payloads | 3,000 | - | 0 | measured once, 2026-11-13 |

Every refusal reason of the matcher occurs in the generated corpora except
"the command nests too deep", which a unit test covers.

`parity.sh` takes 51 s on the desk box (`PARITY_N`, `PARITY_PAYLOADS` scale it).

## 4. Turning shadow mode on (the owner's go)

Not done by this lane. On a box, as its box user, from the main checkout:

```
cd csi-spl-orc && SPL_CMD_GUARD_IMPL=shadow DRY_RUN=0 ./run -a do_spl_cmd_guard_mode
```

It builds the binary with the pinned toolchain (`SPL_RUST_HOME`, default
`/mnt/data/var/csi/rust` where `/mnt/data` is mounted, else `/var/csi/rust`;
the toolchain needs `rustup` from `do_box_pkg_install` and `rustup toolchain
install` once in the crate dir), checks `--self-test`, installs it next to
both users' installed hooks with a `.bak`, and writes `spl-cmd-guard.impl`.
Without `DRY_RUN=0` it prints the plan. Rollback:
`SPL_CMD_GUARD_IMPL=py DRY_RUN=0 ./run -a do_spl_cmd_guard_mode`.
Read the burn-in: `grep -c $'\tmatch=1\t' <log>` and `grep -v $'\tmatch=1\t' <log>`.

## 5. Measurements (rust-candidates-analysis.md 6.3 row 2)

Method of the analysis section 2.4: `unshare -r --pid --fork`, children's
rusage (user + sys) and `ns_last_pid`, so `procs` counts the probe's own
`bash -c` too (an empty `true` reads 1). n = 9 per row, median (min..max).
Tree: commit `6725d4709` plus this lane's change, as landed. Shadow lines
written during these runs: 27 on each box, 0 mismatches.

Desk box, 16 cores, load 41 to 48:

| Mode | Command | CPU ms | procs | wall ms |
|---|---|---:|---:|---:|
| py | `git status` | 153.8 (115.5..179.4) | 10 | 212.8 (158.6..253.4) |
| shadow | `git status` | 115.8 (92.0..131.0) | 13-14 | 126.9 (92.5..167.4) |
| rust | `git status` | 16.5 (14.4..20.1) | 8 | 28.4 (19.1..38.0) |
| py | `git push --force ...` | 151.0 (122.3..170.4) | 11 | 193.8 (145.8..259.9) |
| rust | `git push --force ...` | 57.3 (49.7..62.4) | 9 | 71.5 (54.3..123.8) |
| py | `kill $!` | 187.8 (142.1..217.7) | 12 | 216.0 (148.5..267.3) |
| rust | `kill $!` | 73.4 (70.3..94.3) | 10 | 96.2 (82.9..135.9) |
| binary alone | `spl-cmd-guard hook` | 3.4 | 2 | 3.6 (2.9..4.0) |

sat, 16 cores, load 79 to 82:

| Mode | Command | CPU ms | procs | wall ms |
|---|---|---:|---:|---:|
| py | `git status` | 87.3 (78.7..99.6) | 10 | 135.2 (103.0..146.8) |
| shadow | `git status` | 88.9 (82.2..100.9) | 13-14 | 131.6 (103.7..153.3) |
| rust | `git status` | 15.3 (14.4..16.9) | 8 | 22.6 (19.2..27.5) |
| py | `git push --force ...` | 113.2 (108.0..120.5) | 11 | 155.0 (136.5..173.0) |
| rust | `git push --force ...` | 46.4 (43.2..49.2) | 9 | 57.7 (53.4..78.4) |
| py | `kill $!` | 140.7 (123.6..161.7) | 12 | 181.9 (169.0..211.2) |
| rust | `kill $!` | 64.1 (60.3..66.9) | 10 | 82.2 (73.6..99.5) |

Read it this way:

- An ordinary call drops 5.7x (sat) to 9.3x (desk) in CPU and 6x to 7.5x
  in wall: the 6.3 row 2 bar (wall at most 1/4 of Python) is met on both
  boxes.
- Processes per ordinary call: 8 with the probe, 7 for the hook itself:
  the hook's bash, `$(cd "$(dirname ...)")` (2, the hook's own header),
  `$(cat)`, the command-substitution subshell, `timeout`, the binary. The
  6.3 row 2 bar of at most 2 is NOT met yet; it needs the header's
  `dirname`, `$(cat)` and the subshell gone (a `read -d ''` and a direct
  call), which changes the Python path too, so it belongs to the cut-over,
  not to this landing.
- A refusal and a `*kill*` / `*send*` command still pay Python: the deny
  JSON and the kill-target matcher (Phase 1).
- Shadow adds 3 to 4 processes on top of Python; its wall cost did not show
  above the noise at these loads (n = 9 is too few to size a few ms).

## 6. CI

Job `rust-suite` of `.github/workflows/10_ci-quality.yml` (runs with the orc
part): rustup-init 1.29.3 pinned by sha256 (release-asset cache, the
SPL-5050 pattern, covered by `workflow-release-asset-cache.tst.sh`), the
toolchain of `rust-toolchain.toml` into the runner's tool cache, then `cargo
fmt --check`, `cargo clippy --all-targets -D warnings`, `cargo test`, the
release build (at most 5 MB, `--version`, `--self-test`) and `parity.sh`.
Each step prints its seconds; the first run's numbers are in the issue.
