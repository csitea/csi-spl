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
- [ ] T006 GET session / `/v1/view/me`: expose the act-as state (target name, expiry, admin) so the
      WUI can render the banner and the "Stop acting as X" copy.
- [ ] T007 **No mail/notifications to real people as the clone** unless explicitly allowed (owner
      safeguard): suppress outbound mail/notification when the sender is `humans.technical`.

## WUI

- [ ] T010 Entry point: on the Users page / a member row, an "Act as {member}" action for holders of
      `members.impersonate`, gated by the same ceiling (never a peer admin/owner).
- [ ] T011 A permanent sticky banner "Acting as {X} (test clone) — Stop" (BuildUpdateBar pattern),
      high z-index, on every route; Stop calls `/act-as/exit` then lands on `/login`.
- [ ] T012 Avatar menu: a "Stop acting as {X}" row directly above Sign out, same action as the banner.

## e2e

- [ ] T020 browser: start → act (a permission-gated action visibly behaves as the target) →
      **Stop acting** → **login page** → normal admin login.

## Open (owner, `spec.md` §8)

1. DMs visible to the clone? (built: **no** — private channels excluded; flip = `CloneStart.IncludeDMs`).
2. Keep the clone's messages at expiry? (built: **keep**, marked test).
3. Expiry length? (built: **60 min** — `hub.DefaultActAsTTL`).
