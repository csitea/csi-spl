# Tasks: Uniform box API and the standard box launcher (012)

**Feature**: `specs/012-spool-box-api` · **Milestone**: M1 · **Created**: 2026-09-19
**Narrative (binding)**: `../../doc/md/SPEC-spool-box-api.md`

Status vocabulary follows `../README.md` §2.3: `[x]` Implemented (cited) ·
`[~]` Partial (missing part named) · `[ ]` Planned.

---

## Phase 1 — Box API re-verification (FR-001..FR-007)

- [x] T001 Implemented — Confirm verb ↔ tool 1:1 (`contracts/cli-mcp-map.md`).
      `go test ./internal/mcp/` -> ok (`TestSC004MCPEqualsCLI`). FR-001, FR-003.
- [x] T002 Implemented — Confirm exactly five canonical tool names.
      `TestToolNamesAreCanonical` PASS. FR-002.
- [x] T003 Implemented — Confirm exit 78 on verify/refuse, CLI and MCP.
      `action.go:199`, `spool.go:311`; SC-004 test asserts `(exit 78)`. FR-004.
- [x] T004 Implemented — Mismatch sweep: no rename or code change needed;
      results are supersets of narrative §3 (003 OQ-01 additive fields). FR-003.

## Phase 2 — `spool-harness` (FR-010..FR-015)

- [x] T005 Implemented — `scripts/spool-harness.sh`: parse, id/box-id checks. `c619d5d`. FR-010.
- [x] T006 Implemented — Step 1 dirs 0775 + umask 0002. FR-011.
- [x] T007 Implemented — Step 2 box id + 0600 key; optional local, 78 hub. FR-012.
- [x] T008 Implemented — Step 3 sidecar: one `hub-run` per root under flock,
      roster wait, strict mode 69. FR-013.
- [x] T009 Implemented — Steps 4-5 env + exec. FR-014, FR-015.
- [x] T010 Implemented — `tests/test-spool-harness.sh`, 44 assertions, in
      `run-all-tests.sh` -> `ALL spawn-agents TESTS PASSED`.

## Phase 3 — Follow-ups

- [ ] T011 Planned — Live proof: on a box with a pinned key, run
      `spool-harness --as CLE-<n> --to-box <box> -- true` against the dev hub
      and read `"<box>":[…"CLE-<n>"…]` in `$SPOOL_ROOT/.hub/roster.json`.
      Blocked on a reachable dev hub (007). SC-003.
- [ ] T012 Planned — Box-image packaging: `spool-harness` and the hyphenated
      `spool-<verb>` shims on `PATH` (symlink / 2-line wrappers). FR-006.
- [ ] T013 Planned — Spawn adapters (`spawn-core.inc.sh`) launch the CLI
      through `spool-harness --as <ID>` instead of preparing env inline.
- [ ] T014 Planned — Cross-spec seams, integrator's: `../README.md` §4 index
      row for 012; 004 FR-010 / T023 and narrative identity-routing §2 still
      say "no `spool-harness`" — now answered by this spec (harness in orc,
      not a `spool` verb).

<!-- version: 1.0.0 · updated: 2026-09-19 · last-edit: 2026-09-19T01:55:00Z -->
