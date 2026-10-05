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
- [ ] T009 **3-hour stay** (FR-005): admission writes `access_until =
  admitted + demo.max_stay` (default `3h`); the door answers `401
  demo_expired` after it; a 5-minute sweep closes sockets and drops expired
  memberships and the visitor's personal data. Done: hub + store tests.
- [ ] T010 **return visits and sign-up limits** (Q11, §3.6): at most 2 visits
  per account per day; 3 new demo accounts per client IP per day.

### Phase 3: Privacy, abuse and cost in the hub

- [ ] T011 **pseudonyms** (FR-007): `visitor-xxxx` display names, generated
  avatars, no email in any response to a `demo_user`.
- [ ] T012 **post quota and size** (FR-006): 10 posts/min, 200/day per demo
  user; 4 KiB message cap for `demo_user`.
- [ ] T013 **agent-turn quota** (§3.7): the 21st agent turn of a visit answers
  `429 demo_quota` before any box delivery is built.
- [ ] T014 **DMs to demo agents only** (§3.2): a `demo_user` DM to a human is
  refused in the hub.
- [ ] T015 **exfiltration control** (§3.8): a `demo_user` session reads zero
  rows of another workspace through every read route (`/v1/view/*`, search,
  files, flow, issues).
- [ ] T016 **report / hide / ban** (§3.6).
- [ ] T017 **nightly wipe**: named action `do_spl_demo_wipe` (csi-spl-orc) on a
  schedule; deletes demo messages and topics, re-seeds the channels and the
  pinned welcome.

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

- [ ] T023 **dev on**: cnf `env.demo.enabled: true` for dev, the demo
  workspace created through the 074 operator API by a named action
  (`do_spl_demo_workspace_create`), the owner's walkthrough.
- [ ] T024 **prd on**: only on the owner's explicit go after the dev
  walkthrough.

<!-- version: 0.2.2 · updated: 2026-10-05 · last-edit: 2026-10-05T10:05:00Z -->
