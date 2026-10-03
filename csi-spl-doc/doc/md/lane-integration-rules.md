# Lane integration rules: the why (2026-10-03)

The spawn seed (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh`,
`_spawn_seed_blocks`) states the INTEGRATION rules (1)-(8), SCOPE (a)-(d) and
DEPLOY-GATE (a)-(e) as rules only. The seed is re-read on every turn of every
lane, so the history behind each rule lives here, read once when a rule seems
odd. Practice 02 of `agent-token-focus-plan.md`: a seed states rules, not their
history.

Measured shrink (dry-run spawn, `wc -c` of `prompt.txt`, n=1 per kind, tree
`83183be1`): claude 21,269 -> 7,789 B, qwen 21,475 -> 7,995 B.

## 1. Commit (rule 2)

### 1.1 Pathspec on the `add`, never on the `commit`

`git commit -- <path>` is a PARTIAL COMMIT: it re-reads those paths from the
WORKTREE and commits that, discarding an index mode set by
`git add --chmod=+x`. Measured on the main box 2026-09-12: index `100755` after
the add, COMMITTED `100644`, with and without `core.fileMode=false`.

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

### 1.3 Commit and push continuously

The scenario this prevents: several related changes, some fast (manifest,
prompt, config, docs, scripts, tests) and some slow (image generation,
rendering, uploads, large builds, rate-limited batch API calls). The fast ones
finish in minutes and are then held uncommitted for an hour while the slow one
grinds: the owner sees NOTHING land, trunk moves dozens of commits, and the
rebase becomes unresolvable. The fast changes stand on their own, cannot break
what they do not touch, and are usually the part the owner is waiting to read.
The same holds for verification: if item 3 of N fails, push the other N-1.

## 2. Rebase (rule 3)

### 2.1 Mode-only churn

Something outside a lane moves the OWNER EXECUTE BIT on tracked files, the one
mode bit git records: 158 paths went that way on 2026-09-12 with ZERO content
changed. A rebase then refuses with `cannot rebase: You have unstaged changes`.
`git diff --summary` lists `mode change` lines; a churned path appears there
with NO content hunk in `git diff`. Set the worktree bit back to what
`git ls-files -s <path>` records (`100755` -> `chmod +x`, `100644` ->
`chmod -x`). Staging such a path lands a spurious `100644 => 100755` next to
the change and nothing warns. Do not hunt the writer.

## 3. Push (rule 4)

### 3.1 Judge the landing by the repository, not the output

A REJECTED push also prints `HEAD -> master`; the full line is
`! [rejected] HEAD -> master (fetch first)`. A retry loop that greps the output
for that string reports success for a push that never landed. Measured on the
main box 2026-09-12: two shas were reported PUSHED and published as on trunk,
and were not there. `git merge-base --is-ancestor HEAD origin/master` reads the
repository; its exit code is the same check rule (8) needs before teardown.

## 4. Refresh the main source (rule 5)

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

## 5. Leak-gate (rule 6)

### 5.1 The quoted address is a default

It is read from the shared checkout's `.git/config` at spawn time, and that file
is contested mutable state every lane writes: it has been measured holding three
different values within one day. A canonical address in the repo's own
CLAUDE.md / AGENTS.md wins.

### 5.2 Two identity fields, one survives the protocol

`git rebase` re-stamps the COMMITTER from the ambient config, and rule (3)
mandates a rebase right before every push, so a commit made correctly with
`git -c user.email=… commit` is re-stamped on its way to trunk.
`git commit --amend --author=…` has the same hole from the other side: it fixes
the author and leaves the committer. Hence the identity on the rebase too, and
the gate reads both `%ae` and `%ce`: `%ae` alone reports green on a field it
never read.

### 5.3 `--no-mailmap` is the control

A root `.mailmap` maps the old addresses onto the canonical one, so plain
`git log` renders a wrong commit as correct.

### 5.4 Never `git config` from a worktree

With `extensions.worktreeConfig` unset every worktree shares one common
`.git/config` (`rev-parse --git-common-dir` from a worktree points at the
shared `.git`), so a `--local` identity, or `core.fileMode false`, changes the
shared checkout and every other lane. Pass `-c` per command. On the `commit`,
`-c core.fileMode=false` is worse than useless: a partial commit re-reads the
WORKTREE and the flag makes git ignore the very bit it would read (measured
2026-09-12: index `100755` after `git add --chmod=+x`, COMMITTED `100644`).

## 6. CI and every environment (rule 7)

A run can read cancelled while the commit ships later riding somebody else's
deploy, so a deployed-state check (`./run -a do_check_deploy_lag`) beats the
run colour. A red is yours when it names a module you touched or your commit
introduced it, including a dormant assertion that fired for the first time in
a file you never opened. "My module is not named" is a judgement about a log
not yet read. Reporting a red to its named owner is the discharge; noticing it
and moving on is not.

## 7. Teardown (rule 8)

A merged worktree left in `<repo>-wt/` clutters `git worktree list`, which other
lanes read to see who owns what.

## 8. Scope (SCOPE a-d)

Trunk moves constantly and very often already carries someone else's fix.
`git worktree list` sees one machine only; `lane-map.sh` covers every machine
of the fleet (specs/058 N2), and `--check` prints only the verdict. Duplicated
work is wasted tokens plus a rebase conflict for someone: "I fixed it too" is a
mess-up, not a bonus. A fix for a blocker outside the scope goes in its own
narrow commit so it drops cleanly if it turns out redundant.

## 9. Deploy-gate (DEPLOY-GATE a-e)

The tiers, the scanner list and the workflow numbers are the repo CLAUDE.md's
and `pre-push-gate.md`'s; the seed keeps only the commands. The gate exists
because a break caught on trunk stalls every deploy (SPL-1250). A memory-only
`go test` passes what CI's Postgres run then fails, hence (b).
