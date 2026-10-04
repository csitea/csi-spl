# 072 research 15: the client path - run your own instance from OUR release

Author: c-165 (s072 lane 15). Tree: `origin/master` @ `e3b1627e`, 2026-10-04.
Docs only. Scope: a client (or any third party) that runs its own spool
**from a release we publish, not from source**: what we would ship, how they
install, configure and upgrade it, and what is missing today. This is P1 and
P3 of spec section 3 seen from the release side; the GCP shape (P2) is
research 02 and 05. Ranked by the spec's section 2 rule: time to first
deploy, manual steps, clarity of errors. Costs are numbers where they exist.

`<owner>`, `<fqdn>`, `<release>` and `<date>` are placeholders.

## 1. Today

### 1.1 What a release IS today

| # | fact | check (n = 1 per command unless stated) |
|---|---|---|
| R1 | The repo is public, AGPL-3.0; `LICENSE`, `SECURITY.md`, `.env.example` exist; no `CHANGELOG` | `gh repo view --json visibility,licenseInfo` -> `PUBLIC agpl-3.0`; `ls CHANGELOG*` -> none |
| R2 | **One** release exists: `stable-2026-09-29 (v2.2.0)`, marked Latest | `gh release list` -> 1 row |
| R3 | It has **0 assets**: no image, no binary, no compose file, no checksum; only GitHub's automatic source archives | `gh release view stable-2026-09-29 --json assets` -> 0 |
| R4 | Its notes are 441+ lines: 1083 commits by kind, 52 migrations, a 3-step upgrade | `gh release view stable-2026-09-29 --json body -q .body \| grep -nE '^## '` -> Features 301, Fixes 307, Performance 64, Other 411, Database migrations 52, Upgrade at line 441 |
| R5 | The weekly cron has **never fired**: the one run was a manual dispatch; the first Monday after it is 2026-10-05 | `gh run list --workflow 55_release-stable.yml` -> 1 run, `workflow_dispatch`, 2026-09-29 |
| R6 | The stable is cut on the commit **prd (Cloud Run) runs**, not on a commit proven on compose | `55_release-stable.yml` header; `STABLE_FROM_ENV: prd` |
| R7 | Trunk has moved **1270 commits** past the stable in 5 days | `git rev-list --count stable-2026-09-29..origin/master` -> 1270 |
| R8 | Two version namespaces reach the client: 728 `v*` build tags (highest `v8.4.0`) and the `stable-<date>` tag | `git ls-remote --tags origin 'v*' \| grep -v '\^{}' \| wc -l` -> 728 |
| R9 | Nothing we publish is signed or checksummed: the 9 `sha256sum` lines in CI verify tools we **download** | `grep -rnE 'cosign\|sbom\|sha256sum\|provenance' .github/workflows/*.yml` -> 9, all scanner installs (wf 15, 62, 64, 66, 67, 70, 85) |
| R10 | Support policy: "Only the latest commit on `master` receives security fixes ... A fix on `master` reaches the next weekly stable" | `SECURITY.md:28-33` |

### 1.2 The walk: install from the release, as a client would

| step | what the client does today | check |
|---|---|---|
| 1 | Install Docker + compose plugin | README line 12 |
| 2 | **Clone the repo** (37 MB, 047 U8) into a `<dir>/csi/csi-spl` layout | README:14-16 |
| 3 | `git checkout stable-<date>` (the upgrade text; Quick start runs `master`) | README "Backup, restore and upgrade" step 2 vs README:14 |
| 4 | Copy `.env.example` to `.env`, uncomment the own-domain block (7 groups; 53 `SPOOL_` mentions, all commented), generate 3 passwords | `grep -c SPOOL_ .env.example` -> 53; spec F4 |
| 5 | `docker compose up --build -d`: **builds** hub and WUI from source | `docker-compose.yml:49,79,137` `build:`; images `spool-hub:${SPOOL_IMAGE_TAG:-local}` (lines 56, 80, 146): no registry |
| 6 | Read `docker compose logs hub-init` for the owner link | README "Your own domain" rule 2 |
| 7 | Seat an agent: `install.sh` **from the clone**, which downloads Go from `go.dev` and builds `spool` | `install.sh:6` "Run it from a git clone"; `install.sh:272` `go.dev`; `grep -c releases/download install.sh` -> 0 |

Even with the source archive of R3 instead of a clone, step 5 still needs
the tree: the compose file bind-mounts a repo file into Postgres
(`docker-compose.yml:36` `./csi-spl-api/src/docker/pg-init.sh`) and builds
with `context: .` (lines 52, 138). So **a compose file alone cannot run**.

Configure: the WUI bakes `SPOOL_PUBLIC_URL` and `SPOOL_TENANT` at build time
(`csi-spl-wui/src/docker/wui.Dockerfile:30-31`), so one prebuilt WUI image
would serve `http://localhost:8080` to every client. A1 without A3 is
unusable off localhost.

Upgrade: the release notes' own steps are dump, `git checkout`, `docker
compose up --build -d` (R4, line 441+): a rebuild from source every week.
Migrations are forward-only; there is no rollback line.

### 1.3 Measured times and checks

| measure | value | check |
|---|---|---|
| compose `up --build` + browser proof on a GitHub runner, trunk | **median 168 s**, min 146, max 184 (n=10, successful master runs) | `gh run list --workflow 50_oss-standalone.yml --branch master --status success --limit 10 --json createdAt,updatedAt` |
| of which building images (047, its tree `4dc8df91`, n=1) | 241 s of 268 s to healthy, on a VM | 047 section 1.1 |
| wf 50 trigger | `push` to `master` with a path filter; **not** on a `stable-*` tag | `50_oss-standalone.yml:12-15` |
| client/hub version check | none: 0 non-test Go files name a minimum client version | `grep -rniE 'min(imum)?_?(cli\|client)_?version' csi-spl-api/src/go --include=*.go \| grep -v _test \| wc -l` -> 0 |

## 2. Blockers

1. **No artifact but source.** The release has 0 assets (R3); no workflow
   pushes an image to a public registry (`grep -li ghcr .github/workflows/*`
   -> 0, spec F1). A client is a builder: ~4 min of build on their box,
   every upgrade.
2. **The compose file needs the tree.** `docker-compose.yml:36` bind-mounts
   `pg-init.sh`; lines 52 and 138 build from `context: .`. A release cannot
   ship "one compose file + one `.env`" until both go.
3. **The WUI is configured at build time** (`wui.Dockerfile:30-31`): a
   shared prebuilt image cannot serve a client's domain (spec F2, A3).
4. **The agent box needs a clone and Go** (`install.sh:6`, `:272`; spec F7).
5. **The stable is proven on Cloud Run, not on the path the client runs**
   (R6; wf 50 does not run on tags). A stable that breaks `compose up` would
   ship.
6. **Nothing is signed or checksummed** (R9). A client cannot verify that an
   image or binary is ours; for a chat server that holds agent root keys it
   is the first question a client's security review asks.
7. **The notes are written for us, not the client** (R4): 1083 commit
   subjects, no "what changed in config" section. The one thing a
   self-hoster must act on (a new or renamed `.env` key) is not listed.
8. **Two version names, one meaningless outside** (R8): `v8.4.0` is a build
   odometer that moves ~130 times a day (research 05); `stable-<date>` is
   the release. Neither the CLI nor the hub checks the other's version (1.3).
9. **The cadence and the support policy are unproven** (R5, R10): one
   release, cut by hand; the policy tells self-hosters to rebuild from
   `master` for a security fix, i.e. back to the source path.

## 3. Actions

Each is one lane. Effort as in spec section 6 (XS < 0.5 d, S <= 1 d,
M 2-5 d). Ranked by section 2. Ids: an existing spec action, or a new `C<n>`
in the section 6 shape.

| # | action | changes | effort | done when (a test can check) |
|---|---|---|---|---|
| **C1** | **Release bundle.** On each `stable-*` tag, wf 55 (or a new 56) attaches `docker-compose.yml` (images only, pinned by **digest**), `.env.example` and `SHA256SUMS`, and pushes `ghcr.io/<owner>/spool-hub` and `spool-web` tagged `stable-<date>` and `v<X.Y.Z>` | A1, G1 | M | `gh release view stable-<date> --json assets` lists the 3 files; `grep -c 'build:' <asset compose>` -> 0; `grep -cE '@sha256:' <asset compose>` >= 2 |
| **C2** | **Compose runs with no tree**: `pg-init.sh` moves into the hub image (hub-init already dials Postgres over TCP, `docker-compose.yml:38`) or into a compose `configs:` with inline `content:`; the bind mount goes | new, unblocks C1 | S | in an empty dir with only the asset compose + `.env`: `docker compose up -d --wait` healthy; `grep -c '\./' <asset compose>` -> 0 |
| **C3** | **Runtime WUI config** (spec A3, lane L1): a `config.json` the web container renders from env at start | A3, G2 | S-M | a prebuilt `spool-web` with `SPOOL_PUBLIC_URL=https://<fqdn>` in `.env` calls `<fqdn>`; `grep -c 'ARG SPOOL_PUBLIC_URL' wui.Dockerfile` -> 0 |
| **C4** | **Prove the stable on the client path before cutting it**: wf 55 runs wf 50's job on the candidate commit **with the pulled images and the asset compose**, plus one "previous stable -> candidate" upgrade, and cuts nothing if red | new, G17 | S | a planted break on a throwaway branch (`gh workflow run --ref <branch>`, never trunk) makes wf 55 cut no tag; a green run shows a "stranger smoke" step in its summary |
| **C5** | **`spool` CLI as release assets** (spec A4, lanes L3/L8): linux and darwin, amd64 and arm64, in the same `SHA256SUMS`; `install.sh` downloads and verifies, runs without a clone, builds only as a fallback | A4, G6 | S-M | on a box with no Go and no clone, `curl -fsSL <release>/install.sh \| bash -s -- --env self ...` seats an agent; `grep -c releases/download install.sh` >= 1 |
| **C6** | **Sign what we ship**: keyless `cosign sign` of both image digests and of `SHA256SUMS` from the release job (GitHub OIDC, no key to store); one verify line in `DEPLOY.md` (spec A15) | new | S | `cosign verify ghcr.io/<owner>/spool-hub@<digest> --certificate-identity-regexp '<owner>/csi-spl/.github/workflows/5'` exits 0 in a CI step after the release |
| **C7** | **`do_spl_self_host_upgrade`** (spec A6, lane L14) on the bundle: backup, fetch the newest stable's compose (digests), `pull`, `up --wait`, compare `/version`; on failure print the exact restore command | A6, G5 | S | previous stable -> current in one command with no `--build`; `/version` reports the new stable |
| **C8** | **Notes a client can act on**: a top section "Before you upgrade" with (a) `.env.example` keys added, removed or renamed since the last stable, (b) the migration count and any that lock a table, (c) C7's command; the commit list moves to a collapsed tail | new | S | `do_release_stable` on a fixture range that changes `.env.example` lists each changed key under "Before you upgrade" (a test in its suite) |
| **C9** | **One version name for clients**: on a stable build the release title, `/version`, the WUI footer and `spool version` print `stable-<date> (v<X.Y.Z>)`; the CLI warns once when the hub is on a newer stable than itself | new | S | `curl /version` on a stable image contains `stable-`; a CLI older than the hub prints one warning line naming the upgrade command |
| **C10** | **Support policy in `SECURITY.md` names the release, not `master`** (after Q2): the latest stable gets fixes; a security fix cuts an out-of-cycle stable the same day via wf 55 `workflow_dispatch` | new | XS | `grep -c 'rebuild from it' SECURITY.md` -> 0; the section names `stable-<date>` and the out-of-cycle rule |

### 3.1 Top 3

| rank | action | why first (section 2) |
|---|---|---|
| 1 | **C1 + C2** (bundle, no-tree compose) | install goes from clone + ~4 min build to fetching three files + `up` (pull only): spec A1's "< 2 min, no clone" |
| 2 | **C3** runtime WUI config | without it the bundle works only on localhost; it is the one change that lets a shared image serve any `<fqdn>` |
| 3 | **C5** prebuilt CLI | the agent box is the second thing every client sets up; today it needs Go and a clone |

C4 and C6 are small and make the first three trustworthy; C7-C10 shorten
every week after the first.

### 3.2 The client's whole path after C1-C10

| step | command | manual steps |
|---|---|---|
| fetch | `curl -fsSLO <release>/docker-compose.yml -O <release>/.env.example -O <release>/SHA256SUMS && sha256sum -c SHA256SUMS` | 1 |
| configure | spec A2 `spool-up` asks ~5 questions and preflights (or edit `.env` by hand) | ~5 answers |
| run | `docker compose up -d --wait` (pull, no build) | 1 |
| own it | open the printed owner link | 1 |
| seat an agent | the one line from the WUI (C5; with spec A5, a join token instead of the root key) | 1 |
| upgrade | read "Before you upgrade" (C8), then `do_spl_self_host_upgrade` (C7) | 1 |

### 3.3 Cost (numbers; section 2 ranks them last)

| item | number | check |
|---|---|---|
| CI minutes for C1, C4, C6 | 0 billed | the repo is public (R1) and the jobs run on `ubuntu-latest`; I believe, unchecked, that GitHub bills no hosted-runner minutes on public repos |
| GHCR storage, two images a week | 0 billed | I believe, unchecked, from GitHub's terms for public packages |
| client compute | unchanged: the stack idles at ~110 MiB | README Quick start |
| client time saved | ~4 min of build per install and per upgrade (241 s, 047 n=1), and no Go or Node toolchain on the box | 1.3 |

## 4. Questions for the owner

| # | question | recommendation |
|---|---|---|
| Q1 | Publish images and the CLI on GHCR and GitHub releases under the org (spec D2)? | **yes**: it is the one dependency of C1, C5 and spec A1/A4 |
| Q2 | Which releases get security fixes? Today only `master` (R10) | **the latest stable**, with an out-of-cycle stable the same day for a security fix (C10): a client must never be told to build from trunk |
| Q3 | May a self-hosted hub check for a newer stable (one GET to the public releases API, shown to the tenant owner only)? | **opt-in, off by default** (`SPOOL_UPDATE_CHECK=1`): a phone-home in a self-hosted chat server is a privacy objection; C9's CLI warning covers most of the need with no outbound call |
| Q4 | Sign with keyless cosign (identity = our release workflow) rather than a long-lived key? | **yes**: no key to store or rotate, which fits the repo's "no key in git, state or log" rule |
| Q5 | Which upgrade paths do we support: every stable in turn, or any stable to any later one? | **any to any later**: migrations are ordered and forward-only, so hub-init already applies a gap; C4's upgrade run keeps it true |
