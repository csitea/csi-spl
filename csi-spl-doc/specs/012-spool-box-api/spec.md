# Feature Specification: Uniform box API and the standard box launcher

**Feature ID**: `012-spool-box-api` · **Milestone**: M1

**Created**: 2026-09-19 (git-spec from the binding narrative
`../../doc/md/SPEC-spool-box-api.md` v0.2.0, 2026-09-18; verified on trunk
`c619d5d`)

**Status**: **Partial** — the box API (CLI verbs, five MCP tools, exit 78) was
already shipped by 002/003 and is re-verified here; the launcher
`spool-harness` is new in this spec and **Implemented** for local mode and for
hub mode against a fake sidecar. A harness run against a live hub is Planned.
See "Verified status".

**Input**: every agent kind (claude / grok / agy) on a box must reach spool
through one API: the same CLI verbs, the same MCP tool names, the same `v:1`
JSON. And every agent session must start from the same bootstrap: its spool
dirs, the box identity, the hub sidecar, its env — done by one launcher,
not by hand.

**Authorities**: narrative `../../doc/md/SPEC-spool-box-api.md` (binding);
redo rules `../README.md` §2; trust model
`../002-box-agent-messaging/contracts/trust-modes.md` (wins on any difference).

**Contracts (this dir)**: `contracts/cli-mcp-map.md` (verb ↔ tool ↔ fields ↔
exit codes, with the test that pins each row) and `contracts/spool-harness.md`
(launcher CLI, init sequence, env, exit codes).

**Seams**: the verbs, tools and message schema are **002's**
(`../002-box-agent-messaging/contracts/cli.md`, `mcp-tools.md`,
`message-schema.md`); the hub-mode `to_box` / `delivery` additions and the
sidecar `spool hub-run` are **003's**. 012 cites them and adds only the
launcher. Agent-id allocation stays with the spawner (004 FR-010,
`csi-spl-orc/.../next-agent-id.sh`); the harness validates and prepares the
id it is given, it does not allocate.

**Depends on**: 002 (local folders, verbs, MCP), 003 (`spool hub-run`, roster
cache), 004 (id and box-id formats, box key path). **Used by**: the spawn
adapters in `csi-spl-orc/src/bash/features/spawn-agents/` and any box image.

## User Scenarios & Testing

### User Story 1 - One API for every agent kind (Priority: P1) 🎯 MVP

A grok agent calls `spool send`, a claude agent calls the `spool_send` MCP
tool; both write the same `v:1` object, get the same result and the same exit
code on a refusal.

**Why**: a per-kind dialect forks the bus; a new vendor must be a new id
prefix, not a new API (narrative §8).

**Independent test**: `TestSC004MCPEqualsCLI`, `TestToolNamesAreCanonical`
(`internal/mcp/mcp_test.go`).

1. **Given** twin empty roots, **When** each of put-file / send / recv /
   get-file / tail runs once as a CLI verb and once as its MCP tool, **Then**
   the files written and the returned text are identical.
2. **Given** a corrupted blob, **When** `get-file` runs, **Then** the CLI exits
   78 and the tool returns an error carrying the same reason and `(exit 78)`.
3. **When** the MCP server lists its tools, **Then** exactly the five canonical
   names come back — no `spool_send_claude` style variants.

### User Story 2 - Launch an agent session with one command (Priority: P1)

The operator (or a spawn adapter) runs
`spool-harness --as CLE-07 -- claude`. The agent starts with its inbox,
outbox and archive in place, `SPOOL_AGENT_ID=CLE-07` in its env and, in hub
mode, a connected box sidecar that has announced `CLE-07`.

**Why**: hand-made env and dirs drift per kind and per box; the AI CLI must
never be burdened with key generation or pin setup (identity-routing §2).

**Independent test**: `csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-harness.sh`.

1. **Given** local mode (`SPOOL_HUB_URL` unset) and no box key, **When**
   `spool-harness --as CLE-99 -- echo harness-ok` runs, **Then** it prints
   `harness-ok`, `$SPOOL_ROOT/CLE-99/{inbox,outbox,archive}` and
   `$SPOOL_ROOT/{files,pins}` exist 0775, and the child sees `SPOOL_ROOT`,
   `SPOOL_AGENT_ID=CLE-99` and umask 0002.
2. **Given** hub mode, **When** `SPOOL_BOX_ID` is unset, the box key is
   missing, or the key is not 0600, **Then** the harness refuses with exit 78
   and the agent never starts.
3. **Given** hub mode and a valid key, **When** no sidecar runs for this
   `$SPOOL_ROOT`, **Then** the harness starts one `spool hub-run`, detached,
   waits until the roster cache lists the agent under this box, then exec-s.
   A second session reuses the live sidecar.
4. **Given** hub mode and a hub that is down, **Then** the agent still starts
   with a warning (sends queue as `pending`); with `SPOOL_HARNESS_STRICT=1` it
   refuses with exit 69 instead.

### Edge Cases

- A bad agent id (`cle-1`, `BOX-1`, `AGY-01.1`) or box id → 78, nothing created.
- Two harnesses starting at once on one root → one sidecar (flock on
  `$SPOOL_ROOT/.hub/hub-run.lock`); a second `hub-run` would be superseded by
  the hub (4409) anyway.
- A roster cache left by an earlier sidecar is not trusted after a fresh start:
  the harness waits for one written after the start.
- A spool dir owned by another user and not writable → 73.

## Requirements

- **FR-001** — One API for every kind: the verbs `put-file`, `send`, `recv`,
  `get-file`, `tail` (plus `put-dir`, `get-dir`, `keygen`, `pin`) and the MCP
  tools `spool_put_file`, `spool_send`, `spool_recv`, `spool_get_file`,
  `spool_tail` call the same `internal/action` code. **Implemented** —
  `cmd/spool/main.go:100-114`, `internal/mcp/mcp.go:57-112`;
  `TestSC004MCPEqualsCLI` PASS.
- **FR-002** — The five canonical tool names and no others.
  **Implemented** — `TestToolNamesAreCanonical` PASS.
- **FR-003** — CLI ↔ MCP fields map 1:1 (`contracts/cli-mcp-map.md`).
  **Implemented** — every narrative §3 input field is present with the same
  JSON name; results are **supersets** of narrative §3 (`delivery`, `kind`,
  `file_id` are the additive 003 OQ-01 fields).
- **FR-004** — Verify/refuse exits 78 on the CLI and is a tool error carrying
  `(exit 78)` over MCP: hash mismatch, unpinned box, bad signature.
  **Implemented** — `action.ExitCode` (`internal/action/action.go:199`),
  `spool.ExitCode` (`internal/spool/spool.go:311`); asserted in
  `TestSC004MCPEqualsCLI`.
- **FR-005** — `spool mcp` is a stdio child per agent session, not a daemon.
  **Implemented** — `cmdMCP` (`cmd/spool/main.go`) serves stdin/stdout and
  exits when stdin closes.
- **FR-006** — Hyphenated names `spool-put-file` … `spool-tail` as shims over
  `spool <verb>`. **Planned** — `grep -rln spool-put-file --include=*.sh .` ->
  none. The narrative allows `spool <verb>` instead (§2), which ships; shims
  are packaging for a box image, task T012.
- **FR-007** — `put-dir` / `get-dir` over MCP. **Out of scope** — narrative §3
  names five tools and §4 maps five verbs; adding tools would break FR-002.
- **FR-010** — `spool-harness --as <id> [--to-box <box>] [--] <cmd...>`
  exists on the box. **Implemented** (`c619d5d`) —
  `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-harness.sh`.
  Home decision in `plan.md`.
- **FR-011** — Step 1, dirs: agent `inbox|outbox|archive` and shared
  `files|pins`, 0775; umask 0002 so agent files are 0664. **Implemented** —
  test-spool-harness.sh "local: … is 0775", "umask 0002".
- **FR-012** — Step 2, identity: box id format; key
  `$SPOOL_KEYS_DIR|$HOME/.spool/keys/box-<box_id>.key` mode 0600; optional in
  local mode, required in hub mode (78). **Implemented** — tests "hub: no box
  id/no box key/0644 box key -> 78", "local: no key and no keys dir needed".
- **FR-013** — Step 3, sidecar: in hub mode, a live `spool hub-run` for the
  root and the agent in its roster. **Implemented** against a fake sidecar
  (tests "hub: …"); against the real binary with an unreachable hub (started,
  detached, warned, exec'd). **Partial** — never run against a live hub
  (T011).
- **FR-014** — Step 4, env: `SPOOL_ROOT`, `SPOOL_BOX_ID` (when set),
  `SPOOL_AGENT_ID`. **Implemented** — tests "injected".
- **FR-015** — Step 5, exec: the harness process becomes the agent (no
  wrapper parent left). **Implemented** — `exec "$@"`; test "exec-s the
  command".

## Verified status (2026-09-19)

| Area | Status | Evidence |
|---|---|---|
| CLI verbs = MCP tools, same code | Implemented | `TestSC004MCPEqualsCLI` PASS |
| Five canonical tool names | Implemented | `TestToolNamesAreCanonical` PASS |
| Exit 78 on verify/refuse, CLI and MCP | Implemented | `action.go:199`, `spool.go:311`; SC-004 test |
| Hyphenated `spool-<verb>` shims | Planned | `grep -rln spool-put-file --include=*.sh .` -> none |
| `spool-harness` local mode | Implemented | `c619d5d`; test-spool-harness.sh 44/44 |
| `spool-harness` hub mode, fake sidecar | Implemented | same test, "hub: …" rows |
| `spool-harness` hub mode, real `spool hub-run`, hub unreachable | Implemented | manual run below |
| `spool-harness` hub mode, live hub announce | Planned | T011 |
| Spawn adapters launch through the harness | Planned | T013 |

Runs (tree: `c619d5d` = trunk after this lane's first push; n=1 each):
- `go test ./internal/mcp/ ./internal/spool/` in `csi-spl-api/src/go/spool-hub-api` -> ok, ok.
- `bash csi-spl-orc/src/bash/features/spawn-agents/tests/run-all-tests.sh` -> `ALL spawn-agents TESTS PASSED` (harness 44/0).
- `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` -> `11/11 test files passed`.
- Dry run, throwaway root, `SPOOL_HUB_URL` unset, `$HOME` with no `.spool`:
  `spool-harness --as CLE-99 -- sh -c 'echo harness-ok; env | grep ^SPOOL_; umask'`
  -> `harness-ok`, `SPOOL_AGENT_ID=CLE-99`, `SPOOL_ROOT=<tmp>/spool`, `0002`,
  rc 0; `CLE-99/{archive,inbox,outbox}`, `files`, `pins` all `drwxrwxr-x`.
- Real binary, `SPOOL_HUB_URL=http://127.0.0.1:9`, key minted by
  `SPOOL_BOX_ID=box-t spool keygen` (mode 600):
  `spool-harness --as CLE-99 --to-box box-t -- echo harness-ok` ->
  `sidecar: started spool hub-run (pid …)`, `warning: CLE-99 not yet announced`,
  `harness-ok`, rc 0; `/proc/<pid>/cmdline` = `…/bin/spool hub-run`; its log
  reads `hub session down … connection refused` (retrying).

## Success Criteria

- **SC-001**: MCP == CLI for the five verbs, including exit 78. **Implemented**.
- **SC-002**: The launcher dry run (US2 scenario 1) passes with no key.
  **Implemented**.
- **SC-003**: In hub mode against a live dev hub, a harnessed agent is in the
  hub roster before its first send. **Planned** (T011).

## Assumptions and decisions (auto-mode, logged)

- **D-01 Home**: a bash script next to the spawn adapters, not a `spool`
  subcommand. The steps are process and filesystem plumbing (mkdir, flock,
  setsid, exec) that bash does directly; it reuses `lib/spool-env.inc.sh`
  (id rules, `SPOOL_BIN`), and it keeps `cmd/spool` — owned by the hub lane —
  untouched. Packaging it as `spool-harness` on `PATH` is a symlink (T012).
- **D-02 `--to-box`**: names the box the session is attached to, i.e. it sets
  `SPOOL_BOX_ID` and wins over an inherited value. The narrative leaves it
  undefined; per-send recipient boxes stay `spool send --to-box`.
- **D-03 Not strict by default**: an unannounced agent (hub down) warns and
  starts, because sends queue as `pending` and flush on reconnect (003
  `contracts/flush.md`); `SPOOL_HARNESS_STRICT=1` makes it fatal (69).
- **D-04 Sidecar ownership**: `SPOOL_HARNESS_SIDECAR=auto` starts one
  `hub-run` per root (pidfile `$SPOOL_ROOT/.hub/hub-run.pid`); `external`
  leaves it to a service manager and only waits for the roster; `off` skips.
- **D-05** The harness never mints a key or installs a pin (no TOFU; keys are
  an operator step, trust-modes §7).

<!-- version: 1.0.0 · updated: 2026-09-19 · last-edit: 2026-09-19T01:55:00Z -->
