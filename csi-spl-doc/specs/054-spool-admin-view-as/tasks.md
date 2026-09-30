# Tasks: 054 Admin "act as a user" via a temporary clone

Spec: `spec.md`. Lane CLE-77797. `[x]` = on trunk; the sha is the commit that landed it.

Owner-decided mechanism (topic `18597eaa`): act-as via a temporary technical clone; leaving is a
sign-out. Backend defaults to the `§8` recommendations, kept configurable, pending the owner's answers.

## Hub + DB

- [x] T001 spec `spec.md` — design + the owner's decision, reworked to the clone design - `dc00bd95`
- [x] T002 rdb `0088_member_clones.sql`: `humans.technical`, `member_clones` (RLS FORCE, tenant +
      operator scope), `members.impersonate` permission (biz_owner + admin); `rbac.Defaults` in step
      (TestRBACSeedMatchesDefaults); `crosstenant_test.go` seeds the new table - `ace19c89`
- [x] T003 store clone lifecycle (`clones.go`): `StartClone` (snapshot role + non-DM channels, mint a
      technical human with no identities), `StopClone` (disable + strip memberships, keep messages),
      `Clone`, `ListClones`, `SweepClones` (operator, global); technical humans excluded from
      `TenantHumans`, `ListMembers`, `CountMembers`, the seat gate - `effca492`
- [x] T004 hub + auth: `POST /api/v1/auth/act-as` (mint clone, re-issue this browser's cookie AS the
      clone), `POST /api/v1/auth/act-as/exit` (sign-out: end clone + clear cookie),
      `GET /v1/audit/clones` (audit.read); the `actAs` adapter enforces `members.impersonate` + the
      strict role ceiling server-side; clone expiry on the sweeper tick - `4e952ad4`
- [x] T005 tests: `TestActAsCeiling` (admin→developer ok; developer→x forbidden; admin→admin,
      admin→owner, →self ceiling; →non-member); `TestCoversAccess`; store `TestStartClone`
      (fidelity + exclusion), `TestStopClone`, `TestSweepClones` - `effca492`,`4e952ad4`
- [x] T006 `/v1/view/me` exposes `act_as` { target_hum, target_name, expires_at } for a clone session
      (gated on the `actas` provider so a normal /me adds no round trip, TestRoundTripsPerRequest);
      `store.Clone.TargetName` via a join - `f0ac16e7`
- [x] T007 **No mail/notifications to real people as the clone** — satisfied by design, not code: the
      only email-to-humans paths are invite mail and auth (verify/reset) mail. A clone has no identity
      or email (no auth mail) and its role is always a strict subset of admin, so it never holds
      `members.invite` (no invite mail); message posts go to box delivery, attributed to the visibly
      "(test clone)"-named human, never to a person's inbox. There is no message/mention/digest→email
      path. **If one is ever added, it MUST exclude `humans.technical` senders.**

## WUI

- [x] T010 Entry point (owner 18597eaa): **avatar menu → "Act as…"** directly above Sign out (admins),
      opening a small `ActAsPicker.vue` UiDialog with a searchable member drop-down (ceiling-filtered) +
      Act as / Cancel. The Settings → Members pane keeps its own "Act as {name}" as a second way - `e5f7fc2b`,`e014ecb9`
- [x] T011 Acting-as indicator (owner 18597eaa, iterated: full-width band → slim band → **pill under the
      avatar**): a ~20px "Acting as {X} · Stop" pill fixed under the avatar (top-right), a 1px danger-colour
      accent border + a red "Stop" link, plus a **warning ring on the avatar** while acting. Rendered in
      `UserMenu.vue`; the old full-width `ActAsBanner.vue` is deleted - `cf92c427`,`f7eb8dc9`
- [x] T012 Avatar menu: a "Stop acting as {X}" row above Sign out, `session.stopActingAs()` (exit + logout
      → login page) - `e014ecb9`
- [x] i18n: all new strings translated into every one of the 19 locales (no English placeholders) - `e5f7fc2b`

## e2e

- [x] T020 `tests/e2e/act-as.test.mjs` (browser): avatar menu "Act as…" above Sign out → picker dialog →
      ceiling-filtered drop-down → confirm → "Acting as X" banner → menu shows "Stop acting as X" →
      Stop → login page → banner gone. Opt-in mock (`act-as-mock.mjs`) stands in for the hub's cookie
      swap, so the other 42 specs are untouched. Full `pnpm run test:e2e` run before push - `e5f7fc2b`
- also fixed a pre-existing TDZ (copied-before-init) that crashed the member-edit pane, caught by the
  `users-admin` e2e - `fa54e491`

## Owner decisions (topic 18597eaa)

- [x] **DMs visible to the clone? NO** (owner, verbatim: "no of course"). Enforced in the HUB, not only the
      UI: `GET /v1/view/topics?dm=true` and `?peer=` return **403** for a clone reader (`readerIsActAsClone`,
      store-based); the read door already drops every DM the reader is not an end of, and a clone is an end
      of none, so DM topic reads, search previews and files are all unreachable. `TestActAsCloneCannotReadDM`
      (Postgres) is the control; the WUI hides the DM rail tab + empties its peers while acting, e2e-asserted -
      `ffaed5c0` (hub), `fa970f36` (wui)

## Still open (owner, `spec.md` §8)

2. Keep the clone's messages at expiry? (built: **keep**, marked test).
3. Expiry length? (built: **60 min** — `hub.DefaultActAsTTL`).
