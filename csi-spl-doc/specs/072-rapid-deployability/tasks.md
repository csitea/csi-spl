# Tasks: 072 rapid deployability

Status per item: `[ ]` open, `[x]` landed (with its sha and the check that proved it). One lane = one task, one agent. The task text is the lane row of [spec.md](spec.md) section 7; its **acceptance check is the named action's check** in spec section 6 (A-ids). Generated from spec v0.16 sections 7.0 and 7.1; when the spec changes a lane, regenerate this list rather than editing a row by hand.

Rules for every lane: the spec's ranking rule (section 2: time to first deploy, manual steps, clarity of errors; never cost); the owner's guest rules R1-R3 (section 3.2); no GCP mutation without the owner's go; GCP lanes use the per-env service account only; the cloud-provider layer is out of scope (section 3.1, topic `a5a141bc`).

## Phase 1: user story 1 end to end (spec 2.1, 7.0), in this order

- [ ] T001 **L59** (US1 step 3) A65 + A66: agent-connect help page, hub tests on a fresh clone. Owns: `csi-spl-wui/src/components/ConnectAgentGuide.vue` + its unit test; `doc/help/connect-an-agent.md` + a doc test; the README "another machine" paragraph; `run-all-tests.sh`. Needs: -
- [ ] T002 **L5** (US1 step 4) A13: the runner as a repo variable. Owns: `10_ci-quality.yml` `runs-on` lines. Needs: -
- [ ] T003 **L33** (US1 step 4) A34: estate guard + fork-portability test. Owns: the 8 live-estate workflows, a new iac test. Needs: -
- [ ] T004 **L6** (US1 step 1) A15: `DEPLOY.md` first cut (P1 and P3 as they are today). Owns: `DEPLOY.md`, one README link. Needs: -
- [ ] T005 **L31** (US1 step 4) A46: contributor dev stack (one sub-lane per research 01 action). Owns: `do_setup_app_inf`, `docker-compose.yml` port defaults, a new `do_lde_up`. Needs: -
- [ ] T006 **L32** (US1 step 4) A35: reusable gate for push and pull request. Owns: wf 10, 11, a new reusable workflow. Needs: L5
- [ ] T007 **L45** (US1 step 3) A49 + A50: installer fleet opt-in, errors and defaults. Owns: `spool-install/install.sh` and its tests. Needs: -
- [ ] T008 **L55** (US1 step 4) A60 + A61: trunk ruleset (owner go), contributor rules. Owns: `oss-public-settings.func.sh`, wf 11, CONTRIBUTING, SECURITY.md, `.github/` templates. Needs: D16
- [ ] T009 **L3** (US1 step 3) A4a: `spool` CLI release assets on `stable-*`. Owns: a job in `55_release-stable.yml`. Needs: -
- [ ] T010 **L8** (US1 step 3) A4b: `install.sh` downloads the CLI, builds as a fallback. Owns: `spool-install/install.sh` and its tests. Needs: L3
- [ ] T011 **L26** (US1 step 2) A27: membership `access_until`. Owns: a new migration, the hub auth check, Members pane. Needs: -
- [ ] T012 **L17** (US1 step 3) A5: join tokens, its own spec first (037 T005). Owns: a new spec, then hub, WUI and CLI lanes. Needs: D3
- [ ] T013 **L1** (US1 step 5) A3: WUI runtime config for compose and Hosting (`config.json` read at boot; the build args become lde defaults); one lane with research 06 W1. Owns: `csi-spl-wui/src/docker/wui.Dockerfile`, the WUI boot config. Needs: -
- [ ] T014 **L25** (US1 step 5) A21: one hub image. Owns: `build-push-hub-image.func.sh`, the cloud Dockerfile. Needs: -
- [ ] T015 **L2** (US1 step 5) A1a: a CI job publishing the hub and web images to GHCR (public) on `v*` / `stable-*`. Owns: a new `.github/workflows/56_*.yml`. Needs: L25, D2 answered
- [ ] T016 **L7** (US1 step 5) A1b: compose pulls images by default. Owns: `docker-compose.yml`, `.env.example`. Needs: L1, L2
- [ ] T017 **L9** (US1 step 5) A2: `spool-up` with preflight. Owns: a new `csi-spl-orc/src/bash/run/spl-self-host-up.func.sh` + test. Needs: L7
- [ ] T018 **L30** (US1 step all) A28 + A29: contributor page, then the newcomer test. Owns: `CONTRIBUTING-WITH-AGENTS.md`; a results file in this dir. Needs: L8, L17

## Phase 2: wave 1

- [ ] T019 **L4** A8: generic name validations, project id from cnf. Owns: the 7 steps' `02-variables.tf`, `gcp-001`, `resolve-oap.func.sh`, conf-validator `EnvModels/cloud.py`. Needs: -
- [ ] T020 **L21** A19: full dry run + preflight. Owns: gcp-000..004, a new `gcp-bootstrap-preflight.func.sh` + tests. Needs: -
- [ ] T021 **L22** A24: deploy workflows name envs and secrets from cnf. Owns: the env/secret lines of wf 20 and wf 30. Needs: -
- [ ] T022 **L23** A25: stale deploy text + pinned yq. Owns: the cnf comments, 030 `02-variables.tf`, `build-push-hub-image.func.sh`, wf 20 yq step, the stale 031 rows (wf 20/30, renderer, 019 vars, `specs/README.md:216`). Needs: -
- [ ] T023 **L34** A44: cnf derivations, byte-identical (C4, C5 first). Owns: `csi-spl-cnf`, `spl-merged-cnf.func.sh`. Needs: -
- [ ] T024 **L49** A55: true release notes + forward-only gate (R2 is a live bug, XS). Owns: `release-stable.func.sh`, a new test. Needs: -
- [ ] T025 **L58** A64: digest pins + installer checksums. Owns: the 8 Dockerfiles, `install.sh` and its tests. Needs: -

## Phase 3: wave 2

- [ ] T026 **L10** A10: org optional. Owns: `gcp-001-create-project.func.sh` + test. Needs: -
- [ ] T027 **L11** A11: `do_spl_gh_wire`. Owns: a new action + test. Needs: -
- [ ] T028 **L12** A12: optional steps in cnf. Owns: cnf `steps.*`, `tf-sweep-steps.func.sh`. Needs: -
- [ ] T029 **L13** A14: tpl-gen without a token. Owns: `setup-tpl-gen.func.mk`. Needs: -
- [ ] T030 **L24** A18 + A20: keyless bootstrap, project-only key path. Owns: `gcp-002-*.func.sh`, `do_tf_init`, `do_gcp_account` + tests. Needs: L21
- [ ] T031 **L35** A30: secrets check + seed-all. Owns: two new actions + tests. Needs: -
- [ ] T032 **L36** A42: state bucket action, reviewed-plan apply, validate-all. Owns: `tf-plan`, `tf-apply`, a new action, step 000. Needs: -
- [ ] T033 **L37** A36 + A37: no-tree compose, stable proven on the client path. Owns: `docker-compose.yml`, `pg-init.sh`, wf 55. Needs: L7
- [ ] T034 **L38** A40: no-domain docs, plain-http refusal, one name variable. Owns: README, hub-init entrypoint, WUI banner. Needs: -
- [ ] T035 **L39** A45: migration lint + schema-head guard. Owns: pre-push part, `spool serve`. Needs: -
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

## Owner decisions these tasks wait on

D16 (trunk ruleset) gates L55; D5/D6 (keyless bootstrap) shape L24; D10/D11 gate L40; D13 (a test fork) gates research 12 C5 inside L19; questions 1-21 are in spec 8.1 and 8.2. A lane whose decision is still open builds behind its default and says so.
