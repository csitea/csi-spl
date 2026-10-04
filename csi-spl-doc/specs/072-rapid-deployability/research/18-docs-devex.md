# 072 research 18: docs and DevEx, the newcomer's first hour

Status: **research, v1** for the 072 lead (c-165), who merges it into spec
sections 4-7. Section: the README, the quickstart, the help pages, error
messages and `./run` action discoverability, walked as a newcomer who has
just found the public repo. Tree: `origin/master` @ `324062214`,
2026-10-04. Every command below ran once on that tree (n = 1) unless a row
says otherwise. Docs only: nothing was built, applied or deployed; the
compose times are 047's, labelled as such.

`<org>`, `<app>`, `<env>`, `<fqdn>` are placeholders. Ranking follows spec
section 2: time to first deploy, then manual steps, then clarity of errors.
Cost is given as numbers and ranks last.

## 1. Today

### 1.1 The walk: minute by minute, what a newcomer reads

The minutes are a reading estimate, not a stopwatch; the checks are measured.

| min | step | what they meet | check |
|---|---|---|---|
| 0 | land on `README.md` | a clear one-paragraph pitch; P1 compose comes first | `grep -nE '^## ' README.md` -> 9 sections, lines 10..178 |
| 1 | Quick start | clone into `csi/csi-spl`, with an aside that the layout "matters only for the agent installer": an internal convention in step 1 | `README.md:15`, `:21-22` |
| 2 | `docker compose up --build -d` | builds hub + WUI from source; 047 measured 6 min 26 s to the first human message, 241 s of it the build | spec 072 section 4.2 F1; 047 section 1.1 (n = 1) |
| 8 | sign up on `localhost:8080` | works; the form shows the confirmation link | `README.md:24-27` |
| 10 | Connect an agent | one 290-character line that copies the root key out of the container and runs the installer | `awk 'NR==75{print length}' README.md` -> 290 |
| 15 | "what about GCP, the hosted shape?" | **no link**: the README never names the P2 path, spec 047, 072 or the GCP how-to | `grep -ciE 'gcp\|terraform\|047\|072\|byo' README.md` -> 0 |
| 16 | Repository layout -> `csi-spl-doc` | `csi-spl-doc/README.md` opens on `csi-spl.feature.md`, the **git-rel relay bucket** operator doc, not the spool | `csi-spl-doc/README.md:3-4`, `:15` |
| 18 | the spec table in `csi-spl-doc/README.md` | lists specs 001..011 of **72** dirs; last edit 2026-09-18 | `ls csi-spl-doc/specs \| wc -l` -> 72; `csi-spl-doc/README.md:44` |
| 20 | `csi-spl-iac/README.md` | lists 8 terraform steps of **18**; points at `csi-spl.feature.md` sections 5-7 | `grep -c 'src/terraform/' csi-spl-iac/README.md` -> 8; `ls -d csi-spl-iac/src/terraform/[0-9]* \| wc -l` -> 18 |
| 22 | `csi-spl-api/README.md` | names verbs that no longer exist (`spool-send`, `spool-pin`); the binary has `spool send`, `spool pin` | `csi-spl-api/README.md:4` vs the `spool` usage text |
| 25 | `cd csi-spl-iac && ./run --help` | 3.2 s, 96 actions in **one flat alphabetical list**, no groups, 14 descriptions cut mid-sentence ("... so a"), 10 that echo the action name ("Gcp delete service account.") | 1.2 |
| 27 | try the help footer's tip | `./run -a do_help_with --search <kw>` -> `FATAL action(s) requested: "do_help_with" NOT found` | iac and orc both; 1.3 E2 |
| 28 | `./run -a do_gcp_001_create_project --help` | reprints the whole list: **no per-action help** | 1.3 |
| 30 | `cd ../csi-spl-orc && ./run --help` | 3.7 s, 241 actions, the same flat list | 1.2 |
| 35 | "a `docker-compose.yml` at the root and an `lde` stack in orc: which one?" | neither README names the other | `grep -cw lde README.md` -> 0; `grep -c 'docker-compose.yml' csi-spl-orc/README.md` -> 0 |
| 40 | CONTRIBUTING | asks for a DCO `Signed-off-by:` on every commit, which the last 200 commits do not carry; never names the pre-push gate | `git log -200 --format=%B \| grep -c '^Signed-off-by:'` -> 0; `grep -c 'pre_push\|dist_hygiene' CONTRIBUTING.md` -> 0 |
| 45 | README "Tests" | names the api suite and the WUI; not the iac and orc suites, nor `do_check_pre_push` | `README.md:165-170` |

**Verdict.** P1 (compose) is well documented and reaches a working hub in
about 10 minutes; its friction is build time and the long seat line, not the
prose. Everything past P1 (the P2 GCP estate, contributing, the `./run`
surface) has **no entry point**: stale indexes, a "start there" pointing at
a different product, and a help system whose own tip fails.

### 1.2 The `./run` surface, measured

| module | `./run` | actions listed | cut `...` | name-echo descriptions | named delete / destroy / cleanup / disable | marked destructive | `--help` wall |
|---|---|---|---|---|---|---|---|
| `csi-spl-iac` | yes | 96 | 14 | 10 | 10 | **0** | 3.2 s |
| `csi-spl-orc` | yes | 241 | 8 | 0 | 7 | **0** | 3.7 s |
| `csi-spl-api`, `-wui`, `-cnf` | **no** | - | - | - | - | - | - |

Commands: `sudo -u <clone-owner> bash -c 'cd csi-spl-<m> && time ./run --help'`,
then on the saved output `grep -c '\./run -a do_'`, `grep -c '\.\.\.$'`,
`grep -ciE 'delete|destroy|cleanup|disable'` and
`grep -ciE 'destructive|DANGER|irreversible'`. "Name-echo" = a description
equal to the action name with `do_` and `_` removed (awk). n = 1 each.

Descriptions also carry internal history a newcomer cannot use; the
`do_check_pre_push_lint` row reads, cut there, `The LINT parts of
do_check_pre_push (owner 2026-10-01: "why`. The catalogue is 337 rows across
two modules with no "start here" subset.

### 1.3 Error messages, sampled

| # | trigger | message | names the cause? | names the next command? |
|---|---|---|---|---|
| E1 | `./run --help` where `dat/log/bash` cannot be created (a clone owned by another user) | `./run: line 318: .../dat/log/bash/...log: No such file or directory`, then `FATAL Command '[[ "${RUN_LOG_COMPACT:-0}" == "1" ]]' failed at line 359` | no: blames an unrelated test | no |
| E2 | the help footer's own tip | `FATAL action(s) requested: "do_help_with" NOT found !!!` / `check the spelling` | yes | points at `--help`, which printed the tip |
| E3 | a typo, `do_gcp_001_create_projec` | the same NOT found block, no "did you mean" | yes | no |
| E4 | no SA key for the env | `FATAL no gcloud account: no project SA key at $HOME/.gcp/.<org>/key-<org>-<app>-<env>.json (set ENV, or GCP_SA_KEY_FILE) ...` | yes, well | no: does not say "run the gcp-000 bootstrap first" (`csi-spl-iac/lib/bash/funcs/gcp-account-pin.func.sh:197`) |
| E5 | `spool sned` | `unknown command "sned"` | yes | no suggestion |
| E6 | compose off localhost with a default DB password | `hub-init` refuses and names `openssl rand -hex 24` | yes | yes (`README.md:59-60`) |

The `spool` CLI usage is the model to copy: `spool` alone prints 30 usage
rows in 3 groups by who runs them ("on a box", "a box and its hub",
"running a hub"), one line each, and `spool <verb> -h` for flags.

### 1.4 What is good and must stay

- The README P1 sections (quick start, own-domain table, connect, backup /
  restore / upgrade) are task-shaped, short and copy-pasteable.
- `.env.example`: 91 lines, 6 labelled groups, every setting defaulted
  (`grep -c '^# ---' .env.example` -> 6).
- The end-user help (`csi-spl-doc/doc/help/`, 20 pages) opens from the
  WUI's `?` icon (`getting-started.md` section 1).
- Fail-fast env vars with a reason (`: "${X:?...}"`) are the house style.

## 2. Blockers

Each one is a stop for a newcomer, cited.

1. **No P2 or contributor entry point from the README.** `grep -ciE 'gcp|terraform|047|072|byo' README.md` -> 0.
2. **`csi-spl-doc/README.md` opens on the relay-bucket doc** (`csi-spl-doc/README.md:3-4`), and its spec table stops at 011 of 72 (`:11-42`).
3. **Module READMEs are stale against the tree**: iac lists 8 of 18 steps (`csi-spl-iac/README.md:11-18`); api names removed verbs (`csi-spl-api/README.md:4`).
4. **`./run --help` cannot be navigated**: 337 flat rows, no groups, no "start here", 22 cut, 10 name-echo descriptions, 17 destructive-sounding actions with 0 warnings (1.2).
5. **The help footer advertises an action that does not exist** (`do_help_with`, E2) in both modules, and there is no per-action help.
6. **Misleading FATAL when the log dir cannot be made** (E1): `csi-spl-iac/run:351` swallows the `mkdir` failure (`|| true`), then the ERR trap blames line 359.
7. **Errors stop at the cause, not the next command** (E3, E4, E5): no "did you mean", and the missing-key error does not name the bootstrap action.
8. **Two local stacks, unexplained**: root `docker-compose.yml` (P1, the product) and the `csi-spl-orc` lde (a hub-only dev stack) never reference each other.
9. **CONTRIBUTING disagrees with practice**: DCO required, 0 of 200 commits signed; the pre-push gate and dist-hygiene sweep are not mentioned.
10. **The seat line is 290 characters** (`README.md:75`): correct, but one typo-prone paste is the first agent step. Spec 072 section 4.4 (P3) owns that fix; this file only cites it.

## 3. Actions

Each is one lane: docs, or a small `./run` framework change, with a check a
test can run. Effort in agent-hours (estimate, not measured), ordered by
spec section 2.

| # | action | done when (testable) | est. |
|---|---|---|---|
| D1 | **README "Choose your path" block** under the pitch: P1 compose (here), P2 own GCP estate (the 072 runbook once it exists; 047 until then), P3 seat an agent, Contribute. One line each | `grep -c 'Choose your path' README.md` -> 1; a link test asserts all 4 targets exist | 1 h |
| D2 | **Fix `csi-spl-doc/README.md`**: start here = root README + `doc/help/index.md`; replace the spec table with one line pointing at `specs/README.md` (which is maintained) | `csi-spl.feature.md` no longer on line 3; link test green | 0.5 h |
| D3 | **README freshness test**: every `src/terraform/NNN-*` dir is named in `csi-spl-iac/README.md`; every `spool-<verb>` / `spool <verb>` a README names exists in the `spool` usage | new iac test, red on today's tree | 2 h |
| D3b | update `csi-spl-iac/README.md` (18 steps) and `csi-spl-api/README.md` (current verbs) | D3 green | 1 h |
| D4 | **Grouped `./run --help`**: an optional `# @group` line (bootstrap, terraform, deploy, read-only, destructive, dev, gate); `--help` prints groups and a ~10-row "start here" first; `destructive` rows carry a marker | test: every `do_*` with delete/destroy/disable/cleanup in its name has `@group destructive`; `--help` output contains `start here` | 4 h |
| D5 | **Per-action help, no dead tip**: `./run -a <x> --help` prints only that action's `@description` and `@arg` lines; implement or drop `do_help_with` | test: `./run -a do_check_dist_hygiene --help \| wc -l` < 20; the footer names no missing action | 2 h |
| D6 | **No name-echo or cut descriptions**: a lint fails a `@description` equal to its action name, or a first sentence longer than the help column | lint over both modules -> 0 offenders (today 10 + 22) | 2 h |
| D7 | **"Did you mean"** on an unknown action in `./run` and an unknown verb in `spool` | test: `do_gcp_001_create_projec` suggests `do_gcp_001_create_project`; `spool sned` suggests `send` | 2 h |
| D8 | **The log dir failure names itself**: print `cannot create <dir> (owner <u>, you <me>): clone as yourself or set LOG_DIR`, exit 1 | test with a read-only `PROJ_PATH` -> that line, exit 1, no "line 359" | 1 h |
| D9 | **Errors end with the next command**: the missing-SA-key FATAL adds "first run `ENV=<env> ./run -a do_gcp_000_bootstrap_gcp_env` (owner, once)" | test: every `FATAL no gcloud account` line contains `./run -a` | 1 h |
| D10 | **Name the two local stacks**: one sentence each in README and `csi-spl-orc/README.md` (compose = the product; lde = the hub-only dev loop) | `grep -cw lde README.md` >= 1; `grep -c docker-compose.yml csi-spl-orc/README.md` >= 1 | 0.5 h |
| D11 | **CONTRIBUTING matches practice**: the DCO rule per Q2; add "before a PR: `cd csi-spl-iac && ./run -a do_check_pre_push`"; README "Tests" lists the 4 suites (api, iac, orc, wui) | `grep -c do_check_pre_push CONTRIBUTING.md` >= 1 | 1 h |
| D12 | **A weekly newcomer-walk job**: a fresh clone, as a non-root user, runs `./run --help` in iac and orc and every README fenced block marked `<!-- smoke -->` | green on master; a planted dead link reds it on a throwaway branch | 3 h |

Total ~21 agent-hours across 13 rows, all docs or `./run` framework; no GCP.
Cost: 0 USD for D1-D11; D12 uses GitHub-hosted minutes, about 2 min a week.

**Top 3 by spec section 2:** D1 (one entry point for every path); D4 + D5
(make 337 actions navigable and the help tip true); D9 + D7 (every error
ends with the next command).

## 4. Questions for the owner

1. **Keep the README P1-first, with P2 as a linked runbook, rather than one
   long README that also covers GCP?** Recommended: **yes**. P1 serves most
   people in about 10 minutes (047); P2 needs its own versioned runbook (an
   output of 072), linked from D1.
2. **DCO: keep requiring `Signed-off-by:` from outside contributors, or drop
   it?** Recommended: **keep it for outside PRs and say so** ("maintainer
   commits are exempt"): an AGPL project wants the provenance, and today's
   text reads as if every commit must carry it, while none do.
3. **May `./run --help` show a ~30-row public subset by default and the full
   list behind `--all`?** Recommended: **yes**. Most of the 241 orc rows are
   the agent fleet's own tooling, which a newcomer deploying a hub never
   runs; `--all` keeps every action one flag away.
4. **Should help descriptions drop dated owner quotes ("owner 2026-10-01:
   ...") for a plain verb phrase, keeping the quote in the file's header
   comment?** Recommended: **yes**. The quote is the why for a maintainer, not
   the what for a user; D6 lints only the first sentence.
