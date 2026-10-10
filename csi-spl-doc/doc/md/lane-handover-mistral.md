# Lane handover for mistral lanes

The mistral twin of the [claude lane handover](lane-handover.md) (owner, t1
ba8104f6 msg b072af77; topic 9d603c3d). Same steps, same shared WIP step
(`do_spl_lane_handover_wip`), same helpers; only the session part differs.
Code: `csi-spl-orc/src/bash/run/spl-lane-handover-mistral.func.sh`, test
`csi-spl-orc/src/bash/tests/spl-lane-handover-mistral.tst.sh`.

## 1. Use

Dry run first (the default): the WIP scan, the mode and the plan; no ssh call,
nothing pushed.

`cd csi-spl-orc && FROM=m-050 TO_BOX=sat ./run -a do_spl_lane_handover_mistral`

Then, with the orchestrator's go:

`cd csi-spl-orc && FROM=m-050 TO_BOX=sat DRY_RUN=0 ./run -a do_spl_lane_handover_mistral`

## 2. Where a mistral agent keeps its session

Measured on vibe 2.26.0 (`vibe --version`), 2026-10-10.

| what | where | how checked |
|---|---|---|
| the session | the agent user's `~/.vibe/logs/session/unified/<sid>/`: `CURRENT`, `meta.json`, `chunks/`, `generations/`, `journal/` | `find ~/.vibe/logs/session/unified/<sid> -maxdepth 2 -not -path '*/chunks/*'` |
| its worktree | `meta.json` `.environment.working_directory` | `jq .environment <sid>/meta.json` |
| its lease | `~/.vibe/logs/session/active/<sid>.lock`, outside the session dir: a copy carries no lease | `vibe/core/session/session_lease.py` (`root / "active"`) |
| the session id | NOT in the identity record: `jq .session_id /var/spool-hub/agents/m-*.json` -> null for every m- lane | so the action picks the newest root session whose `working_directory` is FROM's worktree, which is what `vibe --continue` resumes there |
| sizes | the largest session dir on this box is 20 MB | `du -sm ~/.vibe/logs/session/unified/*/ \| sort -n \| tail -1` |

## 3. Resume on another box

`vibe --resume <sid>` needs only `unified/<sid>/CURRENT` under the session
save dir; it is not tied to the box or the cwd
(`vibe/app_server/_runtime.py`, `_resolve_unified_session_id`). So mode A
copies the one session dir over ssh stdin into the target agent user's
`~/.vibe/logs/session/unified/`, then starts
`restore-mistral.sh <TO_ID> <worktree> <sid> <handover brief>` in a new tmux
window: the launch line of `spawn-mistral.sh` (cost cap, `env -u
MISTRAL_API_KEY`, worktree ACL) and the brief as its kick.

A needs `TO_ID` = `FROM`: the session's memory names its worktree path, and
only the same id gives the same path on the other box.

## 4. How the fleet starts a mistral agent

`/mistral-spawn` runs `spawn-window.sh mistral <ID> <workdir> <brief>`, whose
window runs `spawn-mistral.sh` (the mistral adapter of `spawn-core.inc.sh`).
Mode B uses that: `spawn-window.sh mistral <TO_ID> <repo> <handover brief>`.

## 5. Mode B, and the data rule

B (a fresh agent with the written handover brief: FROM's brief, task id, last
outbox report, spec 102 handoff) when `HANDOVER_MODE=B`, `TO_ID` differs, no
session names the worktree, the session is bigger than
`HANDOVER_TRANSCRIPT_MAX_MB` (100), the `box-state-pack.sh scan` finds key
material in it, or the copy fails. A session can hold secrets: it travels box
to box over ssh stdin only, never in argv, the hub, git or a log.
