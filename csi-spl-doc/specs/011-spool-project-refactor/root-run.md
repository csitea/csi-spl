# The repo-root `./run` (SPL-5550)

Owner, t1 #refactoring, 2026-11-15: "Can we create one run.sh for each module
and also for one level up from the modules?", then "B" (keep the module
copies, add a real root one).

## 1. The rule

### 1.1 Four copies, one file

The run.sh framework has four byte-identical copies: `csi-spl-iac`,
`csi-spl-orc`, `csi-spl-utl` (each `./run` -> `src/bash/run/run.sh`) and the
repo root (`./run` -> `src/bash/run/run.sh`, a real file, not a link to a
module's). A change to one is copied to all four in the same commit.

Guard: `csi-spl-iac/src/bash/tests/run-sh-parity.tst.sh`.

### 1.2 The root hands the action to its module

A copy knows it is the root when the dir of its `./run` has module children
(`<dir>/*/src/bash/run/run.sh`). It reads that from `$0` before anything
else runs, with no fork, so a module's `./run` is unchanged.

At the root:

- `./run -a do_x` execs the `./run` of the one module that defines `do_x`
  (its `src/bash/run/` or `lib/bash/funcs/<name>.func.sh`, the file the
  module's loader maps the action from), with the same argv and env.
- `do_x` in two or more modules: the root names them and refuses (exit 2)
  unless `-m <module>` picks one: `./run -m iac -a do_print_help`
  (`iac` or `csi-spl-iac`). `-m` is the root's own flag and is not passed on.
- No module defines it: the same `NOT found` lines and exit 1 as a module.
- Actions of two modules in one call: refused (exit 2), one call per module.
- An action in the root's own `src/bash/run/*.func.sh` runs at the root
  (none today).
- `./run` and `./run --help` list the actions grouped by module.

Guard: `csi-spl-orc/src/bash/tests/run-root-dispatch.tst.sh` (a fixture repo
with two modules, and a control on the old root link).

## 2. Cost

Same box, the same hour, load average 35..41 (n = 12 per arm, interleaved,
`./run -a do_spl_lane_age_report`, wall ms):

| arm | min | median | max |
|---|---|---|---|
| orc module, before | 1030 | 1193 | 1385 |
| orc module, after | 1017 | 1124 | 1657 |
| root, before (link to orc) | 1042 | 1223 | 1451 |
| root, after (dispatch) | 1053 | 1242 | 1469 |

At that load the four arms fall within each other's noise. Measured alone, the
root's lookup and refusal, `./run -a do_no_such_action` at the root, has a
median of 28 ms (n = 20; a bare `bash -c 'exit 0'` was 10 ms), against 584 ms
for an orc `./run` (n = 20). A module pays two globs and no fork
(`csi-spl-iac/src/bash/tests/run-loader-no-fork.tst.sh` stays green).
