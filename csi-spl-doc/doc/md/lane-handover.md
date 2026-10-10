# Lane handover: move a lane, its work and its memory to another box

Owner, t1 ba8104f6 (msg 6d3cafa7): "move the memory from the session of the
previous agent and also to move some work which is not done". Built for
claude lanes (msg b072af77); agy and mistral have their own actions on the
same shared WIP step.

## 1. Use

Dry run first (the default): it scans the WIP, picks the mode and prints the
plan. It makes no ssh call and pushes nothing.

`cd csi-spl-orc && FROM=c-050 TO_BOX=sat ./run -a do_spl_lane_handover`

Then, with the orchestrator's go:

`cd csi-spl-orc && FROM=c-050 TO_BOX=sat DRY_RUN=0 ./run -a do_spl_lane_handover`

`TO_ID` defaults to `FROM`: the new agent keeps the id on the other box
(`c-050@sat`), so its worktree path and its session slug stay the same.

## 2. What it does, in order

| step | what | where |
|---|---|---|
| 1 scan | FROM's uncommitted files and unpushed commits through `box-state-pack.sh scan` (excluded names, NetVisor and bank credential files, key and token material) plus a 0600 rule. A hit: exit 3, the file NAMED, nothing pushed, FROM untouched | `do_spl_lane_handover_wip` |
| 2 close | FROM's window closes, after its spec 102 handoff is composed | `tmux-close-window.sh --agent` |
| 3 WIP | the dirty tree, committed in a temp index on FROM's HEAD (its own index and files untouched), pushed to `refs/heads/wip/handover/<FROM>` without force; the pre-push hook skips `wip/*` refs (spec 102 5.4) | `do_spl_lane_handover_wip` |
| 4 worktree | on TO_BOX, `<repo>-wt/<TO_ID>` on branch `<TO_ID>-handover`, AT that ref | ssh, as the box's OWNER_USER |
| 5A session | FROM's transcript (`<sid>.jsonl` and `<sid>/`) over ssh stdin into the target AGENT_USER's `~/.claude/projects/<slug>`, then `restore-claude.sh` resumes it in a new window, bypass flags, as the agent user | ssh only |
| 5B fresh | `spawn-window.sh claude <TO_ID>` with the handover brief; the existing worktree is reused | ssh |
| 6 retire | FROM's id is retired with `RETIRE_WORKTREE=0`: its worktree stays | `agent-id-retire.sh` |

The handover brief (`<spool root>/handover/<TO_ID>-from-<FROM>.md` on the
target) carries FROM's brief, its spool task id, its last outbox message
and, in B, its `handoff.md`.

## 3. A or B

A (session resume) is used unless one of these holds, then B:

- `TO_ID` differs from `FROM` (another path, another session slug)
- no session id in `agents/<FROM>.json`, or no transcript for it
- the transcript is over `HANDOVER_TRANSCRIPT_MAX_MB` (default 100)
- the transcript scan finds key material: it never leaves the box
- `HANDOVER_MODE=B`, or the copy fails during the run

`HANDOVER_MODE=B` is also the answer when TO_BOX's agent login has no quota
left: a resumed session would start on the same limit.

## 4. After the start

- The new agent's first commit may be `wip(<FROM>): ... handover`: its brief
  tells it to `git reset --mixed HEAD~1` and commit that work properly.
- After its first landed push it deletes `refs/heads/wip/handover/<FROM>`
  and tells its reporter that FROM's old worktree may be removed.
- FROM's worktree on the old box stays until then (it is the fallback copy);
  `git worktree remove` it on that box afterwards.

## 5. Data rule

A transcript can hold secrets. It travels box to box over ssh stdin only:
never the hub, git, a log or argv, and a transcript the scan flags stays on
the box (mode B). The finance key rule (spec 125, C6) is the scan's
NetVisor / bank credential pattern.

## 6. Tests

- `bash csi-spl-orc/src/bash/tests/spl-lane-handover-wip.tst.sh`
- `bash csi-spl-orc/src/bash/tests/spl-lane-handover.tst.sh`

Both offline: stubbed ssh, sudo, tmux and spawn scripts, with red controls
for the scan refusal and "nothing pushed when the scan fails".
