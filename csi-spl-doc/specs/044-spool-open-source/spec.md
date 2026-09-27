# Feature Specification: Open-Sourcing csi-spl (the 4-stage rollout)

**Feature ID**: `044-spool-open-source` · **Status**: In progress (see `tasks.md`)
**Created**: 2026-09-27 · **Lead**: CLE-35047 · **Reviewed**: CLE-35048, AGY-3502, AGY-3503 (topic `a67ea8b5`, 17:36-17:38Z) · **Epic**: SPL-61 (children SPL-62..67; this spec is SPL-67)
**Authority**: this file for the rule; `tasks.md` for the work and its order; `checklist.md` for the go-public gate.

Status vocabulary follows `../README.md` §2.3. Every claim about the tree cites the command that shows it
(`../README.md` §2.2). This spec is itself distribution-clean: it names no secret value, no personal name and
no other organisation. A finding in another org's name is cited by class and command, never by the literal.

## 1. The owner's request, verbatim

prd t1 `#spool-hub-devel`, topic `a67ea8b5-72a8-44ab-9edf-be69b76cddeb`, 2026-09-27 17:19-17:32Z:

> we need to have a proper discussion what prevents us from making this project open source - I need a proper
> discussion from at least 4 agents - 2 agy and 2 cle

> add a proper git-spec for this ...

> to start with the 4 stages rollout

> this should be the work for tonight ... Aka if I wake up at 06:00 on the 28.09.2026 and the repo is open source. I will
> b a happy person

> but we will not accept pull requests lightly , nor will we gie access to the agents to other uesrs ... or shold
> we first implment he feature of the only people and agents having public keys of oter agents can prompt them ?!

> yes strangers can build their own hub with their OWN dns - eveyrhing is parametrized

The discussion ran in that topic: four angles, round 1 (evidence) and round 2 (challenges), 17:22-17:32Z.

| agent | angle | round-1 headline |
|---|---|---|
| CLE-35047 | secrets + git history | no live credential in 1662 commits; the history carries identifying data |
| CLE-35048 | architecture, security, ops | the Go/Nuxt code is almost estate-neutral; cnf, iac/orc, the docs and the self-hosted CI tie us |
| AGY-3502 | legal, licences, hygiene | 0 copyleft conflicts (60 Go modules, 737 npm packages); client licence, trademark, CLA |
| AGY-3503 | product, community, business | a naive flip fails strangers and the business; two repos; the 4-stage rollout (§4) |

## 2. Scope

- **In**: what must be true before the product code of csi-spl is public, the order of the work (§4), the
  decisions only the owner can take (§6), and the gate (`checklist.md`).
- **Out** (non-goals): rewriting the history of this repo (§5, option B is rejected); publishing the estate (cnf
  values, rendered tfvars, the agent-fleet tooling, the specs); changing the hosted `spool-hub.ai` product;
  moving the internal issue tracker to GitHub.
- **Unchanged until Stage 2**: this private repo is the source of truth and keeps its full history. From Stage 2
  on the public repo is the source of truth for the product code, and the private ops repo pins it by ref (§5).

## 3. Measured baseline (tree `4b960899`, n = 1 per scan)

### 3.1 Secrets: none found

| class | command | result |
|---|---|---|
| gitleaks 8.30.1 with `.gitleaks.toml`, all refs | `gitleaks git --log-opts=--all --config .gitleaks.toml` | 0 leaks, 1662 commits |
| gitleaks default rules only (allow-list removed) | same, config `[extend] useDefault=true` only | 29 `generic-api-key`, all the triaged false positives named in `.gitleaks.toml` |
| SA key JSON, PGP blocks, cloud/Slack/GitHub tokens, Stripe secret keys, billing ids | class greps over every added line of `git log --all -p` | 0 each |
| key / tfstate / dump files ever added or deleted | `git log --all --diff-filter=A` and `--diff-filter=D --name-only` | 0 |
| PEM and bearer-token look-alikes | as above | test stubs only (the "private key refused" tests, `ya29.stub_*`) |

Nothing needs rotating for publication.

### 3.2 Identifying data: present (not secret, but public forever once pushed)

| class | evidence | where |
|---|---|---|
| the owner's name and personal e-mail | `git log --all -p` greps: 15 + 6 added lines | cnf `all.env.yaml`, `dev.env.json`, `prd.env.json`; the hygiene sweep in `10_ci-quality.yml` |
| numeric GCP org id | `git grep -nE 'gcp_org_id' HEAD -- csi-spl-cnf` | 3 cnf files |
| service-account e-mails | `git grep -lE 'iam\.gserviceaccount\.com' HEAD` | 23 files (CLE-35048: 41 with a looser pattern) |
| another organisation's bucket and SA names (hygiene rule 1) | `git grep -lE "$OTHER_ORG_PREFIX" HEAD`, prefix named in the round-1 post | 12 files: cnf, terraform providers of steps 000/001/020, spec 001, the feature doc |
| agent-fleet ids in PRODUCT code | `git grep -lE '(CLE\|HUM\|AGY\|GRK)-[0-9]+' HEAD -- csi-spl-api csi-spl-wui csi-spl-rdb` 472 files; 200 without tests (478 lines), CLE-35048 counted 159 with another test filter | comments and test names; the export gate (FR-OS-002) fails on them until T027 |
| agent-fleet ids and box paths, whole tree | `git grep -lE 'CLE-[0-9]{2,}' HEAD` 627 files; `HUM-[0-9]+` 216; `/opt/csi/` 19; `inbox-send` 9 | docs mostly, orc tooling |
| owner quotes, prd tenant ids | 243 of 2058 tracked files are `csi-spl-doc` (CLE-35048) | specs |
| business config, public by design | Stripe publishable key, OAuth client ids, support mailbox | cnf and the 60 rendered tfvars |
| commit metadata | `git log --all --no-mailmap --format='%ae %ce' \| sort -u` | ONE identity on all 1662 commits |

### 3.3 Findings that block a stranger or a safe launch

| finding | evidence | by |
|---|---|---|
| README step 1 clones a private repo | `README.md` line 7 (`tpl-gen`) | AGY-3503 |
| the local stack needs internal actions | `csi-spl-orc/src/docker/docker-compose-infra.yaml:17` requires `do_gen_docker_env` | AGY-3503 |
| the Go build is clean and public-only | `go build ./cmd/spool` exit 0 | AGY-3503 |
| 0 incompatible licences | `go list -deps -json ./...` 60 modules; 737 npm packages | AGY-3502 |
| `csi-spl-wui/package.json` has no `license` field and is `"private": true` | `grep -ci license csi-spl-wui/package.json` -> 0 | AGY-3502 |
| icon paths ported from an ISC-licensed set without its notice | `csi-spl-wui/src/utils/uiIcons.ts:1` | AGY-3502 |
| no `pull_request` trigger today; 11 jobs on the self-hosted runner | `grep -A8 '^on:' .github/workflows/*` | CLE-35048 |
| the deploy identity is pinned to repository AND ref | `017-github-wif-deploy/03-github-wif.tf:88` | CLE-35048 |
| no `SECURITY.md`, no issue templates | `ls SECURITY.md .github/ISSUE_TEMPLATE` | CLE-35048, AGY-3503 |
| the hygiene sweep cannot see other-org names or SA ids | `grep -cE 'gserviceaccount\|org_id' .github/workflows/10_ci-quality.yml` -> 0 | CLE-35047 |
| CLI, MCP and hub are one Go module and one binary; `cmd/spool` imports the hub, store and billing packages | `find csi-spl-api -name go.mod` -> 1; `ls cmd` -> `spool` | CLE-35047, CLE-35048 |

## 4. The 4-stage rollout (the owner: "start with the 4 stages rollout")

AGY-3503's plan with the other angles folded in. A stage starts only when the previous stage's gate in
`checklist.md` is green.

| stage | name | what it produces | gate |
|---|---|---|---|
| **0** | Split and sanitise | owner decisions D1-D8 (§6); the gated export (FR-OS-001..004) green against a PRIVATE target repo; licence files, SECURITY / CONTRIBUTING / CODE_OF_CONDUCT / TRADEMARK; CI safe for PRs; the untrusted-input rule (FR-OS-015) | `checklist.md` §1 |
| **1** | Private beta: the stranger test | the exported repo, still private, run by 3-5 invited outsiders on a clean machine: build, one-command local stack, a message between two agents over MCP, with no help | `checklist.md` §2 |
| **2** | Public launch | the owner flips the NEW repo to public; the CLA/DCO bot is on; the public repo becomes the source of truth and ops pins it by ref; `spool-hub.ai` is the zero-ops option in the README | `checklist.md` §3 (the owner's go) |
| **3** | Community flywheel | public issues and PRs are shown to a human maintainer in `#spool-hub-devel` as DATA (FR-OS-015); an agent works on one only when a maintainer opens a task for it. Outside text never prompts an agent directly | ongoing |

### 4.1 The tonight track (owner's target: the repo open source by 2026-09-28 06:00 local, 03:00Z)

The stages above take days if Stage 1 waits for outside testers. To meet the owner's target they compress:

| stage | tonight | what is deferred to after the flip |
|---|---|---|
| 0 | T001-T004, T020-T025, T027 on the private target repo; decisions default as below | T026 review, T030 licence split |
| 1 | the stranger test run by a fleet agent in a fresh container with no access to this box's credentials, following only the exported README | 3-5 outside testers |
| 2 | the flip, only when `checklist.md` §1 is green and only with the owner's go (D11) | CLA bot (D3), prompt allow-list (D10) |

Defaults that make tonight possible, each reversible later: D2 **AGPL-3.0 for everything** (a later relicence of the
client to Apache-2.0 stays possible: one identity holds every commit); D3 **no outside PRs merged until a CLA/DCO
exists**, stated in CONTRIBUTING; D4 all hub code public; D5 the real identity; D6 curated docs only; D7
TRADEMARK.md; D10 the prompt allow-list after the flip, which is safe under D0 because no outside text reaches an
agent (no bridge exists, FR-OS-015).

## 5. Repo strategy: a fresh public repo from a gated export (option C)

| option | cost | verdict |
|---|---|---|
| A. flip this repo public as it is | no work; §3.2 public forever | rejected: breaks hygiene rules 1, 4, 5 |
| B. rewrite the history (`git filter-repo`), then flip | all 1662 shas change; **723** distinct shas cited in docs go dead; 53 worktrees break | rejected |
| **C. a NEW public repo whose first commit is a gated export of the product dirs; this repo stays private** | one export action; two repos | **recommended by all four angles**; the owner confirms (D1) |

- Public: `csi-spl-api`, `csi-spl-wui`, `csi-spl-rdb`, terraform as parameterised modules with an
  `example.env.yaml`, curated docs, CI on GitHub-hosted runners.
- Private (ops): cnf values and rendered tfvars, the orc fleet/desk/box tooling, prd ops actions, deploy
  workflows, the specs.
- **The export is one-time, not a sync loop** (CLE-35048, round 2). Until Stage 2 it may be re-run to refresh the
  private target. After Stage 2 product changes land in the public repo and ops consumes it by ref, so there is
  never a second history to reconcile.

## 6. Owner decisions

### 6.1 Taken

| # | decision | source |
|---|---|---|
| **D0** | **Self-hosted only, fully parameterised.** Outsiders run their own hub on their own domain and their own cloud project; our hub, tenants and agents are never offered to them. Every host, domain, project and identity value is a parameter (env/cnf); the product code carries no csitea or `spool-hub.ai` default; the local stack (T001) and the self-hosting guide (SPL-66) take the domain as input. This is the isolation baseline for FR-OS-015/017 | owner, topic `a67ea8b5`, 2026-09-27 ~17:34Z: "yes strangers can build their own hub with their OWN dns - eveyrhing is parametrized" |
| **D11** | **Yes: flip the NEW repo public tonight** once `checklist.md` §1 is green, on the tonight track (§4.1). The §4.1 defaults hold unless the owner overrides them: D2 AGPL-3.0 for everything, D3 no outside PR merged before a CLA/DCO, D4 all hub code public, D5 the real identity, D6 curated docs only, D7 TRADEMARK.md, D10 the allow-list after the flip. If any §1 item is red, the repo stays private and the owner gets the failing list | owner, topic `a67ea8b5`, 17:40:55Z: "yes", 53 s after the D11 blocker (17:40:02Z) with no post between |

### 6.2 Open

| # | decision | recommendation |
|---|---|---|
| **D1** | Repo strategy (§5) and the public repo's name | option C; name it after the product (`spool`), not the internal tag |
| **D2** | Licence: AGPL-3.0 for all, or hub + WUI AGPL-3.0 with the client (CLI, MCP, client library) Apache-2.0 | the split, but it is an architecture change: `cmd/spool` is ONE binary that imports hub, store and billing, so the client needs its own binary or module (~2-3 days, CLE-35048). Relicensing is free today because one identity holds every commit (§3.2) |
| **D3** | Contributor terms: CLA or DCO | CLA if dual licensing is ever wanted. Needed before Stage 2, not Stage 0 |
| **D4** | Open-core boundary: does the public hub include the billing rail and multi-tenant admin | public: the whole hub code incl. multi-tenancy; private: the estate and the billing configuration |
| **D5** | Author identity of the public repo's commits | the real identity (repo rule, CLAUDE.md "Commits"); an org identity only if the owner creates that address |
| **D6** | Docs: curated architecture/contract docs only, or the specs too | curated only; the specs stay private (owner quotes, fleet notes) |
| **D7** | Trademark: reserve "Spool" / "Spool Hub" and the logo in `TRADEMARK.md` | yes |
| **D8** | Source of truth after Stage 2: the public repo, with ops pinning it by ref | yes (§5) |
| **D9** | Contribution policy (owner: "we will not accept pull requests lightly"): maintainers-only merges, every outside PR reviewed by a maintainer, fork code never on our runners, CLA/DCO (D3), no automatic action on outside issues | adopt as written; it replaces the "agents triage outside issues" idea of the first draft of Stage 3 |
| **D10** | The per-agent prompt allow-list (FR-OS-017, owner: "only people and agents having public keys of other agents can prompt them"): a precondition of which stage | **Not a launch gate tonight; the first Stage 3 item.** CLE-35048 revised its Stage-2 answer after D11 (topic `a67ea8b5`, ~17:41Z): ~4-6 agent-days cannot land by 06:00, and under D0 no outside text reaches an agent. Ship with the limitation stated in SECURITY.md, no self-hosted PR workflow, the export gate green |

## 7. Functional requirements

| FR | requirement | severity | status | issue |
|---|---|---|---|---|
| FR-OS-001 | An export action builds the public tree from an **allow-list** of paths, never a deny-list | must | Planned | SPL-1011 |
| FR-OS-002 | The export fails closed unless gitleaks, the hygiene sweep and the NEW classes are clean on the exported tree: other-org names, `iam.gserviceaccount.com`, `gcp_org_id`, fleet-id citations `\b(CLE\|HUM\|AGY\|GRK)-[0-9]{3,}\b` (provenance in comments), `/opt/` except the hub image's own `/opt/spool/`, the owner's name and e-mail. **Allowed**: 1-2 digit ids (`HUM-1`, `CLE-07`) - they are the product's own member/agent id format in test fixtures, not a leak (CLE-35052, tree `9acb0635`: 1909 lines short vs 747 citations) | must | Planned | SPL-63 (narrowed: secrets were measured absent) |
| FR-OS-003 | The exported tree carries no cnf values: domain, project ids, SA e-mails, org id, OAuth client ids and Stripe keys come from the operator's env file; `example.env.yaml` documents each | must (owner: "strangers can build their own hub with their OWN dns - everything is parametrized") | Planned | SPL-66, SPL-1012 |
| FR-OS-004 | The public repo's first commit is one snapshot; the private history is never pushed to it | must | Planned | SPL-61 |
| FR-OS-005 | No workflow of the public repo runs on a self-hosted runner; PR jobs run on `ubuntu-latest` with `permissions: contents: read`, no secrets, fork approval required | must | Planned | SPL-64 |
| FR-OS-006 | LICENSE per D2; SPDX identifiers in every manifest (`go.mod` package doc, `package.json` `license`); third-party notices incl. the icon set | must | Partial (AGPL-3.0 LICENSE `8423a14`) | SPL-62 |
| FR-OS-007 | A README a stranger can follow; CONTRIBUTING; SECURITY.md with a private reporting channel; CODE_OF_CONDUCT; issue and PR templates | must | Planned | SPL-65 |
| FR-OS-008 | A one-command local stack at the public root (Postgres + hub + WUI) with no internal action | must | Planned | SPL-66 |
| FR-OS-009 | TRADEMARK.md per D7; an asset licence for the wallpapers and the logo | should | Planned | SPL-1016 |
| FR-OS-010 | A security review of the `asOperator` allow-list; close the 017 parent SPL-35 | should | Planned | SPL-1019 |
| FR-OS-011 | After Stage 2 ops pins the public repo by ref; the export is retired (D8) | should | Planned | SPL-1011 |
| FR-OS-012 | GitHub issues and PRs of the public repo reach the fleet in `#spool-hub-devel` | nice | Planned | Stage 3, not filed (owner: no agent access for outsiders) |
| FR-OS-013 | The relay contract (the bucket semantics the hub relies on) is published as a doc | should | Planned | SPL-1021 |
| FR-OS-014 | DB tier and search cost reviewed before public launch (f1-micro, 25 connections; search cannot use its index under RLS) | should | Planned | SPL-1020 |
| FR-OS-015 | Untrusted-input rule: public text (issues, PR bodies, comments) never reaches a credentialed agent as an instruction; it is framed as data, like the desk's non-owner framing, and no agent acts on it without an owner-originated task | must | Planned | SPL-1017 |
| FR-OS-017 | Per-agent prompt allow-list, enforced by the HUB: a DM, an @mention or a task reaches an agent only from a principal on its list. Principals are a member id (proven by the session; humans hold no key) or a box id (proven by the pin signature the box already carries, spec 004); everything else is refused. ~4-6 agent-days (CLE-35048, `bc3d20b7`). Until it lands, SECURITY.md states the limitation | must, first Stage 3 item (D10) | Planned | SPL-1018 |
| FR-OS-016 | The client licence split per D2: a client binary/module that does not import hub, store or billing code, enforced by an import test | must if D2 = split | Planned | SPL-1022 |
