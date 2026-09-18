# csi-spl git-spec — index, redo ground rules, integrator decisions

This file is the **in-repo authority for the git-spec redo** started
2026-09-18. It holds three things: the rules every spec area follows, the
index of spec dirs (numbering and cross-references), and the cross-spec
decisions the integrator has taken. Area specs link here instead of restating
them.

Owner of this file, of the numbering and of the final cross-spec consistency
pass: the **integrator** lane. Each `NNN-*` dir is owned by its area lane.

---

## 1. Why the redo

The git-spec grew across ~30 parallel lanes and drifted: specs contradicted
each other (002/003/004/006/007), tasks were ticked from agent reports rather
than from artifacts, and one gap went unnoticed end to end — **no terraform
step creates the Cloud DNS managed zone for the product domain**
(`031-gcp-hub-ingress/06-dns.tf` only writes records into an *assumed*
`var.dns_managed_zone`, and cnf sets it to `""`), with DNS sequenced last
instead of first.

---

## 2. Ground rules (every area lane)

1. **`002-box-agent-messaging` is kept untouched.** Local messaging is shipped.
   Other specs cite it; nobody edits it in this redo.
2. **Trust reality, not reports.** Every *Implemented* claim is checked against
   the artifact: `git show` / `grep` for code, `terraform state list` / `plan`
   for infra, `gcloud … --account=$GCP_ACCOUNT` for live GCP, the test suite for
   behaviour. A claim about a file cites the command and its result
   (`grep -c X file -> 3`), not a paraphrase.
3. **Status vocabulary** on every FR and task:
   - **Implemented** — artifact exists and was verified (cite sha or command).
   - **Partial** — some of it exists; say which part is missing.
   - **Planned** — nothing built yet.
4. **Docs only.** A spec that needs code, cnf, iac, orc or wui to change writes
   it as a **task**; it does not make the change.
5. **One dir per lane.** Edit only your own `specs/NNN-*/**`. Seams between
   dirs are the integrator's (section 5).
6. **Stamp** every changed doc on its last line:
   `<!-- version: X.Y.Z · updated: YYYY-MM-DD · last-edit: <ISO-8601-UTC> -->`.
7. **Distribution hygiene** (repo `CLAUDE.md`, CI `10_ci-quality.yml` sweep): no
   personal names, OS users, owner mail addresses or their domains, no
   `/home/<user>/` paths. Write `$GCP_ACCOUNT`, never a literal account.
8. Git: rebase onto `origin/master` before every push, pathspecs under
   `csi-spl-doc/specs/<your-dir>/`, the repo's author identity, no AI trailer.

---

## 3. Binding authorities (reconcile to these)

| Topic | Authority |
|---|---|
| Local unsigned vs hub box keys | `002-box-agent-messaging/contracts/trust-modes.md` |
| Milestone cut M1/M2/M3/M4 | `../doc/md/SPEC-spool-milestones.md` |
| Ids, pins, routing | `../doc/md/SPEC-spool-identity-routing.md` |
| Bus narrative | `../doc/md/SPEC-spool-message-bus.md` |
| Box API (CLI + MCP) | `../doc/md/SPEC-spool-box-api.md` |
| `task_id` / `kind` | `../doc/md/SPEC-spool-task-lifecycle.md` |
| WUI | `../doc/md/SPEC-spool-wui.md` |
| Rental / tenancy | `../doc/md/SPEC-spool-hub-rental.md` |
| Hub infra shape | `../doc/md/SPEC-spool-hub-api-infra.md` |
| Relay estate | `../doc/md/csi-spl.feature.md` |
| 003 open questions OQ-01..15 | folded into `003-spool-message-bus/spec.md` (Clarifications) |

### 3.1 Canon every spec respects

- **Trust:** local mode is **unsigned** (no keys). Hub mode is **one Ed25519
  key per box**; agents share it. `from_box` / `to_box` exist **only in the
  hub envelope**. Send result `delivery` is `local | sent | queued | pending`.
- **Hub wire:** send/recv/tail are **WebSocket only** (`/v1/ws`, hello is
  challenge-response over a hub nonce, `role=box|cli`); REST is **files and
  pins only**. No NATS, no SSE in M1. `max-instances=1` in M1.
- **Milestones:** **M1** local + hub proof on the product domain (IP allowlist
  ingress, owner-made tenants, CLI + MCP, no browser, no checkout) ·
  **M2** buy on the site (thin checkout, one-time root-key email) ·
  **M3** Slack-like WUI · **M4** seats + buy-minute project id ·
  **later** CI logs in chat, reverse chat, BYO GCP.

---

## 4. Index — spec dirs, owners, milestone

Numbering is **kept as-is** (no dir is renamed in the redo; every existing
`specs/NNN-…` citation stays valid).

| Dir | Area | Milestone | Redo lane |
|---|---|---|---|
| `001-relay-bucket-estate/` | git-rel GCS relay estate (retro) | pre-M1 | area lane 001 |
| `002-box-agent-messaging/` | local folder spool, CLI + MCP, `trust-modes.md` | M1 (shipped) | **frozen** |
| `003-spool-message-bus/` | the hub: `spool serve` WS + REST, `hubclient`, store, blob, `spool migrate`, read-only viewer API for the WUI | M1 (+ viewer API for M3) | area lane 003 |
| `004-spool-identity-routing/` | agent ids, box ids/keys, pins, tenant root, `BOX-` forbidden | M1 | area lane 004 |
| `005-spool-wui/` | Slack-like WUI (Nuxt), its hub read-API dependency | M3 | area lane 005 |
| `006-spool-hub-rental/` | tenancy, root-key pinning, quota/unpaid, payment | M1 (tenancy) / M2 (payment) | area lane 006 |
| `007-spool-hub-api-infra/` | the cloud estate in provisioning order (section 6), lde, orc, rdb pointer | M1 | area lane 007 |
| `008-spool-cicd-logs/` | CI/CD: GitHub Actions build + deploy (dev, prd; WIF) + ci-quality gate (**M1**), and CI logs posted into chat (**later**) | M1 + later | area lane 008 |
| `009-spool-m4/` | seats + buy-minute project id | M4 | integrator (seam fixes only) |
| `010-spool-social-auth/` | social IdP login for humans (`../doc/md/SPEC-spool-social-auth.md`): hub `/auth/*`, signed session cookie (`internal/auth`); Google + Facebook first, Microsoft / LinkedIn / xAI on the same rails | M2 (register) / M3 (WUI login) | social-auth lane |

**008 keeps its dir name.** Its scope widens to the whole CI/CD area: the
pipeline (`.github/workflows/10_ci-quality.yml`, `20_hub-build-deploy.yml`) is
an M1 user story, and the CI-logs-in-chat feature stays a separate, *later*
user story in the same spec. Renaming the dir would break citations in
`SPEC-spool-milestones.md` and `SPEC-spool-cicd-logs.md` for no gain.

Dependency order between specs:
`002 → 004 → 003 → 007 (+008 pipeline) → 006 (M1 tenancy) → M1 demo →
006 (M2 payment) → 005 (M3) → 009 (M4) → 008 (CI logs in chat)`.

---

## 5. Seams — who writes what where two specs meet

| Seam | Owner of the text | The other spec |
|---|---|---|
| `trust-modes.md` wording | 002 (frozen) | everyone cites `trust-modes §N` |
| Hub envelope, WS frames, REST files/pins, error envelope | 003 `contracts/` | 004, 006 cite; do not restate |
| Pin semantics (409, `--force`, history, revoke, sync) | 004 | 003 cites for the REST shape |
| Tenant host resolution, root key, quota 429, unpaid 402 | 006 | 003 cites the status codes |
| WUI read API (endpoints the viewer calls) | 003 `contracts/` | 005 cites and depends |
| Terraform steps, DNS, secrets, WIF, lde | 007 | 003/006 name cnf keys, never tf |
| WIF deploy identity (tf step `017`) | 007 | 008 consumes the repo variables it exports |
| Pipeline jobs, gates, deploy matrix | 008 | 007 references the deploy action |

---

## 6. Canonical provisioning order (007 encodes it; others cite it)

Per environment, **dev fully, then prd**. DNS comes **before** anything that
needs a name, and ingress comes **last**:

| # | Step | Terraform / action |
|---|---|---|
| 1 | remote state | `000-gcp-remote-bucket` |
| 2 | enable services | `001-enable-gcp-services` |
| 3 | **DNS managed zone** for the product domain (import, never recreate) + owner-gated nameserver handoff | `025-gcp-dns-zone` (new, prd only; dev records live in the prd zone) — 007 |
| 4 | Cloud SQL Postgres | `040-cloud-sql-postgres` |
| 5 | GCS files bucket | `050-gcs-files` |
| 6 | Artifact Registry | `028-gcp-artifact-registry` |
| 7 | build + push the hub image | `do_build_push_hub_image` |
| 8 | DB user + DSN secret version + `spool migrate` | `do_spl_db_bootstrap` |
| 9 | Cloud Run hub | `030-cloud-run-hub` |
| 10 | ingress: LB + wildcard managed cert + apex / `*.` records | `031-gcp-hub-ingress` |

`020-gcp-relay-bucket` (the git-rel relay, spec 001) is **not in this chain**: it
depends only on step 2 and nothing in the hub chain depends on it, so it is an
independent branch after step 2.

007 numbered the new DNS-zone dir `025-gcp-dns-zone` (csi-rel/pas-psf call it
`007-dns`); the full gate-per-step table is
`007-spool-hub-api-infra/contracts/provisioning-order.md`.

### 6.1 Measured DNS state (2026-09-18T19:05Z) — read before writing the DNS step

| Check | Result |
|---|---|
| `dig +norec NS spool-hub.ai @v0n1.nic.ai` (the `.ai` TLD) | `ns-166-a`, `ns-194-b`, `ns-143-c` `.gandi.net` |
| `gcloud dns managed-zones list --project=csi-spl-prd` | `spool-hub` · `spool-hub.ai.` · `ns-cloud-e1..e4.googledomains.com` (hand-made, only NS + SOA) |
| `gcloud dns managed-zones list --project=csi-spl-dev` | none |
| `dig +short A spool-hub.ai` | Gandi parking address |

So: the Cloud DNS zone **exists but is not delegated**. The registrar still
points at Gandi, and the handoff to `ns-cloud-e1..e4` **has not happened**.

This collides with an earlier owner decision on trunk (`git show 300a998`,
`cb25346`, `04f7dca`): *public DNS stays on Gandi LiveDNS, never re-delegate
the registrar to `ns-cloud-*`, the apex stays Gandi parking*; and
`do_gandi_set_nameservers` refuses `ns-cloud-*`. The redo brief asks for the
handoff. **Open owner question (raised 2026-09-18):**

- **A — hand off:** Gandi NS → `ns-cloud-e1..e4`; terraform imports the zone
  and owns every record, including a copy of the apex parking record.
- **B — stay on Gandi:** the zone is imported into terraform but not delegated;
  ACME CNAME and `*.` records are written with `do_gandi_*`.

Until answered, 007 writes the DNS-zone step as **import the existing zone
(never recreate)** with the handoff as an **owner-gated deliverable**, and
records both options. A prd `fqdn` of the apex also means 031 would write an
apex A record — that is gated on the same answer.

---

## 7. Consistency pass (integrator, after the area lanes push)

A `speckit-analyze`-style pass, recorded in section 8:

- every FR maps to at least one task; every task cites an FR;
- every contract endpoint / frame has an FR; no FR cites a removed endpoint
  (REST `/v1/messages`, `/v1/recv`);
- the DNS-zone step exists and sits before Cloud SQL and before ingress;
- trust, `delivery`, and milestone tags agree across 003/004/005/006/007/008;
- every Implemented status carries a checkable citation.

## 8. Consistency record

Pass run by the integrator on trunk `a27078c`, after every area lane landed
(001 `cacc7a8`, 003 `a4a5918`+`01eed0a`, 004 `6f1e759`, 005 `4942381`+`3e2f1f5`,
006 `523c953`, 007 `16fbda7`, 008 `a27078c`).

### 8.1 Checks

| Check | Result |
|---|---|
| Every FR defined in a `spec.md` is cited in that dir's `tasks.md` | yes, except the invariants in 8.3 (008's `FR-P01..P10` each cited ≥ 1) |
| Every task cites an FR its spec defines | yes — 0 dangling |
| Implemented / Partial / Planned on every FR and task | yes in 001, 003–009; 002 frozen |
| REST `/v1/messages`, `/v1/recv` presented as live | none — every remaining mention is "dropped by OQ-02" or "005 client calls the wrong route" (005 G5, 003 view-v1 §7) |
| NATS / SSE presented as M1 | none outside frozen 002 |
| `delivery` enum lacks `pending` | none |
| DNS-zone step exists and precedes Cloud SQL and ingress | yes — 007 step 3 `025-gcp-dns-zone`, import-only, NS handoff owner-gated |
| Status codes (402 / 409 / 429 / 78) agree 003 ↔ 004 ↔ 006 | yes — 003 `error-envelope.md` is the table, 004/006 cite it |
| Dead relative links in `specs/` | none |

### 8.2 Seams fixed by the integrator

- `331badd` — external liveness gates (005, 006, 007 step 10, SC-004) probe
  `/v1/health` (003 FR-023, landed `6c863ee`); `/healthz` is shadowed on
  Cloud Run. 003 no longer asks 007 for an LB health-check path: a serverless
  NEG backend takes none.
- `614f6c6` — 009 gets `tasks.md` (all Planned); binding docs in `../doc/md`
  follow the redo: WUI catch-up reads view-v1, bus notify is WS frames (NATS
  post-M1), the rental door is the box key on hello + envelope, the DNS-zone
  step is `025-gcp-dns-zone`.

### 8.3 FRs accepted without a task

Invariants already verified in their spec with a cited check; no work remains:
001 FR-004 (anonymous GET/list → 403), 004 FR-011 (sub-agents get top-level
ids), 005 FR-003 (no key or signed URL in the browser), 006 FR-017 (no
`tenant_id` on `v:1`). 007 FR-001 is the ordering rule itself; its open
steps are each a task.

### 8.4 Open after the redo (not seams — owners named)

| Item | Owner |
|---|---|
| NS handoff A vs B (§6.1); blocks 007 step 3a and the prd apex record | **owner** |
| ~~`10 ci: quality gate` red on trunk~~ — **resolved**: `4839514` fixed the sweep under `bash -e`; gate green on `33560da` (run 35385128819); 008 T107 / FR-P07 Implemented (`cb1f254`) | 008 |
| `017-github-wif-deploy` unmerged (`GRK-3343-007-tf-017-wif`); CI deploys skip both envs | 007 T050 |
| prd: 001 services not enabled; nothing past step 2 | 007 |
| dev: 025 and 031 have no state; hub not reachable from outside | 007 |
| `gs://csi-spl-{dev,prd}-tfstate/terraform/025-gcp-dns-zone/default.tfstate` exist with **0 resources** (init ran 18:56–18:57Z) while trunk has no `025-*` dir: `git ls-tree --name-only origin/master csi-spl-iac/src/terraform/ \| grep -c 025` -> 0 (trunk 39d56a5). Land the dir or drop the empty state | 007 |
| Branch `GRK-3342-007-tf-007-dns` (`f08754d`, unmerged) copies the Gandi actions into `csi-spl-iac`; trunk already carries them in `csi-spl-orc` (`04f7dca`). Not a terraform DNS step, so no collision with `025`; likely stale | 007 |
| view-v1 not built; WUI client calls dropped routes | 003 US7 → 005 G5 |
| Several lanes stamped `last-edit` in local time with a `Z` suffix | cosmetic; fix on next edit |

<!-- version: 1.2.1 · updated: 2026-09-18 · last-edit: 2026-09-18T19:23:45Z -->
