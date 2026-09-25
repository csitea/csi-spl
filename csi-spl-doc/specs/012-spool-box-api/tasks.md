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
      `action.go:255`, `spool.go:353` on tree `4ae33835`; SC-004 test asserts `(exit 78)`. FR-004.
- [x] T004 Implemented — Mismatch sweep: no rename or code change needed;
      results are supersets of narrative §3 (003 OQ-01 additive fields). FR-003.

## Phase 2 — `spool-harness` (FR-010..FR-015)

- [x] T005 Implemented — `scripts/spool-harness.sh`: parse, id/box-id checks. `c619d5d`. FR-010.
- [x] T006 Implemented — Step 1 dirs 0775 + umask 0002. FR-011.
- [x] T007 Implemented — Step 2 box id + 0600 key; optional local, 78 hub. FR-012.
- [x] T008 Implemented — Step 3 sidecar: one `hub-run` per root under flock,
      roster wait, strict mode 69. FR-013.
- [x] T009 Implemented — Steps 4-5 env + exec. FR-014, FR-015.
- [x] T010 Implemented — `tests/test-spool-harness.sh`, in
      `run-all-tests.sh`. On tree `4ae33835`,
      `grep -cE '(has|eq|check) ' csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-harness.sh`
      → 42 source lines (one line loops six directories). The old "44 assertions"
      figure is stale.

## Phase 3 — Follow-ups

- [ ] T011 Planned — Live proof: on a box with a pinned key, run
      `spool-harness --as CLE-<n> --to-box <box> -- true` against the dev hub
      and read `"<box>":[…"CLE-<n>"…]` in `$SPOOL_ROOT/.hub/roster.json`.
      Blocked on a reachable dev hub (007). SC-003.
- [ ] T012 Planned — Box-image packaging: `spool-harness` and the hyphenated
      `spool-<verb>` shims on `PATH` (symlink / 2-line wrappers). FR-006.
- [ ] T013 Planned — Spawn adapters (`spawn-core.inc.sh`) launch the CLI
      through `spool-harness --as <ID>` instead of preparing env inline.
- [x] T014 Implemented — Cross-spec seams. On tree `4ae33835`:
      `grep -n 012-spool-box-api csi-spl-doc/specs/README.md` → the §4 index row;
      `grep -n spool-harness csi-spl-doc/specs/004-spool-identity-routing/spec.md`
      names `spool-harness.sh` (spec 012). A search for the old phrase
      "no spool-harness" under `csi-spl-doc` hits only the previous wording
      of this task. 004 itself is another lane's spec and was not edited here.

<!-- version: 1.0.1 · updated: 2026-09-25 · last-edit: 2026-09-25T18:18:58Z -->
