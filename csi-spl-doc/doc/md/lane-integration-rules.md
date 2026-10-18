# Lane integration rules: the why (2026-10-03)

> Generated from qto doc `65b76f5e-7e2d-49fa-885f-7f924536b7bf`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

The spawn seed (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh`,
`_spawn_seed_blocks`) states the INTEGRATION rules (1)-(8), SCOPE (a)-(d) and
DEPLOY-GATE (a)-(e) as rules only. The seed is re-read on every turn of every
lane, so the history behind each rule lives here, read once when a rule seems
odd. Practice 02 of `agent-token-focus-plan.md`: a seed states rules, not their
history.

Measured shrink (dry-run spawn, `wc -c` of `prompt.txt`, n=1 per kind, tree
`83183be1`): claude 21,269 -> 7,789 B, qwen 21,475 -> 7,995 B.

<a id="ws-doc-c1d65c86-1596-47af-a8d5-73017010192b"></a>
## 1. Commit (rule 2)

<a id="ws-doc-789d5adb-981d-4a37-a664-79957d97f76e"></a>
### 1.1 Pathspec on the `add`, never on the `commit`

`git commit -- <path>` is a PARTIAL COMMIT: it re-reads those paths from the
WORKTREE and commits that, discarding an index mode set by
`git add --chmod=+x`. Measured on the main box 2026-09-12: index `100755` after
the add, COMMITTED `100644`, with and without `core.fileMode=false`.

<a id="ws-doc-4da31fe5-99bd-43d2-8897-6a407b09968f"></a>
### 1.2 An executable file needs both bits

- `chmod +x <path>` alone, with no pending edit to that file, is mode-only
  churn by definition (worktree bit set, index `100644`, no content delta), so
  a repair tool clears it. That is the common shape: an existing script that
  should have been executable all along. A bare chmod on a path whose edit is
  STAGED is the safe sub-case: the tool cannot tell it from churn either, so it
  refuses and names it instead of guessing.
- `git add --chmod=+x` alone leaves the worktree bit unset, which git reports
  as an UNSTAGED `mode change 100755 => 100644`. That blocks the next rebase,
  and a churn detector reads it as churn (measured 2026-09-12: worktree 664,
  index 100755, `git diff --summary` -> mode change, detector exit 3).

With the bit in both places the two agree and nothing reports anything.

<a id="ws-doc-5ec45881-ec75-4949-8c0d-b42702106692"></a>
### 1.3 Commit and push continuously

The scenario this prevents: several related changes, some fast (manifest,
prompt, config, docs, scripts, tests) and some slow (image generation,
rendering, uploads, large builds, rate-limited batch API calls). The fast ones
finish in minutes and are then held uncommitted for an hour while the slow one
grinds: the owner sees NOTHING land, trunk moves dozens of commits, and the
rebase becomes unresolvable. The fast changes stand on their own, cannot break
what they do not touch, and are usually the part the owner is waiting to read.
The same holds for verification: if item 3 of N fails, push the other N-1.

<a id="ws-doc-e2815910-92d9-4e44-9a5a-69cd13ec06e4"></a>
## 2. Rebase (rule 3)

<a id="ws-doc-f5d76ef1-437f-47c3-81f3-13d13194f468"></a>
### 2.1 Mode-only churn

Something outside a lane moves the OWNER EXECUTE BIT on tracked files, the one
mode bit git records: 158 paths went that way on 2026-09-12 with ZERO content
changed. A rebase then refuses with `cannot rebase: You have unstaged changes`.
`git diff --summary` lists `mode change` lines; a churned path appears there
with NO content hunk in `git diff`. Set the worktree bit back to what
`git ls-files -s <path>` records (`100755` -> `chmod +x`, `100644` ->
`chmod -x`). Staging such a path lands a spurious `100644 => 100755` next to
the change and nothing warns. Do not hunt the writer.

<a id="ws-doc-33db2381-1bf5-4037-9130-3cef94edac03"></a>
### 2.2 FETCH: one fetch per clone per minute

FETCH in the seed is `git-fetch-fresh.sh` (spawn-agents scripts): `git fetch
origin master`, skipped when any worktree of the clone fetched it less than 60 s
ago (`FETCH_FRESH_MAX_AGE`), with concurrent callers queued on one flock so they
share one round trip. Measured 2026-10-07
(`fleet-hot-commands-2026-10-07.md` section 3.6): 846 fetches, 14,987 s, p90
21 s, the tail being contention of ~20 worktrees on one object store, 2 to 3
fetches per push. A push rejected as stale uses `FETCH --force`.
`FETCH --landed` never skips: the landed check (rule 4) must read the real
remote. Rule (5) no longer fetches: the worktrees share `origin/master`, so the
`--landed` fetch of rule (4) already refreshed it for the main checkout.

<a id="ws-doc-2b5cd4f5-f2ba-4086-a7d1-3ee9df688bb3"></a>
## 3. Push (rule 4)

<a id="ws-doc-8efbb803-41b5-4d0e-89fb-52323b8a66e5"></a>
### 3.1 Judge the landing by the repository, not the output

A REJECTED push also prints `HEAD -> master`; the full line is
`! [rejected] HEAD -> master (fetch first)`. A retry loop that greps the output
for that string reports success for a push that never landed. Measured on the
main box 2026-09-12: two shas were reported PUSHED and published as on trunk,
and were not there. `git merge-base --is-ancestor HEAD origin/master` reads the
repository; its exit code is the same check rule (8) needs before teardown.

<a id="ws-doc-5ed681b2-a262-440e-a739-ecc7f4190dc5"></a>
### 3.2 Never force-push (NO FORCE-PUSH)

Trunk stays: a plain push to master is how a lane lands. A force-push
(`--force`, `--force-with-lease`, `+ref`) is not: it replaces the commits
others landed with yours. A refused push means someone landed first: fetch,
rebase, re-test and push again; `SPL_PREPUSH_OVERRIDE` never gets it through.
No agent force-pushes master without the owner's explicit approval of that one
push, and even then the owner decides who does it, often by hand: ask and wait.

The owner, HUM-10 2026-10-10: "yes we are using the trunk strategy to push to
master , BUT there are RULES. Everyone respects the work of the others. We are
team and not a bunch of selfish cawboys" (msg 097f9de3); "NOBODY PUSH FORCE'S
TO THE MASTER. ONLY AFTER EXPLICIT APPROVAL FROM ME" (1ca01c83); "AND EVEN THAN
I MIGHT PREFER TO MAKE IT MANUALLY" (3e095a04); for every agent type
(1cdfa5ba). Cases: m-615, m-621, m-734, m-713, m-755.

The rule's one home is `NO_FORCE` in `spawn-core.inc.sh`; every kind's seed
renders it (`tests/test-seed-no-force-push.sh`).
What enforces it (ruleset, pre-push hook, matcher, seed), for humans too:
[developer guide](developer-guide.md) section 4.

<a id="ws-doc-f7d23f23-0b6f-498a-85e5-47daa44e2f88"></a>
### 3.3 Push in the background, poll the verdict (SPL-1578)

Rule (4) pushes with `do_spl_push_master` (`csi-spl-orc/src/bash/run/spl-push-master.func.sh`),
never a foreground `git push origin HEAD:master` and never a foreground loop
around one. The action checks the tree, detaches one worker (setsid, its log
and ONE status file under `<spool root>/<id>/lifetime/push-master/`) and
returns at once. The worker runs FETCH, the rebase with the lane's identity,
the `%ae %ce` check of rule (6), then the push; a push refused because master
moved while the hook ran is rebased and retried (`PUSH_RETRIES`, default 4).
It ends with `PUSHED <sha>` plus the `FETCH --landed` exit code, `REFUSED
<reason>` with the hook's tail, or `GAVE-UP`. `PUSH_CMD=status` prints it and
exits 0 / 1 / 3 (running); the lane polls it in short calls. The action never
forces, unsets `SPL_PREPUSH_OVERRIDE` and edits no file (a conflicting rebase
is aborted). Test: `csi-spl-orc/src/bash/tests/spl-push-master.tst.sh`.

Why: the watchdog kills a lane whose ONE tool call runs past 15 min (S4), and
the push is the call that does: m-900@sat (mistral, 2026-10-13 00:30Z, the
push call open 16 min), g-881@sat (grok, 2026-10-12, a foreground fetch ->
rebase -> test -> push loop of up to 4 tries), m-188 on the other box (mistral,
2026-10-11); n=3, two vendors. The pre-push hook's wall time on sat, 48 h to
2026-10-13T00:50Z, from `~/.cache/csi-spl/pre-push.log` (`secs=` of the
verdict lines):

| verdicts | n | p50 | p90 | max | > 10 min | > 15 min |
|---|---|---|---|---|---|---|
| PASS + REFUSE | 292 | 16 s | 450 s | 79058 s (a hung run) | 17 | 9 |
| PASS | 249 | 13 s | 363 s | 857 s | 4 | 0 |
| REFUSE | 43 | 255 s | 1029 s | 79058 s | 13 | 9 |

The hook log does not record git's own verdict, so a push rejected AFTER a
green hook (master moved) is not counted directly. A proxy: of the 102 PASS
shas not on `origin/master` afterwards, 83 were followed by another hook run
of the same tree on a new HEAD within 30 min, the rebase-and-retry shape. Each
retry pays the hook again, so a busy master turns a 6-min hook into a call
past 15 min. The verdict cache (`pre-push-gate.md` 1.1) is content-keyed and
does not help: the rebase makes a new tree.

<a id="ws-doc-642ef755-72a7-427e-a9b1-bff8249747bb"></a>
## 4. Refresh the main source (rule 5)

<a id="ws-doc-7fa084aa-9b22-4a3b-9e25-44fcc44ea649"></a>
### 4.1 `merge --ff-only`, never `pull --ff-only`

`pull` merges FETCH_HEAD, FETCH_HEAD is per-worktree, and every lane runs the
same closing refresh against the ONE shared checkout, so they all append to its
single FETCH_HEAD and pull aborts with
`fatal: Cannot fast-forward to multiple branches`. Measured with 8 concurrent
refreshes x 25 rounds on git 2.47.3, two runs: pull 168/200 then 193/200
failed, merge 8/200 then 0/200. The rate moves; the order of magnitude is the
finding. `merge --ff-only origin/master` reads a REF, needs no network, and
cannot make a merge commit; a push landing in between only means the next
lane's refresh carries the newer tip. It is the one exception to rule (1).

<a id="ws-doc-fb3ab233-854e-444e-81c8-75f32a95e62e"></a>
## 5. Leak-gate (rule 6)

<a id="ws-doc-dea37298-c64b-4767-b940-b55e00633b7a"></a>
### 5.1 The quoted address is a default

It is read from the shared checkout's `.git/config` at spawn time, and that file
is contested mutable state every lane writes: it has been measured holding three
different values within one day. A canonical address in the repo's own
CLAUDE.md / AGENTS.md wins.

<a id="ws-doc-19fb042b-e00b-4592-b737-9a3d0d891619"></a>
### 5.2 Two identity fields, one survives the protocol

`git rebase` re-stamps the COMMITTER from the ambient config, and rule (3)
mandates a rebase right before every push, so a commit made correctly with
`git -c user.email=… commit` is re-stamped on its way to trunk.
`git commit --amend --author=…` has the same hole from the other side: it fixes
the author and leaves the committer. Hence the identity on the rebase too, and
the gate reads both `%ae` and `%ce`: `%ae` alone reports green on a field it
never read.

<a id="ws-doc-08981b80-8906-4b5c-91d7-20b583f528ee"></a>
### 5.3 `--no-mailmap` is the control

A root `.mailmap` maps the old addresses onto the canonical one, so plain
`git log` renders a wrong commit as correct.

<a id="ws-doc-02a8c083-76d5-4785-a56b-a9cacd396c1e"></a>
### 5.4 Never `git config` from a worktree

With `extensions.worktreeConfig` unset every worktree shares one common
`.git/config` (`rev-parse --git-common-dir` from a worktree points at the
shared `.git`), so a `--local` identity, or `core.fileMode false`, changes the
shared checkout and every other lane. Pass `-c` per command. On the `commit`,
`-c core.fileMode=false` is worse than useless: a partial commit re-reads the
WORKTREE and the flag makes git ignore the very bit it would read (measured
2026-09-12: index `100755` after `git add --chmod=+x`, COMMITTED `100644`).

<a id="ws-doc-3e366a65-2319-4489-9b7c-befa29b3913c"></a>
## 6. CI and every environment (rule 7)

A run can read cancelled while the commit ships later riding somebody else's
deploy, so a deployed-state check (`./run -a do_check_deploy_lag`) beats the
run colour. A red is yours when it names a module you touched or your commit
introduced it, including a dormant assertion that fired for the first time in
a file you never opened. "My module is not named" is a judgement about a log
not yet read. Reporting a red to its named owner is the discharge; noticing it
and moving on is not.

<a id="ws-doc-54edd559-9626-4ef5-b8e5-0ee86359b81f"></a>
## 7. Teardown (rule 8)

A merged worktree left in `<repo>-wt/` clutters `git worktree list`, which other
lanes read to see who owns what.

<a id="ws-doc-732577bc-3be3-4a94-92e9-4a99cebe3945"></a>
## 8. Scope (SCOPE a-d)

Trunk moves constantly and very often already carries someone else's fix.
`git worktree list` sees one machine only; `lane-map.sh` covers every machine
of the fleet (specs/058 N2), and `--check` prints only the verdict. Duplicated
work is wasted tokens plus a rebase conflict for someone: "I fixed it too" is a
mess-up, not a bonus. A fix for a blocker outside the scope goes in its own
narrow commit so it drops cleanly if it turns out redundant.

<a id="ws-doc-1aeb4883-1f1c-41e2-a86f-6792685ffe38"></a>
## 9. Deploy-gate (DEPLOY-GATE a-e)

The tiers, the scanner list and the workflow numbers are the repo CLAUDE.md's
and `pre-push-gate.md`'s; the seed keeps only the commands. The gate exists
because a break caught on trunk stalls every deploy (SPL-1250). A memory-only
`go test` passes what CI's Postgres run then fails, hence (b).
