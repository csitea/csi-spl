# Implementation Plan: Uniform box API and the standard box launcher (012)

**Branch**: `CLE-3347-012-box-api-harness` · **Spec**: `spec.md` · **Milestone**: M1

## Summary

The box API itself is already shipped (002 verbs + MCP, 003 hub-mode
additions); 012 re-verifies it against the binding narrative and fixes only
mismatches (none found). The new artifact is `spool-harness`, the launcher
that runs the five-step bootstrap and exec-s the agent CLI.

## Technical Context

**Language**: bash (launcher), Go 1.x (`spool` binary, unchanged).
**Dependencies**: `flock`, `setsid` (util-linux), the `spool` binary for hub
mode only (`SPOOL_BIN`, resolved by `lib/spool-env.inc.sh`).
**Testing**: `tests/test-spool-harness.sh` in the spawn-agents feature, run by
its `run-all-tests.sh`; throwaway `SPOOL_ROOT` and `$HOME`; a fake `spool` that
writes the roster cache stands in for `hub-run`, so no hub is needed.
**Constraints**: org-neutral (no users, hosts, homes); no key ever created or
logged; local mode unsigned.

## Constitution check

- [x] **Uniform API (VIII)**: no per-kind names; the harness is kind-agnostic
  (it takes any command).
- [x] **Local unsigned**: local mode needs no key and creates none.
- [x] **No key in git or logs**: the harness only `stat`s the key.
- [x] **Hub internals untouched**: no edit under `csi-spl-api/.../internal/hub/`
  or `cmd/spool/`.

## Project structure

```text
csi-spl-orc/src/bash/features/spawn-agents/
├── lib/spool-env.inc.sh            # reused: spool_valid_id, SPOOL_BIN
├── scripts/spool-harness.sh        # NEW: the launcher
└── tests/test-spool-harness.sh     # NEW: init sequence, refusals, sidecar
csi-spl-doc/specs/012-spool-box-api/
├── spec.md  plan.md  tasks.md
└── contracts/{cli-mcp-map.md,spool-harness.md}
```

## Design

1. **Parse** `--as`, `--to-box`, `--`; validate the agent id (identity-routing
   §2 regex, no `BOX-`) and box id (`^[a-z0-9][a-z0-9-]{0,31}$`, same as
   `msg.ValidBoxID`) before touching disk.
2. **Dirs** with `mkdir -p` + `chmod 0775` on dirs this user owns; a foreign
   dir must at least be writable. `umask 0002` is inherited by the agent.
3. **Identity**: `stat -c %a` on the key; the hub-mode refusal is 78 so a
   caller reads it the same way as a `spool` refusal.
4. **Sidecar**: under `flock $SPOOL_ROOT/.hub/hub-run.lock`, a pidfile whose
   pid is alive **and** whose `/proc/<pid>/cmdline` carries `hub-run` means
   running; else `setsid spool hub-run` (stdin `/dev/null`, log
   `$SPOOL_ROOT/.hub/hub-run.log`). Then poll the roster cache
   `$SPOOL_ROOT/.hub/roster.json` (`{"<box>":["<id>",…]}`, written by
   `hubclient.saveRoster`) every 0.2 s up to `SPOOL_HARNESS_WAIT_SECS`
   (default 25: `hub-run` rescans agent dirs every 10 s).
5. **Env + exec**.

## Phases

| # | What | Status |
|---|---|---|
| 1 | Verify CLI ↔ MCP 1:1 and exit 78 against the narrative | Implemented |
| 2 | `spool-harness` + tests | Implemented (`c619d5d`) |
| 3 | This git-spec | Implemented |
| 4 | Live-hub harness proof; PATH packaging; spawn adapters use the harness | Planned |

<!-- version: 1.0.0 · updated: 2026-09-19 · last-edit: 2026-09-19T01:55:00Z -->
