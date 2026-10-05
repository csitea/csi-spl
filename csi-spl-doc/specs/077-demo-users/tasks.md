# 077 demo users: tasks

Authority for what is built (`spec.md` holds the behaviour). Each task names
its lane, the files it owns and its done check. Status vocabulary:
`../README.md` §2.3. Owner answers: `spec.md` §1.1 (Q1, Q5) and §9.

Rules for every task (owner Q8, spec §3.10):

- The flag is **OFF everywhere** until the owner's go: hub env
  `SPOOL_HUB_DEMO_ENABLED` (cnf `env.demo.enabled`), default `false` in dev and
  prd. With it off a `demo_user` membership grants nothing and every
  demo-only route answers `404`.
- **dev first**: the flag is turned on in dev for the owner's walkthrough;
  prd only on the owner's explicit go.
- Every deny is enforced **in the hub**; the WUI only hides (025 FR-008).
- The owner's contact address is never written into the repo
  (`<DEMO_CONTACT_EMAIL>`; tests use `contact@example.com`).
- Still open for the owner, built on the recommended answer and kept out of
  the first slices: **Q3** (dedicated demo agents on a throwaway machine) and
  **Q6** (the vendor cap amount).

---

### Phase 0: Specification

- [x] T001 **spec v0.2** (c-223, landed by c-251): `spec.md` with the owner
  answers of §1.1.

### Phase 1: Hub role, deny list, demo workspace (slice 1, flag OFF) — lane c-251

- [x] T002 **rdb migration** (c-251): `0124_demo_user_role.sql`: the role
  `demo_user` (`topics.read`, `notes.send`, `agents.command`, `docs.read`)
  and the four
  new permissions `files.write`, `topics.manage`, `self.keys`,
  `channels.edit`, granted to every existing role in the same
  file so no real member loses anything (FR-001, FR-002). Done:
  `TestRBACSeedMatchesDefaults` on Postgres.
- [x] T003 **rbac Defaults** (c-251): `internal/rbac/rbac.go` constants,
  catalogue and `Defaults` equal the migration; `demo_user` is NOT in
  `RoleIDs` (the Users page cannot grant it). Done: `internal/rbac` tests.
- [x] T004 **hub deny list** (c-251): `files.write` on `POST /v1/files` and
  `DELETE /v1/files/{id}` for a WUI socket's upload token (G1); `self.keys`
  on `/api/v1/auth/keys` and `/api/v1/auth/events` writes (G2);
  `topics.manage` on topic move / merge / promote and every issue write (G3);
  `channels.edit` on every channel change (members, agents, invite setting,
  archive, delete): a channel created by `hub` or `wui` let ANY member add
  people and agents. Done: hub tests.
- [x] T005 **flag + fence** (c-251): `SPOOL_HUB_DEMO_ENABLED` (default
  `false`) and `SPOOL_HUB_DEMO_WORKSPACE` (default `demo`). A `demo_user`
  membership grants nothing unless the flag is on AND the tenant is the demo
  workspace; no member route grants `demo_user`; the demo workspace's topic
  archive policy is `starter` whatever its row says (G4); `GET /v1/demo`
  answers the demo workspace and its limits, `404` with the flag off. Done:
  hub tests; live `GET /v1/demo` = 404 on dev and prd.
- [x] T006 **route-walk control** (c-251): a hub test walks every mutating
  route registered on the mux and asserts a `demo_user` session is refused
  unless the route is on an explicit allow list; a new route without a
  decision fails it (FR-003). Done: the test, with a CONTROL.

### Phase 2: Join path — next lane

- [x] T007 **open admission** (FR-004, c-260): `AdmitPolicy.OpenWorkspace`: a
  verified Google or Facebook identity (hub env `SPOOL_HUB_DEMO_PROVIDERS`,
  default `google,facebook`; the cnf key `env.demo.providers` lands with the
  flag's cnf wiring in T023) signing in with `tenant=<demo id>` and no invite
  is admitted as `demo_user`, only while the flag is on; a `password` or
  `operator` identity never; an invite still wins; bootstrap never seats an
  owner in the demo workspace; a real member of another workspace is not
  seated (spec 3.8). Done: `TestHumansOpenDemoAdmission`,
  `TestHumansOpenDemoNeverBootstraps` (memory + Postgres),
  `TestStoreBackedOpenDemoAdmission` (auth), `TestLoadHubDemoProviders`.
- [x] T008 **9 live at a time** (FR-006, c-258): admission counts live demo
  memberships under the tenant row lock; the 10th answers `demo_full`. Live =
  a `demo_user` membership whose `access_until` (rdb 0113) has not passed, so
  T009's expiry frees the seat with no change here. Cap: hub env
  `SPOOL_HUB_DEMO_MAX_LIVE` (default `9`, below 1 refused at start; the cnf
  key `env.demo.max_live` lands with T023). An invite and a re-login never
  take an open seat. Done: `TestHumansOpenDemoLiveCap`,
  `TestHumansOpenDemoLiveCapRace` (12 racers, cap 5; memory + Postgres; its
  CONTROL: without the tenant `FOR UPDATE` all 12 are seated),
  `TestStoreBackedOpenDemoFull` (auth, `auth_error=demo_full`),
  `TestLoadHubDemoMaxLive`.
- [x] T009 **3-hour stay** (FR-005, c-321): admission writes `access_until =
  admitted + demo.max_stay` (hub env `SPOOL_HUB_DEMO_MAX_STAY`, default `3h`,
  below 1m refused at start; the cnf key is T018's); the door answers `401
  demo_expired` after it; a 5-minute sweep closes sockets and drops expired
  memberships and the visitor's personal data. Built: store `demo_stay.go`
  (`SweepDemo`, `DemoSeatEnded`), hub `demo_stay.go`. A session signed in to
  the demo workspace whose seat ended, or was swept, gets `401 demo_expired`
  from every `humanTenant` route (the `/v1/view/*` reads, the socket upgrade);
  an open socket's next frame gets a `demo_expired` error and close `4401`.
  The sweep (hub `RunSweeper`, every 5 min) drops the ended `demo_user`
  seat, then in the demo workspace the visitor's `read_marks`,
  `flow_watches`, `message_reactions`, `channel_humans` and
  `member_activity` rows, then the `humans` row (name, email, settings; by
  cascade `human_identities`, `human_keys`, `human_events`,
  `member_clones`) only when no membership is left anywhere, and the
  hub-wide `avatars/<file_id>` blob nobody else carries; it closes the
  visitor's sockets `4401 demo_expired`. Posts stay until the nightly wipe
  (Q10). A seat admitted before T009 (no `access_until`) is given admitted +
  the stay by the sweep. Done: store `TestDemoStayAdmissionWritesAccessUntil`,
  `TestDemoStaySweep`, `TestDemoStaySweepKeepsRealMember`,
  `TestDemoStaySweepEndsOpenEndedSeat` (memory + Postgres, fake clock); hub
  `TestDemoStayDoor`, `TestDemoStaySweepClosesSockets`,
  `TestDemoStayShown`; `TestLoadHubDemoMaxStay`. CONTROLS (run by hand,
  each red): the "no membership left" guard removed = a real member's human
  is deleted; `doorDemoExpired` removed = `401 view_door`; the frame check
  removed = the frame is answered; the socket close removed = the socket
  stays open.
- [x] T010 **return visits and sign-up limits** (Q11, §3.6, c-339): at most 2
  visits per account per day; 3 new demo accounts per client IP per day.
  Built: open admission (store `seatDemoTx` / memory `admitToTenant`), after
  the live cap and before the seat INSERT, in the same transaction, counts in
  rdb 0127 `quota_counts` (no new migration) per UTC day: kind `demo_visit`
  keyed `acct:<sha256(provider|subject)>` (the sweep drops the human, so the
  count outlives it), and on the account's FIRST visit of the day kind
  `demo_signup` keyed `ip:<sha256(client IP)>`. Past the limits:
  `auth_error=demo_visits` / `demo_signups`, nothing written (a refusal rolls
  the takes back with the seat; a `demo_full` counts nothing). A re-login
  inside a live stay is no visit. The auth callback hands the store
  `edge.ClientIP` (`Identity.ClientIP`); a caller with no address skips the
  IP rule. Limits: hub env `SPOOL_HUB_DEMO_VISITS_PER_DAY` (2) /
  `SPOOL_HUB_DEMO_SIGNUPS_PER_IP` (3), below 1 refused at start. WUI: the two
  codes in words on `/login` ("try again tomorrow", every locale). Done:
  store `TestDemoReturnVisits`, `TestDemoSignupsPerIP` (memory + Postgres,
  fake clock); auth `TestStoreBackedOpenDemoLimits` (real sign-in, CONTROL
  another address admits); `TestLoadHubDemoAdmissionLimits`; e2e
  `login-demo-intro` 4b. CONTROLS (by hand, each red): the take removed from
  `seatDemoTx` and the check from `admitToTenant` = the 3rd visit and the 4th
  account are seated; the IP rule off = the 4th account is seated; the
  callback's `ClientIP` line removed = `demo_signups` never fires.

### Phase 3: Privacy, abuse and cost in the hub

- [ ] T011 **pseudonyms** (FR-007): `visitor-xxxx` display names, generated
  avatars, no email in any response to a `demo_user`.
- [x] T012 **post quota and size** (FR-006): 10 posts/min, 200/day per demo
  user; 4 KiB message cap for `demo_user`. Done (c-327): hub
  `demo_post_quota.go` counts a demo_user's browser sends and replies per
  human in rdb 0127 `quota_counts` (kinds `post_min` per UTC minute,
  `post_day` per UTC day; a resend of a stored msg_id is no new post), checked
  in `admit` BEFORE the store write: `429 demo_quota`; limits
  `SPOOL_HUB_DEMO_POSTS_PER_MINUTE` (10) / `SPOOL_HUB_DEMO_POSTS_PER_DAY`
  (200). A demo_user body over 4 KiB is `413 too_large` on send, reply,
  edit (PATCH /v1/messages/{id}) and merge (POST .../merge); every other role
  keeps 64 KiB. Tests: `TestDemoPostQuotaPerMinute` (CONTROL limit 11),
  `TestDemoPostQuotaPerDay` (fake clock, CONTROL limit 201),
  `TestDemoPostQuotaOthersUnaffected`, `TestDemoBodyCap`,
  `TestLoadHubDemoPosts`. CONTROLS (by hand, each red): `demoSend` removed
  from `admit`; `demoBodyFits` removed from the edit, then the merge.
- [x] T013 **agent-turn quota** (§3.7): the 21st agent turn of a visit answers
  `429 demo_quota` before any box delivery is built. Done (c-298): hub
  `demo_quota.go` counts a demo_user's fan-outs and @agent sends per visit
  (window = the membership's created_at) in rdb 0127 `quota_counts`, limit
  `SPOOL_HUB_DEMO_AGENT_TURNS` (default 20); T012 reuses `takeDemoQuota`.
  Tests: `TestDemoAgentTurnQuota` (CONTROL limit 21),
  `TestDemoAgentTurnQuotaOthersUnaffected`, store `TestQuotaCounter`
  (CONTROL: 30 racing takes on 20 take 20).
- [x] T014 **DMs to demo agents only** (§3.2): a `demo_user` DM to a human is
  refused in the hub. Done: `demo_dm.go` refuses `403 demo_dm_human` in
  `wuiSend` (the one send path a browser session has; box sends need a pin,
  no HTTP route creates a message) when the DM's `to`, or any DM end the task
  already holds, is a person other than the sender. `TestDemoDMHumanRefused`
  (memory + Postgres; CONTROL: the same 4 frames by a developer are stored,
  and with the guard removed all 4 are stored).
- [x] T015 **exfiltration control** (§3.8, c-315): a `demo_user` session reads zero
  rows of another workspace through every read route (`/v1/view/*`, search,
  files, flow, issues). Done: `TestDemoExfiltration` signs the visitor in
  through the session door and walks every GET on the mux (hub + auth
  source, 56 routes, 222 requests per host, the sign-in flow excepted) plus
  the two POST reads, on the demo, api and B hosts, every path value naming
  B's rows, B in the query and `X-Spool-Tenant`; B holds a DM topic, a
  channel topic, a file, an issue, a workspace doc and members, all marked.
  The visitor also holds a stray `demo_user` seat in B. Found and fixed:
  `GET /v1/view/locate/{id}` searched that fenced seat and named B's tenant
  (`locate.go`). Fixed in internal/auth (c-317, 16e51626): the auth session listed the
  fenced seat and the tenant switch accepted it; now neither does (403
  not_member). The `authSessionGap` cut in the walk stays (owner). CONTROLS: B's owner reads B's markers through the core routes;
  `demoFenced` off = 11 routes leak; the locate fix reverted = locate leaks.
- [ ] T016 **report / hide / ban** (§3.6).
  - report + hide done (c-331), part A: a 🚩 reaction (demo workspace only;
    a reaction row, so one reporter counts once) hides the message at the
    3rd distinct reporter; a moderator (`members.invite`: admin, biz_owner;
    never `demo_user`) hides / unhides with `PUT` / `DELETE
    /v1/messages/{msg_id}/hidden`, and an unhide sticks against old and new
    reports. Store: rdb 0128 `message_moderation` (`tenant_id`, `msg_id`,
    `hidden`, `set_by`, `set_at`; FK to messages ON DELETE CASCADE, RLS,
    change-stamp trigger). Filter (`hub/demo_moderation.go`): topic page,
    `per_topic`, topic list (a hidden opener takes its row), search
    (messages, topics, files), flow, previews, id links, locate, the message
    door of every message route (404), socket frames (edited, reaction,
    merged, moved; a hide sends `message_deleted`, moderators get
    `message_hidden`). Moderators read it marked `hidden: true`.
    `TestDemoReportHide`, `TestDemoHiddenGoneFromEveryRead` (every hub GET
    route from the source plus the two POST reads; memory + Postgres).
    CONTROLS: threshold removed, search / topic page / previews filter
    removed: each red. Part B (ban: member remove + the address-digest block
    list at admission) is still open.
- [x] T017 **nightly wipe** (c-314): named action `do_spl_demo_wipe` (csi-spl-orc) on a
  schedule; deletes demo messages and topics, re-seeds the channels and the
  pinned welcome. Built: wf 46 runs it nightly (03:41 UTC) on dev then prd; it
  deletes the cnf `env.demo.workspace`'s messages (their topics, deliveries,
  reactions cascade), read marks and topic watches, re-inserts the hub's
  default channels, in tenant RLS scope. Refuses any other workspace (cnf) and,
  in SQL, a workspace with a member outside `demo_user` / `admin` /
  `biz_owner`; a demo that is off is skipped. The pinned welcome is T019's:
  the wipe calls `do_spl_demo_greeting_seed` once it exists. Done:
  `csi-spl-orc/src/bash/tests/demo-wipe.tst.sh` (real Postgres, two CONTROLs).

### Phase 4: Settings and greeting

- [ ] T018 **instance settings** (FR-010): `demo.contact_email`,
  `demo.max_live`, `demo.max_stay`, written by an operator-workspace admin
  only; the hub refuses to enable the demo with an empty contact.
- [ ] T019 **greeting seed** (§3.9): the pinned welcome topic in `#lobby`
  reads the limits and the contact from the settings.

### Phase 5: WUI (after Phases 2 and 4)

- [ ] T020 **demo pages**: the "Try the demo" button, the "demo is full" and
  "time is up" pages, the header countdown, and the denied actions hidden for
  a `demo_user` (the hub already refuses them). Done: `pnpm run typecheck` and
  e2e. Parts:
  - [x] **intro + "Try the demo"** (c-311, owner HUM-10 2026-10-05): on
    `/login`, only while `GET /v1/demo` answers 200, a short intro (what the
    demo is, what a visitor can and cannot do, the live `max_live` from the
    hub) and one "Try the demo with <provider>" per registry provider the demo
    admits (google, facebook), starting with `tenant=<demo id>` (T007). A 404
    leaves the page as before. Lazy chunk, initial JS unchanged. It states no
    stay length (T009) and no pseudonym (T011) until those are live. Done:
    `tests/e2e/login-demo-intro.test.mjs`, `tests/unit/demo-info.test.mjs`.
  - [x] **"demo is full"** (c-311): `auth_error=demo_full` (T008) reads "The
    demo is full right now, try again later" on `/login` instead of "Sign-in
    failed". The contact line waits for T018.
  - [ ] "time is up" page and the header countdown (after T009).
  - [ ] denied actions hidden for a `demo_user`.

### Phase 6: Demo agents (Q3 and Q6 pending the owner)

- [ ] T021 **demo box** (FR-008, Q3 recommended): a throwaway machine seated in
  the demo workspace only with a 073 join token, no git, no cloud key, tool use
  off; the hub refuses a demo-workspace pin for a box pinned elsewhere.
- [ ] T022 **vendor key with a hard cap** (Q6 recommended; the amount is the
  owner's).

### Phase 7: Rollout (Q8)

- [x] T023 **dev on** (c-310): cnf `env.demo.enabled: true` for dev (the
  `env.demo` block of all.env.yaml; do_spl_merged_cnf derives the four
  `SPOOL_HUB_DEMO_*`, 030 applied on dev), the demo workspace `demo` created
  by the named action `do_spl_demo_workspace_create` (idempotent). It wraps
  `do_spl_tenant_create` until 074 T007: the 074 operator API takes only an
  admin browser session, which no SA holds (c-001, 2026-10-05). Proven on
  dev: `GET /v1/demo` 200, the Google and Facebook start for `tenant=demo`
  302 to the IdP, a second create changes nothing. Admission as `demo_user`
  and the cap: the T007/T008 hub tests; the live sign-in is the owner's
  walkthrough.
- [x] T024 **prd on** (owner go HUM-10 c0f96152; c-323, c-001, c-336):
  cnf flip 2aea515b (prd `env.demo.enabled: true`), 030 prd applied by the
  owner 11:14:51Z, workspace `demo` created on prd by the owner 11:26:31Z with
  `do_spl_demo_workspace_create`. Verified 2026-10-05 (n=1 each, read only,
  main checkout 96f6efb6, hub f8677d1e v1.2.7): `GET /v1/demo` 200
  `{"max_live":9,"max_stay":"3h","workspace":"demo"}` (11:31:40Z); Google and
  Facebook start for `tenant=demo` 302 to the IdP, state `"t":"demo"`
  (11:31:41Z); `/login` in headless Chrome shows the T020 intro, the limit 9
  and both "Try the demo" links with `tenant=demo` (11:33:04Z); 030 prd plan
  had no demo change pending (11:32:10Z: 2 add / 1 change, all 090 marketing
  plus the scaling no-op); the dry-run create printed `"created":false`
  (c-001, 14:1xZ). The live Google or Facebook join as `demo_user` is a
  human step: a private window, `/login`, "Try the demo with Google", a test
  account the spec allows (not the owner's).

<!-- version: 0.2.5 · updated: 2026-10-05 · last-edit: 2026-10-05T14:30:00Z -->
