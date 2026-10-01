# SPEC: the agent identity map

Status: step (a) built: record + check. Steps (b) to (d) follow in this order.
Owner order, 2026-10-01: "some kind of hash to keep up-to-date the runtime tmux
window names and the session names in sync with this hash on the disk".

## 1. Why

1.1 On 2026-10-01 a reboot restore resumed seven agents in their neighbours'
sessions. The save had recorded window-name to session pairs it never
verified.

1.2 The same day, every spawn shifted six to nine window names by one. The
badge loop looked panes up by window index while the sorter moved them
(fixed in `agent-top.sh`, test `test-agent-top-race.sh`).

1.3 Window names and registry rows were the identity, and both drift. The map
replaces them as the source of truth. Names become derived output.

## 2. The record

2.1 There is one file per agent, `$SPOOL_ROOT/agents/<ID>.json`. Each is
written atomically (temp file plus rename) by `do_spl_agent_identity_record`,
and by nothing else.

| field | from |
|---|---|
| `id` | `SPOOL_AGENT_ID` (else `MCP_BOT_AGENT_ID`) in the process environment |
| `kind` | the CLI's argv[0] (claude, grok, agy, qwen) |
| `session_id` | the process's own `~/.claude/sessions/<pid>.json` (its start time must match), else `--session-id` / `--resume` |
| `worktree` | the session file's cwd, else `/proc/<pid>/cwd` |
| `title` | kept from the record; first set from the window name only when that name carries the same id |
| `model`, `permission_mode` | the CLI's argv |
| `user`, `pid`, `proc_start` | `/proc/<pid>/status` and `/proc/<pid>/stat` |
| `tmux_session`, `window_id`, `pane_id` | the pane whose process tree holds the process |
| `alive` | false once the process is gone; the record and its session are kept |
| `updated_at` | changes only when another field changes |

2.2 `index.json` holds `{v, hash, records, reconciled_at}`. `hash` is a sha256
over every record except `updated_at`, so it changes exactly when a record
changes.

2.3 An id that two live processes carry is reported as CONFLICT and never
recorded. A process whose environment carries no id is skipped, with the
reason.

## 3. Liveness

3.1 One rule holds for every reader (`ai_alive <ID>`, which prints the pid):
the record says alive, the pid exists with the recorded start time, the
process is that agent's CLI, and it carries `SPOOL_AGENT_ID=<ID>`.

3.2 The dispatch lease keeps its own `/proc` walk as a fallback. A relaunched
master is recorded only on the next pass.

## 4. Steps

4.1 (a) Lib `features/spawn-agents/lib/agent-identity.inc.sh`, engine
`scripts/agent-identity.py`, and the actions `do_spl_agent_identity_record` and
`do_spl_agent_identity_check`. Test: `tests/test-agent-identity.sh`.

4.2 (b) `do_spl_agent_identity_reconcile` sets every window name from its
record, from cron and from the tmux hooks, both installed by an action. The
spawn path and `riname.sh` write the record and then reconcile.

4.3 (c) The resolvers (`spool_pane_of`, `agent-send.sh`,
`tmux-close-window.sh`, desk liveness) read the map and verify the process.

4.4 (d) The reboot restore starts each record's session under its own id. The
box engine's save and restore call these actions.
