# Plan: Invite display name and pseudonym (141)

**Spec**: [spec.md](spec.md) · **Lane**: `a-574` · **Issue**: SPL-2025 · **Base**: `d57662969` (SPL-2023)

---

## 1. Phased implementation split

The implementation is partitioned into four independent, sequential implementation phases following the spec-kit conventions. Each phase produces working, tested artifacts that can land independently without holding back other lanes:

| Phase | Scope / Subsystem | Artifacts Produced | Verification / Gate |
|---|---|---|---|
| **Phase 1: Database & Store Core** | PostgreSQL migration, `store.Invite` types, `Postgres.Admit` pre-sign-in resolution, `AuthHooks.Register` avatar suppression | `0199_invite_display_name.sql`, `humans.go`, `humans_postgres.go`, `humans_auth.go` | Unit tests in `invite_pseudonym_test.go` + red control proving zero leakage |
| **Phase 2: Hub API & Auth Routes** | Hub invite handlers, member patch handlers, session token sanitization, self-service lock guards | `rbac.go`, `operator.go`, `tenant_settings.go`, `handler.go`, `openapi.json` | Hub HTTP integration tests in `members_admin_test.go` and `operator_test.go` |
| **Phase 3: Orchestration & CLI** | `do_spl_hub_invite` flags, `do_spl_human_pseudonym` lock integration | `spl-hub-invite.func.sh`, `spl-human-pseudonym.func.sh` | Bash unit tests in `hub-invite-email-send.tst.sh` and `human-pseudonym.tst.sh` |
| **Phase 4: Web UI (WUI)** | Invite form first/last inputs, member edit lock controls, profile lock view | `UserEditPane.vue`, `tenant-users.mjs`, `profile.vue`, `en.json` (i18n) | Vitest unit tests in `tenant-users.test.mjs` + Playwright E2E |
| **Phase 5: Rollout & Verification** | Migration apply, dev testing, prd deploy | Deploy verification | E2E sign-in proof on dev with mock OAuth IdP |

---

## 2. Phase details

### Phase 1: Database schema & Store contracts
1. **Migration `0199_invite_display_name.sql`**:
   - `ALTER TABLE tenant_invites ADD COLUMN IF NOT EXISTS display_name text NULL ...`
   - `ALTER TABLE tenant_invites ADD COLUMN IF NOT EXISTS display_name_locked boolean NOT NULL DEFAULT false`
   - `ALTER TABLE humans ADD COLUMN IF NOT EXISTS display_name_locked boolean NOT NULL DEFAULT false`
2. **Store contracts (`csi-spl-api/src/go/spool-hub-api/internal/store/`)**:
   - Extend `Invite` struct with `DisplayName` and `DisplayNameLocked`.
   - Update `PutInvite` in both `Postgres` and `Memory` stores to persist these fields.
   - Update `ListInvites` / `PendingInvite` to read them back.
3. **Admission logic (`humans_postgres.go` & `humans_auth.go`)**:
   - In `Admit`: probe `tenant_invites` for active invite before calling `recordIdentity`. If found with `display_name`, seed `humans.display_name` with the invite pseudonym, set `display_name_locked`, set `avatar_own = true`, and skip `id.Name`.
   - In `AuthHooks.Register`: if `avatar_own == true && avatar_file_id == ""`, skip `storeAvatar`.
4. **Test suite**:
   - Add `internal/store/invite_pseudonym_test.go` covering normal sign-in, pseudonym sign-in, avatar suppression, and the failing red control.

### Phase 2: Hub API & Auth routes
1. **Invite endpoints**:
   - Update `POST /v1/members/invites` (`rbac.go`) to accept `display_name` and `display_name_locked`.
   - Update `POST /v1/operator/invites` (`operator.go`) to accept `display_name` and `display_name_locked`.
   - Update `GET /v1/members` (`members_admin.go`) to output `display_name` and `display_name_locked` in `inviteRow`.
2. **Member patch & lock**:
   - Update `PATCH /v1/members/{human_id}` (`tenant_settings.go`) to accept `display_name_locked` and `clear_avatar`.
   - Guard profile edits in `handler.go` (`storePreferences`): if `display_name_locked` is true, refuse `SetDisplayName` and `SetOwnAvatar` with `403 Forbidden`.
3. **Session token**:
   - In `handler.go` (`registerLanding`): set `sess.Name` to `humans.display_name`, preventing unmasked IdP name from entering the session cookie.

### Phase 3: Orchestration & CLI
1. **`do_spl_hub_invite`**:
   - Support `INVITE_DISPLAY_NAME`, `INVITE_FIRST_NAME`, `INVITE_LAST_NAME`, and `INVITE_NAME_LOCKED`.
   - Update dry-run output and JSON body construction.
2. **`do_spl_human_pseudonym`**:
   - Add optional `LOCKED=1|0` parameter (default `1`).
   - Update SQL script to set `display_name_locked = :'locked'::boolean`.
3. **Tests**:
   - Extend `csi-spl-orc/src/bash/tests/hub-invite-email-send.tst.sh`.
   - Extend `csi-spl-orc/src/bash/tests/human-pseudonym.tst.sh`.

### Phase 4: Web UI (WUI)
1. **`UserEditPane.vue`**:
   - Add First Name, Last Name inputs and "Lock display name" checkbox under `mode === 'new'`.
   - In `member.manageable`: show display name lock status, allow admins to toggle lock or clear avatar.
2. **`Settings > Profile`**:
   - Display lock indicator and disable self-rename if `display_name_locked` is true.
3. **i18n strings**:
   - Add keys to `en.json` (and translations).

---

## 3. Rollout & Risk Management

### Rollout sequencing
1. Land database migration `0199` and store contracts (backward-compatible, additive).
2. Land Hub API changes.
3. Land WUI and Orchestration updates.
4. Verify on `dev` before promoting to `prd`.

### Risks & Mitigations
- **Multi-tenant accounts**: If an invited person already holds an account in another workspace, `profileEditable` prevents workspace administrators from stomping global settings (`409 Conflict`). In such cases, operator intervention via `do_spl_human_pseudonym` or dedicated workspace aliasing is required.
- **Email identity leakage**: While workspace peers cannot see member emails, workspace administrators can. When full anonymity is required even from administrators, the invitation must be addressed to an anonymous alias.

---

<!-- version: 1.0.0 · updated: 2026-10-15 · last-edit: 2026-10-15T16:35:00Z -->
