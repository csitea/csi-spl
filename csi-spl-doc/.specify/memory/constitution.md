<!--
Sync Impact Report
- Version: 0.1.0 (initial ratification for csi-spl)
- Adapted from csi-rel Constitution v0.5.1; retargeted to the spool.
- Principles: I Paths, II Env-fail-fast, III run-bsh actions, IV Spec-driven,
  V Distribution hygiene, VI Cnf-only config, VII No secrets/keys in git or
  state (spool-specific, NON-NEGOTIABLE), VIII Box API uniformity (spool-specific).
- Templates: plan-template.md Constitution Check references §I/II/VI/V (unchanged).
- Follow-up: the first plans (002, 003) MUST pass the key-hygiene gate (VII)
  and the uniform-API gate (VIII).
-->

# csi-spl Constitution

`csi-spl` — **the spool** — is the csitea-family project that carries signed
agent messages and content-addressed files between AI agents on a box and,
eventually, between boxes through a cloud hub. Public domain: `spool-hub.ai`
(resolved at deploy time, never baked into code). It is built on the `run-bsh`
methodology. This constitution governs every spec, plan, task, and
implementation produced via spec-kit inside this repo.

| Token | Value |
|-------|-------|
| `BASE_PATH` | `/opt` |
| `ORG`       | `csi` |
| `APP`       | `csi-spl` |
| `PROJ_KIND` | `doc` \| `iac` \| `cnf` \| `utl` \| `orc` \| `dat` \| `api` \| `wui` |
| `PROJ`      | `${APP}-${PROJ_KIND}` |
| Public URL  | `spool-hub.ai` (resolved at deploy time, never baked into code) |

## Core Principles

### I. Canonical Path Layout (NON-NEGOTIABLE)
Every sub-project lives at `${BASE_PATH}/${ORG}/${APP}/${APP}-${PROJ_KIND}`
and derives `ORG`, `APP`, `PROJ`, `PROJ_KIND` from its filesystem location. No
hard-coded paths in source. The kinds are:
- `csi-spl-api` — Go codebase: spool CLI, stdio MCP server, and Cloud Run HTTP hub under `src/go/spool-hub-api`.
- `csi-spl-wui` — human web UI: lightweight task and thread viewer web app.
- `csi-spl-iac` — infrastructure-as-code: Terraform steps (state bucket, GCP
  service enablement, the relay bucket + SA), `./run` actions, tpl-gen templates.
- `csi-spl-cnf` — per-env YAML (`all.env.yaml`, `<env>.env.yaml`), the single
  source of truth; tpl-gen renders `<env>/tf/*.tfvars` from it.
- `csi-spl-utl` — run-bsh derivative: shared bash framework, actions, libs.
- `csi-spl-orc` — orchestration / build / packaging for the spool binary.
- `csi-spl-dat` — data / fixtures (README until it has content).
- `csi-spl-doc` (this project) holds ALL human/AI documentation for every
  sub-project — specs, plans, ADRs, IaC docs, runbooks. `.specify/` and
  `specs/<NNN-slug>/` live here. It is not a runtime component.

### II. Full Configurability via Environment (NON-NEGOTIABLE)
`ORG`, `APP`, `PROJ_KIND`, and every external URL/host/bucket MUST be
overridable via environment variables. Shell actions MUST fail fast when a
required env var is missing:

```bash
: "${GCP_ACCOUNT:?GCP_ACCOUNT must be set (no default)}"
```

No default URLs, buckets, or hostnames in code. The project's parent, billing
account and operator identity (`GCP_ORG_ID`/`GCP_FOLDER_ID`,
`GCP_BILLING_ACCOUNT_ID`, `GCP_ACCOUNT`) are env vars that fail fast, never
committed. The literal placeholder `<<run-time>>.csitea.net` is used in
docs/examples where a runtime host would otherwise appear.

### III. run-bsh Action Convention
All operator behaviour is exposed as `do_<name>` Bash functions under
`csi-spl-iac/src/bash/run/<group>/<name>.func.sh` (or the owning sub-project),
dispatched via `./run -a do_<name>`. Function metadata follows run-bsh `@`
tags (`@description`, `@param`, `@arg`, `@example`, `@prereq`, `@output`,
`@see`). Required `@param` entries are validated by the framework.

### IV. Spec-Driven Development
No runtime code is written without a corresponding artifact under
`csi-spl-doc/specs/<NNN-slug>/`:
1. `/speckit-specify` — what & why (no tech stack)
2. `/speckit-clarify` — resolve ambiguities (mandatory before plan)
3. `/speckit-plan`    — chosen stack, contracts, data model
4. `/speckit-tasks`   — ordered, parallelizable task list
5. `/speckit-analyze` — cross-artifact consistency (before implement)
6. `/speckit-implement` — execute

### V. Distribution Hygiene (NON-NEGOTIABLE)
This project ships as a generic, org-neutral package; the csitea doc-hub bans
apply to source AND docs:

- The ONLY org tag permitted is `csi` / `csitea` / `csitea.net`. No other
  company, customer, vendor, bank, or partner names anywhere.
- Banned hosts: any non-csitea environment hostname. Use
  `<<run-time>>.csitea.net` as the placeholder.
- No literal OS usernames, AD identities, machine names, box shorthand, or
  `/home/<name>` paths. Use `$USER`, `$HOME`, `<DEV_USER>`, `<DEV_BOX>`,
  `<HARNESS_USER>`. Per-user state (keys, credential files) resolves from
  `$HOME` or an env var.
- No real personal names. Use the literal `FirstName LastName`.
- No real Confluence space keys or Jira project codes. Use
  `<CONFLUENCE-SPACE>` and `<JIRA-PROJ-CODE>`.
- No image files in the zip distribution. Excluded from the zip: `CLAUDE.md`,
  `GEMINI.md`, `.git/`, `node_modules/`.

**Authorised carve-out:** git authorship metadata (`user.name`/`user.email`,
`Author:`/`Committer:`) carries the author's real name and address. `.git/` is
excluded from the zip, so commit metadata never ships; a placeholder identity
there falsifies provenance and buys no distribution safety.

### VI. Cnf Is the Only Runtime Config (NON-NEGOTIABLE)
Runtime values MUST NOT be hardcoded in source (Go, Bash, Terraform literals
that should vary per env). Author them in `csi-spl-cnf/csi-spl/<env>.env.yaml`.
The domain lives in ONE place: `all.env.yaml → env.dns.BASE_DOMAIN`. Editing a
`*.env.yaml` means re-rendering its generated twin (`<env>.env.json`,
`<env>/tf/*.tfvars`) in the same commit. Switching an env MUST be a YAML edit +
redeploy, never a code change. Tests and comments MAY use example hosts; the
runtime path MUST NOT invent a hostname or bucket by parsing another value.

### VII. No Secret, Key, or Signed URL in Git, Terraform State, or a Log (NON-NEGOTIABLE)
The spool's whole reason to exist is moving material safely, so its own secrets
are held to the strictest standard:
- The relay SA key is minted **out of band** and never a Terraform resource — a
  `google_service_account_key` would store the private key in the state bucket
  in clear. Key files are `chmod 600`, under `$HOME/.gcp/.csi/`, never printed,
  copied into chat, or committed.
- Agent Ed25519 private keys never enter the spool, Postgres, GCS, or a log.
- Signed GET/PUT URLs are short-lived and MUST NOT be logged or persisted.
- Every `gcloud` call carries `--account` or runs under a throwaway
  `CLOUDSDK_CONFIG`; the shared `~/.config/gcloud` is never mutated.

### VIII. One Uniform Box API for Every Agent Kind (NON-NEGOTIABLE)
Every AI agent on a box — `CLE-*` (Claude), `GRK-*` (Grok), `AGY-*`
(Antigravity) — talks to the spool through **the same** verbs, tool names,
JSON, and message schema. Kind is expressed only as an id prefix on `from`/`to`,
never as a field, URL, or per-kind dialect. A new vendor is a new id prefix and
the same API, not a new endpoint. MCP is a thin wrapper over the CLI: same
behaviour, same exit codes (verify/refuse = exit `78`).

## Additional Constraints

### Tech Stack
- **Shell framework:** `run-bsh` (Bash 5+, POSIX-clean where possible).
- **Spool binary (`-api`):** **Go** (1.22+) — one binary behind both the
  CLI verbs (`spool-send`, `spool-recv`, `spool-put-file`, `spool-get-file`,
  `spool-tail`, `spool-keygen`, `spool-pin`) and the stdio MCP server; the same
  binary later serves the stateless Cloud Run HTTP hub (`src/go/spool-hub-api`). Ed25519 from the Go
  standard library; signing done locally.
- **Go reference architecture & test harness:** Server harness, start/stop lifecycle,
  structured logging (`zerolog`), config (`caarlos0/env`), test harness (`testkit`),
  and shell function utilities MUST reference and follow the patterns in `/opt/pas/pas-psf/pas-psf-api`.
- **IaC (`-iac`):** **Terraform** (1.9+). State in a GCS bucket
  (europe-north1) with versioning; per-step run dirs.
- **Hub (end vision):** stateless **Cloud Run**; **PostgreSQL** for
  messages/pins/acks; **GCS** for file bytes (`file_id` = sha256); **NATS
  JetStream** for live tail + replay. Region `europe-north1`.
- **Local fallback:** a plain folder `$SPOOL_ROOT` (default
  `/var/spool-hub`) so agents can queue when the hub is down — and, for
  the near-term MVP (spec 002), the ONLY backing store.
- **Docs (`-doc`):** Markdown under `doc/md/` and specs under `specs/`.
- **Local Dev Setup (`lde`):** Local development environment for Terraform (`-iac`), backend Go API (`-api`), and frontend (`-wui`) MUST reference and follow the patterns in `/opt/pas/pas-psf` (`pas-psf-orc`, `pas-psf-iac`, `pas-psf-api`, `pas-psf-wui`), including containerized tf-runner, local test database setup, and frontend dev server tooling.

Alternatives explicitly rejected: Kafka, Slack-as-a-bus, Mattermost, per-agent
cloud keys, an MCP server per tmux window, a second message schema, and any
per-kind HTTP endpoint (see Principle VIII).

### Reference implementation is read-only
The existing on-box agent-messaging protocol on **ysg-box**
(`$MSGS_ROOT/<id>/{inbox,outbox,archive}/`, the `SendMessage`/tmux/`inbox-send.sh`
notification legs, `ListAgents` for liveness, the `agent-msg` skill) is the
behavioural REFERENCE for spec 002. The spool re-implements that behaviour
cleanly in Go inside csi-spl; it MUST NOT modify, depend on, or import the
ysg-box code. ysg-box is read for its contract, never touched.

### Security & Compliance
- No secrets in git (Principle VII). Credentials come from env vars, `~/.ssh/`,
  or named credential files outside the repo.
- Signatures precede trust: an unpinned author is untrusted. IAM/OIDC is the
  door (who may reach the hub); the Ed25519 pin is the author (who wrote the
  message). Do not swap them.

## Development Workflow

### Repository
- Single git repo: `csitea/csi-spl` (trunk `master`). `.git` at the APP root
  (`/opt/csi/csi-spl`), not inside sub-projects.
- **Branch model: Trunk-Based Development.** All changes commit directly to
  `master`; no long-lived or `feature/*` branches, no PRs. `NNN-<slug>` names a
  directory under `specs/`, NOT a git branch. Spec Kit's optional
  `speckit.git.feature` hook is **disabled** in `.specify/extensions.yml`.
- Commits: authored by the repo's configured git identity (shown as
  `FirstName LastName <dev@csitea.net>` in shippable examples — the real name
  and address live only in git metadata and the zip-excluded `CLAUDE.md`, the
  authorised carve-out in Principle V), no AI trailers, explicit pathspecs
  (never `git add -A`/`.`/`-u`).

### Release Gate
Before landing a completed spec on `master`:
1. `/speckit-analyze` reports no unresolved findings.
2. All tasks marked `[X]` in `tasks.md`.
3. Distribution-hygiene grep sweep returns zero hits outside `CLAUDE.md`/`GEMINI.md`.
4. Tests green (`bash csi-spl-iac/src/bash/tests/run-all-tests.sh`, plus the
   spool binary's own `go test ./...` once it exists).
5. Nothing mutates GCP without the owner's explicit go (project create, billing
   link, IAM change, `terraform apply`, key mint).

### Documentation
- Every `do_*` action carries complete `@param`, `@example`, `@prereq` metadata.
- Every feature has `spec.md`, `plan.md`, `tasks.md` in its `specs/<NNN-slug>/`.
- Each changed doc under `csi-spl-doc/` carries the end-of-file marker
  `<!-- version: X · updated: DATE · last-edit: ISO-8601-UTC -->` (extends the
  global CLAUDE.md §11 merge marker).

## Governance
This constitution supersedes ad-hoc preferences. Amendments require a commit on
`master` updating this file with rationale, a bumped version and `Last Amended`
date, and a re-run of `/speckit-analyze` on every in-flight spec. Complexity
that deviates from a principle must be justified inline (`# WHY:`) and
acknowledged in the spec's Clarifications section.

**Version**: 0.2.0 | **Ratified**: 2026-09-18 | **Last Amended**: 2026-09-18 (added csi-spl-api)

<!-- version: 0.2.1 · updated: 2026-09-18 · last-edit: 2026-09-18T16:15:00Z -->
