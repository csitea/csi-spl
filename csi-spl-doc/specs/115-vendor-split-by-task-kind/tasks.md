# 115 Vendor Split by Task Kind: tasks

Authority for what is built. `spec.md` holds the behaviour; this file follows its sections 3-8.
Each task names its layer, its dependency, the files it owns, a Done line (what runs, what it prints, and a control that must fail), a vendor hint (spec 115's per-kind main and backup), and a box hint.
Status vocabulary: `../README.md` item 3 (`[x]` Implemented, `[~]` Partial / in progress, `[ ]` Planned).

## 1. Configuration

- [x] **CNF-1**: Per-kind weights and backup in `csi-spl-cnf/csi-spl/all.env.yaml`.
  - Depends: none.
  - Owns: `csi-spl-cnf/csi-spl/all.env.yaml` (`env.box.agent_split_by_kind`).
  - Done: the table of section 2 is written under `agent_split_by_kind`; the validator and `tpl-gen` are updated for the new keys; `do_check_dist_hygiene` prints nothing for `csi-spl-cnf/`. Control: a row that does not sum to 100 or a tied main turns the validator red.
  - Vendor: mistral (main: `simple_coding`). Box: any.

## 2. Picker (`do_spl_lane_mix`)

- [ ] **ORC-1**: Per-kind rows, aliases, the one rule of section 5, and the journal reader.
  - Depends: none.
  - Owns: `csi-spl-orc/src/bash/run/spl-lane-mix.func.sh` (`do_spl_lane_mix`), its `.tst.sh`, and the journal reader in `spl-lane-mix-journal.func.sh`.
  - Done: `LANE_MIX_KIND` resolves to the new names or aliases; the picker reads the per-kind row, applies availability, counts failed tries, and picks main, backup or claude (section 5); `_spl_lane_mix_next` and the D5 `first=` map are removed. Test: a fixture with 2 failed tries for mistral on task X gives claude; with 1 try it gives mistral. Control: a threshold at 3 turns the test red.
  - Vendor: mistral (main: `simple_coding`). Box: any.

## 3. Journal writers

- [ ] **ORC-2**: Spawn-window writes the journal row (F1 and `run`).
  - Depends: none.
  - Owns: `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-window.sh`.
  - Done: the spawn writes `attempts.tsv` with `task_id kind vendor id start_epoch outcome=run`; the watchdog (F2), lane restart (F2) and `/exit-clean` (F3) close it. Test: a fixture spawn writes the row; a held-out lane or a split refusal closes it as `fail:F2`. Control: a missing `outcome` field turns the test red.
  - Vendor: mistral (main: `simple_coding`). Box: any.

- [ ] **ORC-3**: Watchdog and lane restart write F2.
  - Depends: ORC-2.
  - Owns: `csi-spl-orc/src/bash/run/spl-lane-restart.func.sh` and `csi-spl-orc/src/bash/run/spl-watchdog.func.sh`.
  - Done: the watchdog writes `fail:F2` when the lane is held out; `do_spl_lane_restart` writes `fail:F2` when it refuses at the split count. Test: a fixture lane held out at 3 restarts writes `fail:F2`; a split refusal does the same. Control: a missing `source` field turns the test red.
  - Vendor: mistral (main: `simple_coding`). Box: any.

- [ ] **ORC-4**: `/exit-clean` writes F3.
  - Depends: ORC-2.
  - Owns: `csi-spl-orc/src/bash/features/spawn-agents/scripts/tmux-close-window.sh`.
  - Done: `/exit-clean` checks F3 (CI on the lane's last landed sha, `git-fetch-fresh.sh --landed`) and writes `fail:F3` or `ok`. Test: a fixture lane with a red CI job it caused writes `fail:F3`; a green lane writes `ok`. Control: a missing `source` field turns the test red.
  - Vendor: mistral (main: `simple_coding`). Box: any.

## 4. Hub (rdb + API)

- [x] **RDB-1**: Migration `0163_tenant_agent_split_kind.sql`.
  - Depends: none. Apply to dev and prd before HUB-1 deploys.
  - Owns: `csi-spl-rdb/src/sql/postgres/spool-hub/0163_tenant_agent_split_kind.sql`.
  - Done: `tenant_agent_split_kind(tenant_id, kind, vendor, weight, is_backup)` under RLS, with the table rules of section 2; forward-only and additive; the migration catalogue gate is green. Control: a row with `agy > 0` in a coding kind turns the test red.
  - Vendor: claude (main: `complex_coding`). Box: one with docker Postgres.

- [x] **HUB-1**: Hub route and WUI settings screen.
  - Depends: RDB-1.
  - Owns: `csi-spl-api/src/go/spool-hub-api/internal/hub/agent_split.go`, `agent_split_test.go`, and the WUI settings screen in `csi-spl-wui/`.
  - Done: `PATCH /v1/agent-split` updates the per-kind rows; `do_spl_agent_split_show --kind <k>` prints `LANE_MIX_SPLIT` per kind; the WUI screen shows the per-kind table. Test: a fixture PATCH updates the row; the WUI screen shows the new weights. Control: a PATCH that sets `agy > 0` in a coding kind is refused.
  - Vendor: claude (main: `complex_coding`). Box: one with docker Postgres.
  - Live (2026-10-10): hub 7bf417a77 (`GET`/`PATCH /v1/agent-split`), orc 66b08cebe (`--kind`), WUI 3b6f41393 (the per-kind table), on dev and prd. The dev proof ran on t1: GET 200, PATCH 200, agy in a coding kind 400 `bad_split`, reset 200. The 0109 header comment is not changed: the migrator hashes applied files (`internal/store/migrate.go`), so editing it would refuse the next migrate. The cnf comment is fixed in a28b2094a.

## 5. Fleet rules

- [x] **DOC-1**: Update the global CLAUDE.md "Spawn an agent" section and `/spawn-an-agent`.
  - Depends: none.
  - Owns: `csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md/20-spawn-an-agent.md` and `csi-spl-orc/src/bash/features/spawn-agents/assets/commands/spawn-an-agent.md`.
  - Done: the section and the launcher say per-kind main and backup; `do_check_fleet_rules_drift` pins the per-kind main. Test: the launcher prints the per-kind table; the drift check fails when a main is changed. Control: a missing per-kind main turns the drift check red.
  - Vendor: mistral (main: `simple_coding`). Box: any.

## 6. Tests (each with its control)

- [ ] **TST-1**: T1-T9 per section 8.
  - Depends: ORC-1, ORC-2, ORC-3, ORC-4.
  - Owns: `csi-spl-orc/src/bash/tests/spl-lane-mix.tst.sh` and its fixtures.
  - Done: T1-T9 green. Controls: each test turns red when its guard is removed (section 8).
  - Vendor: claude (main: `complex_coding`). Box: any.