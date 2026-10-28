# Spec 161: Cursor and Codex as Agent Vendors of the Fleet (Launcher, Routing, Quota)

Version **v1.0** (2026-10-28). Authored by seat a-513 (antigravity).
Placement slug: `c002-s161-cursor-codex-vendors-spec`.
Epic: **SPL-2402**. Issue: **SPL-4010** (status wip). Kind: **specs_and_docs**.
Authority: Dispatch task `dispatch-d60646d9` to current dispatch lease holder `c-002@sat`.
Spec 161 is verified free on origin/master (highest existing spec is 160).

---

## 0. Owner Asks and Decisions (Verbatim)

From HUM-10 (owner), prd topic `d60646d9-f63a-4787-bee6-0a497336a79f`:

| msg | text |
|---|---|
| c-003 Take (11:20Z) | "new agents ... add cursor and codex" |
| `1e9a2d57` | **DECIDED**: "Answer: A — Add both as agent vendors in the fleet (launcher, routing, quota), then name them in the deck" |
| c-003 Baseline (11:2xZ) | 0 hits for cursor or codex as a vendor in `spawn-window.sh` and `csi-spl-cnf/csi-spl/all.env.yaml` |

This spec designs the addition of **Cursor** (Cursor Agent CLI) and **Codex** (OpenAI Codex CLI) as the 6th and 7th agent vendors of the Spool fleet end to end: installation, binary pinning, identity grammar, mailbox layout, launchers, restore adapters, skills, task routing, watchdog quota/auth detection, fleet-wide backoff, and owner decision points.

---

## 1. Goals and Non-Goals

### 1.1 Goals

| # | Goal | Measured by |
|---|---|---|
| **G1** | The Cursor Agent CLI and OpenAI Codex CLI are installed for the agent user (`SPOOL_AGENT_USER`) on all fleet boxes via named actions (`do_install_cursor_agent`, `do_install_openai_codex`), wrapping box package management (`do_box_pkg_install`), pinned to explicit versions in `all.env.yaml`. | Exit 0 from install actions; `cursor-agent --version` and `codex --version` match cnf pins; zero unpinned `curl \| bash`. |
| **G2** | Two new agent kinds with dedicated, non-clashing lowercase letters: `u` for Cursor (`u-NNN`) and `d` for Codex (`d-NNN`). Schema (DDL), Go API, spool routing, CLI grammar, tmux windows, and mailboxes treat `u-` and `d-` as full first-class fleet agents. | DDL migration applies cleanly; Go `agentid` unit tests accept `u-004` and `d-004`; `spool` CLI routes messages to their mailboxes. |
| **G3** | Launchers (`spawn-cursor.sh`, `spawn-codex.sh`) and restore adapters (`restore-cursor.sh`, `restore-codex.sh`) start autonomous interactive sessions with bypassed permissions, positional seed prompts, and session continuity. | `spawn-window.sh cursor auto ...` and `spawn-window.sh codex auto ...` plan valid launch lines with bypass flags; `/cursor-spawn` and `/codex-spawn` skills work. |
| **G4** | Task routing in `env.box.agent_split_by_kind` and `do_spl_lane_mix`: Cursor and Codex are allocated to coding kinds (`simple_coding`, `complex_coding`, `tests`), while strictly upholding the **DATA RULE** (no secrets or personal data) and the **LANGUAGE RULE** (agy leads multilingual text). | `do_spl_lane_mix` assigns coding tasks to Cursor/Codex when available; sensitive/secret tasks strictly refuse them and route to Claude/Grok/Mistral. |
| **G5** | Quota and limit detection: Watchdog situation S2 recognizes Cursor and Codex rate/usage limits and auth failures, propagating fleet-wide holds following the SPL-3998 pattern. | S2 emits `kind=limit` or `kind=auth` from pane banners or API errors; dispatcher receives blocker; spawn placer holds fleet-wide until quota reset. |
| **G6** | Hygiene and safety: Zero API keys or credentials in git, logs, command-line arguments, or tmux scrollbacks; keys entered via `do_set_cursor_key` and `do_set_codex_key` with mode `0600`. | `do_check_dist_hygiene` clean; test suites assert absence of key leaks. |

### 1.2 Non-Goals

- Modifying the Devin presentation deck in this lane: Slide 5 vendor list update is a separate small documentation lane after live fleet verification.
- Hub backend integration with Cursor/OpenAI APIs (the hub Cloud Run API does not call Cursor or Codex directly; execution is local to agent boxes).
- Granting secrets or personal-data access to Cursor or Codex without explicit future owner orders.

---

## 2. The Two CLIs: Install, Version Pin, Flag Contract, Seeds, Resumes, and Logs

### 2.1 Cursor Agent CLI (`cursor-agent` / `agent`)

#### 2.1.1 Installation and Version Pinning
- **Binary and Package**: The official Cursor Agent CLI binary is distributed as `cursor-agent` (aliased or symlinked as `agent`).
- **Prerequisites**: System libraries and dependencies installed using `do_box_pkg_install` (e.g. Node/npm or glibc prerequisites recorded in package journal).
- **Orchestrator Action**: `do_install_cursor_agent` (`csi-spl-orc/src/bash/run/install-cursor-agent.func.sh`) wrapping `csi-spl-orc/src/bash/features/spool-install/install.sh --cli cursor --cli-only`.
  - Runs strictly as the box's agent user (`SPOOL_AGENT_USER`).
  - Reads version pin from cnf: `env.box.cursor_agent.version` in `csi-spl-cnf/csi-spl/all.env.yaml`. Never `@latest` or raw remote script execution (`curl | bash` is strictly forbidden).
  - Pinned binary configured via `CURSOR_BIN` (default `cursor-agent` on the agent user's login `PATH`).
  - Flag contract verification: Install verifies `cursor-agent --help` contains `--force` (or `--yolo`), `--resume`, `--continue`, and `-p`/`--print`. Missing flags refuse the pin.
  - Telemetry and auto-updates disabled via environment variables or `~/.cursor/cli-config.json` (`CURSOR_DISABLE_TELEMETRY=true`, `CURSOR_DISABLE_AUTO_UPDATE=true`).

#### 2.1.2 Non-Interactive & Bypass Permissions
- **Fleet Rule**: All agent runs must be fully autonomous; prompts requiring human confirmation in tmux windows block unattended lanes and violate fleet automation rules.
- **Bypass Flags**:
  - Interactive autonomous mode: `cursor-agent --force` (or `--yolo`), automatically approving proposed file edits and terminal commands.
  - Headless/Programmatic mode: `-p` (or `--print`) with `--force` for non-interactive execution.
- **Permission Boundary**: Runs inside the agent's isolated worktree (`/opt/csi/csi-spl-wt/<ID>`), with ACL `rwX` ensuring the agent can write files directly without dropping to shell workarounds.

#### 2.1.3 Seed Prompt and Resume
- **Seed Prompt**: Passed positionally to `cursor-agent --force "<seed>"` or via `--prompt`. The first action in the seed prompt commands the agent to retitle its tmux window using `riname.sh --agent <ID> "<slug>"` and read `CLAUDE.md`.
- **Resume Mechanism**:
  - Resuming a specific session: `cursor-agent --resume <SESSION_ID>`.
  - Continuing the last active session in the worktree: `cursor-agent --continue` (equivalent to `--resume=-1`).
  - Resume adapter `restore-cursor.sh` injects the brief kick prompt (`restore-core.inc.sh` pattern) so the resumed agent immediately re-reads its inbox and continues work.

#### 2.1.4 Session Logs and Transcripts
- **Configuration Directory**: `<agent-home>/.cursor/` (`cli-config.json`).
- **Session Transcripts**: Stored in `<agent-home>/.cursor/sessions/` or `$CURSOR_HOME/logs/`.
- **Log Pruning**: `csi-spl-orc/src/bash/run/spl-session-prune.sh` updated to prune `.cursor/sessions/` older than the retention threshold, ensuring disk guard compliance.

#### 2.1.5 Auth and Secret Handling
- **Key Location**: `<agent-home>/.cursor/.env` (`CURSOR_API_KEY=...`), permissions `0600`, owned by `SPOOL_AGENT_USER`.
- **Entry Action**: `do_set_cursor_key` (`csi-spl-orc/src/bash/run/set-cursor-key.func.sh`), reading the key securely with `read -s`. Never pasted into tmux panes (avoids pane scrollback leakage into `capture-pane`).
- **Process Isolation**: Launcher starts `env -u CURSOR_API_KEY cursor-agent ...`, ensuring keys are not visible in process tables (`ps aux`) or leaked across tmux global environments.
- **Auth Marker**: `env.box.agent_split.auth_marker.cursor: .cursor/.env`. If the marker is missing on a box, the box is skipped for Cursor lanes.

---

### 2.2 OpenAI Codex CLI (`codex`)

#### 2.2.1 Installation and Version Pinning
- **Binary and Package**: The OpenAI Codex CLI binary is distributed as `codex` (Rust-based standalone binary or npm package `@openai/codex`).
- **Prerequisites**: System dependencies installed via `do_box_pkg_install`.
- **Orchestrator Action**: `do_install_openai_codex` (`csi-spl-orc/src/bash/run/install-openai-codex.func.sh`) wrapping `spool-install/install.sh --cli codex --cli-only`.
  - Runs strictly as `SPOOL_AGENT_USER`.
  - Reads version pin from cnf: `env.box.openai_codex.version` in `csi-spl-cnf/csi-spl/all.env.yaml`.
  - Pinned binary configured via `CODEX_BIN` (default `codex` on agent user `PATH`).
  - Flag contract verification: Install verifies `codex --help` contains `exec`, `--ask-for-approval`, `resume`, and `--full-auto`/`--yes`.
  - Telemetry disabled via environment variable (`OPENAI_TELEMETRY_DISABLED=1`).

#### 2.2.2 Non-Interactive & Bypass Permissions
- **Bypass Flags**:
  - Interactive REPL execution: `codex --ask-for-approval never` (suppresses interactive confirmation prompts).
  - Headless/CLI execution: `codex exec --full-auto "<prompt>"` or `codex exec --yes "<prompt>"`.
  - For full non-interactive workspace modifications, `--ask-for-approval never` (or `--full-auto`) allows autonomous file updates and command execution within the workspace directory.

#### 2.2.3 Seed Prompt and Resume
- **Seed Prompt**: Passed positionally to `codex --ask-for-approval never "<seed>"` or `codex exec --full-auto "<seed>"`.
- **Resume Mechanism**:
  - Resuming a specific session: `codex resume <SESSION_ID>`.
  - Continuing the most recent session: `codex resume --last`.
  - Resume adapter `restore-codex.sh` integrates with `restore-core.inc.sh`, appending the brief kick prompt to wake the resumed agent.

#### 2.2.4 Session Logs and Transcripts
- **Configuration Directory**: `<agent-home>/.codex/config.toml`.
- **Session Transcripts**: Stored in `<agent-home>/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<session-id>.jsonl`.
- **Log Pruning**: `csi-spl-orc/src/bash/run/spl-session-prune.sh` updated to prune `.codex/sessions/` older than the retention threshold.

#### 2.2.5 Auth and Secret Handling
- **Key Location**: `<agent-home>/.codex/.env` (`OPENAI_API_KEY=...`), permissions `0600`, owned by `SPOOL_AGENT_USER`.
- **Entry Action**: `do_set_codex_key` (`csi-spl-orc/src/bash/run/set-codex-key.func.sh`), reading the key securely with `read -s`.
- **Process Isolation**: Launcher runs `env -u OPENAI_API_KEY codex ...`.
- **Auth Marker**: `env.box.agent_split.auth_marker.codex: .codex/.env`. Missing marker causes the box to be skipped for Codex tasks.

---

## 3. Agent IDs: Prefix Letters, Tmux Windows, Mailbox Shapes

### 3.1 ID Letters Selection

- **Existing Letters**: `c` (Claude), `g` (Grok), `a` (AGY), `q` (Qwen), `m` (Mistral).
- **Collision Analysis**:
  - Both Cursor and Codex begin with `c`, which is permanently assigned to Claude.
  - Letter `x` is heavily used across the test suite as the negative control (e.g. `x-004 refused`), and must NOT be used.
  - Letter `b` risks ambiguity with `BOX-` desk agent IDs.
  - Letter `o` can cause visual ambiguity with digit `0` in fixed-width fonts (e.g. `o-004` vs `0-004`).
- **Assigned Letters**:
  - **`u` for Cursor**: `u-NNN` (e.g. `u-004`). Mnemonic from the second letter of **c-U-r-s-o-r**. Crisp, unambiguous, zero collisions.
  - **`d` for Codex**: `d-NNN` (e.g. `d-004`). Mnemonic from the third letter of **c-o-D-e-x**. Crisp, visually distinct from numbers, zero collisions.
- **Updated ID Grammar**:
  - The fleet agent ID regex expands from `^[acgmq]-[0-9]{3}$` to:
    ```regexp
    ^[acdgmqu]-[0-9]{3}$
    ```
  - Case-insensitive regex: `^[ACDGMQUacdgmqu]-[0-9]{3}$`.
  - Legacy prefixes: NONE. (Legacy prefixes ended on 2026-10-03).
- **Role Seats**:
  - `001..003` reserved for role seats (`u-001..u-003`, `d-001..d-003`). Lanes allocate `004..999`.
- **Window and Mailbox Shapes**:
  - Tmux window: `<tag>: u-004 <title>` and `<tag>: d-004 <title>`.
  - Spool mailbox: `$SPOOL_ROOT/u-004/{inbox,outbox,archive}` and `$SPOOL_ROOT/d-004/{inbox,outbox,archive}`.
  - Identity map: `$SPOOL_ROOT/agents/u-004.json` and `$SPOOL_ROOT/agents/d-004.json`.

### 3.2 Code and Schema Touch List

The exact files across the repository that read or enforce the grammar:

| Layer | Files | Required Change |
|---|---|---|
| **RDB (DDL)** | `csi-spl-rdb/src/sql/postgres/spool-hub/0180_cursor_codex_kinds.sql` | Forward-only migration re-making CHECKs with `[acdgmqu]`: `roster_agent_id_check`, `issues_assignee_check`, `fleet_lanes_agent_id_check`, `fleet_asks_{from_agent,acked_by,closed_by}_check`, `agent_id_aliases.new_id`. Updates function `messages_claim_defaults()`. Adds `'cursor'` and `'codex'` to `fleet_agent_kinds_off`. |
| **Hub Go API** | `csi-spl-api/src/go/spool-hub-api/internal/agentid/agentid.go`<br>`internal/agentid/agentid_test.go`<br>`internal/hub/fleet_lanes_view.go`<br>`internal/spool/spool.go`<br>`internal/store/flow_mentions.go`<br>`internal/store/message_claim.go`<br>`internal/store/store.go`<br>`internal/hubclient/host.go` | Update `newRe` and `newAnyCaseRe` to `[acdgmqu]`. Add `'u': "cursor"` and `'d': "codex"` to `kinds` map. Update `roleSeatLetters = "acdgmqu"`, `laneIDRe`, `odSeatRe`. Update `flowAgentSQL` and `agentIDAt` rune set `"acdgmqu"`. Add `cursor` and `codex` to `store.AgentKinds`. Add host CLI version probes for `cursor` and `codex`. |
| **Orchestrator** | `csi-spl-orc/src/bash/features/spawn-agents/scripts/next-agent-id.sh`<br>`scripts/agent-id-map.sh`<br>`scripts/spool-send.sh`<br>`scripts/asks.sh`<br>`scripts/spool-mcp.sh`<br>`scripts/spool-mirror.py`<br>`scripts/agent-name-resume.sh`<br>`scripts/spl-session-prune.sh`<br>`scripts/tmux-close-window.sh`<br>`run/spl-{dispatch-rotate,orch-rotate,orch-load-report,peer-poll,role-id-switch,unanswered-sweep}.func.sh`<br>`run/spl-agent-identity-restore.func.sh` | Add `u` / `cursor` and `d` / `codex` to `_letter_of`, `ID_ROLE_LETTERS = "acdgmqu"`, and regex parsers. Update mailbox verification, session pruning, and identity restore. |
| **WUI** | `csi-spl-wui/src/utils/agent-id.mjs`<br>`src/utils/mention-grammar.json`<br>`src/utils/agent-kind.mjs`<br>`src/utils/rail-order.mjs`<br>`src/utils/fleet-load.mjs`<br>`src/utils/mjs-shims.d.ts`<br>`src/pages/tenant-settings/split.vue`<br>`src/locales/*.json` (19 locales) | Update regex `AGENT_ID_SRC` to `[acdgmqu]`. Add label mappings `agent_kind_cursor` ("Cursor") and `agent_kind_codex` ("Codex"). Add split inputs for Cursor and Codex in `split.vue`. Add i18n translation keys. |
| **Utilities** | `csi-spl-utl/src/bash/run/docker-test-container-prune.func.sh`<br>`run/orphan-process-reap.func.sh`<br>`scripts/workdir-sweep.sh` | Update worktree and process regex patterns from `[acgmq]` to `[acdgmqu]`. |
| **Tests** | `csi-spl-orc/src/bash/tests/test-agent-name-shape.sh`<br>`tests/peer-poll.tst.sh`<br>`csi-spl-iac/src/bash/tests/help-connect-agent.tst.sh`<br>`csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-id.sh`<br>`csi-spl-wui/tests/unit/agent-id.test.mjs` | Add test cases for `u-004` and `d-004`; verify negative control `x-004` remains refused. |

---

## 4. Launchers, Restore Adapters, and Skills

### 4.1 Launchers

1. **`spawn-window.sh`**:
   - Update argument validation:
     ```bash
     case "$KIND" in claude|grok|agy|qwen|mistral|cursor|codex) ;; *) usage ;; esac
     ```
   - Routes `$KIND` to `spawn-cursor.sh` and `spawn-codex.sh`.
2. **`spawn-cursor.sh`**:
   - Adapter of `spawn-core.inc.sh`.
   - `SPAWN_KIND=cursor`, `SPAWN_ID_PREFIX=`, `SPAWN_ID_LETTER=u`, `SPAWN_BIN_VAR=CURSOR_BIN`.
   - Flags: `SPAWN_EXTRA_FLAGS="--force"`.
   - Execution prefix: `SPAWN_EXEC_PREFIX="env -u CURSOR_API_KEY CURSOR_DISABLE_TELEMETRY=true CURSOR_DISABLE_AUTO_UPDATE=true"`.
   - ACL: `SPAWN_AGENT_ACL=rwX`.
3. **`spawn-codex.sh`**:
   - Adapter of `spawn-core.inc.sh`.
   - `SPAWN_KIND=codex`, `SPAWN_ID_PREFIX=`, `SPAWN_ID_LETTER=d`, `SPAWN_BIN_VAR=CODEX_BIN`.
   - Flags: `SPAWN_EXTRA_FLAGS="--ask-for-approval never"`.
   - Execution prefix: `SPAWN_EXEC_PREFIX="env -u OPENAI_API_KEY OPENAI_TELEMETRY_DISABLED=1"`.
   - ACL: `SPAWN_AGENT_ACL=rwX`.

### 4.2 Restore Adapters

1. **`restore-cursor.sh`**:
   - Adapter of `restore-core.inc.sh`.
   - `RESTORE_KIND=cursor`, `RESTORE_ID_LETTER=u`, `RESTORE_BIN_VAR=CURSOR_BIN`.
   - Resume command: `--resume <SESSION_ID>` or `--continue`.
   - Reads `SPAWN_EXEC_PREFIX` and `SPAWN_AGENT_ACL` from `spawn-cursor.sh`.
   - Injects brief re-kick prompt so the restored session resumes work on its inbox.
2. **`restore-codex.sh`**:
   - Adapter of `restore-core.inc.sh`.
   - `RESTORE_KIND=codex`, `RESTORE_ID_LETTER=d`, `RESTORE_BIN_VAR=CODEX_BIN`.
   - Resume command: `codex resume <SESSION_ID>` or `codex resume --last`.
   - Reads `SPAWN_EXEC_PREFIX` and `SPAWN_AGENT_ACL` from `spawn-codex.sh`.
   - Injects brief re-kick prompt.
3. **Restoration Integration**:
   - `spl-agent-restart.func.sh`, `spl-agent-boot-restore.func.sh`, and `spl-agent-identity-restore.func.sh` learn kinds `cursor` and `codex`.

### 4.3 Skills

- New skill **`/cursor-spawn`**: `csi-spl-orc/src/bash/features/spawn-agents/assets/commands/cursor-spawn.md`. Allows spawning a new `u-NNN` agent or sending messages to an active `u-NNN` lane.
- New skill **`/codex-spawn`**: `csi-spl-orc/src/bash/features/spawn-agents/assets/commands/codex-spawn.md`. Allows spawning a new `d-NNN` agent or sending messages to an active `d-NNN` lane.
- Update **`/spawn-an-agent`**: Names Cursor and Codex alongside existing vendors.
- Update `csi-spl-orc/src/bash/features/spawn-agents/harness-parity.tsv` with rows for `spawn-cursor.sh`, `spawn-codex.sh`, `restore-cursor.sh`, `restore-codex.sh`, `cursor-spawn.md`, and `codex-spawn.md`.

---

## 5. Routing, Weights, and the DATA RULE

### 5.1 The DATA RULE (Non-Negotiable)

- **Fleet Rule**: The fleet data rule (global `CLAUDE.md`, spec 110 D2, spec 115) permits secrets, private credentials, and personal data to be handled **only by Claude, Grok, and Mistral**.
- **Constraint**: **Cursor and Codex get NO secret or personal-data work** (`LANE_MIX_SENSITIVE=1`, kind `secret`, kind `orchestration`) unless an explicit future owner order grants an exception.
- **Enforcement**: In `do_spl_lane_mix`:
  - When `LANE_MIX_SENSITIVE=1` or kind is `secret` / `orchestration`, candidate selection is strictly restricted to `{claude, grok, mistral}`.
  - Cursor and Codex are automatically treated as disqualified ("out") for sensitive tasks.

### 5.2 Task Kinds and Split Table

Cursor and Codex are specialized coding agents. Their candidate tasks are `simple_coding`, `complex_coding`, and `tests`.
They hold weight 0 in `specs_and_docs` (led by AGY 80%), `i18n` (led by AGY 100%), `secret` (0 by Data Rule), and `orchestration` (0 by Data Rule).

Configured in `csi-spl-cnf/csi-spl/all.env.yaml` under `env.box.agent_split_by_kind`:

```yaml
env:
  box:
    agent_split_by_kind:
      specs_and_docs: { agy: 80, mistral: 15, claude: 5, backup: claude }
      tests:          { claude: 70, grok: 15, cursor: 15, backup: claude }
      simple_coding:  { claude: 40, grok: 20, cursor: 20, codex: 20, backup: claude }
      complex_coding: { claude: 70, grok: 10, cursor: 10, codex: 10, backup: claude }
      i18n:           { agy: 100, backup: claude }
      secret:         { claude: 100, backup: grok }
      orchestration:  { claude: 65, grok: 35, backup: grok }
    agent_split:
      auth_marker:
        grok: .grok/auth.json
        agy: .gemini
        qwen: .qwen/settings.json
        mistral: .vibe/.env
        cursor: .cursor/.env
        codex: .codex/.env
    cursor_agent:
      version: "2026.10.0"
    openai_codex:
      version: "0.8.0"
```

*(Note: Initial landing sets `cursor: 0` and `codex: 0` in all rows until live pilots pass and the owner decides on target weights via poll).*

### 5.3 Picker Mechanics (`do_spl_lane_mix`)

1. **Candidate Chain**: Main -> Backup -> Claude (universal default and last fallback).
2. **Availability Check**:
   - Binary installed on the box (checked via `spool_vendor_clis`).
   - Auth marker present in agent home (`.cursor/.env` / `.codex/.env`).
   - No recent S2 `kind=limit` or `kind=auth` verdict.
   - Vendor not paused or turned off in fleet load settings (`spool fleet-load get`).
3. **Failed Tries**:
   - If the main vendor fails 2 tries on the same task (`attempts.tsv`), the picker selects the backup.
   - If Cursor or Codex is out (due to quota or auth), it is skipped immediately with 0 failed tries recorded.

---

## 6. Quota, Limits, Auth Failures, and the Watchdog (SPL-3998 Pattern)

### 6.1 Watchdog Situation S2 (`s2.sh` and `lib.inc.sh`)

1. **Process Matching (`WD_HARNESS_COMM_RE`)**:
   - Add `cursor-agent`, `agent`, and `codex` to `WD_HARNESS_COMM_RE` in `lib.inc.sh`.
2. **Quota & Limit Patterns (`WD_STALL_RE`)**:
   - Cursor: `"daily limit exceeded"`, `"rate limit reached"`, `"out of fast requests"`, `"usage limit reached"`.
   - Codex: `"insufficient_quota"`, `"rate_limit_exceeded"`, `"you exceeded your current quota"`.
   - Matched by S2 as `kind=limit`.
3. **Auth Failure Patterns (`WD_AUTH_RE`)**:
   - Cursor: `"invalid api key"`, `"unauthorized"`, `"authentication failed"`, `"token expired"`.
   - Codex: `"incorrect api key provided"`, `"invalid_api_key"`, `"you must provide an api key"`.
   - Matched by S2 as `kind=auth`.

### 6.2 Fleet-Wide Backoff (SPL-3998 Pattern)

1. **Watchdog Blocker**:
   - When a Cursor or Codex lane hits a quota limit, the watchdog emits a blocker to the orchestrator:
     `WATCHDOG (093 S2 kind=limit): <id> is on its usage limit until <UTC> ... box <box>`.
2. **Hub Relay & Fleet Pause**:
   - The hub relays the limit verdict to the fleet load table.
   - `spool fleet-load pause cursor <reset-epoch>` and `spool fleet-load pause codex <reset-epoch>` pause the vendor fleet-wide.
3. **Placer Hold**:
   - The remote spawn placer (`spl_spawn_place_*_remote`) checks active limit blockers across all boxes. Spawning is paused until the limit resets.
   - A dead key (`kind=auth`) sends a blocker to the dispatcher and pauses spawning until the owner re-keys.

---

## 7. Rotation and Restore

1. **Identity Restore (`spl-agent-identity-restore.func.sh`)**:
   - On box reboot or tmux server restart, `do_spl_agent_identity_restore` scans `$SPOOL_ROOT/agents/*.json`.
   - For `u-NNN` and `d-NNN` records, it invokes `restore-cursor.sh` and `restore-codex.sh` respectively.
   - Runs strictly as `SPOOL_AGENT_USER`.
   - Restores session into the agent's dedicated worktree (`/opt/csi/csi-spl-wt/<ID>`), preserving unpushed commits and git branch state.
2. **Role Seats & Failover**:
   - In v1, Cursor and Codex act as lane agents (`004..999`) and hold no standing role seats (`001..003`).
   - If future role seats are assigned, lease failover follows the standard successor chain to Claude.

---

## 8. Accounts, Subscriptions, and Logins

> [!IMPORTANT]
> Accounts, subscription purchases, and login credentials are strictly **OWNER items**. No agent guesses, provisions, or hardcodes credentials.

1. **Cursor Account**:
   - Cursor requires a subscription (Pro at $20/user/mo or Business at $40/user/mo) or API key.
   - Dedicated key or seat per box (`spool-main`, `spool-sat`).
   - Training opt-out: The owner must configure privacy mode in Cursor account settings to ensure repository code is not retained or used for model training.
2. **OpenAI Codex Account**:
   - Requires ChatGPT Plus/Team subscription or an OpenAI platform API key with access to reasoning models.
   - API platform keys have standard enterprise zero-retention / abuse-monitoring policies (30-day retention, no training on API inputs).
3. **Key Provisioning**:
   - Keys are provisioned out of band by the owner using:
     ```bash
     cd csi-spl-orc && ./run -a do_set_cursor_key
     cd csi-spl-orc && ./run -a do_set_codex_key
     ```
   - Both actions prompt with `read -s` and write mode `0600` files in the agent home.

---

## 9. The Devin Deck (Slide 5)

- **Context**: The Devin presentation deck (in the owner's devin workspace) features Spool's multi-agent architecture and lists supported agent vendors on Slide 5.
- **Requirement**: Once the Cursor and Codex vendors pass live verification, Slide 5 will be updated to name Cursor and Codex alongside Claude, Grok, AGY, Qwen, and Mistral.
- **Execution**: Handled as a separate small docs lane following live fleet verification (Row B9).

---

## 10. Build Rows (B1..B9)

Each build row is one small, self-contained task with an explicit red control and test pair:

| Row | Area | Description and Touch List | Red Control | Test |
|---|---|---|---|---|
| **B1** | `rdb` | **DDL Migration**: Add `0180_cursor_codex_kinds.sql`. Update CHECK constraints `roster_agent_id_check`, `issues_assignee_check`, `fleet_lanes_agent_id_check`, `fleet_asks_*_check`, `agent_id_aliases.new_id` to `[acdgmqu]`. Update function `messages_claim_defaults()`. Update `fleet_agent_kinds_off`.<br>*Files*: `csi-spl-rdb/src/sql/postgres/spool-hub/0180_cursor_codex_kinds.sql`, `csi-spl-api/src/go/spool-hub-api/internal/store/cursor_codex_kind_migrate_test.go`. | Inserting `u-004` or `d-004` fails before migration; `x-004` fails after migration. | Go test applying migration and asserting valid inserts for `u-004` and `d-004`. |
| **B2** | `api` | **Hub Go API & AgentID**: Update `agentid.go` (`newRe`, `newAnyCaseRe`, `kinds` map with `'u': "cursor"`, `'d': "codex"`). Update `flow_mentions.go` (`agentIDAt` rune set `"acdgmqu"`, `flowAgentSQL`), `fleet_lanes_view.go`, `spool.go` (`roleSeatLetters`), `message_claim.go` (`odSeatRe`), `store.go` (`AgentKinds`), and `hubclient/host.go` (CLI version probes).<br>*Files*: `csi-spl-api/src/go/spool-hub-api/internal/agentid/agentid.go`, `agentid_test.go`, `hub/fleet_lanes_view.go`, `spool/spool.go`, `store/flow_mentions.go`, `store/flow_mentions_test.go`, `store/message_claim.go`, `store/store.go`, `hubclient/host.go`. | `agentid.Parse("x-004")` and legacy prefix for cursor/codex fail. | `go test ./internal/agentid/... ./internal/store/...` green for `u-004` and `d-004`. |
| **B3** | `orc` | **Install Actions & cnf Pins**: Add `do_install_cursor_agent`, `do_install_openai_codex`, `do_set_cursor_key`, and `do_set_codex_key`. Add cnf pins and auth markers in `all.env.yaml`. Update `install.sh`.<br>*Files*: `csi-spl-orc/src/bash/run/install-cursor-agent.func.sh`, `install-openai-codex.func.sh`, `set-cursor-key.func.sh`, `set-codex-key.func.sh`, `csi-spl-cnf/csi-spl/all.env.yaml`, `csi-spl-orc/src/bash/features/spool-install/install.sh`, `csi-spl-orc/src/bash/tests/install-cursor-agent.tst.sh`, `tests/install-openai-codex.tst.sh`. | Missing pin or unpinned `latest` fails install; key setter writes mode 0600 without stdout leak. | `install-cursor-agent.tst.sh` and `install-openai-codex.tst.sh` pass. |
| **B4** | `orc` | **Launchers & Restore Adapters**: Add `spawn-cursor.sh`, `spawn-codex.sh`, `restore-cursor.sh`, `restore-codex.sh`. Update `spawn-window.sh` vendor routing. Update `next-agent-id.sh` (`_letter_of`, `ID_ROLE_LETTERS`).<br>*Files*: `csi-spl-orc/src/bash/features/spawn-agents/scripts/{spawn-cursor.sh,spawn-codex.sh,restore-cursor.sh,restore-codex.sh,spawn-window.sh,next-agent-id.sh}`. | Dry-run spawn for unknown vendor fails; invalid title or letter mismatch refused. | Dry-run spawn test plans `cursor-agent --force` and `codex --ask-for-approval never`. |
| **B5** | `orc` | **Skills & Tooling Parity**: Add `/cursor-spawn` and `/codex-spawn` skill command assets. Update `/spawn-an-agent`. Update `harness-parity.tsv` and `agent-id-map.sh`. Update `check-fleet-rules-drift.tst.sh`.<br>*Files*: `csi-spl-orc/src/bash/features/spawn-agents/assets/commands/{cursor-spawn.md,codex-spawn.md,spawn-an-agent.md}`, `harness-parity.tsv`, `csi-spl-orc/src/bash/tests/check-fleet-rules-drift.tst.sh`. | Omission of `/cursor-spawn` or `/codex-spawn` in parity TSV fails drift check. | `check-fleet-rules-drift.tst.sh` green. |
| **B6** | `orc` | **Watchdog S2 & Process Monitoring**: Update `s2.sh` and `lib.inc.sh` with Cursor/Codex stall, quota, and auth banners. Add comms `cursor-agent`, `agent`, `codex` to `WD_HARNESS_COMM_RE`. Update `spl-session-prune.sh`.<br>*Files*: `csi-spl-orc/src/bash/features/watchdog/situations/{s2.sh,lib.inc.sh}`, `csi-spl-orc/src/bash/run/spl-watchdog.func.sh`, `csi-spl-orc/src/bash/run/spl-session-prune.sh`, `csi-spl-orc/src/bash/tests/watchdog-s2-cursor-codex.tst.sh`. | Unmatched banner produces no S2; quota error emits `kind=limit`; auth failure emits `kind=auth`. | Situation test passes against simulated Cursor and Codex pane outputs. |
| **B7** | `orc` | **Routing & Lane Mix**: Update `spl-lane-mix.func.sh` and `spl-lane-mix-journal.func.sh` to route coding tasks to Cursor and Codex. Enforce Data Rule (sensitive tasks strictly skip Cursor and Codex).<br>*Files*: `csi-spl-orc/src/bash/run/spl-lane-mix.func.sh`, `csi-spl-orc/src/bash/tests/spl-lane-mix.tst.sh`. | Sensitive task (`LANE_MIX_SENSITIVE=1`) picking Cursor or Codex fails control. | `spl-lane-mix.tst.sh` verifies weight allocation and Data Rule enforcement. |
| **B8** | `wui` | **WUI Split & Fleet Load**: Update `split.vue` with split inputs for Cursor and Codex. Update `agent-id.mjs`, `agent-kind.mjs`, `fleet-load.mjs`, `mention-grammar.json`. Add i18n keys for 19 locales.<br>*Files*: `csi-spl-wui/src/pages/tenant-settings/split.vue`, `src/utils/{agent-id.mjs,agent-kind.mjs,fleet-load.mjs,mention-grammar.json}`, locale files.<br>Initial JS chunk size delta must remain $\le 100$ B. | Sum mismatch or 5-number split without cursor/codex refused by hub/WUI. | `pnpm run typecheck` and `tenant-settings.test.mjs` unit/e2e tests pass. |
| **B9** | `ops` | **Live Pilot Verification**: Spawn live pilot lanes (`u-NNN` and `d-NNN`) on fleet boxes, execute sample test tasks, verify git commit creation, inbox/outbox messaging, and clean retirement.<br>*Scope*: Fleet boxes `sat` and `main`. | Lane failure, invalid sha, or leaked credential fails pilot. | Both agents complete assigned tasks and report exit 0. |

---

## 11. Owner Questions (Verbatim Poll Form)

The following poll questions are prepared for the dispatcher (`c-002@sat`) to present to the owner (HUM-10):

### Poll 1: Agent ID Letters
> Cursor and Codex both share the initial letter 'c', which is permanently assigned to Claude. We propose `u` for Cursor (`u-NNN`) and `d` for Codex (`d-NNN`).
>
> - **(Recommended) Option A**: **`u` for Cursor and `d` for Codex** (`u-004`, `d-004`). Mnemonic, distinct, unambiguous.
> - **Option B**: `r` for Cursor and `o` for Codex (`r-004`, `o-004`). (Note: letter `o` can resemble digit `0`).
> - **Option C**: Other custom single letters.

### Poll 2: Subscriptions and Accounts
> Which account and billing model should be provisioned for the fleet boxes?
>
> - **(Recommended) Option A**: **Dedicated seats/API keys per box** (`spool-main`, `spool-sat`), enabling isolated billing and individual revocation.
> - **Option B**: Centralized Organization / Enterprise workspace pool with centralized billing and org-wide model training opt-out.
> - **Option C**: Pay-as-you-go platform API keys only.

### Poll 3: Initial Task Routing and Split
> How should Cursor and Codex be introduced into `agent_split_by_kind`?
>
> - **(Recommended) Option A**: **Start at 0% weight initially**; enable manual testing via `/cursor-spawn` and `/codex-spawn` first. Move shares from Claude/Grok after live pilots pass.
> - **Option B**: Allocate immediately to `simple_coding` and `tests` (e.g. 15% Cursor, 15% Codex) with Claude as backup.
> - **Option C**: Dedicated coding kind allocations on specific workspaces only.

### Poll 4: The Data Rule and Secrets
> May Cursor and Codex take personal-data or secret work (`LANE_MIX_SENSITIVE=1`), as Claude, Grok, and Mistral do?
>
> - **(Recommended) Option A**: **No**. Strict fleet Data Rule applies: zero secrets and zero personal data (like Qwen and AGY).
> - **Option B**: Yes for Cursor only (with verified zero-data retention).
> - **Option C**: Yes for Codex only (with OpenAI enterprise privacy terms).
> - **Option D**: Yes for both.
