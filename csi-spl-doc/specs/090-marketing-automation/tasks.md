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
    - prd: `marketing.linkedin.inject: "true"` (96f6efb6, in `all.env.yaml`). 030 prd applied 2/1/0: the two secret refs, a `secretAccessor` binding per secret for the hub SA, and `SPOOL_HUB_MARKETING_WORKSPACES=<WORKSPACE>`. `marketing.workspaces` stays `[<WORKSPACE>]`.
    - dev: inject is **held at `"false"`** (0969c7b9, a `dev.env.yaml` override) until the owner answers whether dev may post at all. The workspace was created with `do_spl_tenant_create` (`TENANT_HOST=0`, box-wui pinned), and `marketing.workspaces` is `[t1, <WORKSPACE>]` (97ed6831). 030 dev applied 0/1/0: `SPOOL_HUB_MARKETING_WORKSPACES=t1,<WORKSPACE>`.
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
  - **Rule for T007 and T009 (sweeps, not routes)**: the draft queue and the dispatcher do not pass through `marketingRoute`. Each one must skip a workspace unless it is allow-listed (`marketingListed`) AND `MarketingEnabled` is true. The dispatcher checks this again when it claims a post, so turning the switch off stops a post that is already approved.
  - **Tests**: hub `TestMarketingSwitch*` (on both stores), store `TestMarketingSwitch*` (RLS on Postgres), `hub-marketing-workspaces-030.tst.sh`, and e2e `marketing-switch.test.mjs`.

- [ ] T015 **blog auto-share to the owner's LinkedIn** (c-919, SPL-1634; owner HUM-10, topic `add4fbf4` msgs `06f5fd99`, `489d18e6`: "each time a new publish is done from spool hub to the blog post it should be also posted to my LinkedIn profile", "not even approve it"). It replaces T007, T008 and T012 for this flow: no draft queue and no approval.
  - [x] **Connect path**: rdb `0187_marketing.sql` (the four tables of section 12, `tenant_id`; posts keyed UNIQUE on `(channel_id, source_type, source_ref)`, the events table append-only), `store.Marketing` (`marketing.go`, `marketing_memory.go`), the LinkedIn OAuth client (`internal/marketing/linkedin_oauth.go`), and the hub routes (`hub/marketing_channels.go`):
    - `GET /v1/marketing/linkedin/connect?workspace=<id>`: the one-click link, a 302 to LinkedIn. It runs on the hub's API host, where the member's session cookie arrives. `POST` gives `{authorize_url}` for the WUI.
    - `GET /v1/marketing/linkedin/callback`: verifies the HMAC state (workspace, member, 15 minutes; keyed from the client secret, so any instance checks it), exchanges the code, reads the member id, seals the token (T005), stores the channel with `auto_publish`. The callback arrives through the WUI host's `/api` rewrite with no cookie, so the state is the only proof. No PKCE: LinkedIn offers it to native apps only.
    - `GET /v1/marketing/channels`: the workspace's accounts, never a token.
    - Who: an admin (`tenant.settings`) of an allow-listed workspace with the switch on (T014).
    - cnf `marketing.kms_key.inject: "true"` renders `SPOOL_HUB_MARKETING_KMS_KEY` into 030 (`hub-marketing-kms-key-030.tst.sh`). It reaches the hub only with a 030 apply (owner go). Connect is on only when the client id, the secret and the key are all set; otherwise it answers 503.
  - [x] **Share sweep** (`hub/marketing_share.go`, `marketing/blog.go`, `marketing/linkedin_post.go`; started next to `RunSweeper` in `cmd/spool/hub.go`), every 5 minutes on every hub instance:
    - **Only the owner publishes** (SPL-40; owner HUM-10, topic `add4fbf4` msg `3a3f366b`: only they can post to LinkedIn). It supersedes "not even approve it": the sweep never starts a share. The workspace owner (rbac `TenantOwner`) who connected the channel publishes one live post with `POST /v1/marketing/posts/{id}/publish` (`PublishMarketingPost`). The publish schedules the post's row and shares it through the same claim and dispatch. The sweep then only retries what the owner started. An admin, any other member and an agent's member session get 403. A second publish, or a publish of a baselined post, gets 409 (`TestMarketingShareOnlyTheOwnerPublishes`).
    - **An agent publishes for the owner** (SPL-1855; owner HUM-10, topic `f46301d4` msgs `54795a30`, `c5ed6345`: "you SHOULD be able to push to LinkedIn without me"). It widens SPL-40 for the NEXT posts. The same route called with a box upload token (not the WUI's) is an agent (`AgentPublishMarketingPost`): it names the owner in `X-Spool-Requester`, and every gate of the owner's publish holds. The allow-list is the existing cnf `marketing.workspaces` plus the workspace switch (no new list); the requester must be the workspace owner, the share goes out on THAT owner's connected channel (no channel: 404), and a box joined for another member (its join token's `for_human`) is refused 403. Once per post is unchanged: a second publish, by the agent or the owner, gets 409, and the sweep still starts nothing (`TestMarketingShareAgentPublishesForTheOwner`). The agent's side is `spool marketing-publish <post-id> --for <HUM-id>`, run by `cd csi-spl-orc && ENV=<env> TENANT_ID=<workspace> POST_ID=<id> FOR_HUM=<HUM-id> ./run -a do_spl_marketing_publish` on the agent's desk; it is DRY_RUN=1 by default and then prints the post, its link and the commentary, and publishes nothing.
    - **Emojis** (SPL-1855; owner msg `8c3e0a83`: "add some emojis on the LinkedIn post as well"): `marketing.BlogArticle` leads the commentary's title, summary and link lines with a memo, a light bulb and a pointing hand. None is a little-text reserved character, so `EscapeLittleText` keeps them while it still escapes the title's markup (`TestBlogArticleEmojisSurviveLittleText`).
    - **The owner's button** (SPL-1698; owner msg `f78e3eab`, "Why is it not published?"): Tenant settings -> General shows the owner a "Publish to LinkedIn" list under the marketing switch (`MarketingPublish.vue`). It reads `GET /v1/marketing/posts` (`UnsharedMarketingPosts`, `hub/marketing_posts.go`): the live posts with no row yet on one of the owner's baselined channels, newest first. Same gate as the publish: 403 for anyone but the owner, 404 while marketing is off or no channel is connected, and either one hides the list. Before the first sweep (no baseline) the list is empty. Each row's Publish button calls the publish; a 409 and a 403 show as plain messages (`TestMarketingPostsListsOnlyUnsharedForTheOwner`, e2e `tests/e2e/marketing-switch.test.mjs` steps P1..P5). Both routes answer the browser's CORS preflight.
    - **New** = a post of the LIVE `en` blog index (`<app>/blog-md/index.json`) with no row on the channel yet. The first sweep after a connect records the posts already live as `skipped` (the baseline): connecting never floods the profile with the back catalogue.
    - **Once**: the row is UNIQUE per `(channel, source_type, source_ref)` and a claim moves it to `dispatching` in one guarded UPDATE, so two instances never both call LinkedIn for it (`TestMarketingShareEachNewPostOnce`: two sweeps share nothing, then four racing publishes and sweeps, one share per post).
    - **The share**: `POST /rest/posts` as `urn:li:person:<sub>`, commentary = title, summary and link (little-text escaped), an article card linking to `<app>/blog/<id>`, its thumbnail the post's picture (WEBP re-encoded as PNG, uploaded through the Images API; a picture failure shares without it).
    - **Failures**: a 429, a 503 or a connection that failed before sending is retried (10, then 20 minutes), at most 3 attempts, then failed. Any other answer, and a request whose outcome is unknown (sent, then no answer, or a 500/502/504), fails at once and is never sent again. A final failure is an error log line plus a mail to the member who connected. A 401 expires the channel; its posts wait for the re-connect.
    - **Token lifetime**: 60 days, no refresh token. 7 days before the end, one mail with the one-click re-connect link (`<api>/v1/marketing/linkedin/connect?workspace=<id>`); at the end the channel is expired and new posts wait.
    - **Where it runs**: only where LinkedIn is wired (client id, secret and KMS key all set) and only for an allow-listed, switched-on workspace (T014 sweep rule). dev keeps `linkedin.inject: "false"`, so dev never posts.

### Later phases (placeholders, one line each; each gets its own tasks when phase 1 is live)
- [ ] T020 **Phase 2, email newsletter**: transactional provider, double opt-in, RFC 8058 headers, bounce/complaint webhooks, per-release or weekly cadence. Needs from the owner: the provider, the sending subdomain and the postal address (`spec.md` §11 Q4, Q5).
- [ ] T021 **Phase 2, standing grants**: 30-day, one person, one channel, release template only. The grant id is logged on each post.
- [ ] T022 **Calendar linkage**: scheduled posts appear on `/calendar`, and moving one there edits `scheduled_for` (FR-010, AC-04). Depends on 089 T008.

### Phase 3a: Meta Graph API (Facebook Pages & Instagram Professional)
Added 2026-10-26 (v0.2.2 tasks, SPL-3553) for Facebook Pages and Instagram Professional Content Publishing API (`spec.md` §16, §20, §21; runbook `meta-app-setup.md`).

- [ ] T030 **Meta OAuth app secret slots & cnf infrastructure** (`iac`, `cnf`).
  - **Build**: Add cnf block `marketing.facebook` (`inject`, `client_id_secret`, `client_secret_secret`, `app_id`, `api_version: "v26.0"`). Add Secret Manager empty slots in step 030 (`csi-spl-hub-marketing-facebook-client-id`, `csi-spl-hub-marketing-facebook-client-secret`). Update `csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` to forward `/api/v1/marketing/facebook/callback` to the hub.
  - **Owns**: `csi-spl-cnf/csi-spl/all.env.yaml`, `csi-spl-iac/src/terraform/030-cloud-run-hub/`, `csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh`.
  - **Tests**: `ENV=dev ./run -a do_tpl_gen`, `git diff --exit-code`, lint, `bash csi-spl-iac/src/bash/tests/run-all-tests.sh`.
  - **Red Control**: Local test `csi-spl-iac/src/bash/tests/hub-marketing-facebook-030.tst.sh` verifies that `do_tpl_gen` with `marketing.facebook.inject: "true"` renders the required secret volume mounts and environment variables into `csi-spl-iac/src/terraform/030-cloud-run-hub/`, and fails if `marketing.facebook.app_id` or secret references are absent.
  - **Needs from the owner**: Meta Developer App creation in Meta Business Portfolio, and adding client ID and secret version 1 into Secret Manager on dev and prd (runbook: `meta-app-setup.md`).

- [x] T031 **Hub database schema extensions for Meta channels, media assets & approval hold** (`rdb`, `api/internal/store`).
  - **Landed** (c-434, SPL-3873, 4798d4e0c): rdb `0236_marketing_meta.sql` (0229 and 0234 were taken on master first; the four CHECK swaps and the two columns below, plus `account_type` gains `page` and `business`, `metadata` must be a JSON object, `media_assets` a JSON array, and the events CHECK also gains `post_held` and `post_approved`). Store (`marketing.go`, `marketing_memory.go`): `MarketingChannel.AccountType` and `.Metadata`, `MarketingPost.MediaAssets` (`MarketingMediaAsset`), `ScheduleMarketingPost` holds a post whose `Status` is `awaiting_approval` (event `post_held`), `ApproveMarketingPost` (held -> scheduled, due now, `post_approved`) and `HandOverMarketingPost` (held or scheduled -> published, `platform_post_id = 'manual'`, `post_handed_over`) for T034 and T036. Tests `marketing_meta_test.go` on Postgres (`TestMarketingMetaChannelsRLS`, `...ApprovalHold`, `...HandOver`, `...ChecksRefuse`) and on the Memory store; red control: the same tests on the schema without 0236 fail (`column "metadata" ... does not exist`), and a raw insert of `facebook_page`, `instagram_business` or `awaiting_approval` violates the 0187 CHECKs.
  - **Build**: Migration `0229_marketing_meta.sql` (next free migration after `0228`): swaps `marketing_channels_platform_check` constraint on `marketing_channels.platform` to `CHECK (platform IN ('linkedin', 'facebook_page', 'instagram_business'))` (CHECK constraint swap, not an enum). Swaps `marketing_posts_status_check` constraint on `marketing_posts.status` to `CHECK (status IN ('awaiting_approval', 'skipped', 'scheduled', 'dispatching', 'published', 'failed'))` to provide an explicit approval hold for unapproved posts. Add `metadata jsonb NOT NULL DEFAULT '{}'::jsonb` to `marketing_channels` (storing page ID, Instagram business ID, username, profile picture URL) and `media_assets jsonb NOT NULL DEFAULT '[]'::jsonb` to `marketing_posts` (storing candidate image URLs, dimensions, aspect ratios, and selected flag). Swaps `marketing_post_events_event_type_check` to add `'post_handed_over'`. Update store queries in `internal/store/marketing.go`.
  - **Owns**: `csi-spl-rdb/src/sql/postgres/spool-hub/0236_marketing_meta.sql`, `csi-spl-api/src/go/spool-hub-api/internal/store/marketing.go`, `marketing_meta_test.go`.
  - **Tests**: `PRE_PUSH_TIER=full ./run -a do_check_pre_push`, `TestMarketingMetaChannelsRLS` on PostgreSQL.
  - **Red Control**: Inserting a channel with platform `'facebook_page'` or `'instagram_business'` or post with status `'awaiting_approval'` fails on pre-migration schema; passes on new schema. Attempting cross-tenant read of Meta channel tokens fails closed via RLS.
  - **Depends**: T030. **Serial**.

- [x] T032 **Meta Graph API client for Facebook Pages & Instagram Content Publishing** (`api/internal/marketing`) (c-435, SPL-3875, 47a3790dd). Landed as `meta_client.go` (token exchange, `/me/accounts` by cursor, backoff), `meta_errors.go` (`MetaError`, `MetaKind`: auth / rate_limit with `RetryAfter` / permission / media / not_ready / transient), `meta_publish.go` (Page feed or photo post, container create / poll / publish, local caps of §21.1); token in the Authorization header with `appsecret_proof`, never in a URL or an error. Not wired to a route (T033, T034); tested only against an httptest fake.
  - **Build**: Go package `internal/marketing/meta_client.go`:
    - `ExchangeLongLivedUserToken(ctx, code)`
    - `ListAccounts(ctx, userToken) -> []MetaPageAccount` (with `instagram_business_account`)
    - `PublishFacebookPagePost(ctx, pageAccessToken, pageID, post)`
    - `CreateInstagramContainer(ctx, pageAccessToken, igUserID, media)`
    - `PollInstagramContainer(ctx, pageAccessToken, containerID) -> status`
    - `PublishInstagramContainer(ctx, pageAccessToken, igUserID, containerID)`
    - Exponential backoff retry helper and error code parser (classifying OAuthException 190, rate limits, media validation errors).
  - **Owns**: `csi-spl-api/src/go/spool-hub-api/internal/marketing/meta_*.go`.
  - **Tests**: Unit tests with httptest stub server: `TestMetaOAuthExchange`, `TestFacebookPagePostSuccess`, `TestInstagramTwoStepPublish`, `TestMetaTokenExpiredErrorHandling`.
  - **Red Control**: Submitting Instagram publish with unpublished container or media error returns typed error; verified in `TestInstagramContainerErrorFailsTerminal`.
  - **Depends**: T005 (KMS envelope seal). **Parallel** with T031.

- [ ] T033 **Personal settings Meta OAuth connect & callback endpoints** (`api/internal/hub`).
  - **Build**:
    - `GET /v1/marketing/facebook/connect?workspace=<id>`: 302 to Meta OAuth dialog with scopes `pages_show_list,pages_read_engagement,pages_manage_posts,instagram_basic,instagram_content_publish`.
    - `POST /v1/marketing/facebook/connect`: Returns `{authorize_url}` for WUI.
    - `GET /v1/marketing/facebook/callback`: Validates HMAC state, exchanges code for long-lived user token, queries `/me/accounts`, seals Page Access Tokens via KMS, stores channels in `marketing_channels`.
    - `GET /v1/marketing/facebook/pages`: Lists authorized Pages and connected Instagram accounts available for workspace connection.
  - **Owns**: `csi-spl-api/src/go/spool-hub-api/internal/hub/marketing_meta_channels.go`.
  - **Tests**: `bash csi-spl-api/src/bash/tests/run-all-tests.sh`, route tests against `fakeidp`.
  - **Red Control**: Missing or tampered `state` parameter returns `400 bad_state`. Connecting non-allowlisted workspace returns `404`.
  - **Depends**: T031, T032. **Serial**.

- [ ] T034 **Publishing approval & dispatcher for Facebook & Instagram** (`api/internal/hub`).
  - **Build**: Extend hub dispatcher and manual publish API:
    - Extend `POST /v1/marketing/posts/{id}/publish` to support Facebook Page and Instagram channels: transitions post from `'awaiting_approval'` to `'scheduled'` with `next_attempt_at = now()`.
    - Background worker single-flight dispatch: claims due posts using `ClaimMarketingPosts` (`FOR UPDATE SKIP LOCKED` and `RETURNING`), opens KMS sealed token in memory, dispatches via `meta_client.go`, stores `platform_post_id` and permalink.
    - Enforces Instagram 100 posts/24h rolling rate limit and daily 1 post/day channel cap.
    - Handles OAuth token invalidation (OAuthException 190) by updating channel status to `expired` and sending re-consent alert.
  - **Owns**: `csi-spl-api/src/go/spool-hub-api/internal/hub/marketing_meta_dispatch.go`.
  - **Tests**: Concurrency tests: two racing dispatchers claim post exactly once; rate limit mock tests; approval hold test.
  - **Red Control**: An unapproved post with status `'awaiting_approval'` on an `auto_publish = false` channel is never claimed by `ClaimMarketingPosts`; calling publish API transitions it to `'scheduled'` permitting exactly one claim. Second dispatch call for same post returns `409 Conflict`.
  - **Depends**: T032, T033. **Serial**.

- [ ] T035 **WUI connected accounts & management for Facebook & Instagram** (`wui`).
  - **Build**: New component `MarketingAccounts.vue` and update `MarketingPublish.vue`:
    - List connected Facebook Pages and Instagram accounts with profile avatars and status.
    - Connect button triggering OAuth popup / redirect.
    - Disconnect button with confirmation dialog and revocation instructions.
    - Publish queue displaying platform-specific character counters (2,200 for IG, 63,206 for FB) and media previews.
  - **Owns**: `csi-spl-wui/src/components/MarketingAccounts.vue` (new), `MarketingPublish.vue` (update), `tests/e2e/marketing-meta-accounts.test.mjs`.
  - **Tests**: `pnpm run test:unit`, `pnpm run typecheck`, E2E test verifying account listing and disconnect flow.
  - **Red Control**: Connecting account without Page Admin task displays permission error banner; disconnect purges channel from UI state.
  - **Depends**: T033, T034. **Serial**.

### Phase 3b: Customer Manual Draft Handover & Messaging Deep Links
Added 2026-10-26 (v0.2.2 tasks, SPL-3553) for customer draft handover (`spec.md` §17, HUM-23 input) and Viber/WhatsApp deep links (§18, §19).

- [ ] T036 **Customer draft handover & photo selection UI (HUM-23 design)** (`api`, `wui`).
  - **Build**: Component `MarketingDraftHandover.vue` and hub endpoint:
    - Displays platform badges (Facebook, Instagram, LinkedIn, Viber, WhatsApp).
    - Photo selector gallery: Displays candidate images with multi-select checkboxes (1 to 10 photos).
    - 1-click "Download Selected Photos" (ZIP archive or single download).
    - 1-click "Copy Caption & Hashtags" with clipboard copy toast.
    - Dedicated Viber Short Variant generator ensuring headline + link <= 200 characters.
    - Deep-link launch buttons: "Open Instagram Web / App", "Open Facebook Composer", "Open WhatsApp Web / App", "Open Viber Desktop / App".
    - Hub route `POST /v1/marketing/posts/{id}/manual-publish` updates status to `published`, sets `platform_post_id = 'manual'`, `published_at = now()`, and writes audit event `post_handed_over`.
  - **Owns**: `csi-spl-api/src/go/spool-hub-api/internal/hub/marketing_manual_publish.go`, `csi-spl-wui/src/components/MarketingDraftHandover.vue`, `tests/e2e/marketing-draft-handover.test.mjs`, i18n keys in all 19 locales.
  - **Tests**: `bash csi-spl-api/src/bash/tests/run-all-tests.sh`, `pnpm run test:unit`, `pnpm run typecheck`, E2E test verifying photo toggle and clipboard copy.
  - **Red Control**: Unchecked photos are excluded from download pack; clipboard copy verifies full formatted string; bundle size increase guard verifies `MarketingDraftHandover.vue` adds < 15 KB uncompressed (< 5 KB gzipped) to marketing bundle.
  - **Depends**: T031 (migration 0236 for post_handed_over event). **Serial**.

- [ ] T037 **One-click fallback & deep link generator for FB, IG, Viber & WhatsApp** (`api/internal/hub`, `wui`).
  - **Build**:
    - Hub endpoint `GET /v1/marketing/posts/{id}/share-links` returns pre-rendered share URLs:
      - Facebook: `https://www.facebook.com/sharer/sharer.php?u=<url>`
      - Viber: `viber://forward?text=<urlencoded_text>` (clamped to <= 200 chars to respect Viber client limit)
      - WhatsApp: `https://wa.me/?text=<urlencoded_text>`
      - Instagram: Client-side copy-caption + download pack (no web intent exists).
    - WUI integration in `BlogShareRow.vue` and `MarketingDraftHandover.vue`.
  - **Owns**: `csi-spl-api/src/go/spool-hub-api/internal/hub/marketing_share_links.go`, `csi-spl-wui/src/utils/marketing-share-links.mjs`.
  - **Tests**: Unit tests validating exact URL encoding, protocol prefixes, absence of deprecated parameters (e.g. no `quote=` on Facebook), and verifying Viber prefill text is clamped/formatted to <= 200 characters with headline and link intact.
  - **Red Control**: Passing raw unencoded Unicode characters to deep link generator fails URL validation test; Viber link generator fails if output exceeds 200 characters.
  - **Depends**: T031. **Parallel**.

- [ ] T038 **Meta App Review submission & live verification** (`doc/manual`).
  - **Deliver**: Detailed owner submission guide and verification package:
    - 2-minute video screencast script demonstrating OAuth login, Page connection, post drafting, human review, and live publishing.
    - Test user credentials and test Facebook Page setup instructions (with security note never to commit credentials to git or logs).
    - Submission text for `pages_show_list`, `pages_read_engagement`, `pages_manage_posts`, `instagram_basic`, and `instagram_content_publish`.
  - **Owns**: `csi-spl-doc/specs/090-marketing-automation/meta-app-review-submission.md`.
  - **Tests**: Executable test `csi-spl-doc/src/bash/tests/meta-app-review-package.tst.sh` verifies required permission justifications (`pages_show_list`, `pages_read_engagement`, `pages_manage_posts`, `instagram_basic`, `instagram_content_publish`), video screencast script, and test user steps are present and non-empty.
  - **Red Control**: Missing permission justification or incomplete test user reproduction steps in `meta-app-review-submission.md` fails `csi-spl-doc/src/bash/tests/meta-app-review-package.tst.sh` with exit 1.
  - **Needs from the owner**: Recording the video screencast on live staging/dev environment and clicking "Submit for Review" in Meta Developer Portal.
  - **Depends**: T035. **Serial**.

### Phase 4: Extended Platforms
- [ ] T040 **Phase 4, X (Twitter)**: OAuth 2.0 PKCE, rotating refresh tokens, live price check. Needs from the owner: an X developer account and prepaid credit.
- [ ] T041 **Phase 4, LinkedIn company page**: needs from the owner LinkedIn Community Management API access and business verification.
- [ ] T042 **Phase 4, Viber Channels 1-Way Post API**: high-volume broadcast channel support via Channel Auth Token.

<!-- version: 0.2.2 · updated: 2026-10-26 · last-edit: 2026-10-26T12:50:00Z -->
