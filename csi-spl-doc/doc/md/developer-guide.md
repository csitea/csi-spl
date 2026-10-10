# Developer guide: how a change reaches master

For every coder of this repository, human or agent. It describes the branching
and deployment strategy as it is, and the rules that keep it safe. It changes
none of it. Each rule keeps its one home (see the
[fleet rules index](fleet-rules-index.md)); this page explains and points.

Owner, 2026-10-10: "we should have a Developer guide which explains those
rules for both human and agent coders" (msg d1753612), and it "explains the
branching and deployment strategy of ours, WHICH HAS WORKED for the last 4500
commits" (msg b7a94362).

## 1. The strategy, as it is

### 1.1 Trunk: everyone pushes to master

There is one long-lived branch, `master`. A change is a small commit, rebased
onto the current `origin/master` and pushed straight to it:
`git push origin HEAD:master`. The fleet opens no pull requests; a lane's
local branch and worktree are scratch space, removed once the change landed.
Outside contributors use a fork and a pull request instead
([CONTRIBUTING.md](../../../CONTRIBUTING.md)).

It has carried the project so far, measured 2026-10-10:

- `git rev-list --count origin/master` -> 4951 commits.
- `git log --merges --oneline origin/master | wc -l` -> 1 merge commit: the
  history is linear, every change rebased.

### 1.2 CI deploys dev and prd on the push

A push to master runs the gate (`.github/workflows/10_ci-quality.yml`) and,
when their inputs changed, the deploys: the hub
(`20_hub-build-deploy.yml`) and the web UI (`30_wui-build-deploy.yml`), both
to `dev` and `prd` (`grep -n "wanted=(dev prd)"` on each file -> one line).
Nobody deploys by hand on the normal path. A change is done when it is
deployed in both environments:
`cd csi-spl-orc && ENV=<dev|prd> ./run -a do_check_deploy_lag`.

### 1.3 The version is minted, never edited

Every hub and web UI deploy mints its commit's version with
`do_release_version` (`csi-spl-orc/src/bash/run/release-version.func.sh`): a
`v<X.Y.Z>` git tag one step past the highest, claimed by pushing the tag. Never
roll the version by hand; the repo [CLAUDE.md](../../../CLAUDE.md) says when
the floor (`.version`) is raised.

## 2. The rules for a change

### 2.1 Small commits, explicit pathspecs

- One topic per commit; the message says why.
- Stage named paths: `git add <path>...`, then `git commit` with no pathspec.
  Never `git add -A` or `git commit -a`: in a shared tree they sweep up other
  people's work. Why the pathspec goes on the `add`:
  [lane integration rules](lane-integration-rules.md) section 1.1.
- Push each commit soon: a change held back while trunk moves becomes a
  rebase nobody can resolve (same page, section 1.3).

### 2.2 Rebase onto the others' work, re-test, then push

Before EVERY push:

1. `git fetch origin master`
2. `git rebase origin/master`: your commits go on top of what others landed.
3. Re-run the tests of what you touched (repo [CLAUDE.md](../../../CLAUDE.md),
   "Run the cheap gate for the tree you touched").
4. `git push origin HEAD:master`

A refused push means someone landed first: go back to step 1. A push has
landed when `git merge-base --is-ancestor HEAD origin/master` holds after a
fresh fetch, not when the push printed `HEAD -> master`
([lane integration rules](lane-integration-rules.md) section 3.1).

### 2.3 The pre-push gate

`cd csi-spl-iac && ./run -a do_check_pre_push` runs before every push; the
installed pre-push hook runs it for you. Its tiers and parts:
[pre-push gate](pre-push-gate.md). Touching the store or a migration:
`PRE_PUSH_TIER=full`.

### 2.4 Identity, no AI trailers

Commits carry the author's real identity, the address on the repo
[CLAUDE.md](../../../CLAUDE.md) "Commits:" line, as author and as committer
(a rebase re-stamps the committer, so pass the identity to it too). No
`Co-Authored-By:`, `Generated with …` or session-link trailer. The why:
[lane integration rules](lane-integration-rules.md) section 5.

## 3. Never force-push or delete master

A force-push (`--force`, `--force-with-lease`, `+ref`) replaces the commits
others landed with yours; deleting master removes everyone's. Neither is how a
change lands, and `SPL_PREPUSH_OVERRIDE` is never a way through a refused push.

The rule, final wording (owner msgs 1ca01c83, 3e095a04):

> No agent force-pushes to master without the owner's explicit approval of
> that one push; even then the owner decides who does it, often by hand. Ask
> and wait; never treat an approval as permission to go ahead alone.

Its one home is `NO_FORCE` in
`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh`,
rendered into every agent's seed; its history and cases are in section 3.2 of
the [lane integration rules](lane-integration-rules.md).

The why, the owner (msg 097f9de3): "Everyone respects the work of the others.
We are team and not a bunch of selfish cawboys".

## 4. What enforces it

Live on master on 2026-10-10, each checked by the command shown:

| layer | what it refuses | where |
|---|---|---|
| GitHub ruleset `master-no-force` | a non-fast-forward push and a deletion of master, for everyone, no bypass actor | `gh api repos/csitea/csi-spl/rulesets/24832017` -> `enforcement: active`, rules `deletion` + `non_fast_forward`, `bypass_actors: []`; managed by `do_spl_gh_master_ruleset` (`csi-spl-iac/src/bash/run/spl-gh-master-ruleset.func.sh`, e900d9f04); lifting it is the owner's, by hand |
| pre-push hook | a non-fast-forward push or delete of master, `SPL_PREPUSH_OVERRIDE` included | `csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push` (3e082c94c), test `spawn-agents/tests/test-pre-push-non-ff.sh` |
| shared command matcher | every forbidden push form in a shell command, for the harness guards to call | `csi-spl-orc/src/bash/features/spawn-agents/lib/force-push-guard.inc.sh` (f6a7da70f), test `csi-spl-orc/src/bash/tests/force-push-guard.tst.sh` |
| agent seed rule | states the rule to every agent type (c-, g-, a-, q-, m-) | `NO_FORCE` in `spawn-core.inc.sh` (6bdd3c436), test `spawn-agents/tests/test-seed-no-force-push.sh` |
| pre-push hook | a push to master by a coder with no ack of this guide (section 6), `SPL_PREPUSH_OVERRIDE` included | `dga_check` in `csi-spl-orc/src/bash/features/spawn-agents/lib/dev-guide-ack.inc.sh`, test `spawn-agents/tests/test-pre-push-dev-guide.sh` |

Not yet live: the harness hooks that call the shared matcher before a command
runs (`git grep -l force-push-guard origin/master` -> the matcher and its test
only). Until they land, the ruleset and the pre-push hook are the layers that
stop a forbidden push.

## 5. Where the rest is

- Every fleet rule and its one home: [fleet rules index](fleet-rules-index.md).
- The why of each seed rule: [lane integration rules](lane-integration-rules.md).
- Repo rules (environments, service accounts, terraform, gates):
  [CLAUDE.md](../../../CLAUDE.md).
- Outside contributors: [CONTRIBUTING.md](../../../CONTRIBUTING.md).

## 6. Confirm you have read this guide

Owner, 2026-10-10 (msg 56d7073e): every new coding person or agent "must
agree that they have read" this guide. After reading it, confirm it once, as
the OS user you push with:

`cd csi-spl-orc && ./run -a do_dev_guide_ack`

On a terminal it shows the guide and asks; an agent passes its id and the
confirmation: `AGENT_ID=<id> DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack`
(STEP 0 of every agent seed). It records one line, who and this guide's git
blob sha, in your ack store under `$XDG_STATE_HOME` (default
`$HOME/.local/state`) or `$DEV_GUIDE_ACK_FILE`.

- The pre-push hook refuses a push to master without an ack for the guide
  the push carries, and prints the command above.
- **A material change is any change to this file's blob**
  (`git rev-parse HEAD:csi-spl-doc/doc/md/developer-guide.md`): it asks
  every coder to read and confirm again. Batch small fixes into one commit.
- Work trees created before 2026-10-11T00:00Z pass without an ack until
  the guide first changes after that time, so the rollout stopped no one
  already working.
