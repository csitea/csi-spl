# Box clean-tree check: is every live lane's work pushed before a switch-off

SPL-4202, [spec 069](../../specs/069-ysg-box-out/spec.md). Before a box is
switched off, the work of every lane that RUNS on it must be pushed. On the
shutdown drill of a fleet box (2026-10-29) this was a manual loop over every folder of the
worktree root: 358 folders, dozens of them retired lanes still dirty (a-461,
c-005, c-135 ...), and that noise hid the live lanes, the rows that matter.

It is **read only**: it writes nothing, sends nothing and fetches nothing.
The drain itself (spawns refused, roles handed over, a note to every lane) is
[`do_spl_box_leave`](../../../csi-spl-orc/src/bash/run/spl-box-leave.func.sh);
this check is the look before it, or after it.

## 1. Run it

### 1.1 The live lanes and the retired count

```bash
cd csi-spl-orc && ./run -a do_spl_box_clean_tree
```

### 1.2 Also the ids of the dirty retired worktrees

```bash
cd csi-spl-orc && CLEAN_TREE_LIST_RETIRED=1 ./run -a do_spl_box_clean_tree
```

## 2. What it reads

- A **live lane** is an agent id a running process carries
  (`SPOOL_AGENT_ID`, read from `/proc` as the lease loop reads it). Its
  worktree is its latest `registry.tsv` run dir, else `<worktree root>/<id>`.
- A **retired worktree** is every other folder of the worktree root
  (`SPOOL_WT_ROOT`, default `/opt/csi/csi-spl-wt`).
- **Pushed** is read as `do_spl_box_leave`'s table reads it: `yes`,
  `no (<n> unpushed, <m> dirty)`, or `n/a (no own worktree)` for an agent
  that works in the main checkout.

## 3. The output

1. one row per live lane: `agent | pushed | worktree`;
2. one count line for the retired worktrees: scanned, dirty or unpushed.
   They are not in the verdict;
3. `CLEAN: every live lane pushed` (exit 0) or
   `NOT CLEAN: <n> live lanes hold unpushed or dirty work` (exit 3).

Measured on sat, 2026-10-29: 19 live rows, `181 scanned, 69 dirty or
unpushed` retired in one line, 35 s wall.

Test: `csi-spl-orc/src/bash/tests/spl-box-clean-tree.tst.sh`.
