# Spec 165: Antigravity as an Orchestrator/Dispatcher Vendor and Read-Only Watcher Seats

Version **v1.0** (2026-10-29). Authored by seat `a-591` (Antigravity).  
Placement slug: `c002-agy-orch-watcher-seats-spec`.  
Epic: **SPL-1308** (Orchestration across boxes). Issue: **SPL-4172** (status wip).  
Kind: **specs_and_docs**.  
Authority: Dispatch task `dispatch-6aeebb4d` to current dispatch lease holder.  
Next free spec number on origin/master verified: **165** (highest existing is `164-channel-box-pin`, landed by a-590).

---

## 0. Owner Asks and Baseline Facts

### 0.1 The Owner's Order (HUM-10, Verbatim)

From prd topic `6aeebb4d-5dca-4a49-8257-bf1122133147` (#refactoring), msg `5c62817c-e63f-4e3c-9b8d-b39be052b6af`:

> "Well, we should start also teaching Antigravity how to be the orchestrator as well. [...] We would need a capability for \"watcher seeds\" (aka agents), which will be read-only, and they will be only watching what the other agents are doing."

This order establishes two interrelated architectural capabilities:
1. **Antigravity (agy) as an Orchestrator and Dispatcher**: Elevating Antigravity from a coding/docs/review lane agent into a first-class vendor capable of holding fleet leadership roles (`a-001` orchestrator, `a-002` master dispatcher, `a-003` failover dispatcher), with full participation in the rotation, lease acquisition, desk interaction, and lane management.
2. **Watcher Seats (\"Watcher Seeds\")**: A dedicated new seat archetype designed as an autonomous observer that operates under strictly enforced read-only constraints, inspecting fleet behavior across tmux panes, spool streams, hub channels, and lane states without mutating git repositories, posting to humans, or issuing lane commands.
3. **Shadow Training Pipeline**: Utilizing the read-only watcher capability as an empirical proving ground to \"teach\" Antigravity fleet orchestration dynamics by shadowing active orchestrators in real time before granting lease authority.

### 0.2 Baseline Facts on `origin/master` (Measured 2026-10-29)

- **Roles & Vendor Lettering**: Defined in `csi-spl-doc/doc/md/SPEC-spool-fleet-roles.md` section 1. A role seat's number (`001`..`003`) is fixed; the letter is the vendor running it (`c-001`, `g-001`, `a-001`). Role helpers `spl_is_role_seat` (`SPL_ROLE_SEAT_RX='[acgmq]-00[1-3]'`) and `spl_role_seat_id` in `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh:221-246` already accept `a-001`..`a-003`.
- **Role Vendors Today**: Claude and Grok are active role vendors. `spl-dispatch-rotate.func.sh` lines 60–65 accepts `ROTATE_ROLE_VENDOR = claude | grok | agy`, but `spl-rotate-lib.func.sh:155-158` explicitly restricts `agy` to dispatch seats and refuses `agy` for the orchestrator seat.
- **Vendor Split in Configuration**: `csi-spl-cnf/csi-spl/all.env.yaml:1275` configures `orchestration: { claude: 65, grok: 35, backup: grok }`. Antigravity holds 0% in orchestration and is excluded by validation rules.
- **Conf-Validator Hard Block**: `csi-spl-cnf/src/python/conf-validator/EnvModels/agent_split.py:21-22, 95-103` categorizes `orchestration` under `SECRET_KINDS` along with `secret`, restricting it strictly to `SECRET_VENDORS = ("claude", "grok", "mistral")` under the data rule (owner msgs `803c3b38`, `26117740`, `474f32a0`). Setting `agy > 0` or as backup in `orchestration` currently raises a validator error.
- **Watcher Seats Status**: Zero watcher seat infrastructure exists today. `git grep -n -i watcher -- csi-spl-doc` matches only the lease renewal watcher loop (`spl-dispatch-lease.func.sh:1722`).

---

## 1. Goals and Non-Goals

### 1.1 Goals

| ID | Goal | Measured By |
|---|---|---|
| **G1** | **Antigravity Role Qualification**: Enable Antigravity (`agy`) to operate as Orchestrator (`a-001`), Master Dispatcher (`a-002`), and Failover Dispatcher (`a-003`) under automated rotation. | `spl-orch-rotate.func.sh` and `spl-dispatch-rotate.func.sh` successfully spawn, verify, receive ACK from, and hand off leases to `a-001`/`a-002`/`a-003`. |
| **G2** | **Configuration Split Alignment**: Update configuration models and `all.env.yaml` to permit and enforce a measured share for `agy` in `orchestration` without violating data boundary rules. | `conf-validator` passes on updated `agent_split_by_kind.orchestration` rows containing non-zero `agy`; `do_spl_lane_mix` resolves `agy` for orchestration. |
| **G3** | **Mechanically Enforced Read-Only Watcher Seats**: Implement watcher seats (`w-NNN` or `a-wNN`) that inspect fleet execution while strictly blocking filesystem writes, git pushes, human-facing desk replies, and unauthorized spool commands at the OS/tooling layer. | Automated test suite verifying that a watcher session cannot push to git, cannot execute `do_spl_take` or `do_spl_desk_reply`, and cannot spawn lane agents. |
| **G4** | **Fleet Observation & Telemetry Feed**: Provide watchers with structured read access to tmux capture panes, spool journals (`take.log`, `registry.tsv`, `rotate.log`), hub topics, and lane map JSON. | Watcher script or tool reads state across all active fleet lanes in < 5 seconds without locking shared files. |
| **G5** | **Shadow Orchestration Pipeline**: Establish a continuous shadowing framework where a watcher ingests live incoming fleet asks, generates structured \"Shadow Decision Cards\", and evaluates concordance against live orchestrator decisions. | `/var/spool-hub/watchers/shadow-decisions.jsonl` logs shadow evaluations with >= 85% concordance benchmark prior to active lease promotion. |

### 1.2 Non-Goals

- Granting Antigravity access to raw GCP credentials or production secret keys (the data rule for `secret` kind remains inviolable).
- Removing Claude or Grok from role seats (the fleet retains a balanced multi-vendor rotation).
- Allowing watchers to post unsolicited messages into owner-facing WUI topics (findings are routed exclusively to the active Orchestrator or internal logs).

---

## 2. Section A: Antigravity in Orchestrator and Dispatcher Roles

### 2.1 What Each Role Requires from Its Vendor

#### 2.1.1 The Orchestrator Role (`a-001`)
The orchestrator is the decisive brain of the fleet on a box (`SPEC-spool-fleet-roles.md` section 1). Its vendor must support:
1. **Decision Making & Placement**: Evaluate incoming task briefs, check fleet lane map and box capacity (`do_spl_box_pick`, `lane-map.sh`), and place lanes (`spawn-window.sh`).
2. **Lease Management**: Acquire and hold the orchestrator lease (`/var/spool-hub/dispatch/lease.orch` or fleet lease in `od_pool`).
3. **Queue Ingestion**: Ingest and process requests via `do_spl_orch_inbox`.
4. **Hourly Rotation & Handoff**: Quiesce upon rotation signal, read handoff summary, resume execution under identical ID, and emit `ROTATE_CMD=ack ROTATE_ID=<rid> do_spl_orch_rotate`.
5. **Production Verification**: Run verification actions approved by policy (e.g. `do_check_deploy_lag`, `git merge-base --is-ancestor`, release note checks) without mutating production infrastructure directly.
6. **Lane Lifecycle Management**: Enforce the one-agent-one-task rule; verify and clean up finished lanes (`/exit-clean`, `kill-your-self`).

#### 2.1.2 The Dispatcher Roles (`a-002` Master, `a-003` Failover)
Dispatchers handle communication and topic ownership (`SPEC-spool-fleet-roles.md` sections 2.1, 3):
1. **3-Minute Take Rule**: Take new human posts within 180 seconds via `do_spl_take`, posting a single-line plan visible to the user.
2. **Desk Reply & Topic Ownership**: Reply directly in WUI channels via `do_spl_desk_reply` and `do_spl_desk_post`, retaining context across thread turns.
3. **Task Routing & Spawning**: Answer status queries directly; spawn a fresh lane for real coding/doc work; forward follow-ups to owning lanes via `spool-send.sh`.
4. **Standby Failover**: The failover dispatcher (`a-003`) monitors the master lease; if the master drops the lease (> 180s), failover promotes itself.
5. **Escalation**: Escalate unhandled decisions, owner blocks, and prd operations to `a-001`/`c-001`.

---

### 2.2 Today's Gaps for Antigravity (with Exact `file:line` Cites)

A comprehensive empirical inspection of `origin/master` reveals nine distinct blockers preventing Antigravity from holding role seats:

#### Gap A1: Conf-Validator Hard Exclusion of Antigravity from Orchestration
- **Files**: `csi-spl-cnf/src/python/conf-validator/EnvModels/agent_split.py:21-22, 95-104`
- **Current Code**:
  ```python
  21: SECRET_KINDS = ("secret", "orchestration")
  22: SECRET_VENDORS = ("claude", "grok", "mistral")
  ...
  95:         for kind in SECRET_KINDS:
  96:             row = rows[kind]
  97:             others = [
  98:                 v for v in VENDORS if v not in SECRET_VENDORS and getattr(row, v) != 0
  99:             ]
  100:            if others or row.backup not in SECRET_VENDORS:
  101:                raise ValueError(
  102:                    f"{kind}: only claude, grok and mistral may be non-zero or the backup"
  103:                )
  ```
- **Finding**: `orchestration` is grouped into `SECRET_KINDS`. Antigravity is strictly forbidden from holding a non-zero weight or serving as backup. Any edit to `all.env.yaml` granting Antigravity a share in `orchestration` causes `conf-validator` to exit with status 1.

#### Gap A2: Hardcoded Vendor Ratios in Global Environment Configuration
- **Files**: `csi-spl-cnf/csi-spl/all.env.yaml:1250-1254, 1275`
- **Current Code**:
  ```yaml
  1251:     # agy is 0 and never the backup in
  1252:     # tests, simple_coding and complex_coding; in the secret-class kinds,
  1253:     # secret and orchestration (dispatching and orchestrating, owner msgs
  1254:     # a1e5c678, ff1baf01), only claude, grok or mistral may be non-zero or the backup...
  1275:       orchestration:  { claude: 65, grok: 35, backup: grok }
  ```
- **Finding**: Antigravity is completely absent from the live orchestration kind row.

#### Gap A3: Orchestrator Rotation Gate Refuses Antigravity
- **Files**: `csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh:155-158`, `csi-spl-orc/src/bash/run/spl-orch-rotate.func.sh:298-301`
- **Current Code**:
  - In `spl-rotate-lib.func.sh`:
    ```bash
    155:    agy)
    156:      if [[ "${1:-orch}" != dispatch ]]; then
    157:        ROTATE_VENDOR_WHY="ROTATE_ROLE_VENDOR=agy is for the dispatch seats only, not the ${1:-orch} seat: claude"; return 0
    158:      fi
    ```
  - In `spl-orch-rotate.func.sh`:
    ```bash
    298:  case "$pick" in
    299:    claude|grok|mistral) ;;
    300:    *) ROTATE_VENDOR_WHY="lane-mix orchestration gave '${pick:-no pick}': claude"; return 0 ;;
    301:  esac
    ```
- **Finding**: `spl_rotate_role_vendor` explicitly rejects `agy` if the role family is `orch`, forcing fallback to `claude`. Furthermore, `spl_orch_rotate_vendor` only recognizes `claude|grok|mistral` in its pick switch; any pick of `agy` is discarded.

#### Gap A4: Role Rotation Agy Guard Tests Wrong Task Kind
- **Files**: `csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh:208-219`
- **Current Code**:
  ```bash
  208: spl_rotate_agy_why() {
  209:   local out pick why
  210:   out="$(env LANE_MIX_KIND=specs_and_docs LANE_MIX_SPLIT_KIND="claude=0 grok=0 agy=100 qwen=0 mistral=0 backup=claude"   211:     timeout "${ROTATE_SRC_TIMEOUT:-120}" "$ROTATE_RUN" -a do_spl_lane_mix 2>&1 7>&- 8>&- 9>&-)" || true
  ```
- **Finding**: Because `orchestration` rejected `agy`, the pre-rotation check was forced to test `specs_and_docs` as a proxy to check if the `agy` binary and sign-in are functional. Once `agy` is admitted to orchestration, this check must validate against `LANE_MIX_KIND=orchestration`.

#### Gap A5: Dispatch Setup Spawner Hardcodes Claude
- **Files**: `csi-spl-orc/src/bash/run/spl-dispatch-setup.func.sh:444-446`
- **Current Code**:
  ```bash
  444:  spl_dispatch_do spawn "spawn-window.sh claude $id $DISPATCH_REPO $brief dispatcher-$role (SPAWN_REUSE_ID=$reuse)"   445:    env SPAWN_REUSE_ID=$reuse bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/spawn-window.sh"   446:    claude "$id" "$DISPATCH_REPO" "$brief" "dispatcher-$role"
  ```
- **Finding**: Cold provisioning via `do_spl_dispatch_setup` hardcodes `claude` as the binary and harness vendor, ignoring `ROTATE_ROLE_VENDOR` or `SPL_ROLE_VENDOR`.

#### Gap A6: Allow Rules and Claude-Specific Settings Files
- **Files**: `csi-spl-orc/src/bash/run/spl-dispatch-setup.func.sh:366-377, 390-410`, `csi-spl-orc/src/bash/run/spl-dispatch-check.func.sh:137-152`
- **Current Code**:
  - `spl_dispatch_settings_json` generates `.claude/settings.local.json` to allow `do_spl_desk_reply`, `do_spl_take`, `do_spl_desk_post`, `do_spl_topic_archive`.
  - `spl-dispatch-check.func.sh:140-141` notes: `if [[ "$vendor" != claude ]]; then row "$id desk-reply permission" "$vendor seat, no Claude settings file" "ok (its launch flags allow it)"`.
- **Finding**: Antigravity runs with `--dangerously-skip-permissions` (`spool_claude_perm_flags agy` in `spool-env.inc.sh:612`). While this allows general command execution, `agy` requires custom project instructions and allow-rule hooks to ensure that internal agent tools (such as `run_command`) do not trigger interactive approvals or unexpected sandboxing during automated dispatcher takes.

#### Gap A7: Process Hierarchy Detection in Rotation Acknowledgement
- **Files**: `csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh:738-750, 1416-1418`
- **Current Code**:
  ```bash
  741: spl_rotate_claude_ancestor() {
  742:   local p="$$" comm
  743:   for _ in $(seq 1 32); do
  744:     comm=""; { read -r comm < "/proc/$p/comm"; } 2>/dev/null || true
  745:     [[ "$comm" == claude || ( -n "${ROTATE_NEW_PID:-}" && "$p" == "$ROTATE_NEW_PID" ) ]] && { echo "$p"; return 0; }
  746:     p="$(awk '{sub(/^.*\) /, ""); print $2}' "/proc/$p/stat" 2>/dev/null || true)"
  747:     [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )) || return 0
  748:   done
  749:   return 0
  750: }
  ```
- **Finding**: `spl_rotate_ack_send` verifies that the caller executing `ROTATE_CMD=ack` descends from `$ROTATE_NEW_PID`. When Antigravity executes a tool call via its subagent/tool runner, process tree hierarchy walking may encounter intermediate node or bash wrappers. If `$comm` is not `claude` and `$p` does not strictly match `$ROTATE_NEW_PID`, the ACK is rejected with status 3 (`refused: caller pid is not the new session`). `spl_rotate_cli` logic must be used to recognize `agy` process ancestry.

#### Gap A8: Prompt Poke Recognition and Terminal Composer Ghost Text
- **Files**: `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-notify.inc.sh:394-411, 507-510`
- **Current Code**:
  ```bash
  507:   last_raw="$("${SPOOL_TM[@]}" capture-pane -p -e -t "$pane" 2>/dev/null   508:     | grep -E '❯|^> ' | tail -1 || true)"
  ```
- **Finding**: Terminal doorbell notifications (`spool_notify_poke`) capture the pane and match against `❯` or `^> ` to locate the input line and determine whether the composer holds unsent text (`spool_notify_refuse_unsent`). The interactive prompt formatting of the Antigravity CLI does not use `❯`, risking false positives where pokes are continually refused with status 6 (`holds unsent text`), stranding incoming posts in `inbox/`.

#### Gap A9: Watchdog Quota Detection and Proactive Limit Handling
- **Files**: `csi-spl-orc/src/bash/run/spl-watchdog.func.sh:1194-1195, 1300-1304`
- **Current Code**: Watchdog S2 detects `login required (agy)` and `resets in XhYmZs` (SPL-3022).
- **Finding**: While basic banner parsing exists, role seats require proactive limit detection. Unlike lane agents that can afford to wait, an orchestrator or dispatcher that hits a rate limit must trigger immediate automated role failover (`do_spl_role_failover`) to prevent fleet-wide stalling.

---

### 2.3 Steps to Close the Antigravity Role Gaps

1. **Update Conf-Validator Schema**:
   - Refactor `csi-spl-cnf/src/python/conf-validator/EnvModels/agent_split.py`:
     - Retain `SECRET_KINDS = ("secret",)` as the sole restricted secret kind.
     - Move `orchestration` into an operational role kind where `ALLOWED_ORCHESTRATION_VENDORS = ("claude", "grok", "mistral", "agy")`.
     - Validate that `orchestration` contains only allowed vendors, sums to 100, and has a valid backup.
2. **Update Environment Split**:
   - Update `csi-spl-cnf/csi-spl/all.env.yaml`:
     - Introduce Antigravity share: `orchestration: { claude: 50, grok: 30, agy: 20, backup: grok }` (or owner-decided percentage).
3. **Unblock Orchestrator Rotation for Antigravity**:
   - In `csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh:155-163`:
     - Remove the `if [[ "${1:-orch}" != dispatch ]]; then` block so `agy` is accepted for both `orch` and `dispatch` families.
   - In `csi-spl-orc/src/bash/run/spl-orch-rotate.func.sh:298-301`:
     - Add `agy` to the accepted picks: `claude|grok|mistral|agy) ;;`.
4. **Generalize Dispatcher Cold Provisioning**:
   - In `csi-spl-orc/src/bash/run/spl-dispatch-setup.func.sh:444-446`:
     - Resolve the initial vendor via `spl_role_seat_vendor "$id"` (falling back to `ROTATE_ROLE_VENDOR` or `claude`), spawning the appropriate binary.
5. **Calibrate Ancestor Walking & Prompt Poke Notifier**:
   - Update `spl_rotate_claude_ancestor()` in `spl-rotate-lib.func.sh` to check `spl_rotate_cli "$p"` instead of literal `claude`, correctly identifying `agy` process ancestors during rotation ACK.
   - Update `spool_notify_refuse_unsent()` in `spool-notify.inc.sh` to recognize Antigravity's prompt boundary.

---

## 3. Section B: Watcher Seats (Read-Only Observer Agents)

### 3.1 Definition and Role of a Watcher Seat

A **Watcher Seat** is an autonomous, persistent, strictly read-only agent whose purpose is fleet observation, drift detection, and learning. It does not compete for work, does not take user posts, does not execute code builds, and does not push commits.

- **Identity Grammar**: Uses a dedicated, distinct prefix: `w-NNN` (e.g. `w-001` on box-a, `w-002` on box-b). Alternatively, if constrained to existing single-letter vendor grammar, uses `a-w01`..`a-w99` or dedicated high-range seats `a-090`..`a-099` marked with a lifetime role flag `/var/spool-hub/<ID>/.watcher-role`.
- **Core Function**:
  - Continuously inspects active fleet lanes, tmux panes, and git worktrees.
  - Monitors compliance with repo rules (`CLAUDE.md`, `developer-guide.md`, `pre-push-gate.md`).
  - Detects hangs, unhandled pokes, lease stalls, duplicate work, and anomalous token burn.
  - Generates diagnostic reports for the live Orchestrator.

---

### 3.2 What a Watcher Reads

A watcher is provided extensive read access across the box and hub:
1. **Spool Messages and Channels**:
   - Inboxes and outboxes across all active seats (`/var/spool-hub/*/outbox/*.json`).
   - Audit ledgers: `/var/spool-hub/registry.tsv`, `/var/spool-hub/dispatch/take.log`, `/var/spool-hub/dispatch/rotate.log`.
   - Fleet lease state: `/var/spool-hub/dispatch/lease`, `/var/spool-hub/dispatch/lease.orch`.
2. **Terminal Panes (Tmux Inspection)**:
   - Tmux capture panes: `tmux capture-pane -p -t <pane>` across all live agent windows to inspect active command execution, dialog prompts, and error traces without sending input.
3. **Fleet Lane Map**:
   - Output of `bash .../lane-map.sh --json` to track live lanes, scope ownership, and box load across all fleet machines.
4. **Git Repository Status**:
   - Origin/master commit history, worktree branches, diffs, and uncommitted changes across `/opt/csi/csi-spl-wt/*`.
5. **Hub Discussions and Issues**:
   - Hub topics and message streams via read-only API calls or database view queries (`ENV=dev ./run -a do_spl_db_query`).
6. **Watchdog Logs & CI Telemetry**:
   - Watchdog episode logs (`/var/spool-hub/watchdog/wd.log`) and GitHub Actions CI run status (`gh run list`).

---

### 3.3 Mechanical Enforcement of "Read-Only"

Read-only status must never rely on prompt instructions alone. It must be mechanically enforced through multiple independent security boundaries:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        WATCHER AGENT (w-NNN)                           │
└────────────────────────────────────────────────────────────────────────┘
     │
     ├── 1. Filesystem / OS Boundary:
     │      - Worktree mounted read-only (chmod a-w or read-only bind mount)
     │      - No write permissions to /opt/csi/csi-spl or shared worktrees
     │      - Scratch directory restricted to /var/spool-hub/watchers/<ID>/tmp
     │
     ├── 2. Git & Push Gate Boundary:
     │      - do_spl_push_master explicitly checks spl_is_watcher "$AGENT_ID" -> REFUSE
     │      - Git push remote configured to invalid sink: remote.origin.pushurl = "no_push"
     │      - Pre-push hook enforces refusal for watcher IDs
     │
     ├── 3. Desk & Communication Boundary:
     │      - do_spl_take: fails fast if caller is a watcher
     │      - do_spl_desk_reply / do_spl_desk_post: fails fast if caller is a watcher
     │      - do_spl_desk_up: watchers are excluded from workspace desk seating
     │
     ├── 4. Fleet Orchestration Boundary:
     │      - spool_spawn_gate: watcher is NOT a role seat (001-003) -> cannot spawn
     │      - spool-send.sh: kind=task is refused; watcher can only send kind=note to orch
     │
     └── 5. Cloud & Infrastructure Boundary:
            - Zero access to GCP service account keys or CLOUDSDK_CONFIG
```

#### Detailed Enforcement Rules:
1. **Push Gate Refusal**: In `csi-spl-orc/src/bash/run/spl-push-master.func.sh`:
   ```bash
   if [[ "$AGENT_ID" =~ ^w-[0-9]{3}$ ]] || [[ -f "${SPOOL_ROOT:-/var/spool-hub}/$AGENT_ID/.watcher-role" ]]; then
     do_log "FATAL Watcher seat $AGENT_ID is read-only: push is mechanically refused"
     return 1
   fi
   ```
2. **Desk Reply / Take Refusal**: In `csi-spl-orc/src/bash/run/spl-take.func.sh` and `csi-spl-orc/src/bash/run/spl-desk-reply.func.sh`:
   ```bash
   if [[ "$DESK_AGENT" =~ ^w-[0-9]{3}$ ]] || [[ -f "${SPOOL_ROOT:-/var/spool-hub}/$DESK_AGENT/.watcher-role" ]]; then
     do_log "FATAL Watcher seat $DESK_AGENT cannot take topics or post desk replies: read-only seat"
     return 1
   fi
   ```
3. **Spawn Refusal**: In `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh`:
   `spool_spawn_is_seat` returns non-zero for watchers, and `spool_spawn_gate` rejects watcher callers with exit 9.
4. **Spool Send Message Kind Restriction**: In `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh`:
   If `$FROM` is a watcher, `--kind task` and `--kind blocker` are forbidden. Only `--kind note` addressed to `orchestrator` or internal logs is permitted.

---

### 3.4 Findings Routing and Delivery

Where do watcher findings go?
- **Owner Noise Protection**: A watcher **never** posts directly into customer or owner-facing WUI channels. Unfiltered automated telemetry directly violates human communication hygiene.
- **Routing Rules**:
  1. **Routine Observations & Health Checks**: Appended to local JSONL journal `/var/spool-hub/watchers/findings.jsonl`.
  2. **Anomalies & Protocol Violations** (e.g. lane violating scope, missing dev-guide ack, silent hang, unpushed commits older than 30 min): Sent via spool note to the active Orchestrator:
     `spool-send.sh --from <watcher_id> --to orchestrator --kind note --task fleet-anomaly --body "<structured finding>"`
  3. **The Orchestrator Acts**: The Orchestrator (`c-001` or `a-001`) receives the note, verifies the empirical evidence, and decides whether to send a correction, restart the lane, or escalate to the dispatch holder.

---

### 3.5 Watcher Count, Vendor Split, and Rotation

- **Seat Allocation**: Exactly 1 watcher seat per active fleet box (`w-001@box-a`, `w-002@box-b`).
- **Vendor Selection**: Antigravity (`agy`) is the primary watcher vendor, fulfilling the owner's directive to teach Antigravity. Grok or Claude may be rotated in periodically to provide comparative analysis.
- **Rotation Schedule**: Watcher seats participate in hourly or 2-hourly rotation (matching spec 060 cadence) via `do_spl_watcher_rotate` to reset context, clear memory accumulation, and ensure continuous operational freshness.

---

## 4. Section C: Teaching Antigravity the Orchestrator Role (Shadowing)

### 4.1 The Shadowing Architecture

The owner noted: *"start also teaching Antigravity how to be the orchestrator as well"*. Orchestrating is high-stakes: mistakes can corrupt branches, drop customer messages, or leak keys.

The watcher seat provides the ideal **safe sandbox** for Antigravity to shadow the active orchestrator:

```
                  ┌────────────────────────────────────────┐
                  │          Incoming Fleet Event          │
                  │  (Human post, lane result, ask queue)  │
                  └───────────────────┬────────────────────┘
                                      │
                   ┌──────────────────┴──────────────────┐
                   ▼                                     ▼
      ┌─────────────────────────┐           ┌─────────────────────────┐
      │   Active Orchestrator   │           │     Watcher Shadow      │
      │        (c-001)          │           │       (w-001/agy)       │
      └────────────┬────────────┘           └────────────┬────────────┘
                   │                                     │
                   │ Real Action                         │ Shadow Decision Card
                   ▼                                     ▼
      ┌─────────────────────────┐           ┌─────────────────────────┐
      │  Executes: Lane Spawn,  │           │ Writes: Predicted Brief,│
      │   Desk Post, Verification│          │ Vendor Pick, Task Scope │
      └────────────┬────────────┘           └────────────┬────────────┘
                   │                                     │
                   └──────────────────┬──────────────────┘
                                      ▼
                        ┌───────────────────────────┐
                        │   Shadow Evaluator Loop   │
                        │ (Compares Real vs Shadow) │
                        │  Computes Concordance %   │
                        └───────────────────────────┘
```

### 4.2 The Shadow Decision Card Contract

For every incoming ask or escalation, the watcher formulates a **Shadow Decision Card** recorded in `/var/spool-hub/watchers/shadow-decisions.jsonl`:

```json
{
  "timestamp": "2026-10-29T10:15:00Z",
  "event_id": "ask-74b891a2",
  "watcher_id": "w-001@box-a",
  "predicted_action": "spawn_lane",
  "scope": "fix(orc, SPL-4180): correct desk timer race",
  "target_vendor": "claude",
  "target_box": "box-a",
  "brief_draft_path": "/var/spool-hub/watchers/drafts/c002-spl4180-fix.md",
  "live_orchestrator_action": "spawn_lane",
  "live_vendor": "claude",
  "concordance_score": 1.0
}
```

### 4.3 Concordance Scoring and Calibration

The Shadow Evaluator calculates concordance across four dimensions:
1. **Action Concordance**: Did the watcher pick the same operational action (spawn lane, answer directly, escalate, refuse) as the live orchestrator? (Weight: 40%)
2. **Vendor Routing Concordance**: Did the watcher select the vendor conforming to `agent_split_by_kind` and the data/language rules? (Weight: 20%)
3. **Scope & Issue Precision**: Did the watcher identify the correct issue key and narrow git scope without scope bloat? (Weight: 20%)
4. **Safety & Policy Adherence**: Zero violations of the data rule, zero proposed force-pushes, zero secret leaks. (Weight: 20%; binary gate).

### 4.4 Four-Phase Staged Progression to Full Orchestrator

```
Phase 1: Pure Observation
  └─ Watcher runs read-only; audits fleet hygiene; reports anomalies to c-001.

Phase 2: Real-Time Shadowing
  └─ Watcher generates Shadow Decision Cards; Evaluator logs concordance; benchmark >= 85%.

Phase 3: Supervised Co-Orchestration / Timed Drill
  └─ Antigravity participates in do_spl_orch_drill (orch-panel-plan section 4.4);
     measured against Claude and Grok on dev.

Phase 4: Full Active Lease Rotation
  └─ Antigravity added to ROTATE_ROLE_VENDOR and all.env.yaml orchestration row;
     takes a-001 / a-002 / a-003 seats in hourly rotation.
```

---

## 5. Build Rows (B1..B6)

Every row is one small, self-contained task with an explicit red control and test.

| Row | Slug | Focus Area | Touched Files | Red Control & Test |
|---|---|---|---|---|
| **B1** | `b1-conf-validator-agy-orch` | Conf-Validator schema update | `csi-spl-cnf/src/python/conf-validator/EnvModels/agent_split.py`<br>`csi-spl-cnf/csi-spl/all.env.yaml`<br>`csi-spl-orc/src/bash/tests/spl-lane-mix.tst.sh` | **Red**: Setting `orchestration.agy = 20` fails `conf-validator`.<br>**Test**: `conf-validator` succeeds with `agy > 0` in `orchestration`, while `secret` kind continues to refuse `agy`. |
| **B2** | `b2-orch-rotate-unblock-agy` | Orchestrator rotation vendor unblock | `csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh`<br>`csi-spl-orc/src/bash/run/spl-orch-rotate.func.sh`<br>`csi-spl-orc/src/bash/tests/orch-rotate.tst.sh` | **Red**: `ROTATE_ROLE_VENDOR=agy ./run -a do_spl_orch_rotate` logs `ROTATE_ROLE_VENDOR=agy is for the dispatch seats only: claude`.<br>**Test**: `orch-rotate.tst.sh` verifies `ROTATE_ROLE_VENDOR=agy` plans and spawns `a-001`. |
| **B3** | `b3-dispatch-setup-vendor-param` | Dispatch setup spawner generalization | `csi-spl-orc/src/bash/run/spl-dispatch-setup.func.sh`<br>`csi-spl-orc/src/bash/tests/dispatch-setup-check.tst.sh` | **Red**: `spl_dispatch_spawn` spawns `claude` regardless of configured role vendor.<br>**Test**: `dispatch-setup-check.tst.sh` verifies `SPL_ROLE_VENDOR=agy` provisions `a-002` and `a-003`. |
| **B4** | `b4-watcher-read-only-enforcement` | Mechanical read-only enforcement gates | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-watcher.sh`<br>`csi-spl-orc/src/bash/run/spl-push-master.func.sh`<br>`csi-spl-orc/src/bash/run/spl-take.func.sh`<br>`csi-spl-orc/src/bash/run/spl-desk-reply.func.sh`<br>`csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh`<br>`csi-spl-orc/src/bash/tests/watcher-read-only.tst.sh` | **Red**: Watcher agent executing `do_spl_push_master` or `do_spl_take` attempts execution.<br>**Test**: `watcher-read-only.tst.sh` asserts exit 1 and FATAL logs for all mutation attempts. |
| **B5** | `b5-watcher-observation-loop` | Watcher observation loop and telemetry | `csi-spl-orc/src/bash/run/spl-watcher-tick.func.sh`<br>`csi-spl-orc/src/bash/features/dispatch/brief-watcher.tpl.md`<br>`csi-spl-orc/src/bash/tests/watcher-observation.tst.sh` | **Red**: Watcher has no automated tick action to inspect lane map and panes.<br>**Test**: `watcher-observation.tst.sh` verifies tick generates structured anomaly findings into `findings.jsonl`. |
| **B6** | `b6-orch-shadow-scoring` | Shadow decision logger and scoring engine | `csi-spl-orc/src/bash/run/spl-orch-shadow-eval.func.sh`<br>`csi-spl-orc/src/bash/tests/orch-shadow-eval.tst.sh` | **Red**: No comparator evaluates shadow cards against live orchestrator placements.<br>**Test**: `orch-shadow-eval.tst.sh` asserts correct concordance calculation across test fixtures. |

---

## 6. Owner Questions (Poll for Owner Decisions)

The following architectural decisions are reserved for the owner (HUM-10):

### Q1: Vendor Share Allocation for Antigravity in Orchestration
Once Antigravity passes Phase 3 drill qualifications, what initial percentage share should it receive in `env.box.agent_split_by_kind.orchestration`?
- **Option A (Recommended)**: `claude: 50, grok: 30, agy: 20, backup: grok` (Conservative phased rollout; Claude retains majority lead).
- **Option B**: `claude: 34, grok: 33, agy: 33, backup: claude` (Equal three-way split across all capable vendors).
- **Option C**: Keep `agy: 0` in active production orchestration until Phase 2 shadow evaluation achieves >= 90% concordance over 7 consecutive days.

### Q2: Watcher Seat Identity Grammar
How should watcher seats be identified in agent naming and spool routing?
- **Option A (Recommended)**: Use dedicated `w-` prefix: `w-001`, `w-002` (expanding regex in `spool-env.inc.sh` to `[acgmoquw]-[0-9]{3}`). Cleanly distinguishes observers from coding/role agents.
- **Option B**: Use Antigravity IDs with a dedicated range (e.g. `a-090`..`a-099`) and an on-disk lifetime marker `/var/spool-hub/<ID>/.watcher-role`. Avoids altering agent ID grammar.
- **Option C**: Reserve seat `004` across vendors as a designated watcher role seat (e.g. `a-004`, `c-004`), integrating with `spl_is_role_seat` (`001`..`004`).

### Q3: Read-Only Enforcement Rigor
What level of mechanical read-only enforcement should be established for watcher seats?
- **Option A (Recommended)**: Dual-layer enforcement: tool-level action refusal (push, desk-reply, take, spawn) plus filesystem read-only permissions (`chmod a-w` on worktree, isolated scratch directory).
- **Option B**: Tool-level action refusal only (scripts reject execution, but local worktree remains writable for local temp files).
- **Option C**: Full containerized/sandboxed isolation for watchers with no writable mount points outside `/tmp`.

### Q4: Watcher Findings Routing and Delivery
Where should watcher anomaly reports and health summaries be delivered?
- **Option A (Recommended)**: Exclusively to the live Orchestrator (`c-001` / `a-001`) via internal spool notes (`kind=note`, `--task fleet-anomaly`), keeping human WUI channels silent.
- **Option B**: Low-priority findings to internal logs; critical anomalies (such as a hung orchestrator or lease drop) escalate directly to the dispatch holder.
- **Option C**: Post a daily aggregated summary card to a designated ops channel (e.g. `#monitoring` or `#spool-hub-ops`).

---

## 7. Public Distribution Hygiene Compliance

In accordance with project repository distribution rules:
- No customer names, personal names, internal infrastructure hostnames, or unredacted credentials are included.
- All code symbols, file paths, and line references have been empirically verified against `origin/master`.
- Public author attribution: standard project maintainer identity.
