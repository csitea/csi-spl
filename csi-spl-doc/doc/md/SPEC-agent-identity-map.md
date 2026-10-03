# SPEC: the agent identity map

Status: steps (a) to (d) are built. The box engine calling (d) at boot is the last switch.
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

Agent ids follow the grammar in [spec 061 section 0](../../specs/061-agent-id-rename/spec.md#0-the-marker-the-old-form-ends-2026-10-03):
`^[acgq]-[0-9]{3}$` (`c-`, `a-`, `g-`, `q-` with 3 digits `004`..`999`; role seats `001`..`003`). Legacy ids end at `2026-10-03T20:59:59Z`.

2.1 There is one file per agent, `$SPOOL_ROOT/agents/<ID>.json`. Each is
written atomically (temp file plus rename) by `do_spl_agent_identity_record`,
and by nothing else.

| field | from |
|---|---|
| `id` | `SPOOL_AGENT_ID` (else `MCP_BOT_AGENT_ID`) in the process environment |
| `kind` | the CLI's argv[0] (claude, grok, agy, qwen) |
| `session_id` | the process's own `~/.claude/sessions/<pid>.json` (its start time must match), else `--session-id` / `--resume` |
| `worktree` | the session file's cwd, else `/proc/<pid>/cwd` |
| `session_name` | the session file's `name` (`--name`, `/rename`) |
| `title` | the session name without tag and id, adopted when the session name changes; else what `riname.sh` set; first set from the window name only when that name carries the same id |
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

4.2 (b) `do_spl_agent_identity_reconcile` sets every agent window to
`<ID>@<tag> [badge] <title>` (older windows: `<tag>: <ID> [badge] <title>`) from its record. It keeps a state badge only on
the right id, compare-and-sets each rename on the pane id, and turns off
`allow-rename` / `automatic-rename` on that window. `riname.sh` writes the
title into the record (`set-title`) and then reconciles. Its pane comes from
the process, never from a registry row. `do_spl_agent_identity_install` adds
the per-minute cron line and the `after-new-window[1]` / `pane-exited[1]`
hooks (the sorter keeps index 0); `IDENTITY_UNINSTALL=1` removes them. Test:
`tests/test-agent-identity-reconcile.sh`.

4.3 (c) The resolvers read the map first and verify the process:
`spool_pane_of` (which pokes from `spool-send.sh` and `agent-send.sh` go
through), `tmux-close-window.sh --agent`, and the desk's live-agent list. The
desk now counts an agent as live when the map proves its process, even when no
window carries its id. The check is fork-free bash (`ai_alive_fast`,
`ai_pane_of`), so a poke costs the same as before (about 120 to 170 ms live).
When there is no record, or the process cannot be proven (another user's
environment), the old registry and window-name lookup runs unchanged. A
process of another user is read as that user (`sudo -n -u <owner>`, only on a
permission error), so agents that run as the agent user are mapped too.
Test: `tests/test-agent-identity-resolve.sh`.

4.4 (d) `do_spl_agent_identity_restore` (DRY_RUN=1 default) starts again every
agent the restart killed:

- a record that still says alive with no process, or one the first pass after
  the restart flipped (dead between the boot time and
  `IDENTITY_RESTORE_WINDOW` minutes later);
- each resumes its own session in its own worktree, in a NEW window (tmux
  re-issues pane ids after a restart), through `restore-<kind>.sh`, as the
  box's AGENT user (`SPOOL_AGENT_USER`), never the user the record says it
  ran as (owner rule 2026-10-01: every programmatic start runs as the agent
  user); a claude transcript only in that recorded user's home is copied into
  the agent user's `~/.claude/projects` first (the jsonl and its `<sid>/`,
  never overwriting), and a started agent that still runs as the box user is
  an ALERT with a non-zero exit;
- each gets a fresh spool-registry row (`IDENTITY_LEGACY_REGISTRY` also takes
  one), then reconcile names the windows and check runs.

A record is REFUSED, named and skipped, when its session is unknown, is on two
records, or is already running; when its worktree is gone; or when its
transcript is not under that worktree's project dir or belongs to another
agent. Tests: `tests/test-agent-identity-restore.sh`,
`tests/test-agent-identity-restore-user.sh`. The box engine's boot job
calls this action instead of inferring agent sessions from window names.

4.5 A box with no such boot job (the satellite) runs
`do_spl_agent_boot_restore` at `@reboot`, installed by
`do_spl_agent_boot_restore_install_cron` (one line tagged
`csi-spl:agent-boot-restore`): it waits for the tmux server (creates the
session when none came), runs (d), then applies the owner's check (no agent
CLI runs as the box user). A failure leaves `<SPOOL_ROOT>/agents/boot-FAILED`.
Test: `tests/test-agent-boot-restore.sh`.
