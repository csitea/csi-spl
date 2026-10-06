# 075 repo-edit: tasks

What gets built ([`spec.md`](spec.md) v0.3 holds the behaviour; §14 records the owner's answers O1-O9). Each task is one lane: one agent, one small task (S or M), the files it owns, the proof that it is done, and what it depends on. Status words: `../../README.md` §2.3. Topic: t1 `2e20d6d4-16b7-4be2-b7d7-45c4f1fbf56e`.

Paths: `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`, `api/` = `csi-spl-api/src/go/spool-hub-api/`, `wui/` = `csi-spl-wui/`, `orc/` = `csi-spl-orc/`, `iac/` = `csi-spl-iac/`, `cnf/` = `csi-spl-cnf/csi-spl/`, `wf/` = `.github/workflows/`.

## Rules for every task

- **Gate before every push, and again after the mandatory rebase**: `cd csi-spl-iac && ./run -a do_check_pre_push`, plus the gate of each tree touched (repo `CLAUDE.md`):

  | tree | gate |
  |---|---|
  | `rdb/`, `api/internal/store/` | `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (store tests on Postgres) |
  | `api/` | `bash csi-spl-api/src/bash/tests/run-all-tests.sh`; new Go functions pass the clean-code gate (<= 80 lines, depth <= 4, <= 8 params) |
  | `wui/` | `pnpm run test:unit`, `pnpm run typecheck`, the task's e2e against a generated mock bundle, the initial-chunk budget (load the editor lazily) |
  | `iac/`, `cnf/` | `ENV=<env> ./run -a do_tpl_gen` then `git diff --exit-code`; `./run -a do_check_pre_push_lint`; `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` |
  | `orc/`, `wf/` | `./run -a do_check_pre_push_lint` (shellcheck, actionlint); the orc suite |

- **The feature stays OFF** (`env.docs.repo_edit.enabled: false` on both envs) until T13 switches dev on. Code may land and deploy dark.
- **No test reaches GitHub.** Every Go test uses the fake GitHub of T09; e2e runs with `enabled` off or `github_api` on a stub.
- **GCP**: only the per-env service account (`~/.gcp/.csi/key-csi-spl-<env>.json`), `--account` on every call; never the owner account. Terraform only through the tf-runner make path; every apply needs the owner's go.
- **Secrets**: the App private key lives only in Secret Manager; never in git, cnf, terraform state, a log, a spool message or an API answer. A missing key blocks T13; it is never stubbed in prd.
- No host literal (`BASE_DOMAIN` / cnf); "workspace" in prose (`tenant_id` stays the SQL column).

## Order and parallelism

```
T00 owner: GitHub App (§9.1) ──────────────────────────────────────────────┐ (live only)
T01 iac 030 secret + cnf keys ─► T04 put/rotate key actions ───────────────┤
T02 rdb migration ─► T06 store ─┬─► T07 author + requester ─┐               │
T05 path policy + text gates ───┼───────────────────────────┴─► T08 hub routes ─► T11 WUI editor ─► T12 WUI chip/edits/conflict ─┐
T03 publish exclude + wf 32 ────┤                                                                                                │
T09 GitHub client + fake ───────┴─► T10 worker ──────────────────────────────────────────────────────────────────────────────────┴─► T13 dev proof ─► T14 prd proof
```

- **Start at once, in parallel**: T01, T02, T03, T05, T09 (disjoint files). T00 is the owner's, any time before T13.
- After T01: T04. After T02: T06. After T06: T07. After T06 + T09 + T05: T10. After T05 + T06 + T07: T08.
- T11 can start on a mock of the T08 contract once T08's route table is on master; T12 after T11.
- **T03 must be live on both envs before any overlay is written** (T13 checks it): the publish deletes `.edits/` today.
- The serial spine: T02 -> T06 -> T07 -> T08 -> T11 -> T12 -> T13 -> T14.

---

### Phase 0: Specification
- [x] T-spec **spec v0.3 + this file** (c-388): owner answers O1-O9 folded in.

### Phase 1: owner step

- [ ] T00 **Create the GitHub App** (the OWNER, on GitHub; O8 = go).
  - **Do**: [`spec.md`](spec.md) §9.1 steps 1-7: App with Contents read and write + Metadata read only, webhook off, installed on this repo only, a private key generated into `~/Downloads/` on the box, App ID + installation id + key path posted to the orchestrator.
  - **Done-proof**: the orchestrator has the two ids and the file path; nothing pasted anywhere else.
  - **Depends**: none. **Blocks**: T13 (the key must be in Secret Manager before dev is switched on).

### Phase 2: foundations (parallel)

- [x] T01 **iac: secret slot + cnf keys** (S). Done `b6dec7e1` + `7f7d1f76` (code; the 030 apply on dev/prd is not verified here).
  - **Build**: in `iac/src/terraform/030-cloud-run-hub/`, the secret container `spool-hub-github-app-key` (no version) and `secretAccessor` for the hub runtime SA, injected as `SPOOL_GITHUB_APP_KEY` only when cnf `docs.repo_edit.inject` is `"true"` (after a version exists). cnf block `env.docs.repo_edit` in `cnf/all.env.yaml`: `enabled: false`, `inject: "false"`, `github_app_id`, `installation_id`, `github_api`, `deny` (the 13 globs of spec §5.2), `coalesce_after: 120s`, `coalesce_max: 10m`, rate caps (member 30/h, agent 60/h, workspace 100/day, env 300/day; `dev.env.yaml` env cap 50), `min_member_age: 24h`, `blocked_workspaces: []`; the rendered tfvars; the hub env passthrough of these keys.
  - **Owns**: those cnf keys, 030's new secret resources, the rendered tfvars.
  - **Done-proof**: tpl-gen with no diff, iac suite green, `make do-tf-plan` for 030 on dev and prd shows only the new secret + binding (owner's go for the apply).
  - **Depends**: none.

- [x] T02 **rdb migration** `rdb/0142_repo_doc_edits.sql` (S; 0134 was taken). Done (c-413): migration + `seedTenantAll` seeds, hub-pg suite green. Take the next free number on the sha you build on (`ls csi-spl-rdb/src/sql/postgres/spool-hub | tail -1` -> `0133_...` on `7f67bb604`).
  - **Build**: the four tables of spec §10 (`repo_doc_edits`, `repo_doc_authors`, `repo_doc_author_notices`, `repo_doc_known_authors`); ENABLE + FORCE RLS with the `NULLIF` `tenant_scope` + `operator_scope` on the three tenant tables (`repo_doc_known_authors` is hub-wide, no tenant column); grants for the runtime role; in the SAME commit, seeds in `seedTenantAll` (`api/internal/store/crosstenant_test.go`).
  - **Owns**: that `.sql` and that seed.
  - **Done-proof**: on Postgres: `TestRLSPoliciesFailClosed`, `TestCrossTenantEveryTable`, the migration catalogue gate; applied on dev with `ENV=dev DRY_RUN=0 ./run -a do_spl_db_bootstrap`, prd command sent to the orchestrator; `information_schema` shows the tables on both envs.
  - **Depends**: none.

- [x] T03 **publish: keep overlays, add blob shas, workflow 32** (S). Done `61ad3b4a` (c-414): workflow 32 run 37527265240 green, `tree.json` on dev and prd holds `blob` (565/565).
  - **Build**: `orc/src/bash/run/publish-docs.func.sh`: `spl_docs_upload` excludes `^\.edits/` from `rsync --delete-unmatched-destination-objects`, `do_docs_publish_none` skips `.edits/` the same; `tree.json` files gain `blob` (the git blob sha, `git ls-files -s`). New `wf/32_docs-publish.yml`: `push` to master, `paths: ['**/*.md', '!csi-spl-wui/**', '!.github/**']`, runs `do_publish_docs` for dev then prd, no build, no version; concurrency group `docs-publish-<env>` (`cancel-in-progress: false`), and the SAME group on workflow 30's publish step.
  - **Owns**: `publish-docs.func.sh`, its test `orc/src/bash/tests/publish-docs.tst.sh`, `wf/32_docs-publish.yml`, the concurrency line in `wf/30_wui-build-deploy.yml`.
  - **Done-proof**: orc tests: the rsync argument list carries the exclude; provider none keeps a planted `.edits/x/y.md`; `tree.json` has `blob`; actionlint green; after landing, workflow 32 runs green on its own commit (it touches no `.md`, so run it once with `gh workflow run 32_docs-publish.yml`) and `tree.json` on dev and prd holds `blob`.
  - **Depends**: none. **Must be live on both envs before T13.**

- [x] T05 **hub: path policy + text gates** (S, pure Go, no store). Done `6ce1e20b` (c-404).
  - **Build**: `api/internal/repodocs/` (new package): `Editable(path, tree, deny) (bool, reason)` = spec §5.2 (published, not denied, or new in an editable dir; `ValidDocsPath`); `Gate(old, new []byte) []Hit` = the hygiene patterns on new lines + the secret scan of spec §5.1. The hygiene patterns come from the same list `do_check_dist_hygiene` reads, copied into an embedded file by a sync script with a drift test (the help-sync pattern), so the hub image needs no other tree.
  - **Owns**: that package, the embedded patterns file, its sync script and drift test.
  - **Done-proof**: one sample path per deny row denied; an editable doc, a new file in an editable dir allowed; traversal refused; each gate rule hits; clean text passes; only new lines scanned; the drift test fails when the list changes.
  - **Depends**: none.

- [x] T09 **hub: GitHub App client + fake GitHub** (M, no store). Done `16c64252`: its done-proof tests green (10/10, checked by c-420 before T10). T10 added `Commits` (the commit list) to the client and the fake.
  - **Build**: `api/internal/github/` (new package): JWT from the App key, installation token cached in memory 50 min (never logged); `HeadBlob(path)`, `Commit(path, bytes, author, message, parent)` via blob -> tree -> commit -> `PATCH ref force:false`; `Compare(base, head)`. A reusable `githubtest` fake (httptest) holding an in-memory repo, which refuses a non-fast-forward ref update with 422 and can inject 5xx/401.
  - **Owns**: those two packages.
  - **Done-proof**: tests against the fake: a commit lands with author != committer; a stale parent -> 422 surfaced as `ErrRefMoved`; 401 -> permanent; token reused within 50 min; no key bytes in any log line.
  - **Depends**: none.

### Phase 3: hub

- [x] T04 **iac: `do_put_github_app_key` + `do_rotate_github_app_key`** (S). Done `badbc8a3` (c-415).
  - **Build**: `iac/src/bash/run/put-github-app-key.func.sh` and `rotate-github-app-key.func.sh` (csi-rel naming), as the env's project SA: add a secret version from `KEY_FILE` (refuse a file that is not a PEM private key; never echo it), shred the file only when `SHRED=1` (the prd call); rotate = new version, hub roll, then a reminder to delete the old key in GitHub. Tests with a stubbed gcloud.
  - **Owns**: those two actions and their `.tst.sh`.
  - **Done-proof**: iac suite green; `grep -rn do_put_github_app_key --include='*.sh' .` -> >= 1; a dry run on dev names the secret and prints no key byte.
  - **Depends**: T01 (the secret container). Live run: T00.

- [x] T06 **hub store: edits, authors, notices** (M). Done `7a1f6199` (c-416): store tests on Postgres per method, coalescing never joins two authors, a workspace reads only its rows. Not in T06: the newest-live-overlay read for `GET /v1/docs/{path}` (T08).
  - **Build**: `api/internal/store/repo_doc_edits_postgres.go`: insert (with `next_try_at`, `first_saved_at`), coalesce (same path + author + agent + requester, `queued` only, capped by `coalesce_max`), claim (`FOR UPDATE SKIP LOCKED`, due rows), status transitions, stuck-`pushing` reclaim, rate counts (member/agent/workspace/env), "My edits" list (incl. the requester's agents), authors + notices + known authors CRUD. Tenant calls via `inTenant`, the worker's via `asOperator`.
  - **Owns**: that file and its `_test.go`.
  - **Done-proof**: store tests on Postgres for each method; coalescing never joins two authors; a workspace reads only its rows.
  - **Depends**: T02.

- [x] T07 **hub: author resolution, notice, agent requester** (S). Done `be63f865` (c-419): `repodocs/author.go`, each rule and each 403 reason tested over a fake `Directory`, anchored trailer grep over generated messages = 0. For T08: implement `repodocs.Directory` on the store (sign-in email + verified flag from `humans`/`human_identities`, `Can` via rbac, `SeatHuman` = `agent_join_tokens.for_human` by `consumed_box`); an unverified mapping row is 403 `email_unverified`; an opt-out-only mapping row (no identity) falls through to rules 2-3.
  - **Build**: in `api/internal/repodocs/`: `ResolveAuthor` (mapping row > history match > display name + verified sign-in email; unverified -> `email_unverified`), `NeedsNotice` (no consent row for the resolved identity), `CheckRequester` (spec §4.3 a-e, reading `agent_join_tokens.for_human`), commit subject/body (`docs:` / `docs(dev):`, agent line, no AI trailer).
  - **Owns**: those files and tests.
  - **Done-proof**: each rule and each 403 reason tested; anchored grep `^(Co-Authored-By:|Claude-Session:)` over generated messages = 0.
  - **Depends**: T06.

- [x] T08 **hub routes** (M). Done `3d902622` (c-421): every §10 API answer tested on Postgres (`repo_docs_edit_test.go`), `demo_user` 403, every write route 404 while off; the T10 worker started from `cmd/spool/hub_repo_edit.go` only when enabled. For T13: the hub also needs `SPOOL_HUB_DOCS_EDIT_GITHUB_REPO` (`<owner>/<repo>`, no default; not yet derived in cnf), else editing stays off with a logged reason.
  - **Build**: `api/internal/hub/repo_docs_edit.go`: `PUT /v1/docs/{path}` (session or agent token, `docs.write`, `enabled`, `blocked_workspaces`, `min_member_age`, rate, size, T05 gates, T07 author + 428 + requester, overlay write `.edits/<path>/<edit_id>.md`, row insert), `POST /v1/docs/author-notice`, `GET /v1/docs/edits`, `POST .../retry`, `GET .../conflict`; `GET /v1/docs/{path}` serves the newest live overlay; `tree.json` merged with overlay-only paths. Wiring of the cnf keys into `Options`.
  - **Owns**: that file, its tests, the small edits in `docs.go` and the server wiring.
  - **Done-proof**: hub tests for every answer in the spec §10 API table; `demo_user` 403; with `enabled: false` every write route 404s; deployed dark to dev and prd (`/version` shows the commit's version on both).
  - **Depends**: T05, T06, T07.

- [x] T10 **hub worker** (M). Done `63dad9b7` + `3dc4ad52` (c-420): every spec §12 worker case tested against the T09 fake on Postgres (`hub-pg.tst.sh` runs `internal/repodocs` on its own database), incl. the dev/prd race and no double commit after a reclaim. For T08: start `repodocs.NewWorker(WorkerConfig{Env, Queue: pg, Repo: github.New(...), Bucket: Options.Docs, Deny, Lock: <adapter of pg.LockRepoDocWorker>}).Run` only when `enabled`. Overlays of published rows are deleted by the 30-day sweep (§5.1 audit), not at once.
  - **Build**: `api/internal/repodocs/worker.go`: advisory lock per env, `NOTIFY` + 30 s poll, claim due rows, coalescing window, head check, diff3 merge, gates again on merged bytes, commit via T09, fast-forward only, retries with the backoff of spec §3, 422 ref-moved = transient, stuck-`pushing` reclaim with the "commit naming this edit_id" check, the `published` sweep (one compare per new `tree.json.sha`), the daily `repo_doc_known_authors` refresh, the 30-day orphan-overlay sweep.
  - **Owns**: that file and its tests.
  - **Done-proof**: worker tests against the T09 fake for every case in spec §12 "worker", including two workers on one fake repo (the dev/prd race) and no double commit after a reclaim.
  - **Depends**: T05, T06, T09.

### Phase 4: WUI

- [ ] T11 **WUI: Edit, editor, save, author notice** (M).
  - **Build**: Edit button on `/docs/repo/<path>` for an editable doc (the hub's `tree.json` says which), the editor (lazy chunk), save with `If-Match`, the 428 notice dialog with the exact text of spec §4.2 (i18n key `docs.repoEdit.authorNotice`, 19 locales), the 409/413/422/429 messages.
  - **Owns**: the new editor component(s), its store slice, i18n keys, unit + e2e tests.
  - **Done-proof**: unit tests; e2e on a mock bundle: edit -> notice -> consent -> saved; a denied doc shows no Edit button; typecheck; the initial-chunk budget holds.
  - **Depends**: T08 (contract; may start on a mock once the route table is on master).

- [ ] T12 **WUI: status chip, My edits, conflict view** (M).
  - **Build**: the chip of spec §3 on the doc header, "My edits" (own + own agents' edits, retry), the side-by-side conflict view that re-saves with `base = head`.
  - **Owns**: those components, i18n keys, tests.
  - **Done-proof**: unit tests per status; e2e on a mock bundle for chip transitions, retry and conflict resolve.
  - **Depends**: T11.

### Phase 5: proof

- [ ] T13 **dev proof** (S).
  - **Do**: check T03 is live on dev and prd (`tree.json` has `blob`); key on dev and prd via T04 (the orchestrator runs it); cnf `docs.repo_edit.inject: "true"`, apply 030 (owner's go), then `enabled: true` on dev only; run spec §12 dev proof 1-6.
  - **Done-proof**: the six results with commit shas; `git log -1 --format='%an <%ae> | %cn | %s'` for the proof commit; `gh run list --commit <sha>` shows 10, 15, 32, 64 and no hub/WUI deploy.
  - **Depends**: T00, T03, T04, T08, T10, T12.

- [ ] T14 **prd proof** (S).
  - **Do**: `enabled: true` on prd; one real edit under `csi-spl-doc/`; spec §12 prd proof.
  - **Done-proof**: the commit sha, its author line, workflow 32 green, both overlays `published`, no hub/WUI deploy for that sha.
  - **Depends**: T13.

## Count

15 tasks (T00-T14): one owner step (T00) and 14 agent tasks, 8 S (T01, T02, T03, T04, T05, T07, T13, T14) and 6 M (T06, T08, T09, T10, T11, T12), no L. At most five agents run at once (T01, T02, T03, T05, T09).

<!-- version: 0.3 · updated: 2026-10-06 -->
