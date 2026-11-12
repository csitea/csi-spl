# The wui-e2e bundle cache kept a bundle that failed the budget (SPL-5347)

**Spec**: `016-spool-testability` · **Code**: `csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh`
(`_pp_part_wui_e2e`, `_ppe_budget`, `_ppe_tree_lock`) · **Test**:
`csi-spl-iac/src/bash/tests/check-pre-push-e2e.tst.sh` checks 19, 20, CONTROL f.

## 1. The defect

The pre-push part `wui-e2e` moved a freshly built mock bundle into its cache
(`~/.cache/csi-spl/wui-e2e-bundle/<key>`) before it ran the bundle budget
(`perf-budget.py bundle`, then the local margin). A bundle that failed the
budget stayed cached under its key, and every later push of the same WUI tree
re-used it (`wui-e2e: bundle re-used`) and failed the same way, never
rebuilding. The build also ran under no lock, so two runs in one tree could
build into the same `.output` at once.

Reported by c-461 (tree 58fab815a, n=2 pushes, both re-used one key and read
home 425.2 KB; a clean build of the same sha read 331.7 KB, n=1). That the
colliding builds caused the bigger bundle is suggested, not shown.

## 2. The rules now

1. **The budget runs before the cache.** A built bundle that fails it is
   removed from the tree and never cached, so the next push builds again. A
   re-used bundle is measured again, because the budgets are not in its key.
2. **One run at a time per tree.** The part takes an exclusive flock on
   `<git dir>/ppe-tree.lock` (the git dir is per worktree) before it touches
   `.output`, and holds it until it exits. A second run prints
   `wui-e2e: another run uses this tree, waiting for it`, then re-uses the
   first run's bundle if it passed. The lock covers the run, not only the
   build: a run that re-used the bundle the other one built lost its
   `.output/public` to the other's EXIT trap (seen in check 20 before the
   lock spanned the run). The build and the runner start with the lock's fd
   closed, so a child left behind (a Chrome past the timeout) cannot hold it.
3. Unchanged: a bundle a live run holds is never pruned, and the hold locks
   live in `<cache>/.locks`, outside the bundle dir (SPL-4351).

## 3. Not done

- A bundle cached over budget before this change is still re-used until the
  prune drops it (newest 3 kept) or someone removes it.
- `pre-push-gate.md` (the wui-e2e paragraph) is the export of a qto doc and
  is not edited here; this note is the record until that doc is updated.
