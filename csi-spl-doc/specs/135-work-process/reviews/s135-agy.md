signed against 4160581d3bc76827a494f82749572866c7f08926

## 1. Objects
- **discussion (topic)**: Created by human posts in channels or via terminal (developer-guide.md). States: open, on hold (⏸️ on the opening message via `do_spl_react`, SPEC-spool-fleet-roles.md:60), archived/closed. Moved by humans or agents. Links to an issue (`TaskID`). Ends when a human closes it.
- **issue**: Created by agents (`c-002`/`c-003` from the first answer) or humans. States (`csi-spl-api/src/go/spool-hub-api/internal/store/issues.go:26-35` and `csi-spl-wui/src/pages/issues.vue:1144-1151`): `eval` (backlog), `todo`, `wip` (in progress), `diss` (discarded/canceled), `blocked`, `onhold`, `qas` (review), `done`. Moved by agents. Links to a discussion (via `TaskID`). Ends in `done` or `diss`. Fields include Level (1 epic/feature, 2 issue, 3 subtask), Priority (1-5), Assignee, Labels, etc. (`csi-spl-api/src/go/spool-hub-api/internal/store/issues.go:126-147`).
- **lane (agent + worktree + branch)**: Created by orchestrator `c-001`. States: spawned, running, closed. Links to an issue. Ends when its one small task is verified (`/exit-clean`).
- **spec**: Created by panel editors (e.g. `s135-claude`). States: draft, v1.0-rc, v1.0. Links to an issue. Ends when implemented.
- **doc page**: Created/updated by lane agents based on approved specs.
- **release (v-tag)**: Created by CI deploys (`do_release_version`). States: immutable tag on master. Links to commits. Ends never.

## 2. Roles
- **owner**: Does: asks questions, answers blocking decisions, approves prd operations and force-pushes. Never does: uses owner account (must use SA keys, CLAUDE.md:30), routes traffic.
- **orchestrator (c-001)**: Does: decides, spawns lanes, re-seats agents, verifies "live" claims, runs prd ops that dispatchers refuse (SPEC-spool-fleet-roles.md:16). Never does: takes a post the dispatch lease holder has taken, routes routine traffic.
- **dispatchers (c-002/c-003)**: Does: takes new posts, answers them, owns the topic, spawns a new lane for real work, escalates to c-001 (SPEC-spool-fleet-roles.md:17). Never does: runs prd ops its harness refuses, decides for the owner.
- **lane agents**: Does: one small task, builds, tests, lands, proves live, reports. Never does: route other lanes' traffic, touch other agents' files (clobber guard).
- **panel seats + editor**: Does: panel seats write their review file; editor writes `spec.md` and collects consensus. Never does: touch another seat's file.
- **reviewers (agy language rule)**: agy has the final word on multilingual text (CLAUDE.md:141).
- **CI**: Does: deploys dev and prd, runs pre-push gates, mints versions. Never does: guess if a test failure is yours.

## 3. The flow
1. **Owner post**: The owner posts a request or question.
2. **Discussion**: Taker dispatcher (`c-002`) takes the post and owns the topic.
3. **Issue(s)**: The dispatcher spawns an issue (if not already existing) in `eval` state. An owner question waits for his decision before proceeding.
4. **Lane**: Orchestrator `c-001` spawns a lane agent for the work item.
5. **Branch**: Lane agent creates a worktree and local branch to work. Issue moves to `wip`.
6. **Master**: Agent rebases, tests, and pushes to `master`.
7. **CI**: CI runs quality gates, tests on `master`.
8. **Deploy dev and prd**: CI deploys to `dev` and `prd`.
9. **Issue DONE**: The lane agent checks deployed lag, then `c-341` moves the issue to `done` once landed.
10. **Docs updated**: Agent updates docs if the task requires it.
11. **Owner told**: The lane agent reports final summary to `c-001` who tells the owner.

## 4. Branching and deployment
Today: Changes are rebased onto `origin/master` and pushed directly (`git push origin HEAD:master`). The pre-push hook runs the gate (`do_check_pre_push`). A push to `master` runs CI which deploys to `dev` and `prd` and mints version tags (`CLAUDE.md:129`).
- **Option A**: Keep the push-to-trunk strategy as it is. It is fast, linear, and heavily guarded by CI and pre-push hooks.
- **Option B**: Switch to a branch-based strategy requiring PRs and CI checks before merging to master.
- **Recommendation**: **Option A**. The owner has explicitly stated this strategy "HAS WORKED for the last 4500 commits" (`developer-guide.md:10`) and enforcing strict pre-push gates provides adequate safety without losing velocity.

## 5. Context and restart
An issue carries enough state in the hub's DB and the spool messages to restart work. The issue record maintains the `Status`, `TaskID` (pointing to the spool topic thread), and `Assignee`. The dispatcher can "park its context (branch, held commit, the open question) in `/var/tmp/c-parent-level/dispatch/hold/<topic>/`, close it, and respawn from the hold dir when the answer comes" (`SPEC-spool-fleet-roles.md:43`). The transcript history is durable in the `<spool root>/<id>/inbox` and `asks/journal.log`, allowing a fresh session or watchdog restart to read the context and resume the lane work.

## 6. What today's lanes keep or change
- **c-880**: Keep carrying an issue per lane.
- **c-350**: Keep owner questions as discussions until the owner explicitly makes them an issue.
- **c-340**: Keep discarding stale issues.
- **c-339**: Keep needs-owner label and daily digest.
- **c-341**: Keep moving a landed fix's issues to DONE.

## 7. Owner questions
Owner: "Maybe spawn one issue always, and the agents should discuss with me how to define the issue properly... Even if the entity of work is to do some kind of evaluation and some kind of answering my questions"
- **Option A**: Spawn an issue in `eval` status for every new discussion to track it structurally, even for questions, until it is defined or discarded.
- **Option B**: Keep discussions and issues completely decoupled until actionable work is decided.
- **Recommendation**: **Option A**. Spawning an issue immediately in `eval` ensures no context is lost, provides a concrete tracker for the discussion, and fulfills the owner's request to "keep track of what is happening" and manage context windows better.
