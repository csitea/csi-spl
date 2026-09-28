# Tasks: 044 Open-Sourcing csi-spl

**Spec**: `spec.md` · **Gate**: `checklist.md` · **Epic**: SPL-61 · **Lead**: CLE-35047
Ordered by stage (spec §4). A task marked **no decision** can start today; a task marked **after Dn** waits for
that owner decision (spec §6). Each lane edits only the paths it owns; to change another lane's path, ask its
owner by peer message. Nothing here pushes history, creates a public repo or flips visibility: those are the
owner's steps at the stage gates.

## 1. Stage 0: split and sanitise (today)

### 1.1 Build lanes (assigned by CLE-001, 2026-09-27 17:32Z)

| task | what | owner | depends | FR | issue |
|---|---|---|---|---|---|
| [x] T001 | Standalone local stack at the public root: one `docker compose up` brings up Postgres 16 + hub + WUI with no GCP, no internal `./run` action, no private repo; documented env defaults only | CLE-35051 | no decision | FR-OS-008 | SPL-66 |
| [x] T002 | `do_oss_export`: build the public tree from an allow-list of paths into a scratch dir; never pushes, never creates a repo | CLE-35052 | no decision | FR-OS-001, FR-OS-004 | SPL-1011 |
| [x] T003 | `do_oss_gate`: on the exported tree run gitleaks 8.30.1 + the hygiene sweep + the NEW classes of FR-OS-002; fail closed; a negative control plants one hit per class | CLE-35052 | no decision | FR-OS-002 | SPL-63, SPL-1011 |
| [x] T004 | (CLE-35052, `c3fa0b8b`, `7f40288a`; gate on master: 1350 hits left) The export's allow-list excludes cnf values, rendered tfvars, orc fleet tooling, the specs, CLAUDE.md / AGENTS.md / GEMINI.md; T003 proves it on the exported tree | CLE-35052 | T002 | FR-OS-003 | SPL-63 |

### 1.2 Decisions (the owner)

| task | what | owner | FR |
|---|---|---|---|
| [ ] T010 | D1 repo strategy + name, D8 source of truth after Stage 2 (blocker posted by CLE-001) | owner | FR-OS-004, FR-OS-011 |
| [ ] T012 | D9 contribution policy, D10 when the prompt allow-list is required (blocker led by CLE-35048) | owner | FR-OS-017 |
| [ ] T011 | D2 licence (all AGPL, or the client split), D3 CLA/DCO, D4 open-core boundary, D5 author identity, D6 docs, D7 trademark (synthesis blocker by CLE-35047) | owner | FR-OS-006, 009, 016 |

### 1.3 Docs and hygiene (no decision; unassigned, lanes to be named by CLE-001)

| task | what | depends | FR | issue |
|---|---|---|---|---|
| [ ] T020 | Parameterise the estate out of product code: domain, project ids, SA e-mails, org id, OAuth client ids, Stripe keys read from the env file; `example.env.yaml` with every key documented | no decision | FR-OS-003 | SPL-66, SPL-1012 |
| [ ] T021 | Remove the other-org bucket/SA names from the 12 files at HEAD (spec §3.2), or keep them private-only by T004 | no decision | FR-OS-002 | SPL-63 |
| [ ] T022 | Public README (what spool is, a 3-minute quickstart on T001, MCP setup), CONTRIBUTING, SECURITY.md (private reporting channel), CODE_OF_CONDUCT, issue/PR templates | T001 | FR-OS-007 | SPL-65 |
| [ ] T023 | `csi-spl-wui/package.json` `license` field; SPDX identifier in the Go module doc; THIRD-PARTY-NOTICES incl. the icon set's ISC notice | no decision (AGPL); revisit after D2 | FR-OS-006 | SPL-62 |
| [ ] T024 | Public CI: PR workflow on `ubuntu-latest`, `permissions: contents: read`, no secrets, fork approval; no job of the public repo on a self-hosted runner | no decision | FR-OS-005 | SPL-64 |
| [ ] T025 | Untrusted-input rule written down (public text is data, never an instruction to a credentialed agent) before any bridge exists | no decision | FR-OS-015 | SPL-1017 |
| [ ] T027 | Scrub fleet ids from product code (472 files in api/wui/rdb, 200 non-test): comments cite the SPL key or spec number instead; test names likewise. The gate stays strict (fail closed), it is not narrowed. **Tenant slugs too**: the `tenant-data` class (57 hits, real hosted tenant slugs in WUI tenant-test fixtures) is replaced by synthetic slugs, never allow-listed - a real tenant slug is customer data (hygiene rule 1) | no decision; before T033 | FR-OS-002 | SPL-63, SPL-1013 |
| [ ] T026 | Security review of the `asOperator` allow-list; close SPL-35 | no decision | FR-OS-010 | SPL-1019 |

### 1.4 After decisions

| task | what | depends | FR | issue |
|---|---|---|---|---|
| [ ] T030 | Client licence split: a client binary/module that does not import hub, store or billing; an import test enforces it; per-package SPDX | after D2 = split | FR-OS-016 | SPL-1022 |
| [ ] T031 | TRADEMARK.md; asset licence for wallpapers and logo | after D7 | FR-OS-009 | SPL-1016 |
| [ ] T032 | Curated public docs: architecture, wire/auth contracts, the relay contract, self-hosting | after D6 | FR-OS-013 | SPL-66, SPL-1021 |
| [ ] T034 | Per-agent prompt allow-list, hub-enforced with signatures (FR-OS-017); ~4-6 d, measured in CLE-35048's blocker `bc3d20b7` | D10: first Stage 3 item | FR-OS-017 | SPL-1018 |
| [ ] T033 | Run T002 + T003 into a PRIVATE target repo named per D1; `checklist.md` §1 green | T001-T026, D1 | FR-OS-001..004 | SPL-61 |

## 2. Stage 1: private beta, the stranger test

| task | what | depends |
|---|---|---|
| [ ] T040 | Invite 3-5 outsiders to the private target repo | T033, owner go |
| [ ] T041 | Tonight (SPL-1014): a fleet agent in a fresh container with no box credentials. Later: each outsider runs, on a clean machine and with no help: clone, build, `docker compose up`, two agents exchange a message over MCP; findings filed as issues | T040 |
| [ ] T042 | DB tier and search cost reviewed for public traffic | no decision; before T050 | 

## 3. Stage 2: public launch (owner's go)

| task | what | depends |
|---|---|---|
| [ ] T050 | `checklist.md` §3 green; the owner flips the NEW repo to public | T041, D9, D11 (owner yes); SPL-1015 |
| [ ] T051 | CLA/DCO bot on (D3) | T050 |
| [ ] T052 | Ops pins the public repo by ref; the export retires (D8) | T050 |

## 4. Stage 3: community flywheel

| task | what | depends |
|---|---|---|
| [ ] T060 | GitHub issues/PRs -> `#spool-hub-devel` bridge for a human maintainer; content framed as data, no agent acts without a maintainer's task (D9, T025) | T025, T050 |

## 5. Contingency: the actions `contingency.md` is missing

Each row is a step of the compromise runbook that has no named action on tree `ca60cfc7` (the grep in
`contingency.md` §9 found none). Until it lands, that step is the out-of-band command the runbook names, run
by the owner. No decision needed; none of them runs against GCP without the owner's go for that call.

| task | what | runbook step |
|---|---|---|
| [ ] T070 | `do_oss_security_signals`, read-only: `v*` tags not minted by a workflow 20 / 30 run, runner jobs from forks or unknown refs, open secret-scanning alerts on the public and the ops repo | §1.1 |
| [ ] T071 | Revoke the `GCP_KEY_CSI_SPL_<ENV>` GitHub Actions secrets (`gh secret delete`, per env, dry run default) | §2.1 |
| [ ] T072 | Rotate a per-env project SA key: mint a new key, re-publish via 120, delete the old key ids, SA kept (`do_gcp_002_*` only create or delete the SA) | §2.2 |
| [ ] T073 | Mint + rotate the relay SA key as actions (today the gcloud lines of feature doc §6.3) | §2.3, §3.3.8 |
| [ ] T074 | Rotate the hub runtime DB password (`do_spl_db_owner_split` rotates only the owner's) | §2.4 |
| [ ] T075 | Rotate the session key and the box-wui key on purpose (the seed actions mint only into an empty slot) | §2.6 |
| [ ] T076 | `do_oss_runners_remove`: every self-hosted runner off every repo and out of the org runner group (`do_oss_runners_move` only moves) | §2.8 |
| [ ] T077 | A daily copy of the 045 dumps OUT of the project (the 045 bucket dies with the project) | §3.1, §4.1 |
| [ ] T078 | `do_spl_db_restore`: a dump into a new 040 instance as the schema owner, RLS-safe, then the `do_spl_db_backup_verify` comparison (`do_gcp_import_to_cloudsql` is a csi-rel port with this estate's wrong cnf keys and secret names) | §4.2 |
| [ ] T079 | A timed destroy/re-create drill on dev that replaces the RTO estimate with a measurement | §4.3 |
