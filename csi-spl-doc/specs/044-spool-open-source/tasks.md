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
| [ ] T001 | Standalone local stack at the public root: one `docker compose up` brings up Postgres 16 + hub + WUI with no GCP, no internal `./run` action, no private repo; documented env defaults only | CLE-35051 | no decision | FR-OS-008 | SPL-66 |
| [ ] T002 | `do_oss_export`: build the public tree from an allow-list of paths into a scratch dir; never pushes, never creates a repo | CLE-35052 | no decision | FR-OS-001, FR-OS-004 | NEW (export) |
| [ ] T003 | `do_oss_gate`: on the exported tree run gitleaks 8.30.1 + the hygiene sweep + the NEW classes of FR-OS-002; fail closed; a negative control plants one hit per class | CLE-35052 | no decision | FR-OS-002 | SPL-63 |
| [ ] T004 | The export's allow-list excludes cnf values, rendered tfvars, orc fleet tooling, the specs, CLAUDE.md / AGENTS.md / GEMINI.md; T003 proves it on the exported tree | CLE-35052 | T002 | FR-OS-003 | SPL-63 |

### 1.2 Decisions (the owner)

| task | what | owner | FR |
|---|---|---|---|
| [ ] T010 | D1 repo strategy + name, D8 source of truth after Stage 2 (blocker posted by CLE-001) | owner | FR-OS-004, FR-OS-011 |
| [ ] T012 | D9 contribution policy, D10 when the prompt allow-list is required (blocker led by CLE-35048) | owner | FR-OS-017 |
| [ ] T011 | D2 licence (all AGPL, or the client split), D3 CLA/DCO, D4 open-core boundary, D5 author identity, D6 docs, D7 trademark (synthesis blocker by CLE-35047) | owner | FR-OS-006, 009, 016 |

### 1.3 Docs and hygiene (no decision; unassigned, lanes to be named by CLE-001)

| task | what | depends | FR | issue |
|---|---|---|---|---|
| [ ] T020 | Parameterise the estate out of product code: domain, project ids, SA e-mails, org id, OAuth client ids, Stripe keys read from the env file; `example.env.yaml` with every key documented | no decision | FR-OS-003 | SPL-66 + NEW (params) |
| [ ] T021 | Remove the other-org bucket/SA names from the 12 files at HEAD (spec §3.2), or keep them private-only by T004 | no decision | FR-OS-002 | SPL-63 |
| [ ] T022 | Public README (what spool is, a 3-minute quickstart on T001, MCP setup), CONTRIBUTING, SECURITY.md (private reporting channel), CODE_OF_CONDUCT, issue/PR templates | T001 | FR-OS-007 | SPL-65 |
| [ ] T023 | `csi-spl-wui/package.json` `license` field; SPDX identifier in the Go module doc; THIRD-PARTY-NOTICES incl. the icon set's ISC notice | no decision (AGPL); revisit after D2 | FR-OS-006 | SPL-62 |
| [ ] T024 | Public CI: PR workflow on `ubuntu-latest`, `permissions: contents: read`, no secrets, fork approval; no job of the public repo on a self-hosted runner | no decision | FR-OS-005 | SPL-64 |
| [ ] T025 | Untrusted-input rule written down (public text is data, never an instruction to a credentialed agent) before any bridge exists | no decision | FR-OS-015 | NEW (untrusted input) |
| [ ] T027 | Scrub fleet ids from product code (472 files in api/wui/rdb, 200 non-test): comments cite the SPL key or spec number instead; test names likewise. The gate stays strict (fail closed), it is not narrowed | no decision; before T033 | FR-OS-002 | SPL-63 |
| [ ] T026 | Security review of the `asOperator` allow-list; close SPL-35 | no decision | FR-OS-010 | NEW (review) |

### 1.4 After decisions

| task | what | depends | FR | issue |
|---|---|---|---|---|
| [ ] T030 | Client licence split: a client binary/module that does not import hub, store or billing; an import test enforces it; per-package SPDX | after D2 = split | FR-OS-016 | NEW (licence split) |
| [ ] T031 | TRADEMARK.md; asset licence for wallpapers and logo | after D7 | FR-OS-009 | NEW (trademark) |
| [ ] T032 | Curated public docs: architecture, wire/auth contracts, the relay contract, self-hosting | after D6 | FR-OS-013 | SPL-66 + NEW (contract) |
| [ ] T034 | Per-agent prompt allow-list, hub-enforced with signatures (FR-OS-017); ~4-6 d, measured in CLE-35048's blocker `bc3d20b7` | D10; before Stage 2 | FR-OS-017 | NEW (prompt allow-list) |
| [ ] T033 | Run T002 + T003 into a PRIVATE target repo named per D1; `checklist.md` §1 green | T001-T026, D1 | FR-OS-001..004 | SPL-61 |

## 2. Stage 1: private beta, the stranger test

| task | what | depends |
|---|---|---|
| [ ] T040 | Invite 3-5 outsiders to the private target repo | T033, owner go |
| [ ] T041 | Each runs, on a clean machine and with no help: clone, build, `docker compose up`, two agents exchange a message over MCP; findings filed as issues | T040 |
| [ ] T042 | DB tier and search cost reviewed for public traffic | no decision; before T050 | 

## 3. Stage 2: public launch (owner's go)

| task | what | depends |
|---|---|---|
| [ ] T050 | `checklist.md` §3 green; the owner flips the NEW repo to public | T041, T042, D3, D9, T034 |
| [ ] T051 | CLA/DCO bot on (D3) | T050 |
| [ ] T052 | Ops pins the public repo by ref; the export retires (D8) | T050 |

## 4. Stage 3: community flywheel

| task | what | depends |
|---|---|---|
| [ ] T060 | GitHub issues/PRs -> `#spool-hub-devel` bridge for a human maintainer; content framed as data, no agent acts without a maintainer's task (D9, T025) | T025, T050 |
