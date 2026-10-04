# 072 research 16: release artifacts, versions, upgrades and notes

Author: c-174. Tree: `origin/master` @ `d0fbbcf7a`, 2026-10-04. Docs only.
Scope: what an outsider can **consume** from a release today: the version
(`do_release_version`, `do_release_stable`), public images, installers and
binaries, the upgrade and migration path between versions, and the release
notes. Ranked by the spec's section 2 rule (time to first deploy, manual
steps, clarity of errors). The odometer itself (9.9.9) is research 05
(B6, H1, Q1) and is not repeated here.

## 1. Today

### 1.1 The walk: an outsider wants "the current release"

| # | step | what they find | check |
|---|---|---|---|
| 1 | open the repo's Releases page | **1 release**, `stable-2026-09-29 (v2.2.0)`, marked Latest, cut by a manual dispatch | `gh release list` -> 1 row; `gh run list --workflow 55_release-stable.yml` -> 1 run, `workflow_dispatch` |
| 2 | look for something to download | **0 assets**: no image, no binary, no checksums, no compose file | `gh release view stable-2026-09-29 --json assets --jq '.assets\|length'` -> 0 |
| 3 | look for a published image | none for the hub or the WUI; the org's container registry holds one package, tpl-gen's | `gh api 'orgs/<org>/packages?package_type=container' --jq '.[].name'` -> 1 name; `grep -li ghcr .github/workflows/*` -> 0 |
| 4 | follow the README quick start | it clones **master**, not the release, and builds | `README.md:15` `git clone ...`; `README.md:17` `docker compose up --build -d` |
| 5 | follow the README upgrade | "pin a release, not master": dump, `git checkout stable-<date>`, `up --build` | `README.md:115-124` |
| 6 | install an agent box | `install.sh` needs a clone, builds `spool` from source with the **latest** Go from go.dev; `--update` pulls master | `install.sh:6`, `:272-277`, `:113` `git pull -q --ff-only` |
| 7 | read what changed | a 49,363-byte note: 1083 commit subjects by kind, 52 migrations, 3 upgrade lines | `gh release view stable-2026-09-29 --json body --jq '.body\|length'` -> 49363 |
| 8 | check what runs | `GET /version` -> `{version, commit, built_at}`; the version is `git describe` of the build tree | `server.go:274-277`; `hub.Dockerfile:21-26` |

So the only consumable artifact is a **git tag**. Every consumer (compose
host, agent box, GCP estate) builds from source; compose's fresh build plus
its browser proof is 146..184 s on a GitHub-hosted runner (wf 50, n=10 green
runs, 2026-10-03..04:
`gh run list --workflow 50_oss-standalone.yml --status success --limit 10`).

### 1.2 Two version lines

| line | made by | rate | meaning | check |
|---|---|---|---|---|
| `v<X.Y.Z>` | every hub (wf 20) and WUI (wf 30) deploy, `do_release_version` | ~130 a day (05 section 1.2) | a **build id**: one odometer step, no semver meaning | `git ls-remote --tags origin 'v*' \| wc -l` -> 728, highest `v8.4.0` |
| `stable-<YYYY-MM-DD>` | wf 55, Mondays 06:41 UTC, on the commit the prd hub runs | weekly; the cron has not fired yet (wf 55 landed 2026-09-29, a Tuesday) | the **release** the README tells outsiders to pin | `git ls-remote --tags origin 'stable*'` -> 1 |

A stable is labelled with the hub's v-tag only. Dry run of the next one
(`STABLE_FROM_ENV=prd DRY_RUN=1 ./run -a do_release_stable`, tree above, n=1):
`stable-2026-10-04 (v8.3.5)` on `3703c480`, while `v8.4.0` (a later WUI-only
mint) already exists. To an outsider the release is numbered lower than a
build they can see.

A source download without `.git` (the Releases page's "Source code" zip)
builds as `1.1.3-dev`: `hub.Dockerfile:24` falls back to `.version`
(`cat .version` -> `1.1.3`). A `git clone --depth 1` has no tags and does the
same.

### 1.3 Upgrade and migration path

| item | today | check |
|---|---|---|
| migration files | 112, in one dir, applied in filename order at hub start (compose `hub-init`) or by `do_spl_db_bootstrap` (GCP) | `ls csi-spl-rdb/src/sql/postgres/spool-hub \| wc -l` -> 112 |
| forward-only rule | per DATABASE: an applied filename whose sha256 changed is a hard error | `migrate.go:28-30`, `:74` |
| renamed or deleted applied file | **not detected**: a renamed file is a new name and is applied again; a deleted one is skipped silently | `migrate.go:60-95` reads the dir only, never the table's leftovers |
| duplicate number prefix | `0021` twice (order then rests on the rest of the name) | `ls ... \| cut -c1-4 \| sort \| uniq -d` -> `0021` |
| downgrade | none; the README restore is the rollback | `README.md:118` |
| skip-version upgrade | works in principle (all pending files apply in order) but is **never run**: wf 50 builds a fresh stack only | `git ls-files \| grep -ic upgrade` -> 0 |
| CLI vs hub compatibility | no contract: no version header, no minimum client, no warning | `grep -rnE 'MinClient\|X-Spool-Version\|client_version' --include=*.go csi-spl-api` -> 0 (the `MinVersion` hits are TLS) |
| upgrade command | none for compose (spec A6 proposes `do_spl_self_host_upgrade`) | `git ls-files \| grep -c self-host-upgrade` -> 0 |

### 1.4 Release notes

Three note channels exist, and the outsider sees only the first:

1. **The GitHub release body** (`do_release_stable`,
   `release-stable.func.sh:117-163`): commit subjects grouped by kind, up to
   a cap per kind with a "... and N more" line, then migrations, then the
   compose upgrade steps.
2. **The in-app release notes table** (spec 065): every commit carries six
   `Lay-*` / `Tech-*` trailers (`csi-spl-doc/doc/help/release-notes.md`),
   ingested per deploy, shown in the WUI.
3. `do_release_note_link`: the `<sha> v<X.Y.Z> <link>` line for agents' posts.

Measured on the current and the next stable (n=2):

| measure | stable-2026-09-29 | next (dry run) | check |
|---|---|---|---|
| bytes / lines | 49,363 / 448 | 54,151 / 462 | `wc -c -l` of the body |
| commits covered | 1083 | 1254 | first line of the body |
| bullet lines | 416 | 431 | ``grep -c '^- `'`` |
| lines with internal tracker or agent ids | 323 | 57 | `grep -ciE 'SPL-[0-9]+\|CLE-[0-9]+\|c-[0-9]{3}'` |
| subjects cut mid-sentence | 40 | 92 | `grep -c '\.\.\.$'` |
| uses the `Lay-*` trailers | no | no | `grep -c 'Lay-' release-stable.func.sh` -> 0 |
| migrations listed that are not in the release | **1**: `0040_tenants_display_name.sql` (renamed to `0041_` by `b4ef0630`, before the stable) | - | `git ls-tree --name-only stable-2026-09-29 csi-spl-rdb/src/sql/postgres/spool-hub/ \| grep -c 0040_tenants` -> 0 |

The wrong migration line comes from `release-stable.func.sh:145`: the list is
`git log --diff-filter=A` over the range, i.e. every file ever ADDED in the
history, not the files that differ between the two trees.

## 2. Blockers

1. **Nothing to download.** 0 release assets, 0 hub or WUI images; every
   consumer builds from source (1.1 rows 2, 3, 6). This is spec A1/A4, the
   top of 6.1; section 3 below gives the asset contract they should meet.
2. **The front door points at master.** The quick start clones master
   (`README.md:15`), and `install.sh --update` pulls master
   (`install.sh:113`), although the README's own upgrade section says
   "pin a release, not master" (`README.md:115`). A first-time user starts on
   a commit no release vouches for, and a box updates past the hub it talks to.
3. **The installer is not reproducible.** It fetches the newest Go from
   go.dev (`install.sh:276`) and the newest yq (`install.sh:241`,
   `releases/latest`), while the module pins `go 1.25.14` (`go.mod:5`). The
   same command can build different binaries on two days.
4. **Release notes are a commit log, not notes.** 49-54 KB, 1083-1254
   subjects, tracker ids in 57-323 lines, 40-92 subjects cut mid-sentence
   (1.4), and the plain-words `Lay-*` trailers every commit now carries are
   ignored. An outsider cannot find "what changes for me" or "what breaks".
5. **The migration list in the notes is wrong** (`release-stable.func.sh:145`):
   it names a file the release does not contain. It is the one list the
   README tells upgraders to read before they upgrade.
6. **Forward-only is enforced per database, not per release.** Renaming or
   deleting an applied migration passes every gate (1.3). `0041_` was safe
   only because its SQL says `IF NOT EXISTS`. Nothing compares the tree's
   migrations with the last `stable-*`.
7. **No upgrade is ever tested.** wf 50 proves a fresh stack; no job starts
   the previous stable, writes data, checks out the new one and proves the
   data and `/version` (1.3). The first upgrade test is the user's production.
8. **No CLI/hub compatibility contract.** Agent boxes built from any commit
   talk to any hub; a mismatch shows as a protocol error, not as "upgrade
   your box to stable-X" (1.3).
9. **The version an outsider sees is ambiguous** (1.2): a stable numbered
   below a visible build, and a source zip that reports `1.1.3-dev`.

## 3. Actions

Effort as spec 072 section 6 (XS < 0.5 day, S <= 1 day, M 2-5 days).
Each names the A id it serves; R-numbers are new.

| # | action | changes | owner | effort | done when (a test can check) |
|---|---|---|---|---|---|
| **R1** | **Release asset contract** for every `stable-*`: hub and web images (A1) tagged `stable-<date>` + the build `v<X.Y.Z>`; `spool` CLI for linux/darwin x amd64/arm64 (A4); a `docker-compose.yml` whose images are pinned to that tag; `SHA256SUMS`. `release-stable.tst.sh` gains a contract check; wf 55 fails when an asset is missing | A1, A4 (their acceptance target) | CI + orc | S (contract + check; the builds are A1/A4) | `gh release view <latest stable> --json assets --jq '[.assets[].name]'` lists the 4 CLI builds, `SHA256SUMS`, `docker-compose.yml`; `sha256sum -c SHA256SUMS` passes on a download |
| **R2** | Migrations in the notes from the **tree diff**: `git diff --name-only --diff-filter=A <prev>..<sha> -- csi-spl-rdb/src/sql` | W10 fix | orc | XS | `release-stable.tst.sh` case: add `0040_x`, rename it to `0041_x` inside the range -> the notes list `0041_x` only; on `stable-2026-09-29`'s range it lists 0 files absent from that tree |
| **R3** | **Release-level forward-only gate**: a test fails when a migration present in the latest `stable-*` tag is renamed, edited or deleted, or when two files share a number; `Migrate` WARNs on an applied filename missing from the dir | new | api + orc | S | the test on this tree passes (`0021` grandfathered by name); a control renaming any stable migration turns it red on a throwaway branch; `go test ./internal/store -run Migrate` covers the WARN |
| **R4** | **Upgrade test**: a wf 50 job (also run by wf 55 before it cuts) starts the previous `stable-*` with compose, signs up, posts one message, checks out the candidate, `up -d --wait`, then proves the message reads back and `/version` names the candidate | A6, A16 | CI + orc | M | the job is green on master; a control migration that drops a column the old stable wrote turns it red on a throwaway branch; wf 55 refuses to cut when it is red |
| **R5** | **Front door on the release**: README quick start uses `--branch <latest stable>` (resolved by a one-line `git ls-remote` helper, or the R1 compose asset); `install.sh --update` moves to the newest `stable-*`, `--update=master` keeps today's behaviour | A2, A4b, A15 | docs + orc | S | `grep -n 'git clone' README.md` shows `--branch stable-`; `install.sh --update --dry-run` prints the newest stable tag; the install tests cover both modes |
| **R6** | **Reproducible installer**: the Go version from `go.mod` (`go 1.25.14`), yq pinned by version and sha256, no `latest` fetch | A4b fallback path | orc | XS | `grep -cE 'VERSION\?m=text\|releases/latest' install.sh` -> 0; the install test asserts the Go version it fetches equals `go.mod`'s |
| **R7** | **Notes for people**: the stable body is built from the `Lay-What` trailers (one line per commit, grouped by kind, deduplicated), capped at ~150 lines; internal ids and the full subject log move to an attached `CHANGES-full.md`; an "Action needed" section comes first (migrations, keys added to `.env.example`, removed flags) | W10, spec 065 | orc | S | for the next stable: body < 16 KB; `grep -cE 'SPL-[0-9]+\|CLE-[0-9]+' <body>` -> 0; a fixture commit adding an `.env.example` key appears under "Action needed" |
| **R8** | **A version a human can read**: the release title is `stable-<date>` with both builds second ("hub v8.3.5, web v8.4.0"); the source tarball asset carries a `VERSION` file so a no-git build reports the stable, not `1.1.3-dev` | W6, 05 H1 | orc + api | XS-S | a build from the release tarball: `curl -s localhost:8080/version` -> the stable's version; the release title names the hub and web builds |
| **R9** | **CLI/hub compatibility**: `GET /version` adds `min_client`; `spool` sends its version on connect and on a refusal prints "this box runs X, the hub needs >= Y: run install.sh --update"; `spool version --hub` prints both | P3 | api | S-M | a test hub with `min_client` above the test CLI -> the CLI exits non-zero with that line; `spool version --hub` against compose prints two versions |

Order: R2 (XS, fixes a wrong fact in a published note) and R6 now; R1 with
A1/A4 (it is their acceptance target); R3 then R4 (R4 needs the previous
stable's image from R1, or builds it); R5 after R1; R7, R8, R9 any time.

Cost, as numbers (none changes the ranking): public GHCR packages and
GitHub-hosted runners are free for a public repo; R4 adds about two compose
builds per run, ~5-6 min at wf 50's 146..184 s, once per master push, or once
a week if only wf 55 runs it; R1's 4 CLI cross-builds take seconds each
(`CGO_ENABLED=0`).

## 4. Questions for the owner

| # | question | recommended answer |
|---|---|---|
| Q1 | Is `stable-<date>` THE public release line, with `v<X.Y.Z>` documented as a build id outsiders never pin? | **Yes**: one name to pin, weekly; the v-tag stays the hosted estate's deploy counter. DEPLOY.md (A15) says so in one line |
| Q2 | Publish images and the CLI on `stable-*` only, or also on every `v*` (spec A1 says both)? | **Images on both, CLI on stable only.** Images per `v*` let a fork's estate (05 H6) roll exactly what we roll; ~130 CLI release pages a day would bury the stable one |
| Q3 | Upgrade support window: from how many stables back must one command work (R4)? | **The last 4 stables (one month)**, tested; older installs step through them, and the notes say so |
| Q4 | Public notes from the `Lay-*` trailers only, with the full commit log as an attachment (R7)? | **Yes**: the trailers were written for exactly this reader (spec 065), and they keep tracker ids out of the public page |
