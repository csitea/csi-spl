# 093 Agent watchdog: tasks

What gets built. [spec.md](spec.md) v0.2 holds the behaviour; its section 12
records the six-opinion panel consensus. Each task is one lane: one agent, one
small task, the files it owns, the tests that prove it, how it deploys and how
it is proven live. Topic: t1 `340f3be9-bd64-4419-8267-cb1b8083d8ea`. Owner
rule (consensus, then build, no go): the build starts now.

Paths: `orc/` = `csi-spl-orc/src/bash/`, `rdb/` =
`csi-spl-rdb/src/sql/postgres/spool-hub/`, `api/` =
`csi-spl-api/src/go/spool-hub-api/`, `doc/` = `csi-spl-doc/`.

## Rules for every task

- **Gate before every push, and again after the mandatory rebase**: `cd
  csi-spl-iac && ./run -a do_check_pre_push`, plus the tree's own gate (repo
  `CLAUDE.md`): `orc/` -> `bash csi-spl-orc/src/bash/tests/run-all-tests.sh`
  and `./run -a do_check_pre_push_lint`; `api/`, `rdb/` ->
  `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (store tests on Postgres) and
  the clean-code gate for new Go functions; `doc/` -> `do_check_dist_hygiene`.
- **Nothing ad hoc**: every step is a `do_<verb>_<noun>` action in
  `orc/run/<verb>-<noun>.func.sh` plus its test in the same commit; every cron
  line is installed by an `_install_cron` action (068 8.1).
- **Test seams, never a live pane**: the lease and rotate seams already exist
  (`LEASE_PANE_CMD`, `LEASE_ACTIVITY_CMD`, `LEASE_KEYS_CMD`, `LEASE_PROC_ROOT`,
  `ROTATE_SPAWN`, `ROTATE_TMUX`, `ROTATE_KILL`); new scripts take the same kind
  of seam. Tests run under the `SPOOL_TEST` guard and never on the live spool root.
- **Each fixture has a control**: an input flipped so the check DOES fire (spec
  FR-011), so a test cannot pass vacuously.
- **Live changes on the boxes** (a cron, a settings entry, a loop) go through
  the orchestrator on each box with the exact command; nothing on `sat` is
  changed by a lane on the `<pc box>` directly.
- **Migration numbers**: on `18c78bf9f` the last is `0131_demo_post_audit.sql`.
  Check again at build time (`ls csi-spl-rdb/src/sql/postgres/spool-hub | tail -1`)
  and take the next free number.
- Commits: the repo's canonical author (repo `CLAUDE.md`), no AI trailers,
  explicit pathspecs. No personal names, box tags or hosts in shipped files.

## Order and parallelism

```
P0  T001 lease stall + activity fix ─────────────────────────────► live first, alone
P1  T002 hooks + heartbeat ──┬─► T004 watchdog S1..S8 ──► T005 takeover ──► T006 lease reads wd.<id>
    T003 harness ping tests ─┘         │                                         │
                                       └─► T007 wd keeper + crons ◄──────────────┘
P2  T008 claim migration + store ──► T009 claim frames + CLI ──► T010 poll loop rounds/anchor/reconcile ──► T011 hub-down files
    T012 doc (fleet-roles) after T006; T013 live drill after T007 (P1) and after T011 (P2)
```

T001, T002, T003 and T008 start in parallel; they own disjoint files.

## Tasks

| id | phase | task | owns (files) | tests | deploy + prove |
|---|---|---|---|---|---|
| **T001** | P0 | **The incident fix.** In `spl_lease_stall`: a `LEASE_STALL_RE` hit with no moving spinner is a stall with or without a reset time; the transcript's last entry (`isApiErrorMessage`) breaks the tie against a stale banner. In `spl_lease_activity`: ignore API-error entries and prompt-only writes. (spec 9, FR-000) | `orc/run/spl-dispatch-lease.func.sh` (these two functions only), `orc/tests/fleet-lease.tst.sh` (new section) + fixtures | a fixture of the 2026-10-05 pane (`Login expired · Please run /login`, no spinner) + a transcript whose last entry is that API error -> not able; control: the same pane after a good turn -> able; control: today's code returns able on the fixture. A usage-limit fixture with a reset time behaves as today | lands on master; the lease loops pick it up at their next `ensure` restart on each box (orchestrator restarts them on the `<pc box>` and `sat`); prove with `LEASE_CMD=show` and `cat <spool root>/dispatch/able.<id>` for each OD seat on both boxes, and one replay: a scratch claude session with an expired login under `LEASE_PANE_CMD` -> `able.<id>` names the login |
| **T002** | P1 | **Hooks + heartbeat.** `spool-agent-hook.sh <event>` (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop): `heartbeat.json` + `heartbeat.log` (spec 5.2), the progress rules (5.2), the inject hook (7.2), S5's first warning, the Stop block; `do_spl_agent_hooks_install` (adds the entries beside the existing `spool-mirror.py` ones, idempotent, dry run by default) | `orc/features/spawn-agents/scripts/spool-agent-hook.sh`, `orc/run/spl-agent-hooks-install.func.sh`, `orc/features/spawn-agents/tests/test-agent-hook.sh` | per event: heartbeat fields; UserPromptSubmit and an API-error Stop leave `progress_ts` unchanged (FR-013); inject: 3 messages / 12 KB cap, never archives, never accepts; a broken spool root -> exit 0 and `hook.err`; budget: 200 runs under 50 ms each on the CI runner | install on the `<pc box>` agent user via the orchestrator (`DRY_RUN=0`), then `sat`; prove with a fresh lane: its `heartbeat.json` moves on a tool call and not on a poke; a message sent mid-turn appears in its context within one tool call (n >= 3) |
| **T003** | P1 | **Harness ping tests.** One ping hook per harness (grok, agy via `PreInvocation` / `injectSteps`, qwen): inject a random token after a tool call, ask the agent to echo it (spec 7.3) | `orc/features/spawn-agents/scripts/hook-ping/` (one file per harness), `orc/run/spl-hook-ping.func.sh` + its test | the action's own test with a stub harness | run on the `<pc box>` for each installed harness, n >= 3 each; record pass / fail per harness in spec 7.3 (a doc commit). A harness that fails stays on the S8 path |
| **T004** | P1 | **Watchdog + situations.** `do_spl_watchdog` (30 s tick, `timeout 5` per script, verdict file `dispatch/wd.<id>`, debounces, the 6.2 guards, the 6.3 limits); `situations/s1..s8.sh`; `do_spl_wd_hold` | `orc/run/spl-watchdog.func.sh`, `orc/run/spl-wd-hold.func.sh`, `orc/features/watchdog/situations/*.sh`, `orc/tests/wd-situations.tst.sh` + fixtures | one fixture + control per situation (6.1) and per false-positive row (6.2), FR-011; a script that sleeps 60 s -> the tick ends within 30 s (FR-014); S2 never takes over | the loop needs T007 to run on a box; until then prove with `WD_TICKS=1 ./run -a do_spl_watchdog` on the `<pc box>`: one verdict line per live agent, all `OK` except what is really stuck |
| **T005** | P1 | **Takeover.** `do_spl_wd_takeover` through the 060 functions (spec 8.1), the handoff's `## watchdog` section, the investigation blocker (8.2), the remote relay `--to wd@<box>` | `orc/run/spl-wd-takeover.func.sh`, `orc/tests/wd-takeover.tst.sh` | S1, S3, S4, S5 end in a fresh session under the same id (ROTATE seams), FR-012; a request with no hit -> exit 3; a third in an hour -> held out + one owner DM; a human hold -> refused; a role id writes `rotate.hold` while it runs | live: a throwaway lane with a stopped harness (S3) on the `<pc box>` is taken over within 2 ticks; `rotate.log` shows the `WD-` phases; its peers receive the `wd-<id>-<rid>` blocker |
| **T006** | P1 | **Lease reads the watchdog.** `spl_lease_agent_able` reads `dispatch/wd.<id>`: a `HIT` fresh within 90 s = "not able: wd <code>" (spec 9 P1) | `orc/run/spl-dispatch-lease.func.sh` (`spl_lease_agent_able` only; after T001 has landed), `orc/tests/fleet-lease.tst.sh` (new section) | a fresh `HIT S3` -> not able, renew stops, standby takes over at 181 s; a stale `HIT` (> 90 s) -> ignored; no file -> unchanged behaviour | lease loops restarted on both boxes by the orchestrator; prove with `able.<id>` after a planted `wd.<id>` on a standby seat (never on the holder) |
| **T007** | P1 | **Keeper + crons.** `do_spl_wd_ensure` (starts only the watchdog, runs with or without seats) and `do_spl_wd_ensure_install_cron` (`* * * * *`, tag `# csi-spl:wd-ensure`) | `orc/run/spl-wd-ensure.func.sh`, `orc/run/spl-wd-ensure-install-cron.func.sh`, their test | a dead loop is restarted on the next run; a second run with the loop alive starts nothing; crontab fixture before / after; 068 8.1's crontab path check | the orchestrator installs it on the `<pc box>` and `sat`; prove with `crontab -l \| grep -c 'csi-spl:wd-ensure'` -> 1 on each, and SIGKILL of the watchdog restarted within 60 s (n >= 3, FR-015) |
| **T008** | P2 | **Claim migration + store.** The columns of spec 4.1; the transitions T1..T10 in the memory and Postgres stores (`message_claim*.go`), `claim_n` on accept, the anchor on renew | `rdb/<next>_messages_claim_round.sql`, `api/internal/store/message_claim.go`, `message_claim_postgres.go`, `message_claim_test.go` | memory + Postgres: two accepts in one round, n >= 100 (FR-004); lapse, one-lap skip, `OFFER_MAX` dead (FR-003); renew writes the anchor (FR-002); park renews only while able (FR-006); per-job touch (FR-007); every row in exactly one `claim_state` | `ENV=dev DRY_RUN=0 ./run -a do_spl_db_bootstrap`; prd: the exact command to the orchestrator; prove with `do_spl_db_query` on the catalog on dev and prd |
| **T009** | P2 | **Frames + CLI.** Box frame `claim` ops `poll` (with `idle\|busy`), `accept --round`, `park --wait`, `unpark`, `touch`, `release`, `done`, `check`; `spool claim` flags | `api/internal/hub/box_claim.go`, `api/cmd/spool/claim.go`, their tests | `TestBoxMessageClaim` extended: two boxes, a round, the accept race, park lapse on a not-able holder; fence exit 1 vs 2 vs answer-once 409 (FR-009) | hub via wf 20, proven by `/version` on dev and prd; the CLI via the box update |
| **T010** | P2 | **Poll loop.** Rounds (idle first, `BUSY_DELAY`, `OFFER_K`, harness mix), stubs, the anchor renew, inbox reconciliation (4.5), park renew on able, T7b; `PEER_PROGRESS_MAX` removed | `orc/run/spl-peer-poll.func.sh`, `orc/tests/peer-poll.tst.sh` | 4 seats on 2 simulated boxes: FR-001 (125 s, n >= 20), FR-005 (idle first), FR-008 (stale stub archived, no takeover), park lapse (FR-006) | inert until seats exist (068 L7); prove in the 068 drill (T013) |
| **T011** | P2 | **Hub-down files.** `.offer` / `.accept` local two-phase claim (spec 4.6) | `orc/run/spl-peer-poll.func.sh` (the hub-down functions only, after T010), the agent side in `spool claim --accept`'s local fallback (`api/cmd/spool/claim.go`, after T009) | hub stub down: an offer file is not ownership; only the accept file is; adopt on return only if still free (FR-010) | as T010 |
| **T012** | doc | **Fleet-roles doc.** SPEC-spool-fleet-roles.md section 4 (the P0 stall rule, the `wd.<id>` input), a new section for the watchdog and the takeover; spec 093 status rows | `doc/doc/md/SPEC-spool-fleet-roles.md`, `doc/specs/093-agent-watchdog/spec.md` (status only) | `do_check_dist_hygiene`, `lint-mdlinks` | lands on master |
| **T013** | drill | **Live drill on both boxes.** P1: S2 (a scratch session with an expired login), S3 (a killed harness), S4 (a hung tool), S6 (a stuck poke line), each n >= 3, delays recorded against spec 11. P2 (after 068 L7): the claim drill, n >= 5 per FR-001 / FR-006 | `doc/specs/093-agent-watchdog/drill-<date>.md` | the drill log vs spec 11 | the orchestrator on each box runs the destructive steps; the lane writes the log |

## What blocks what

| task | needs |
|---|---|
| T001 | nothing |
| T002, T003, T008 | nothing |
| T004 | T002 (heartbeat format) |
| T005 | T004 |
| T006 | T001 (same file, landed first), T004 (the verdict file) |
| T007 | T004 |
| T009 | T008 |
| T010 | T008, T009, T002 |
| T011 | T009, T010 |
| T012 | T006 |
| T013 | P1: T005, T006, T007; P2: T011 and 068 L7 (seats) |

## Not built here

The 068 cut-over itself (068 L7..L10: seats, staged hand-over, deleting the
lease roles) stays 068's; T010 and T011 change the poll loop 068 L3 built and
stay inert until 068 L7 writes the seat file.

<!-- version: 0.1.0 · updated: 2026-10-05 · last-edit: 2026-10-05T20:10:00Z -->
