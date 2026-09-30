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

- [x] T010 Entry point: the admin Members pane (`UserEditPane.vue`) shows "Act as {name}" for holders of
      `members.impersonate` on a manageable, non-self member; a full reload lands as the clone - `e014ecb9`
- [x] T011 `ActAsBanner.vue`: a permanent sticky "Acting as {X} (test clone) — Stop" strip, top of every
      route, z above the top bar, not dismissible; Stop = the sign-out - `e014ecb9`
- [x] T012 Avatar menu: a "Stop acting as {X}" row above Sign out, `session.stopActingAs()` (exit + logout
      → login page) - `e014ecb9`

## e2e

- [ ] T020 browser: start → act (a permission-gated action visibly behaves as the target) →
      **Stop acting** → **login page** → normal admin login.

## Open (owner, `spec.md` §8)

1. DMs visible to the clone? (built: **no** — private channels excluded; flip = `CloneStart.IncludeDMs`).
2. Keep the clone's messages at expiry? (built: **keep**, marked test).
3. Expiry length? (built: **60 min** — `hub.DefaultActAsTTL`).
