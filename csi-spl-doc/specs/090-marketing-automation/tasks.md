# 090 Marketing Automation: tasks

What gets built (`spec.md` v0.3.3 holds the behaviour, and §13 records the panel consensus). Each task is one lane: one agent, one task, the files it owns, the tests that prove it, and what it depends on. Status words: `../README.md` §2.3. Topic: `f0c3927e-12fd-4602-9ac6-5ec96bdcabaa`. The owner's rule (msg `e76278e3`) is to start building once the panel agrees, without waiting for the owner's go. The owner questions in `spec.md` §11 are information only, not a gate.

Paths: `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`, `api/` = `csi-spl-api/src/go/spool-hub-api/`, `wui/` = `csi-spl-wui/`, `doc/` = `csi-spl-doc/`, `iac/` = `csi-spl-iac/`, `cnf/` = `csi-spl-cnf/csi-spl/`.

## Phase 1 platform: LinkedIn personal feed

Phase 1 posts to **one** platform from start to finish: the **LinkedIn personal member feed**, for the Spool Hub project workspace only. Why this one:

- `w_member_social` ("Share on LinkedIn") is self-serve and free and needs no app review. The other platforms need a paid tier (X) or weeks of business verification and app review (Facebook Pages, LinkedIn company pages).
- The member signs in to their own account and approves each post. That is exactly the "delegated posting with consent" rule in `spec.md` §2.
- It has the fewest moving parts. There is no refresh token, so nothing needs rotating, and the only lifetime rule is re-consent every ~60 days, which T006 handles with a reminder.

## Rules for every task

- **Gate before every push, and again after the mandatory rebase**: run `cd csi-spl-iac && ./run -a do_check_pre_push`, plus the gate for each tree the task touches (repo `CLAUDE.md`):

  | tree | gate |
  |---|---|
  | `rdb/`, `api/internal/store/` | `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (store tests on Postgres) |
  | `api/` | `bash csi-spl-api/src/bash/tests/run-all-tests.sh`; new Go functions pass the clean-code gate (≤ 80 lines, depth ≤ 4, ≤ 8 params) |
  | `wui/` | `pnpm run test:unit`, `pnpm run typecheck`, the task's e2e against a generated mock bundle (`BASE_URL=<bundle> pnpm run test:e2e <names>`), and the initial-chunk check (`src/node/test/bundle-size.mjs`, `ci_initial_gzip_kb`) |
  | `iac/`, `cnf/` | `ENV=<env> ./run -a do_tpl_gen` then `git diff --exit-code`; `./run -a do_check_pre_push_lint`; `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` |
  | `doc/` | `./run -a do_check_dist_hygiene`, `lint-mdlinks` |

- **Deploy dev and prd, then prove it live.** A hub change ships through wf 20. Prove it with `/version` on dev and prd showing the commit's `v<X.Y.Z>`. A WUI change ships through wf 30. Prove it with `build.json` (and the footer) on dev and prd. Then run `./run -a do_check_deploy_lag`, and report `SHA=<sha> ENV=<env> ./run -a do_release_note_link` for both envs. A migration ships through `ENV=dev DRY_RUN=0 ./run -a do_spl_db_bootstrap`. For prd, send the exact command to the orchestrator and wait. Prove it with `do_spl_db_query` on `information_schema` on both envs. Terraform runs only through the tf-runner make path, with the per-env service-account key. It needs the owner's go for every apply, and it is proven by a clean `make do-tf-plan` on dev and prd after the apply.
- **Secrets**: OAuth tokens are stored only as KMS-envelope ciphertext. They are never written to git, terraform state, a log, a spool message or an API answer. The LinkedIn client secret lives only in Secret Manager, and its version is added out of band. **A missing key or secret blocks the task.** It is never optional, and it is never worked around with a stub in prd. Report it with `DESK_KIND=blocker`.
- **GCP**: use only the per-environment service account (`~/.gcp/.csi/key-csi-spl-<env>.json`), with `--account` on every call. Never use the owner account.
- Phase 1 is on only for the workspaces listed in cnf `marketing.workspaces` (the Spool Hub project workspace). Everywhere else, the routes answer `404` and the WUI hides the section.
- Plain English, "workspace" in prose (the SQL column stays `tenant_id`, as in the rest of the hub schema). No host literals: read `BASE_DOMAIN` or the cnf.

## Order and parallelism

```
T002 iac KMS + secret slots ────────────────────────────────┐ (live only)
T003 rdb ─► T004 store ─┬─► T006 connect API ──┬─► T009 dispatcher ─► T010 audit read API ─┬─► T012 review UI ─► T013 help
T005 envelope seal ─────┘   (T005 too)         │                                         │
                        ├─► T007 draft queue ──┤                                         │
                        └─► T008 approval API ─┘                                         │
                            T006 ──────────────────────────────────────────────► T011 accounts UI ─┘
```

The serial spine is T003 -> T004 -> T008 -> T009 -> T010 -> T012 -> T013. T002, T003 and T005 own separate files and can start at once. T006, T007 and T008 can run in parallel after T004 (T006 also needs T005). T011 can run in parallel with T009 and T010 once T006 is on master.

---

### Phase 0: Specification
- [x] T001 **spec + tasks** (c-286): `spec.md` v0.3.3 (AC-08 fixed: a stale draft stays `draft` and gets a `draft_stale` audit event) and this file.

### Phase 1: LinkedIn personal feed, end to end

- [x] T002 **KMS key + LinkedIn secret slots** (iac) (c-290, 04fcf59b7; **apply pending owner**). Plans clean on dev and prd: 001 +1, 055 +4, 030 +2 ~1 (the ~1 is pre-existing hub drift), 0 destroy. Also in 055: `serviceAccountTokenCreator` on the runtime SA for the env's project SA, so `do_spl_kms_check` can act as the runtime SA. The secrets are injected as `SPOOL_HUB_MARKETING_LINKEDIN_CLIENT_ID` / `_CLIENT_SECRET` only once cnf `marketing.linkedin.inject` is `"true"`, after both versions exist.
  - **Build**: a new terraform step `iac/src/terraform/055-gcp-kms-marketing/` with one key ring and one symmetric `ENCRYPT_DECRYPT` key, rotated every 90 days. Grant `roles/cloudkms.cryptoKeyEncrypterDecrypter` on that key only to the hub runtime SA (its email comes from cnf). Add `cloudkms.googleapis.com` to step 001. Add the cnf block `marketing` (`workspaces`, `kms_key`, `linkedin.client_id_secret`, `linkedin.client_secret_secret`, `post_hour_local`) in `cnf/all.env.yaml`, with env overrides if any. Add both LinkedIn secret ids to cnf `env.auth.social.secret_env` / `hub.secret_env`, so 030 creates the empty slots and injects them.
  - **Owns**: that step dir, the `marketing` cnf keys, the rendered tfvars for 001/030/055, and the step-001 API line.
  - **Tests**: tpl-gen with no diff, iac suite, lint.
  - **Depends**: none. **Parallel** with T003 and T005.
  - **Needs from the owner**: the go for `make do-provision` of steps 001, 055 and 030 on dev and prd (a new API, a new KMS key, an IAM binding and new secret slots). Also a **LinkedIn developer app** with the products "Share on LinkedIn" (`w_member_social`) and "Sign In with LinkedIn using OpenID Connect" (`openid profile`), and the redirect URI `https://<BASE_DOMAIN>/v1/marketing/linkedin/callback` for each env. Its client id and client secret are added as Secret Manager versions on dev and prd, out of band. **Done 2026-10-05**: app "Spool Hub", secrets version 1 on dev, prd and csi-spl-all; see `linkedin-app-setup.md`.
  - [x] **Inject + workspaces, 2026-10-05** (c-333; owner HUM-10 f0c3927e items 1-3; applied by c-001 from d8d2366e):
    - prd: `marketing.linkedin.inject: "true"` (96f6efb6, in `all.env.yaml`). 030 prd applied 2/1/0: the two secret refs, a `secretAccessor` binding per secret for the hub SA, and `SPOOL_HUB_MARKETING_WORKSPACES=spool`. `marketing.workspaces` stays `[spool]`.
    - dev: inject is **held at `"false"`** (0969c7b9, a `dev.env.yaml` override) until the owner answers whether dev may post at all. Workspace `spool` was created with `do_spl_tenant_create` (`TENANT_HOST=0`, box-wui pinned), and `marketing.workspaces` is `[t1, spool]` (97ed6831). 030 dev applied 0/1/0: `SPOOL_HUB_MARKETING_WORKSPACES=t1,spool`.
    - Read-back: re-plan of 030 on both envs = the scaling no-op only. `/version` 200 on both. `do_check_deploy_lag`: hub and wui current on both. `do_spl_secrets_check`: both LinkedIn slots have an ENABLED version on dev and prd (no value read).
    - `/v1/marketing/*` still answers 404 for every workspace on both envs (control `/v1/channels` = 405): the routes are T006 onward and are not built yet.
  - **Deploy + prove**: a clean `make do-tf-plan` for 055 on dev and prd. Then a named check action, `./run -a do_spl_kms_check`, added in this task: it encrypts and decrypts a fixed test string as the runtime SA and prints only OK or FAIL.

- [ ] T003 **rdb migration** `rdb/0126_marketing.sql`. Find the next free number on the sha you build on with `ls csi-spl-rdb/src/sql/postgres/spool-hub | tail -1`. On 65d92246c the last file is `0124_demo_user_role.sql`, and 089's T002 has 0125. If that number is taken, use the next one.
  - **Build**: the four phase-1 tables from `spec.md` §12: `marketing_channels`, `marketing_channel_tokens`, `marketing_posts` and `marketing_post_events`, with `tenant_id` in place of `workspace_id` and `REFERENCES tenants (tenant_id)`. The email subscribers table comes in phase 2.
    - Each table gets ENABLE + FORCE ROW LEVEL SECURITY, `tenant_scope` in the `NULLIF` form and `operator_scope`, exactly as in `0091_member_activity.sql`.
    - `marketing_post_events` is append-only: `REVOKE UPDATE, DELETE` from the runtime role (the role from the owner/runtime split), plus a `BEFORE UPDATE OR DELETE` trigger that raises an error. It has no `ON DELETE CASCADE` from posts or channels.
    - `marketing_posts` gets `post_day date NULL` and `body_sha256 text NOT NULL`.
    - Two unique indexes: `(tenant_id, channel_id, post_day) WHERE status IN ('scheduled', 'published')` for the daily cap (FR-007), and `(channel_id, body_sha256)` so the same text is never posted twice.
    - Add `tenants.marketing_tz text NOT NULL DEFAULT 'UTC'` for the workspace day.
    - **In the same commit**, seed all four tables in `seedTenantAll` (`api/internal/store/crosstenant_test.go`). Without that seed, `TestCrossTenantEveryTable` turns trunk red.
  - **Owns**: that `.sql` file and that seed.
  - **Tests** (on Postgres): `TestRLSPoliciesFailClosed`, `TestCrossTenantEveryTable`, the migration catalogue gate, and a new test that an `UPDATE` or `DELETE` on `marketing_post_events` fails for the runtime role.
  - **Depends**: none. **Serial** (it starts the spine).
  - **Needs from the owner**: nothing (prd bootstrap goes through the orchestrator).
  - **Deploy + prove**: bootstrap dev, then prd via the orchestrator. On both envs, `information_schema.tables` lists the four tables, and `pg_class.relforcerowsecurity` is true for each.

- [ ] T004 **store** `api/internal/store/marketing.go` + `marketing_test.go`.
  - **Build**:
    - Channels: create, get, list, set status.
    - Tokens: put and get **ciphertext only**. The store never sees plaintext.
    - Posts: create a draft, edit (only while `draft`, which re-hashes the text), approve, reject, list by status.
    - Single-flight claim: `UPDATE … SET status='scheduled' WHERE status='approved' AND scheduled_for <= now() … FOR UPDATE SKIP LOCKED RETURNING`.
    - Mark published or failed, the next free `post_day` for a channel, and insert/list events.
    - Every status change is a guarded `WHERE status = <from>` transition, and it writes its event in the same transaction.
    - Reads run `inTenant` and the sweep runs `asOperator`. A `to_regclass` probe (the `store/agent_seats.go` pattern) returns empty, not 500, while the table is missing on an env.
  - **Owns**: those two files.
  - **Tests** (on Postgres):
    - Two concurrent claims return the post once.
    - An edit after approve is refused.
    - A second scheduled post on the same channel and day hits the cap index.
    - Workspace A cannot read workspace B's channels or tokens.
  - **Depends**: T003 on master and on dev. **Serial**.
  - **Needs from the owner**: nothing.
  - **Deploy + prove**: hub `/version` on dev and prd. Gate: `PRE_PUSH_TIER=full`.

- [x] T005 **envelope seal** (c-291) `api/internal/marketing/seal.go` + `seal_test.go`.
  - **Build**: `Seal(plaintext) -> (ciphertext, kmsKeyID)` and `Open(ciphertext)`. Each token gets its own AES-256-GCM data key, and Cloud KMS wraps that key (the key name comes from cnf `marketing.kms_key`). The code calls KMS through a small interface with an in-memory fake for tests. The plaintext type has a `String()` / `MarshalJSON` that prints `[redacted]`.
  - **Owns**: the `internal/marketing/` package files `seal*.go`, and the KMS client dependency in `go.mod`/`go.sum`.
  - **Tests**:
    - Seal then open gives back the original text.
    - A ciphertext that has been tampered with fails.
    - A log-capture test proves the plaintext never shows up in a `slog` line or a JSON encoding.
  - **Depends**: none. **Parallel** with T003 and T004.
  - **Needs from the owner**: nothing for the code. Live use needs T002's KMS key.
  - **Deploy + prove**: hub `/version` on dev and prd.

- [ ] T006 **connected accounts API** `api/internal/hub/marketing_channels.go` + `_test.go` and its route lines.
  - **Routes**:
    - `GET /v1/marketing/channels`: the caller's own channels; admins see all of the workspace's, but never a token.
    - `POST /v1/marketing/linkedin/connect`: returns the authorize URL with `state` and PKCE, scopes `openid profile w_member_social`.
    - `GET /v1/marketing/linkedin/callback`: exchanges the code, reads the member id from userinfo, seals the token with T005, stores the ciphertext and `expires_at`, and writes `channel_connect`.
    - `DELETE /v1/marketing/channels/{id}`: only the account holder. It calls LinkedIn's revoke endpoint, purges the token row, sets status `revoked`, cancels open drafts and writes `channel_revoke` (AC-02).
  - **Sweep**: an expiry sweep sends a re-consent notice through `internal/notify` 7 days before `expires_at`, and on the day it passes it sets `expired` (US2).
  - **Owns**: that file, its routes, the sweep entry, and the LinkedIn OAuth client `api/internal/marketing/linkedin_oauth.go`.
  - **Tests** (with an httptest fake of LinkedIn):
    - A bad `state` returns `400`.
    - No token text appears in any answer or log.
    - A non-holder cannot disconnect.
    - A workspace outside `marketing.workspaces` gets `404`.
  - **Depends**: T004, T005. **Parallel** with T007 and T008.
  - **Needs from the owner**: the LinkedIn app and its client id/secret (T002) for the live proof.
  - **Deploy + prove**: `/version` on dev and prd. `GET /v1/marketing/channels` answers `200` on both.

- [ ] T007 **daily draft queue** `api/internal/marketing/queue.go` + `_test.go` and its sweep entry.
  - **Build**: once a day, at `marketing.post_hour_local` in `tenants.marketing_tz`, for each active channel, make at most one draft from a real source ("no source, no post", FR-006):
    1. The newest release in `release_notes` (spec 065) with no post yet on that channel.
    2. Otherwise, the first help article (`doc/doc/help/*.md`, read from the help list the hub already serves; if it has none, a `go:embed` of a synced copy, and say which in this file) with no post yet.
    3. Otherwise, nothing: the day is skipped.
  - The text is a fixed template: the title, one or two sentences from the source, and its public link built from `BASE_DOMAIN`. No AI-generated filler. An agent may then edit it through T008.
  - The same text is never drafted twice (`body_sha256`). A draft older than 7 days is flagged stale: it stays `draft` and gets a `draft_stale` event (AC-08).
  - **Owns**: that file and its sweep entry.
  - **Tests**:
    - Quiet day: no draft.
    - A new release beats a help tip.
    - A second run on the same day adds nothing.
    - A stale draft is flagged once and is not scheduled.
  - **Depends**: T004. **Parallel** with T006 and T008.
  - **Needs from the owner**: nothing.
  - **Deploy + prove**: `/version` on dev and prd.

- [ ] T008 **approval API** `api/internal/hub/marketing_posts.go` + `_test.go` and its route lines.
  - **Routes**:
    - `GET /v1/marketing/posts?status=`.
    - `PATCH /v1/marketing/posts/{id}`: edits the text while `draft`. Any workspace reviewer or an agent may edit (`post_edited`).
    - `POST …/approve`: **only the channel's `delegated_by` member** (FR-005, §2.3). A workspace admin gets `403`. Approve sets `scheduled_for` to the next free day at the post hour (cap: AC-07 staggers the second post to the next day).
    - `POST …/reject`.
  - There is no standing grant in phase 1: `standing_grant_id` stays NULL.
  - **Owns**: that file and its routes.
  - **Tests**:
    - Admin approve returns `403`; holder approve returns `200`.
    - Two approvals on one day land on two different days.
    - An edit after approve returns `409`.
  - **Depends**: T004. **Parallel** with T006 and T007.
  - **Needs from the owner**: nothing.
  - **Deploy + prove**: `/version` on dev and prd. `GET /v1/marketing/posts` answers `200` on both.

- [ ] T009 **single-flight dispatcher + LinkedIn post** `api/internal/marketing/dispatch.go`, `linkedin_post.go` + tests, and its sweep entry.
  - **Build**: claim a due post (T004). Open the token in memory only (T005). Then `POST` the LinkedIn Posts API (the `LinkedIn-Version` header comes from cnf; the author is `urn:li:person:<member id>`).
    - On success: `published` with `platform_post_id`, `platform_url` and `published_at`.
    - On failure: back off, and after 3 attempts mark `failed` with `last_error` (no token text). The author is told.
    - An expired token fails at once, without calling LinkedIn (AC-05, AC-06).
    - Each step writes its event (`post_scheduled`, `post_dispatched`, `post_published`, `post_failed`).
  - **Owns**: those files and its sweep entry.
  - **Tests** (with a fake LinkedIn):
    - Two dispatchers running at once post exactly once.
    - A `5xx` is retried 3 times and then marked `failed`.
    - A `401` marks `failed` and notifies the author.
    - No token appears in any log.
  - **Depends**: T005, T006, T008. **Serial**.
  - **Needs from the owner**: the LinkedIn app (T002). The first live post goes to the owner's own feed: they connect their account and approve the post themselves. That approval is the product working as designed, not a separate go.
  - **Deploy + prove**: `/version` on dev and prd. On dev, one approved test post reaches `published` with a `platform_url`.

- [ ] T010 **audit read API** `api/internal/hub/marketing_events.go` + `_test.go` and its route line.
  - **Route**: `GET /v1/marketing/events?post_id=&channel_id=`, newest first. Readable by the workspace admins and by the account holder for their own channel, behind `audit.read` or self.
  - **Owns**: that file and its route.
  - **Tests**:
    - The full lifecycle (connect, draft, edit, approve, schedule, dispatch, publish, revoke) leaves one event per step, in order, each with `body_sha256` where it applies.
    - A non-admin non-holder gets `403`.
  - **Depends**: T009. **Serial**.
  - **Needs from the owner**: nothing.
  - **Deploy + prove**: `/version` on dev and prd. `GET /v1/marketing/events` answers `200` on both.

- [ ] T011 **connected accounts page** `wui/src/pages/tenant-settings/marketing.vue`, its entry in the workspace settings nav, and the `marketing.*` i18n keys in every `wui/i18n/locales/*.json`.
  - **Build**: Connect LinkedIn, then connected status and the expiry date, then Disconnect. Disconnect also shows the link for removing the app in LinkedIn's settings. The page loads lazily and is hidden outside `marketing.workspaces`.
  - **Owns**: those files and `tests/e2e/marketing-accounts.test.mjs` (AC-01, AC-02 against the mock API).
  - **Depends**: T006. **Parallel** with T009 and T010.
  - **Needs from the owner**: nothing.
  - **Deploy + prove**: `build.json` on dev and prd. The initial-chunk check still passes.

- [ ] T012 **review queue + audit list** `wui/src/components/MarketingPostQueue.vue`, `MarketingPostEvents.vue`, mounted on the T011 page.
  - **Build**: drafts with their source link. Edit, approve and reject. The holder sees Approve; others see only Edit/Recommend. Scheduled and published posts show the platform link. The post's event list comes from T010.
  - **Owns**: those two components, their i18n keys and `tests/e2e/marketing-queue.test.mjs` (AC-03, AC-07; an admin sees no Approve on someone else's feed).
  - **Depends**: T008, T010, T011. **Serial**.
  - **Needs from the owner**: nothing.
  - **Deploy + prove**: `build.json` on dev and prd.

- [ ] T013 **help** `doc/doc/help/marketing.md`.
  - **Content**: what it does and what it never does (no passwords, no filler, at most one post a day per channel), connecting and disconnecting LinkedIn, re-consent every ~60 days, the review queue, and who may approve.
  - Add its link in `doc/doc/help/index.md`. Then run `node src/node/help/sync-help.mjs` and commit the public copy under `wui/src/public/help-md/` separately.
  - **Owns**: those files.
  - **Depends**: T012. **Serial**.
  - **Needs from the owner**: nothing.
  - **Gate**: `do_check_dist_hygiene`, `lint-mdlinks`.
  - **Deploy + prove**: `build.json` on dev and prd serves the page.

- [x] T014 **per-workspace switch** (c-334, `spec.md` §15): rdb `0129_tenant_marketing_switch.sql` (`tenants.marketing_enabled`, default off), `store.MarketingSwitch`, hub `marketing_switch.go` (`GET`/`PATCH /v1/marketing/settings`, the `marketingRoute` gate, the `GET /v1/marketing` probe), the cnf allow-list as `SPOOL_HUB_MARKETING_WORKSPACES` (ids or `all`), and the WUI toggle `MarketingSwitch.vue` in General.
  - **Rule for T006..T010**: register every `/v1/marketing` route with `s.marketingRoute(mux, "<METHOD> <path>", h)`, never `mux.HandleFunc`. The gate answers `404` unless the workspace is allow-listed and switched on, and the demo route walk scans it.
  - **Tests**: hub `TestMarketingSwitch*` (on both stores), store `TestMarketingSwitch*` (RLS on Postgres), `hub-marketing-workspaces-030.tst.sh`, and e2e `marketing-switch.test.mjs`.

### Later phases (placeholders, one line each; each gets its own tasks when phase 1 is live)
- [ ] T020 **Phase 2, email newsletter**: transactional provider, double opt-in, RFC 8058 headers, bounce/complaint webhooks, per-release or weekly cadence. Needs from the owner: the provider, the sending subdomain and the postal address (`spec.md` §11 Q4, Q5).
- [ ] T021 **Phase 2, standing grants**: 30-day, one person, one channel, release template only. The grant id is logged on each post.
- [ ] T022 **Calendar linkage**: scheduled posts appear on `/calendar`, and moving one there edits `scheduled_for` (FR-010, AC-04). Depends on 089 T008.
- [ ] T023 **Phase 3, X**: OAuth 2.0 PKCE, rotating refresh tokens, live price check. Needs from the owner: an X developer account and prepaid credit.
- [ ] T024 **Phase 3, Facebook Page and LinkedIn company page**: needs from the owner Meta App Review and Business Verification, plus LinkedIn Community Management API access.

<!-- version: 0.1.0 · updated: 2026-10-05 · last-edit: 2026-10-05T05:30:00Z -->
