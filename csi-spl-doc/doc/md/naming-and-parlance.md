# Naming Conventions and Spool Hub Parlance

> Generated from qto doc `d7fcaaa7-0785-4f02-a4a4-19dbf8b0fbbd`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

> Generated from Qto doc in repo docs tree; export at `csi-spl-doc/doc/md/naming-and-parlance.md`. Discussion: topic `f269f087-9c97-4336-9241-afa4a4a56abe` in #spool-hub-devel (origin: topic `823bfaca-d291-4299-9ca4-d2b2bc247ae0` msg `26709eb8`). Issue: `SPL-1968`.

This document is the authoritative dictionary and reference for naming conventions, domain vocabulary, and conversation parlance across the Spool Hub ecosystem (the repository, the agent fleet, the box infrastructure, and hub discussions).

It explains the terms as they are used in practice, highlights how they differ from general English or standard industry terminology, and points to the single home of each governing rule without duplicating it.

---

<a id="ws-doc-d05b8990-ef7d-41c2-9051-18c6669dbdfd"></a>
## 1. Naming conventions

<a id="ws-doc-bf067b1c-d526-4adf-9abc-3ef0aa550bf4"></a>
### 1.1 Repositories and directories

| Pattern | Example | Where it is defined |
|---|---|---|
| `csitea/csi-spl` (trunk `master`) | `github.com/csitea/csi-spl` | `CLAUDE.md#L3-L5` |
| `csi-spl-api` | `csi-spl-api/src/go/spool-hub-api` | `CLAUDE.md#L9` (Go module for box CLI, MCP server, Cloud Run hub API) |
| `csi-spl-wui` | `csi-spl-wui/src/pages/` | `CLAUDE.md#L10` (Nuxt 3 + TypeScript WUI) |
| `csi-spl-iac` | `csi-spl-iac/src/bash/run/` | `CLAUDE.md#L11` (GCP bootstrap, terraform steps, `./run` actions) |
| `csi-spl-orc` | `csi-spl-orc/src/bash/run/` | `CLAUDE.md#L12` (Local dev orchestration, infra stack, test DB) |
| `csi-spl-cnf` | `csi-spl-cnf/csi-spl/all.env.yaml` | `CLAUDE.md#L13` (Single source of truth configuration) |
| `csi-spl-doc` | `csi-spl-doc/doc/`, `csi-spl-doc/specs/` | `CLAUDE.md#L14` (Documentation, guides, specifications) |
| `csi-spl-rdb` | `csi-spl-rdb/src/sql/postgres/spool-hub/` | Repo root directory (Postgres SQL schema migrations) |
| `csi-spl-dat`, `csi-spl-utl` | `csi-spl-dat/`, `csi-spl-utl/` | `CLAUDE.md#L15` (README only, placeholders until content added) |
| `tpl-gen/` | sibling directory clone | `CLAUDE.md#L16` (Template generator pinned by `csi-spl-iac/cnf/tpl-gen.ref`) |

<a id="ws-doc-d74c2346-a9a2-439d-a708-372c2c22eaab"></a>
### 1.2 `./run` actions and function files

| Pattern | Example | Where it is defined |
|---|---|---|
| `do_<verb>_<noun>` | `do_check_pre_push`, `do_check_dist_hygiene` | `CLAUDE.md#L57-L59` (Action entry function exposed by `./run`) |
| `<verb>-<noun>.func.sh` | `check-dist-hygiene.func.sh` | `CLAUDE.md#L57-L59` (csi-rel naming: file = action without `do_`, `_` -> `-`) |
| `spl-<noun>-<verb>.func.sh` | `spl-lane-rotate.func.sh` (`do_spl_lane_rotate`) | `csi-spl-orc/src/bash/run/` (the spool action family: 394 of 482 action scripts start with `spl-`) |
| `./run -a do_<verb>_<noun>` | `./run -a do_check_pre_push` | `CLAUDE.md#L58` (Standard action execution format) |
| `<action>_args` | `do_read_cmd_args` | `csi-spl-orc/run#L31-L45` (Decentralized argument parsing hook) |
| `<action>_pre`, `<action>_post` | `<action>_pre`, `<action>_post` | `csi-spl-orc/run#L31-L45` (Action lifecycle hooks) |
| `@param <NAME> ...`, `@arg --<flag> <VAR>` | `@param DRY_RUN (optional) - 1 or 0` | `csi-spl-orc/run#L46-L96` (Action metadata declarations) |

<a id="ws-doc-24cc8725-5d8f-4c3d-b597-1d23c4c00d21"></a>
### 1.3 Test files and suites

| Pattern | Example | Where it is defined |
|---|---|---|
| `src/bash/tests/*.tst.sh` | `check-fleet-rules-drift.tst.sh` | `src/bash/tests/`, `fleet-rules-index.md#L68`, `pre-push-gate.md` |
| `src/bash/features/*/tests/test-*.sh` | `test-pre-push-dev-guide.sh` | `developer-guide.md#L153-L156` (Feature unit tests) |
| `csi-spl-wui/tests/unit/*.test.mjs` | `markdown-unfenced.test.mjs` | `CLAUDE.md#L104`, `how-to-post.md#L169-L181` (WUI unit tests) |
| `csi-spl-wui/tests/e2e/*.test.mjs` | `docs-links.test.mjs` | `CLAUDE.md#L105`, `how-to-post.md#L173` (WUI browser E2E tests) |
| `*_test.go` | `internal/store/read_marks_test.go` | `csi-spl-api/src/go/spool-hub-api/...` (Go backend tests) |
| `bash <module>/src/bash/tests/run-all-tests.sh` | `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` | `CLAUDE.md#L93`, `L106` (Module test runner) |

<a id="ws-doc-16fecccb-39e5-43e4-93ba-c7c6bc898eba"></a>
### 1.4 Agent identifiers and box tags

| Pattern | Example | Where it is defined |
|---|---|---|
| `^[acgmq]-[0-9]{3}$` | `c-001`, `m-166`, `a-185` | Spec 061 section 0, `fleet-rules-index.md#L32` |
| `c-<NNN>` | `c-001`, `c-124` | Anthropic Claude agent (`spec 061 section 0`, `20-spawn-an-agent.md`) |
| `g-<NNN>` | `g-002`, `g-224` | xAI Grok agent (`spec 061 section 0`, `20-spawn-an-agent.md`) |
| `m-<NNN>` | `m-166`, `m-917` | Mistral / Vibe agent (`spec 061 section 0`, `spec 110`) |
| `a-<NNN>` | `a-185`, `a-194` | Google Antigravity / Gemini agent (`spec 061 section 0`, `20-spawn-an-agent.md`) |
| `q-<NNN>` | `q-101` | Alibaba Qwen agent (`spec 061 section 0`, `20-spawn-an-agent.md`) |
| `001`..`004` | `c-001`, `c-002`, `c-003`, `c-004` | Reserved OD / Peer seats (`spec 068 section 3.2`, `glossary.md#L38`; fleet-roles lists 001..003 lease roles, 068 added 004) |
| `005`..`999` | `a-185`, `c-989` | Lane agents (`glossary.md#L37`, `spec 061 section 0`) |
| `@<box>` | `c-001@sat`, `<ID>@<box>` | Box host tag (`SPEC-spool-fleet-roles.md section 4.1 L417-L420`, `glossary.md#L37`) |

<a id="ws-doc-b767413a-addb-4485-961f-914995a94f95"></a>
### 1.5 Git branches and worktrees

| Pattern | Example | Where it is defined |
|---|---|---|
| `master` | `master`, `origin/master` | `CLAUDE.md#L3`, `developer-guide.md#L17-L31` (Trunk branch) |
| `<agent-id>-<slug>` | `a-185-c002-parlance-doc` | `developer-guide.md#L21-L22`, prompt INTEGRATION (1) (Lane branch) |
| `/opt/csi/csi-spl-wt/<agent-id>` | `/opt/csi/csi-spl-wt/a-185` | Prompt INTEGRATION (1), `lane-integration-rules.md section 7 L203` (Lane worktree) |
| `/opt/csi/csi-spl` | `/opt/csi/csi-spl` | Prompt INTEGRATION (1) & (5) (Shared checkout on master) |
| any non-master branch | `a-185-c002-parlance-doc` | `CLAUDE.md#L118-L121` (Throwaway branch for CI workflow testing) |
| `v<X.Y.Z>` | `v1.3.5` | `CLAUDE.md#L131-L138`, `developer-guide.md#L42-L49` (Minted release tag) |

<a id="ws-doc-6a2ff0d6-3213-47a1-8b92-4ad6fd0099a0"></a>
### 1.6 Specifications and issue keys

| Pattern | Example | Where it is defined |
|---|---|---|
| `csi-spl-doc/specs/<NNN>-<slug>/` | `csi-spl-doc/specs/061-agent-id-rename/` | Spec root directory |
| `csi-spl-doc/specs/<NNN>-<slug>/spec.md` | `csi-spl-doc/specs/135-work-process/spec.md` | Specification document file |
| `SPL-<digits>` | `SPL-1968`, `SPL-975` | Issue key (`spec 135`, `developer-guide.md#L50-L80`) |
| `<type>(<area>, SPL-<digits>): <summary>` | `feat(orc, SPL-1968): add parlance doc` | `developer-guide.md#L67-L70` (Closing commit subject scope) |
| `Closes: SPL-<digits>` | `Closes: SPL-1968` | `developer-guide.md#L67-L70` (Closing commit body trailer) |
| `Refs: SPL-<digits>` | `Refs: SPL-1968` | `developer-guide.md#L69-L70` (Non-closing reference trailer) |

<a id="ws-doc-33f02e5c-7fcf-4f6b-80cf-a99bb502cd5e"></a>
### 1.7 GCP projects and service accounts

| Pattern | Example | Where it is defined |
|---|---|---|
| `csi-spl-<env>` | `csi-spl-dev`, `csi-spl-prd` | `CLAUDE.md#L20-L26` (Strictly dev and prd projects) |
| `europe-north1` | `europe-north1` | `CLAUDE.md#L20-L21` (Standard GCP region) |
| `csi-spl-<env>@csi-spl-<env>.iam.gserviceaccount.com` | `csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com` | `CLAUDE.md#L34-L37` (Project SA from key `client_email`) |
| `csi-spl-<env>-<role>@csi-spl-<env>.iam.gserviceaccount.com` | `csi-spl-dev-box-state@csi-spl-dev.iam.gserviceaccount.com` | Special-purpose service accounts in GCP |
| `~/.gcp/.csi/key-csi-spl-<env>.json` | `~/.gcp/.csi/key-csi-spl-prd.json` | `CLAUDE.md#L35-L38` (SA key file on disk) |
| `CLOUDSDK_CONFIG=/tmp/...` | `CLOUDSDK_CONFIG=/tmp/sdk-1234` | `CLAUDE.md#L36`, `L88-L90` (Throwaway gcloud configuration) |

<a id="ws-doc-8bddc6f1-ca76-4f14-b3ed-0eb3153f6f76"></a>
### 1.8 Terraform steps

| Pattern | Example | Where it is defined |
|---|---|---|
| `<NNN>-<slug>` | `000-gcp-remote-bucket`, `030-cloud-run-hub`, `032-gcp-cloud-run-domain-mapping` | `csi-spl-iac/src/terraform/<NNN>-<slug>/`, `CLAUDE.md#L71-L87` |
| `STEP=<NNN>-<slug>` | `STEP=030-cloud-run-hub`, `STEP=040-cloud-sql-postgres` | `CLAUDE.md#L73` (Make / run step identifier) |
| `csi-spl-cnf/csi-spl/<env>/tf/<step>.vars.tfvars` | `csi-spl-cnf/csi-spl/dev/tf/030-cloud-run-hub.vars.tfvars` | `CLAUDE.md#L13`, `L76-L77` (Rendered tfvars and backend config) |
| `csi-spl-iac/bin/csi/spl/<env>/<step>` | `csi-spl-iac/bin/csi/spl/prd/030-cloud-run-hub` | `CLAUDE.md#L82-L84` (Step terraform binary & state directory) |
| `con-csi-csi-spl-tf-runner` | `con-csi-csi-spl-tf-runner` | `CLAUDE.md#L71-L77` (Isolated Terraform runner container) |

<a id="ws-doc-bc09b2b2-5dc3-455c-a1d2-17d3c425c2f8"></a>
### 1.9 cnf keys

| Pattern | Example | Where it is defined |
|---|---|---|
| `csi-spl-cnf/csi-spl/<env>.env.yaml` | `all.env.yaml`, `dev.env.yaml`, `prd.env.yaml` | `CLAUDE.md#L13`, `L20-L26` (Single source of truth) |
| `env.gcp.<key>` | `env.gcp.gcp_org_id`, `env.gcp.gcp_account_owner_email` | `CLAUDE.md#L21-L24` (GCP estate settings in cnf) |
| `env.dns.<key>` | `env.dns.BASE_DOMAIN`, `env.dns.env_subdomain`, `env.dns.mapped_tenants` | `csi-spl-cnf/csi-spl/all.env.yaml`, `dev.env.yaml` |
| `env.box.<key>` | `env.box.agent_split`, `env.box.spawn_fill.enabled` | `fleet-rules-index.md#L19`, `L48` (Fleet orchestration knobs) |
| `env.hub.image.tag` / `.version` | `1.1.3` (advances with released tags) | `CLAUDE.md#L131-L138` (Hub image tag version floor) |

<a id="ws-doc-22a96e44-8137-401e-ac31-1ab06108ad80"></a>
### 1.10 Channels and topics

| Pattern | Example | Where it is defined |
|---|---|---|
| `#<slug>` | `#spool-hub-ops`, `#spool-hub-devel`, `#spool-hub-bugs` | `glossary.md#L23` (Shared channel in workspace) |
| `/lobby` | `/lobby` | `glossary.md#L24` (Default landing channel) |
| `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$` | `f269f087-9c97-4336-9241-afa4a4a56abe` | `glossary.md#L27`, `spec 002` (Topic UUID / `task_id`) |
| `topic:<uuid>` | `topic:f269f087-9c97-4336-9241-afa4a4a56abe` | `how-to-post.md#L73-L78` (Linkable topic reference) |
| `msg:<uuid>` | `msg:26709eb8-f2fc-4519-a264-f6babe410655` | `how-to-post.md#L73-L78` (Linkable message reference) |
| `<wui>/m/<msg-uuid>`, `<wui>/t/<topic-uuid>` | `<wui>/m/bb0b6df9-e457-4d96-a5dc-0f23b1d2e876` | `how-to-post.md#L51-L58`, `glossary.md#L15-L16` (Deep permalinks) |

---

<a id="ws-doc-59630039-e123-466e-bf62-d08d57eb826c"></a>
## 2. Spool Hub parlance

| Phrase | Meaning here | Differs from everyday English by | One real example (topic id or msg id) |
|---|---|---|---|
| **on master** | A commit has reached `origin/master` (`git merge-base --is-ancestor <sha> origin/master` exits 0), but is not yet deployed, or requires no deploy (docs-only). | In git vernacular, people often say "on master" loosely to mean committed locally or pushed; here it strictly denotes presence on `origin/master` and is explicitly distinguished from "live". | `csi-spl-doc/doc/help/how-to-post.md#L100-L102`, topic `3209f8b8-cdf7-42b3-9018-8376989f9461` msg `6eab1f5f-ef41-427b-946a-3619765e4e61` |
| **live** | Committed to master AND deployed. "Live on dev" / "live on prd" means that specific environment serves the commit (probed via `/build.json` or `/version`); bare "live" means live on dev AND live on prd. | In everyday software talk, "live" often means running in production or available on the web. Here, work pushed to master without deploy verification is explicitly NOT live. | Owner rule in topic `3209f8b8-cdf7-42b3-9018-8376989f9461` msg `6eab1f5f-ef41-427b-946a-3619765e4e61` (SPL-1952), `how-to-post.md#L95-L113` |
| **landed** | A commit confirmed to be an ancestor of `origin/master` after a fresh fetch, or an issue automatically closed when its citing commit reaches trunk. | Not merely executing `git push` or seeing `HEAD -> master` printed; confirmation requires `git merge-base --is-ancestor HEAD origin/master` after `git fetch origin master`. | `developer-guide.md#L106-L109`, `lane-integration-rules.md#31-how-a-lane-knows-its-commit-landed`, the spawn seed (`spawn-core.inc.sh`) INTEGRATION (4) |
| **ACCEPTED** | The protocol word starting a spool message sent by the dispatch lease holder or task spawner, formally accepting a lane's result and authorizing `/exit-clean`. | Not general conversational agreement or polite acknowledgement; it is a machine-parsed token required by exit gates and rotation scripts before closing a lane (body must start with `ACCEPTED`; newer `REJECT`/`SEND-BACK` outweighs it). | `spl-lane-rotate.func.sh#L258-L264`, `/var/spool-hub/<id>/lifetime/brief.md#L26` ("Wait for ACCEPTED before /exit-clean"), the spawn seed (`spawn-core.inc.sh`), msg `4f6aa9a4` |
| **send-back** | A rejection or rework instruction sent to a lane by the dispatcher/orchestrator (body starting with `SEND-BACK` or `REJECT`), invalidating previous results and keeping the lane active to remediate. | Not returning a physical shipment; a formal lifecycle message that resets the accepted state and mandates continued execution by the lane. | `spl-lane-rotate.func.sh#L263`, `/var/spool-hub/<id>/lifetime/brief.md#L26` / the spawn seed ("stay idle and answer send-backs") |
| **lane** | A transient AI agent session (IDs `005`..`999`, e.g. `a-185`) dedicated to exactly one small task, executing in an isolated worktree and branch, exiting via `/exit-clean` upon acceptance. | Not a traffic lane or bowling alley; a sandboxed resource, task, and git execution boundary for an AI worker constrained by "stay in your lane". | `glossary.md#L37`, `fleet-rules-index.md#L38` (`25-stay-in-your-lane.md`), `spec 061 section 0` |
| **seat** | A named operational slot that a session fills: an OD seat (`001`..`004`, its box, harness; session replaced hourly while seat stays), a panel seat (one member of a panel, a lane), or a standing seat (CI seat, round reviewer seat). | Not furniture to sit on; the seat is the role/slot, while the session is the ephemeral agent process currently filling it. | `spec 068 section 2`, `glossary.md#L38-L41`, msg `156e27fe`, msg `03861c5d`, `rounds-rulebook.md#L90` |
| **panel** | A cross-vendor group of lane seats that each write a draft or opinion on one question (a spec, a round plan, a design, a text), then reach consensus and sign one v1.0. | Not a physical board, solar panel, or GUI sub-window; a multi-agent review committee. | Owner rule in t1 `5901e226` msg `86dd343f` (cited in `specs/099-topic-head/spec.md#L5`), `rounds-rulebook.md#L43` & `L165-L167`, msg `095c897a`, msg `507de892`, `spec 135/reviews/` |
| **round** | A bounded campaign of at most 10 related items (bug fixes, refactoring steps, or weekly security reviews) executed continuously by lanes without individual owner go per item. | Not a circular geometric shape or a round of drinks; a structured batch execution cycle governed by standing rules R1-R16. | `rounds-rulebook.md`, `fleet-rules-index.md#L44` & `L49`, topic `3d0675ba-6dab-46cc-92c9-2aba3ac7cd23` |
| **holder** | The specific agent process (e.g. `c-001@sat` or `c-002@sat`) that currently owns a lease (`orch` or `dispatch`) in the fleet lease store. | Not a physical grip or container; the active leader holding a distributed mutual exclusion token. | `spl-dispatch-lease.func.sh`, `SPEC-spool-fleet-roles.md section 4 L315 & section 4.1 L403` (lease line `<ID>@<box> <epoch>` L500-L503), brief line 3 |
| **lease** | A time-bounded, renewable distributed lock in the hub (`orch`, `dispatch`) designating which box and agent is primary for orchestration or user dispatch. | Not a real estate rental contract; a distributed consensus mechanism with generation numbers, heartbeats, and failover timeouts. | `spl-dispatch-lease.func.sh`, `SPEC-spool-fleet-roles.md section 4.1 L434-L437` (`gen`, `spool lease --if-gen`) |
| **standby** | An OD seat that does not hold the lease right now: it reads, stays ready and relays what reaches it to the holder, but does not route, spawn or post. Also a vendor on reserve ("claude active, grok standby"). | Not standby airline travel or low-power appliance mode; an OD seat in ready reserve, relaying messages while the lease loop tracks heartbeats. | `SPEC-spool-fleet-roles.md section 3 L202-L203, section 4.1 L476-L477, L500-L506, L754`, msg `fff236ff`, msg `002c56dd` |
| **active** | The state of holding authority under an acquired lease (active orchestrator or active dispatcher) and actively performing leadership duties. | Not merely "turned on" or "busy"; possessing explicit lease leadership authority versus standing by. | `SPEC-spool-fleet-roles.md section 4.1`, `spl-dispatch-lease.func.sh`, lease event msg `02701289` ("FLEET LEASE dispatch: you are now ACTIVE...") |
| **takeover** | The automated acquisition of the lease by a standby seat when the holder's row is 180 s old (holder gone/stalled/silent, or orchestrator stuck >10 min unread); the new holder's first duty is the unanswered sweep (`do_spl_unanswered_sweep`). Also refers to watchdog takeover (`spl-wd-takeover.func.sh`). | Not a corporate acquisition or hostile raid; an orderly distributed failover protocol. | `SPEC-spool-fleet-roles.md section 4.1 L467-L477`, `spl-dispatch-lease.func.sh`, msg `02701289`, `spl-wd-takeover.func.sh` |
| **rotation** | The mandatory hourly replacement of an agent session (no session runs longer than 60 minutes) through QUIESCE -> HANDOFF -> SPAWN -> ACK -> RETIRE -> CLOSE, preserving identity and work. | Not physical spinning or employee shift scheduling; an automated agent process replacement preventing context degradation and quota lockouts. | `SPEC-spool-fleet-roles.md section 4.4`, `spec 102 section 3 L171` (`REBIRTH_AT`), `spl-lane-rotate.func.sh#L461`, the spawn seed (`spawn-core.inc.sh`) |
| **poke** | A no-op line typed into an agent's tmux pane (`: 'SPOOL <id>: ...'`) that wakes the agent's turn. | Not prodding with a finger or a social media nudge; a terminal injection triggering an agent turn (the poke is only a doorbell, the spool file is the message). | `spec 042`, `spec 002`, the spawn seed (`spawn-core.inc.sh`: "A poke line... is only a doorbell, the spool FILE is the message") |
| **ask** | A structured work request entity stored in the hub ask book (`spool ask put`), used for cross-box work delegation, blocker reporting, and spawn requests. | Not the verb "to inquire"; a concrete database object with an ID, kind, priority, and lifecycle state. | `fleet-rules-index.md#L47` (`askClassRank`), `spl-asks-open.func.sh`, `spool ask` CLI |
| **queue** | The hub's prioritized fleet spawn queue (`do_spl_spawn_enqueue`, `fleet_asks`), partitioned by work classes (`ci`, `refactor`, `bug`, `feature`) within strict percentage bands. | Not a line of people waiting; a resource scheduler balancing lane allocation across work types. | `fleet-rules-index.md#L47` (SPL-1817), topic `3209f8b8-cdf7-42b3-9018-8376989f9461` msg `8cb6cc7d-7628-4ac3-be00-86e427bb3487` |
| **placed** | A queued ask that has been matched to an available box and spawned into a live agent lane by the spawn placer (`do_spl_spawn_place`). | Not setting an object on a surface; the transition of an ask from the queue to a running agent process. | `fleet-rules-index.md#L47`, `csi-spl-orc/src/bash/run/spl-spawn-queue.func.sh` (`do_spl_spawn_place`) |
| **owner go** | Explicit approval from the repository/project owner (`HUM-10`), strictly required before GCP mutation, billing link, IAM change, `terraform apply`, or force-push. | Not an everyday "green light" or informal cheer; a strict contractual barrier preventing unauthorized infra mutations. | `CLAUDE.md#L66-L70`, `how-to-post.md#L230-L245`, topic `0f93cc2a-dc03-4bb1-9aee-294e9d558758` |
| **dry run** | Executing an action with `DRY_RUN=1` (the default for mutation scripts), printing planned steps without modifying state. | Not a theater dress rehearsal; a safety execution mode in `./run` actions requiring explicit `DRY_RUN=0` to take effect. | `CLAUDE.md#L68`, `spl-desk-reply.func.sh#L104-L109` |
| **the gate** | The complete suite of automated checks, linters, tests, and hygiene scanners required before pushing (`do_check_pre_push`) or in CI (`10_ci-quality.yml`). | Not a fence door or airport boarding gate; an automated software quality barrier that rejects non-compliant code. | `CLAUDE.md#L94-L117`, `pre-push-gate.md`, `developer-guide.md#L111-L117` |
| **red** | A failing test, build, lint scanner, or CI pipeline status; on trunk, a broken state requiring immediate fix. | Not a color on a spectrum; a failure indicator for automated verification. | `CLAUDE.md#L96`, `spec 131` |
| **green** | A passing test suite, clean lint check, or successful CI workflow run. | Not an ecological term or plant color; a verified passing state. | `CLAUDE.md#L93`, `developer-guide.md#L102-L104` |
| **flake** | A test or CI check that fails intermittently due to timing, network, or environmental races rather than code defects. | Not a flake of snow or an eccentric person; a non-deterministic automated test failure. | `csi-spl-doc/specs/016-spool-testability/ci-gate-reliability-2026-09-21.md#L26-L28` (rows C6, C7, C9), msg `56644fbe` |
| **verdict** | The decision a check or a judge returns: the dispatcher's ACCEPTED / send-back on a lane result, the push verdict (`PUSH_CMD=status`), or a gate part's pass/fail. | Not a court jury's legal finding; an automated or reviewer decision record. | Msg `008ca682` ("verdicts 0"), `lane-integration-rules.md section 3.3` ("poll the verdict"), `pre-push-gate.md` |
| **brief** | The authoritative task specification given to a lane at spawn (`/var/spool-hub/<agent-id>/lifetime/brief.md`), defining its scope, sources, steps, and acceptance criteria. | Not an adjective meaning short, a legal court brief, or undergarments; the immutable contract guiding a lane's work. | `/var/spool-hub/<id>/lifetime/brief.md`, the spawn seed (`spawn-core.inc.sh`: "read your full task brief at ... That file is your complete, authoritative instructions") |
| **scope** | The strict boundary of files and functionality described in a lane's brief that the agent is permitted to touch. | Not a telescope, microscope, or general project breadth; an inviolable operational boundary ("your brief's scope, no more"). | Seed prompt SCOPE, `lane-integration-rules.md section 8 L208` ("Scope (SCOPE a-d)") |
| **collision** | Two agents concurrently modifying the same files or overlapping paths, checked via `lane-map.sh --check <path>`. | Not an automobile accident or particle crash; a concurrent git worktree conflict between live agent sessions. | Seed prompt SCOPE + COLLISION CONTROL, `lane-map.sh` |
| **exit-clean** | The formal procedure and skill (`/exit-clean`) executed by an agent when its task is complete and ACCEPTED, verifying git cleanliness and issue tracking before termination. | Not exiting a room quietly; an automated validation check refusing termination if unlanded commits or unrecorded issues remain. | `/var/spool-hub/<id>/lifetime/brief.md#L26` ("Wait for ACCEPTED before /exit-clean"), the spawn seed (`spawn-core.inc.sh`: "Run /exit-clean... ONLY on a spool message... whose body starts with ACCEPTED"), `developer-guide.md#L74-L77` |
| **the desk** | The bridge and mailbox infrastructure (`do_spl_desk_up`, `spl-desk-reply`) connecting an agent running in a terminal pane to the Web UI / customer workspace for human interaction. | Not a piece of office furniture; an agent UI connector harness. | `glossary.md#L41`, `spl-desk-up.func.sh`, `spl-desk-reply.func.sh` |
| **workspace (never "tenant" in posts)** | A customer's isolated instance/realm (channels, members, DMs, docs, agents), e.g. `t1`. "Workspace" is the user-facing term; "tenant" is reserved strictly for code variables (`TENANT_ID`) and internal cnf. | In developer parlance, "workspace" often means a local git worktree; here it is the multi-tenant customer organization realm. | `glossary.md#L22` & `L57`, topic `6e61fb91` |

---

<a id="ws-doc-c86867e2-6715-4000-9892-01f7c1b82887"></a>
## 3. Where each rule lives

Per repository architectural standards, every fleet rule lives in exactly one authoritative location; all other references are pointers. The drift check (`./run -a do_check_fleet_rules_drift`) fails when two copies of a pinned fact disagree (`fleet-rules-index.md` section 3).

| Rule / Topic | What it governs | One home | Reference |
|---|---|---|---|
| **Agent ceiling & window count** | Maximum concurrent agent window ceiling across the box; regex count command | `csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md/20-spawn-an-agent.md` | `fleet-rules-index.md#L31`, `CLAUDE.md#L141-L147` |
| **Agent ID grammar** | Syntax and vendor letter classes for agent identifiers | Spec 061 section 0; code `SPOOL_AGENT_ID_NEW_RX` in `spool-env.inc.sh` | `fleet-rules-index.md#L32`, `CLAUDE.md#L146-L147` |
| **Data rule** | Secrets and sensitive data routing restrictions across agent vendors | `csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md/20-spawn-an-agent.md` | `fleet-rules-index.md#L33`, `CLAUDE.md#L141-L147` |
| **Language rule** | Authority for multilingual text and translation reviews across vendors | `csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md/20-spawn-an-agent.md` | `fleet-rules-index.md#L34`, `CLAUDE.md#L141-L147` |
| **Commit identity & trailers** | Commit author requirements matching repo rules; prohibition of AI trailers | Repo `CLAUDE.md` "Commits:" line | `fleet-rules-index.md#L35`, `lane-integration-rules.md section 5 L159` |
| **Spool posts format** | Markdown rendering without fences; mandatory real file extensions | `csi-spl-doc/doc/help/how-to-post.md` | `fleet-rules-index.md#L36`, `CLAUDE.md#L128-L130` |
| **Tangent discussions** | Handling pop-up side issues with new discussions and issue links | `csi-spl-doc/doc/help/how-to-post.md#8-a-tangent-gets-its-own-discussion-spl-1778` | `fleet-rules-index.md#L37`, topic `4f98d07c` |
| **Stay in your lane** | Scope adherence; reporting out-of-scope blockers to orchestrator | `csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md/25-stay-in-your-lane.md` | `fleet-rules-index.md#L38` |
| **Lane issue & docs tracking** | Issue key in commit scope; documentation updates or explicit reason line | `csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md/27-lane-issue-and-docs.md` | `fleet-rules-index.md#L39`, `lane-issue-and-docs.md` |
| **Lane integration** | Step-by-step commit, rebase, push, and teardown protocol | The agent seed, `spawn-core.inc.sh` | `lane-integration-rules.md`, `fleet-rules-index.md#L40` |
| **Master push execution** | Background push execution via named action and status polling | The spawn seed (`spawn-core.inc.sh`), INTEGRATION (4) | `fleet-rules-index.md#L41`, `lane-integration-rules.md section 3.3 L108` |
| **Never force-push master** | Strict prohibition on non-fast-forward push or deleting master | `spawn-core.inc.sh` (`NO_FORCE`), enforced by GitHub ruleset & hook | `fleet-rules-index.md#L42`, `developer-guide.md#3-never-force-push-or-delete-master` |
| **Two-language documentation** | Workspace `ws-b` dual documentation requirement (EN and BG) | `csi-spl-doc/doc/md/workspace-rules.md section 1.1` | `fleet-rules-index.md#L43` |
| **Rounds rulebook** | Campaign item limits, push caps, continuous execution rules | `csi-spl-doc/doc/md/rounds-rulebook.md` | `fleet-rules-index.md#L44`, `SPEC-spool-fleet-roles.md` |
| **Runbooks are Qto docs** | Authoritative runbooks maintained in Qto; markdown is export only | `csi-spl-doc/doc/md/qto-docs.tsv` | `fleet-rules-index.md#L45`, `runbook-dispatcher.md` |
| **Tests in production** | Non-execution of tests in production by default; opt-in operator choice | `csi-spl-doc/doc/md/guides/devops-guide.md section 16` | `fleet-rules-index.md#L46` |
| **Spawn queue bands** | Work-class target ratios and scheduler priority rules | `fleet-rules-index.md#L47` (SPL-1817); `spl-spawn-share.func.sh` (`SPL_SPAWN_BANDS`) | `SPEC-spool-fleet-roles.md section 4.3`, topic `3209f8b8` msg `8cb6cc7d` |
| **Idle filler capacity** | Automated conversion of open issues to lanes when box capacity is idle | `fleet-rules-index.md#L48` (SPL-1922); `spl-spawn-fill.func.sh` | `runbook-orchestrator.md section 5.1 L272` |
| **Weekly security round** | Standing weekly cross-vendor review round inspecting security chains | `fleet-rules-index.md#L49` (SPL-1954); `spl-security-round-queue.func.sh` | `runbook-orchestrator.md section 5.1 L272`, topic `3d0675ba` |
| **Orchestrator never runs terraform** | Requirement to delegate terraform runs to lanes rather than running in role seat | `SPEC-spool-fleet-roles.md section 1.4` | `fleet-rules-index.md#L50` |
| **Dev equals or leads prd** | Infrastructure deployment progression order; gating prd apply on clean dev plan | `fleet-rules-index.md#L51` (SPL-1947); `check-dev-leads-prd.func.sh` | `CLAUDE.md#L78-L81`, `developer-guide.md` |
