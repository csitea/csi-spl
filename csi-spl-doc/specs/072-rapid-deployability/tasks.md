# Tasks: 072 rapid deployability

Status per item: `[ ]` open, `[x]` landed (with its sha and the check that proved it). One lane = one task, one agent. The task text is the lane row of [spec.md](spec.md) section 7; its **acceptance check is the named action's check** in spec section 6 (A-ids). Generated from spec v0.19 sections 7.0 and 7.1; when the spec changes a lane, regenerate this list rather than editing a row by hand.

Rules for every lane: the spec's ranking rule (section 2: time to first deploy, manual steps, clarity of errors; never cost); the owner's guest rules R1-R3 (section 3.2); no GCP mutation without the owner's go; GCP lanes use the per-env service account only; the cloud-provider layer is out of scope (section 3.1, topic `a5a141bc`).

## Phase 1: user story 1 end to end (spec 2.1, 7.0), in this order

- [x] T001a **L59** (US1 step 3) A65, the live bug: the in-app guide opens on `c-001`, the help page and `en.json` carry no `CLE-01`. `496bfb803` (c-174), unit test `connect-agent-default-id.test.mjs`; WUI live on dev and prd (c-174). Check: `git grep -c CLE-01 origin/master -- csi-spl-wui/src/components/ConnectAgentGuide.vue csi-spl-doc/doc/help/connect-an-agent.md` -> 0
- [ ] T001b **L59** (US1 step 3, 4) the rest of A65 and A66: getting started drops "(Recommended)" on social sign-in (`getting-started.md:29`), the README "another machine" paragraph stops teaching a root-key copy, one connect story across README / help / guide; `run-all-tests.sh` works on a fresh clone (`GOPROXY=off` at line 18 today). Owns: `doc/help/getting-started.md`, the README paragraph, `run-all-tests.sh`. Needs: -
- [x] T002 **L5** (US1 step 4) A13: the runner as a repo variable. Owns: `10_ci-quality.yml` `runs-on` lines. Needs: - **Landed**: `d8c60e64b` + `25e1254fb`. Check: `git show origin/master:.github/workflows/10_ci-quality.yml \| grep -cE "runs-on: \[self-hosted"` -> 0; `SPOOL_CI_RUNNER` 12 refs
- [x] T003 **L33** (US1 step 4) A34: estate guard + fork-portability test. Owns: the 8 live-estate workflows, a new iac test. Needs: - **Landed**: `8651ee708`. Check: `csi-spl-iac/src/bash/tests/ci-estate-guard.tst.sh` on master
- [x] T004 **L6** (US1 step 1) A15: `DEPLOY.md` first cut (P1 and P3 as they are today). Owns: `DEPLOY.md`, one README link. Needs: - **Landed**: `c7ed917ad`. Check: `DEPLOY.md` on master; `grep -c DEPLOY.md README.md` -> 1
- [x] T005 **L31** (US1 step 4) A46: contributor dev stack (one sub-lane per research 01 action). Owns: `do_setup_app_inf`, `docker-compose.yml` port defaults, a new `do_lde_up`. Needs: - **Landed**: `5ec928322`. Check: `do_lde_up` in `csi-spl-orc/src/bash/run/lde-up.func.sh`. Follow-up: its CI SKIP line reds gate 10 (run 37194693175); g-186 fixes `lde-up.tst.sh`
- [x] T006 **L32** (US1 step 4) A35: reusable gate for push and pull request. Owns: wf 10, 11, a new reusable workflow. Needs: L5 **Landed**: `12003205` (wf 10 is the reusable gate itself, not a new file: runner group spool-ci-trusted admits only named workflows). Check: `bash csi-spl-iac/src/bash/tests/ci-one-gate.tst.sh` -> `PASS: all` (wf 11 = one call of wf 10 on ubuntu-latest); hosted run 37205084819 lists iac, orc, cnf, hygiene, sec. Follow-up: on hosted runners `spool-install.tst.sh` (3 of 59) and `spool-permissions.tst.sh` (3 controls) are red
- [x] T007 **L45** (US1 step 3) A49 + A50: installer fleet opt-in, errors and defaults. Owns: `spool-install/install.sh` and its tests. Needs: - **Landed**: `f5d06ee8f`. Check: `SPOOL_HUB_URL=http://127.0.0.1:9 install.sh --env self --tenant t1` -> rc 5 naming the URL; `test-install.sh` 12-13 (default home: no `CLAUDE.md`, no `skipDangerous`, no `/var/spool-hub` or `CLE-00` under `~/.claude`; `--fleet` writes them), 68 passed
- [ ] T008 **L55** (US1 step 4) A60 + A61: trunk ruleset (owner go), contributor rules. Owns: `oss-public-settings.func.sh`, wf 11, CONTRIBUTING, SECURITY.md, `.github/` templates. Needs: D16
- [x] T009 **L3** (US1 step 3) A4a: `spool` CLI release assets on `stable-*`. Owns: a job in `55_release-stable.yml`. Needs: - **Landed**: `d6525ec23`. Check: `55_release-stable.yml` attaches the CLI builds + `SHA256SUMS`
- [ ] T010 **L8** (US1 step 3) A4b: `install.sh` downloads the CLI, builds as a fallback. Owns: `spool-install/install.sh` and its tests. Needs: L3
- [x] T011 **L26** (US1 step 2) A27: membership `access_until`. Owns: a new migration, the hub auth check, Members pane. Needs: - **Landed**: `d34d3eb9e` (hub) + `5d0db71ad` (WUI). Check: migration `0113_membership_access_until.sql` on master
- [x] T012 **L17** (US1 step 3) A5: join tokens, its own spec first (037 T005). Owns: a new spec, then hub, WUI and CLI lanes. Needs: D3 **Landed**: spec only: `ce842d9ac` wrote spec 073 (agent join tokens). The hub, WUI and CLI build lanes follow spec 073's own tasks
- [x] T013 **L1** (US1 step 5) A3: WUI runtime config for compose and Hosting (`config.json` read at boot; the build args become lde defaults); one lane with research 06 W1. Owns: `csi-spl-wui/src/docker/wui.Dockerfile`, the WUI boot config. Needs: - **Landed**: `4a5957be3`. Check: `grep -c "ARG SPOOL_PUBLIC_URL" csi-spl-wui/src/docker/wui.Dockerfile` -> 0
- [x] T014 **L25** (US1 step 5) A21: one hub image. Owns: `build-push-hub-image.func.sh`, the cloud Dockerfile. Needs: - **Landed**: `6a00c67b4`. Check: `csi-spl-orc/src/docker/spool-hub-api/Dockerfile` absent on master
- [ ] T015 **L2** (US1 step 5) A1a: a CI job publishing the hub and web images to GHCR (public) on `v*` / `stable-*`. Owns: a new `.github/workflows/56_*.yml`. Needs: L25, D2 answered
- [ ] T016 **L7** (US1 step 5) A1b: compose pulls images by default. Owns: `docker-compose.yml`, `.env.example`. Needs: L1, L2
- [ ] T017 **L9** (US1 step 5) A2: `spool-up` with preflight. Owns: a new `csi-spl-orc/src/bash/run/spl-self-host-up.func.sh` + test. Needs: L7
- [ ] T018 **L30** (US1 step all) A28 + A29: contributor page, then the newcomer test. Owns: `CONTRIBUTING-WITH-AGENTS.md`; a results file in this dir. Needs: L8, L17

## Phase 2: wave 1

- [x] T019 **L4** A8: generic name validations, project id from cnf. Owns: the 7 steps' `02-variables.tf`, `gcp-001`, `resolve-oap.func.sh`, conf-validator `EnvModels/cloud.py`. Needs: - **Landed**: `433151db6`. Check: `git grep -F 'regex("^csi-spl' origin/master -- csi-spl-iac/src/terraform \| wc -l` -> 0
- [ ] T020 **L21** A19: full dry run + preflight. Owns: gcp-000..004, a new `gcp-bootstrap-preflight.func.sh` + tests. Needs: -
- [ ] T021 **L22** A24: deploy workflows name envs and secrets from cnf. Owns: the env/secret lines of wf 20 and wf 30. Needs: -
- [ ] T022 **L23** A25: stale deploy text + pinned yq. Owns: the cnf comments, 030 `02-variables.tf`, `build-push-hub-image.func.sh`, wf 20 yq step, the stale 031 rows (wf 20/30, renderer, 019 vars, `specs/README.md:216`). Needs: -
- [x] T023 **L34** A44: cnf derivations, byte-identical (C4, C5 first). Owns: `csi-spl-cnf`, `spl-merged-cnf.func.sh`. Needs: - **Landed**: part 1 (C4, C5): `f755f67f7`. The derivations C1-C3, C8-C10 stay open as T023b
- [ ] T023b **L34** A44 the remaining derivations (research 04 C1-C3, C8-C10), byte-identical renders. Owns: `csi-spl-cnf`, `spl-merged-cnf.func.sh`. Needs: T023
- [x] T024 **L49** A55: true release notes + forward-only gate (R2 is a live bug, XS). Owns: `release-stable.func.sh`, a new test. Needs: - **Landed**: `c5ae4a1e1`. Check: `release-stable.func.sh:141` lists migrations from `git diff --name-only` (a tree diff)
- [ ] T025 **L58** A64: digest pins + installer checksums. Owns: the 8 Dockerfiles, `install.sh` and its tests. Needs: -

## Phase 3: wave 2

- [ ] T026 **L10** A10: org optional. Owns: `gcp-001-create-project.func.sh` + test. Needs: -
- [ ] T027 **L11** A11: `do_spl_gh_wire`. Owns: a new action + test. Needs: -
- [ ] T028 **L12** A12: optional steps in cnf. Owns: cnf `steps.*`, `tf-sweep-steps.func.sh`. Needs: -
- [x] T029 **L13** A14: tpl-gen without a token. Owns: `setup-tpl-gen.func.mk`. Needs: - **Landed**: tpl-gen half: `5c74662d6`. Check: `do-setup-tpl-gen` demands no `GITHUB_TOKEN` (`setup-tpl-gen.func.mk:8`). `do-setup-tf-runner` still does (line 30): open as T029b
- [ ] T029b **L13** A14 the rest: `do-setup-tf-runner` without `GITHUB_TOKEN` (only step 120 needs it), the key dir mounted read-only, no `~/.aws` / `~/.ssh` mounts (research 03 A5). Owns: `setup-tpl-gen.func.mk` tf-runner target, `docker-compose-tf-infra.yaml`. Needs: T029
- [ ] T030 **L24** A18 + A20: keyless bootstrap, project-only key path. Owns: `gcp-002-*.func.sh`, `do_tf_init`, `do_gcp_account` + tests. Needs: L21
- [x] T031 **L35** A30: secrets check + seed-all. Owns: two new actions + tests. Needs: - **Landed**: `25a9228a6`. Check: `do_spl_secrets_check` and `do_spl_secrets_seed_all` defined on master
- [ ] T032 **L36** A42: state bucket action, reviewed-plan apply, validate-all. Owns: `tf-plan`, `tf-apply`, a new action, step 000. Needs: -
- [ ] T033 **L37** A36 + A37: no-tree compose, stable proven on the client path. Owns: `docker-compose.yml`, `pg-init.sh`, wf 55. Needs: L7
- [ ] T034 **L38** A40: no-domain docs, plain-http refusal, one name variable. Owns: README, hub-init entrypoint, WUI banner. Needs: -
- [x] T035 **L39** A45: migration lint + schema-head guard. Owns: pre-push part, `spool serve`. Needs: - **Landed**: `09ee4426f` (lint in `check-pre-push-lint.func.sh` + test) + `c2f80bc55` (`spool serve` refuses a schema behind its image)
- [ ] T036 **L46** A51: fresh-box installer job. Owns: a new workflow. Needs: L45
- [ ] T037 **L50** A54: release asset contract + front door on the stable. Owns: wf 55, `release-stable.tst.sh`, README, `install.sh --update`. Needs: L2, L3
- [ ] T038 **L52** A57: compose `.env.hub`, Caddy locale root, own-domain wf 50 leg. Owns: `docker-compose.yml`, the Caddyfile, wf 50. Needs: -
- [ ] T039 **L57** A63: evaluation mode for a P2 estate. Owns: the cnf template mail/payment keys, `DEPLOY.md`. Needs: L15

## Phase 4: wave 3

- [ ] T040 **L14** A6: `do_spl_self_host_upgrade`. Owns: a new action + test. Needs: L7
- [ ] T041 **L15** A7: cnf template + `do_spl_cnf_init`. Owns: `csi-spl-cnf/template/`, a new action. Needs: L4, L12
- [ ] T042 **L16** A17: box deploy for any env and `self`. Owns: `spl-box-deploy.func.sh`, `spl-pool-ctl.func.sh`. Needs: -
- [ ] T043 **L27** A22: `do_hub_deploy`. Owns: a new action + test; wf 20 deploy job. Needs: L25
- [ ] T044 **L28** A23: `do_spl_wui_deploy`. Owns: a new action + test; wf 30 deploy job. Needs: L1
- [ ] T045 **L29** A26: prebuilt WUI bundle as a release asset. Owns: a job in `55_release-stable.yml`. Needs: L1
- [ ] T046 **L40** A31 then A32: WIF first, then least privilege. Owns: auth steps of wf 00/20/30/40/45; gcp-003. Needs: A11, D4
- [ ] T047 **L41** A38 + A39: signing, client release notes, one version name. Owns: wf 55, `SECURITY.md`. Needs: L2
- [ ] T048 **L42** A47 + A48: compose second workspace, browser -> agent leg. Owns: `do_spl_tenant_create`, hub-init. Needs: -
- [ ] T049 **L47** A52: box enrol for a second machine. Owns: a new action + test. Needs: L16
- [ ] T050 **L51** A56: CLI/hub version agreement. Owns: hub `/version`, `spool` CLI. Needs: -

## Phase 5: wave 4

- [ ] T051 **L18** A9: `do_spl_estate_up`. Owns: a new action + test. Needs: L4, L10, L11, L12, L15
- [ ] T052 **L19** A16: P1 stranger test on stables; P2 clean-room estate (one sub-lane per research 20 CR1-CR8; CR1 teardown first). Owns: a results file in this dir; `75_cleanroom-estate.yml`; cleanroom actions. Needs: L9, L18, D4 answered
- [ ] T053 **L20** A15 final: `DEPLOY.md` with every new command and the error index. Owns: `DEPLOY.md`. Needs: wave 3
- [ ] T054 **L43** A41: GCP without a custom domain. Owns: cnf, 005/025/032 skip. Needs: L12
- [ ] T055 **L48** A53: box bootstrap for any ssh host. Owns: `do_box_playbook`, the satellite playbook vars. Needs: -
- [ ] T056 **L60** A67: `@arg` flags for `./run` actions. Owns: the `./run` framework of iac and orc. Needs: L53

## Phase 6: any time

- [ ] T057 **L44** A33, A43: key resolver, relay key actions, AWS leftovers. Owns: iac run dir. Needs: -
- [ ] T058 **L53** A58: `./run` front door (one sub-lane per item). Owns: the `./run` framework of iac and orc, `spool` usage. Needs: -
- [ ] T059 **L54** A59: docs that stay true + weekly newcomer walk. Owns: READMEs, CONTRIBUTING, a new weekly workflow. Needs: -
- [ ] T060 **L56** A62: open-source hygiene (one sub-lane per item). Owns: spec 044 files, wf 11 gate job, licence files, `.github/dependabot.yml`. Needs: -

## Phase 7: added by the owner's answers (spec 8.3)

- [ ] T061 **L61** A68: trusted-developer keys, its own spec (owner Q19). Owns: a new spec dir. Needs: spec 073 (A5)
- [ ] T062 **L62** A69: external managed Postgres profile for compose (owner Q20). Owns: `docker-compose.yml` profile, `.env.example`, wf 50 leg. Needs: A6

## Owner decisions these tasks wait on

Answered by the owner on 2026-10-04 (spec 8.3, msg `bee1f6b2`): D5/D6 yes (L24), D10/D11 both (L40), D13 up to 10 test repos, D16 a ruleset with a trusted-contributor bypass (L55). No task waits on an owner answer now.
