# 141: Invite display name and pseudonym (pre-sign-in display name, pseudonym lock, and avatar suppression)

Status: **Ready for review** (Initial specification; issue SPL-2025).  
Authority: this file for the architecture and technical requirements; [plan.md](plan.md) for the phased implementation tasks.  
Status vocabulary: [README.md](../README.md) §2.3. Docs only: this spec builds nothing ([README.md](../README.md) §2.4).  
Topic: Relayed by `c-001`, msg `16e140bd` (HUM-10, operator terminal ~16:2xZ 2026-10-15).

Builds on, and does not repeat:
- [002 box-agent messaging](../002-box-agent-messaging/spec.md) (local folder spool, CLI + MCP contracts)
- [003 message bus](../003-spool-message-bus/spec.md) (the hub, store, viewer API, RLS)
- [005 WUI](../005-spool-wui/spec.md) (Nuxt 3 web interface, theme variables, layout)
- [006 tenant rental / tenancy](../006-spool-hub-rental/spec.md) (tenancy, tenant invites)
- [010 social auth](../010-spool-social-auth/spec.md) (Google + Facebook OIDC/OAuth, `internal/auth`, `AuthHooks.Register`, `Admit`)
- [015 native auth](../015-spool-native-auth/spec.md) (email + password auth)
- [019 LinkedIn auth](../019-spool-auth-linkedin/spec.md) (LinkedIn OIDC auth)
- [025 tenant RBAC](../025-spool-tenant-rbac/spec.md) (roles, `rbac.MembersInvite`, `rbac.MembersRoles`)
- [046 tenant settings](../046-spool-tenant-settings/spec.md) (`profileEditable`, `PATCH /v1/members/{id}`)
- [077 demo users](../077-demo-users/spec.md) (`DemoPseudonym`, `ErrPseudonymFixed`, avatar suppression)
- Migration `0084_invite_provenance.sql` (`ordered_by`, `ordered_via`, `tenant_invites`)
- Migration `0150_human_own_avatar.sql` (`avatar_own`, `idp_avatar_file_id`, `Postgres.SetAvatar`)
- SPL-2023 / c-573 (`do_spl_human_pseudonym` interim operator action)
- [135 work process](../135-work-process/spec.md) (issue workflow, lane integration rules)

`<BASE_DOMAIN>`, `<tenant>`, `<workspace_id>`, `<human_id>`, `<org>`, `<app>`, and `<env>` are placeholders. No estate value appears as a literal to copy. Per the owner's wording rule, this specification uses the term **workspace** throughout the narrative, requirements, user stories, and acceptance scenarios; the term **tenant** appears strictly when citing existing code identifiers, database columns, shell functions, terraform resources, or API headers.

---

## 0. Owner asks and decisions (verbatim, HUM-10)

The owner established the requirements in terminal communication ~16:2xZ on 2026-10-15 (relayed by `c-001`, msg `16e140bd`), verbatim:

> "ok, let's add a functionality that some users might be able to set different first name and last name after gmail or facebook or LinkedInn .. invite"

**Why**: An invited person (such as a customer, external tester, or contractor) must be shown under a short pseudonym so the other workspace members cannot identify who she or he is.

What these instructions bind:
- **B1 (Invite-time display name)**: An invite created via the web UI (Workspace Settings > Users) or via the CLI / orchestration action (`do_spl_hub_invite`) can carry an optional display name (specified as first name and last name in the UI, or a combined display name).
- **B2 (Zero-leakage guarantee applied BEFORE anyone sees the person)**: At the moment the invited person accepts the invitation or signs in for the first time, no Identity Provider (IdP) real name and no IdP profile picture is ever stored in `humans` or in blob storage, nor shown anywhere across the platform (audit logs, emails, notifications, member lists, mentions, or automated desk welcome posts).
- **B3 (Pseudonym lock)**: The pseudonym is optionally locked (`display_name_locked = true`), preventing the invited person from changing it back to their IdP real name or uploading an identifying profile photo. Only workspace administrators or owners (`rbac.MembersInvite` / `rbac.MembersRoles`) and platform operators may unlock or change it.
- **B4 (Provider parity)**: The protection works identically across Google, Facebook, LinkedIn, Microsoft, or native credentials.
- **B5 (Governance & existing members)**: Workspace administrators and owners can configure the pseudonym on new invitations and can retroactively apply or remove pseudonyms and locks on existing members through the Users pane.
- **B6 (Strict privacy boundaries for email)**: The member's email address remains visible only to workspace administrators and owners (`rbac.MembersInvite`). Regular workspace members cannot see emails in the roster, message posts, mentions, or search results.
- **B7 (Verifiability & Red Control)**: The specification defines exact automated test controls proving zero leakage of IdP name and avatar, including a control that fails on current master.

---

## 1. Today, measured (trunk reality and gaps)

An audit of the implementation on trunk (`master`) reveals how identity data is ingested, stored, and displayed today:

### 1.1 Demo visitors vs. normal members

| Member Kind | Display Name Source | Avatar Handling | Self-Rename Allowed? | Code Reference |
|---|---|---|---|---|
| **Demo visitor** | Deterministic pseudonym `visitor-<sha256[:4]>` | IdP avatar discarded; `avatar_file_id = NULL`; deterministic initials drawn | No (`ErrPseudonymFixed`) | `internal/store/demo_pseudonym.go:20-38`, `internal/store/demo_pseudonym_auth.go:9-19`, `internal/auth/demo_pseudonym.go:9-14` |
| **Normal member (Today)** | Seeded from IdP `id.Name` at sign-in (`INSERT INTO humans`) | IdP avatar unconditionally saved to blob storage (`avatars/<sha>`, `t/<tenant>/files/<sha>`); `idp_avatar_file_id` and `avatar_file_id` populated | Yes (`PATCH /api/v1/auth/profile` calls `SetDisplayName`) | `internal/store/humans_postgres.go:176-203`, `internal/store/humans_auth.go:87-89`, `internal/store/humans_postgres.go:593-599` |

### 1.2 The admission leakage flaw in current trunk

In `csi-spl-api/src/go/spool-hub-api/internal/store/humans_postgres.go`:
1. **Premature Name Injection**: When a new user signs in via OAuth, `Admit` executes `findHuman(ctx, tx, id)` followed immediately by `recordIdentity(ctx, tx, id, f, now)`. In `recordIdentity` (lines 176–180):
   ```go
   if !f.linked {
       if err := tx.QueryRow(ctx, `INSERT INTO humans (display_name, email, created_at)
           VALUES (NULLIF($1, ''), NULLIF($2, ''), $3) RETURNING human_id`,
           id.Name, id.Email, now).Scan(&hum); err != nil {
           return "", err
       }
   }
   ```
   The IdP real name (`id.Name`) is directly inserted into `humans.display_name` **before** the invite is ever examined or accepted in `admitTx` / `acceptInviteTx` (lines 315–333).
2. **Unconditional Avatar Storage**: In `csi-spl-api/src/go/spool-hub-api/internal/store/humans_auth.go` (lines 84–89), `AuthHooks.Register` only checks `a.demoSeat(ctx, hum, tenant)`. For any non-demo member, it calls `a.storeAvatar(ctx, hum, tenant, id.Avatar)`. This stores the raw picture bytes into blob storage under `avatars/<sha256>` and `t/<tenant>/files/<sha256>`, and sets `humans.idp_avatar_file_id` and `humans.avatar_file_id` via `SetAvatar` (`humans_postgres.go:593–599`).
3. **Session Cookie Leak**: In `csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go` (lines 498–499), `Session.Name` is seeded with `id.Name`. Even if a display name is later loaded, `sess.Name` in the signed JWT cookie contains the unmasked real name.
4. **Desk Welcome Bot Broadcast**: The background automation in `csi-spl-orc/src/bash/run/spl-desk-welcome.func.sh` runs periodically, querying new admissions (lines 323–325):
   ```sql
   'name', coalesce(nullif(btrim(h.display_name), ''),
                    nullif(split_part(split_part(coalesce(h.email, ''), '@', 1), '+', 1), ''),
                    '')
   ```
   Because `h.display_name` contains the IdP name from step 1, `spl_desk_welcome` generates a greeting via `desk-welcome-text.py` and posts `Welcome @RealName!` directly into the public `#lobby` channel (`spl-desk-welcome.func.sh:141-152`). Once posted into chat, the real identity is visible to every workspace member and permanently recorded in chat history.

### 1.3 Gaps in the interim operator action (`do_spl_human_pseudonym`)

On 2026-10-15, lane `c-573` landed commit `d57662969` introducing `do_spl_human_pseudonym` (`csi-spl-orc/src/bash/run/spl-human-pseudonym.func.sh`). While valuable as an operator break-glass utility, it has specific limitations:
- **Post-Facto Only**: It requires an existing `humans` row. By the time an operator runs it, the user has already signed in, their IdP real name was written to `humans`, the avatar was saved to blob storage, and `#lobby` welcome bots may have already broadcast their identity.
- **Operator-Only**: Requires GCP service account credentials and direct Cloud SQL proxy access; workspace administrators and owners cannot use it through the web UI.
- **Unlocked**: As noted in its own header (line 13–14), it sets `display_name` but does not prevent the user from renaming themselves back to their real name or uploading a new profile photo.

---

## 2. Technical Architecture & Database Schema

### 2.1 Database migration (`0199_invite_display_name.sql`)

A forward-only, additive PostgreSQL migration under `csi-spl-rdb/src/sql/postgres/spool-hub/0199_invite_display_name.sql`:

```sql
-- 0199_invite_display_name.sql - pre-sign-in display name and pseudonym lock.
-- Forward-only, additive.

-- 1. tenant_invites gains optional display_name and display_name_locked
ALTER TABLE tenant_invites
    ADD COLUMN IF NOT EXISTS display_name text NULL
        CONSTRAINT tenant_invites_display_name_check
            CHECK (display_name IS NULL OR (length(display_name) BETWEEN 1 AND 200 AND display_name = btrim(display_name))),
    ADD COLUMN IF NOT EXISTS display_name_locked boolean NOT NULL DEFAULT false;

-- 2. humans gains display_name_locked
ALTER TABLE humans
    ADD COLUMN IF NOT EXISTS display_name_locked boolean NOT NULL DEFAULT false;
```

**Catalog impact**: All `ADD COLUMN` statements specify either `NULL` or a constant default (`DEFAULT false`). In PostgreSQL 11+, constant defaults on non-null columns update the system catalog without rewriting the table. Existing rows remain valid without table locks.

### 2.2 Go store types & interfaces

In `csi-spl-api/src/go/spool-hub-api/internal/store/`:

1. **`Invite` struct** (`humans.go`):
   ```go
   type Invite struct {
       TenantID          string
       Email             string
       Role              string
       InvitedBy         string
       ExpiresAt         time.Time
       OrderedBy         string
       OrderedVia        string
       DisplayName       string // optional pseudonym (1..200 runes)
       DisplayNameLocked bool   // true = user cannot rename or change avatar
   }
   ```
2. **`PendingInvite` struct** (`member_directory.go`):
   Embeds `Invite`, automatically exposing `DisplayName` and `DisplayNameLocked` to `ListInvites`.
3. **`Member` struct** (`member_directory.go`):
   Gains `DisplayNameLocked bool` to inform the admin Users table whether a member's name is locked.
4. **Sentinel errors**:
   - `store.ErrDisplayNameLocked = errors.New("store: display name is locked by administrator")`
   - `auth.ErrDisplayNameLocked = errors.New("auth: display name is locked by administrator")`

---

## 3. Admission & Zero-Leakage Lifecycle (The 7 Decisions)

### 3.1 Decision 1: Invites carry optional first + last display name

#### A. Web UI (WUI)
In `csi-spl-wui/src/components/UserEditPane.vue` (under `mode === 'new'`):
- The invite form gains two input fields:
  - **First name** (`data-test="users-invite-first-name"`, optional)
  - **Last name** (`data-test="users-invite-last-name"`, optional)
  - **Lock display name checkbox** (`data-test="users-invite-lock"`, optional, default checked if a name is entered)
- Form submission normalizes and trims the combined display name:
  ```ts
  const displayName = [firstName.value.trim(), lastName.value.trim()].filter(Boolean).join(' ')
  ```
- Validation enforces `1 <= displayName.length <= 200` and `auth.ValidDisplayName` constraints (no control characters, no line separators, no directional override characters).

#### B. Orchestration / CLI (`do_spl_hub_invite`)
In `csi-spl-orc/src/bash/run/spl-hub-invite.func.sh`:
- Parameters added:
  - `INVITE_DISPLAY_NAME` (optional string, 1..200 characters)
  - `INVITE_FIRST_NAME` / `INVITE_LAST_NAME` (convenience alternatives: if `INVITE_DISPLAY_NAME` is omitted, combined as `"$INVITE_FIRST_NAME $INVITE_LAST_NAME"`)
  - `INVITE_NAME_LOCKED` (optional: `1` or `0`, default `1` when a display name is provided)
- Payload sent to `POST /v1/operator/invites` includes:
  ```json
  {
    "tenant": "t1",
    "email": "invited.person@example.com",
    "role": "developer",
    "display_name": "FirstName LastName",
    "display_name_locked": true
  }
  ```

#### C. Hub API endpoints
1. `POST /v1/members/invites` (`internal/hub/rbac.go:262`):
   - Accepts `display_name` (string) and `display_name_locked` (bool).
   - Validates `auth.ValidDisplayName(body.DisplayName)`.
   - Calls `h.PutInvite(ctx, in, now)`.
2. `POST /v1/operator/invites` (`internal/hub/operator.go:124`):
   - Accepts `display_name` and `display_name_locked`.
   - Populates `store.Invite`.
3. `GET /v1/members` (`internal/hub/members_admin.go:121`):
   - `inviteRow` includes `display_name` and `display_name_locked` so administrators see pending pseudonyms in the directory.

---

### 3.2 Decision 2: Applied BEFORE anyone sees the person (Zero-leakage guarantee)

To eliminate the vulnerability described in §1.2, the admission and registration flow is restructured so that the invite pseudonym takes precedence **before** any database row or session token is populated:

```
[ OAuth Callback from Google / Facebook / LinkedIn ]
                    │
                    ▼
[ Resolve verified Email & target Tenant ]
                    │
                    ▼
[ Query tenant_invites FOR UPDATE for (tenant, email) ]
                    │
       ┌────────────┴────────────┐
       ▼                         ▼
[ Invite has DisplayName ]  [ Normal Invite / No Name ]
       │                         │
       ├─ Set humans.display_name = invite.display_name
       │  (Discard IdP real name completely)
       ├─ Set humans.display_name_locked = invite.display_name_locked
       ├─ Set humans.avatar_own = true
       ├─ Set humans.avatar_file_id = NULL
       ├─ Set humans.idp_avatar_file_id = NULL
       ├─ Skip storeAvatar (0 bytes written to blob store)
       ├─ Set Session.Name = invite.display_name
       │                         │
       ▼                         ▼
[ Write tenant_memberships & commit transaction ]
                    │
                    ▼
[ Desk welcome bot reads humans.display_name -> Greets @Pseudonym ]
```

#### Detailed Execution Steps in `Postgres.Admit` and `AuthHooks.Register`:
1. **Pre-Admission Invite Lookup**:
   In `csi-spl-api/src/go/spool-hub-api/internal/store/humans_postgres.go`, inside the `Admit` transaction, before calling `recordIdentity`:
   Query whether a pending, unexpired invite exists for `id.Email` in `tenant`:
   ```sql
   SELECT display_name, display_name_locked
     FROM tenant_invites
    WHERE tenant_id = $1 AND email = $2
      AND accepted_at IS NULL AND expires_at > $3
    LIMIT 1
   ```
2. **Deterministic Seeding in `recordIdentity`**:
   - If an invite display name is found (`invDisplayName != ""`):
     - For a newly created human (`!f.linked`):
       Insert into `humans`:
       ```sql
       INSERT INTO humans (display_name, display_name_locked, avatar_own, email, created_at)
       VALUES ($1, $2, true, $3, $4)
       RETURNING human_id
       ```
       using `$1 = invDisplayName`, `$2 = invDisplayNameLocked`. **The provider name `id.Name` is never passed to SQL and never stored in `humans`.**
     - For an existing unlinked or linked human whose display name was empty or being initialized:
       Update `humans` setting `display_name = invDisplayName`, `display_name_locked = invDisplayNameLocked`, `avatar_own = true`, `avatar_file_id = NULL`, `idp_avatar_file_id = NULL`.
3. **Avatar Suppression in `AuthHooks.Register`**:
   In `csi-spl-api/src/go/spool-hub-api/internal/store/humans_auth.go` (line 84):
   Add check: if the admitted human has `avatar_own = true` and `avatar_file_id == ""` (or if the active invite specified a pseudonym):
   ```go
   if a.avatarSuppressed(ctx, hum, tenant) {
       return hum, nil
   }
   ```
   `storeAvatar` is **not called**. No HTTP calls to fetch avatar bytes occur, no hash is calculated, no file is stored in `avatars/<sha256>` or `t/<tenant>/files/<sha256>`, and `idp_avatar_file_id` remains `NULL`.
4. **Session Token Sanitization**:
   In `csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go` (`callback` and `registerLanding`):
   When `registerLanding` returns the human ID, `sess.Name` in the signed JWT cookie is updated to the human's canonical `display_name` (the pseudonym), never `id.Name`.
5. **Channel and Feed Protection**:
   - **Desk Welcome Bot (`spl-desk-welcome.func.sh`)**: When `spl_desk_welcome_admits` runs its query (line 323), `h.display_name` is already `FirstName LastName` (the pseudonym). The bot posts `@FirstName LastName` to `#lobby`. Neither the IdP real name nor the email local-part ever appears in chat.
   - **Workspace Roster (`viewHumans` in `view.go:344`)**: Returns `DisplayName: &pseudonym` and `AvatarFileID: nil`. The WUI renders deterministic initials and background color based on the pseudonym.
   - **Mentions Autocomplete**: `useMentionPicker.ts` constructs suggestions from `people.names.value` (`DisplayName`), displaying only the pseudonym.
   - **Audit Logs**: `internal/auth/audit.go` (`recordAuth`) records only `(tenant, human_id, kind, method)`. No names or emails are logged.

---

### 3.3 Decision 3: Optionally LOCKED (Pseudonym immutability & unlock authority)

1. **Enforcement on Self-Service Changes**:
   - When `humans.display_name_locked == true`:
     - **Profile name edit**: When the user calls `PATCH /api/v1/auth/profile` (`internal/auth/handler.go:1309`): `SetDisplayName` checks `humans.display_name_locked`. If `true`, returns `auth.ErrDisplayNameLocked`. The HTTP response is `403 Forbidden` (`code: "display_name_locked"`, message: `"display name is locked by workspace administrator"`).
     - **Profile avatar upload**: When the user calls `PUT /api/v1/auth/avatar`: If `humans.display_name_locked == true`, avatar upload is refused with `403 Forbidden` (`code: "avatar_locked"`, message: `"avatar modifications are locked for pseudonymous accounts"`). This prevents the user from accidentally or intentionally uploading a personal photograph that de-anonymizes them.
2. **Authority to Unlock or Modify**:
   - **Workspace Administrators & Owners**: Users holding `rbac.MembersInvite` / `rbac.MembersRoles` permissions can manage the member in Workspace Settings > Users. Calling `PATCH /v1/members/{human_id}` with `{ "display_name": "NewName", "display_name_locked": false }` updates the name and clears the lock.
   - **Platform Operators**: Can update or unlock via `do_spl_human_pseudonym` or operator API routes.

---

### 3.4 Decision 4: Multi-Provider Parity (Google, Facebook, LinkedIn)

All external authentication providers in `csi-spl-api/src/go/spool-hub-api/internal/auth/` follow a uniform pattern:
1. Provider-specific exchange (`google` in `idp.go`/`oidc.go`, `facebook` in `idp.go`, `linkedin` in `oidc.go`) validates credentials and constructs a generic `auth.Identity`:
   ```go
   type Identity struct {
       Provider string // "google", "facebook", "linkedin", "password"
       Subject  string // Provider-unique subject ID
       Email    string // Verified email address
       Name     string // Profile name returned by IdP
       Avatar   []byte // Raw avatar image bytes
   }
   ```
2. The `Identity` is passed into `AuthHooks.Register` -> `Humans.Admit`.
3. Because the pseudonym replacement and avatar suppression logic execute entirely inside `Admit` and `AuthHooks.Register`, provider differences are completely abstracted. Google, Facebook, LinkedIn, Microsoft, and native credentials behave identically.

---

### 3.5 Decision 5: Setting on Existing Members

A member who previously signed in under their real name (or was invited before this feature existed) can be transitioned to a pseudonym at any time:

1. **Workspace Administrator Path (WUI)**:
   - In `csi-spl-wui/src/components/UserEditPane.vue` (under `member.manageable`):
     - The profile section provides:
       - **Display name input** (`v-model="profileName"`)
       - **Lock display name checkbox** (`v-model="profileLocked"`)
       - **Clear avatar button / checkbox** (`v-model="clearAvatar"`)
     - Submitting calls `api.patchTenantUser(m.humanId, patch)`.
2. **Hub API Route Enhancement (`PATCH /v1/members/{human_id}`)**:
   In `csi-spl-api/src/go/spool-hub-api/internal/hub/tenant_settings.go` (`handleMemberPatch`):
   - Accepts optional fields:
     - `display_name` (string)
     - `display_name_locked` (bool)
     - `clear_avatar` (bool)
   - When `clear_avatar` is `true`:
     Executes inside transaction:
     ```sql
     UPDATE humans
        SET avatar_file_id = NULL,
            idp_avatar_file_id = NULL,
            avatar_own = true
      WHERE human_id = $1
     ```
   - Guards: Checks `s.profileEditable(w, r, target, t.ID)`. If the account belongs to multiple workspaces (`sharedAccount == true`), profile modification is refused with `409 Conflict` (`code: "shared_account"`) to prevent an administrator in one workspace from mutating another workspace's member profile.
3. **Operator CLI Path**:
   `do_spl_human_pseudonym` is enhanced to accept `LOCKED=1|0`. When `LOCKED=1`, it sets `display_name_locked = true` alongside `display_name` and the avatar clear.

---

### 3.6 Decision 6: Email Visibility & Identity Leak Analysis

A forensic audit of all data paths confirms where email addresses appear across the platform:

| Surface | Who Can See It? | Leaks Identity to Workspace Peers? | Rationale & Protection |
|---|---|---|---|
| **Admin Member Directory (`GET /v1/members`)** | Workspace Admins & Owners (`rbac.MembersInvite`) | **No** (regular members cannot access; 403 Forbidden) | Administrators must be able to manage accounts, send invitations, and perform administrative operations. |
| **Workspace Roster (`GET /v1/view`)** | All workspace members | **No** | `viewHuman` struct contains `HumanID`, `DisplayName`, `AvatarFileID`, `Owner`, `Interests`, `LastSeen`, `Status`. **Email is omitted entirely.** |
| **Message Posts & Topics** | All channel members | **No** | Messages store `author_hum` (e.g. `HUM-12`). The client renders the display name from the roster map (`people.names[m.author]`), which displays the pseudonym. |
| **Mention Autocomplete (`@mention`)** | All workspace members | **No** | Candidate list derives from `people.names`, displaying the pseudonym or `HUM-*`. Email is never displayed or searched by regular users. |
| **Search API (`/v1/search`)** | All workspace members | **No** | Search indexes message text and topic titles; user email addresses are not indexed. |
| **Current User Session (`/api/v1/auth/me`)** | The signed-in user only | **No** | Returned strictly to the authenticated user in their own private session response. |

#### Identity Leak Risk Assessment:
- **Intra-workspace members**: Protected. There is zero leakage of email addresses to regular peers in any view, message, mention, or search result.
- **Intra-admin visibility**: Administrators who have access to the Users tab see `member.email`. If an invited person's email address contains their real full name (e.g. `first.last@company.com`), other workspace administrators can observe that address.  
  *Operational Guidance*: When total anonymity against all workspace administrators is required, the invitation must be issued to a role-based or anonymous email alias (e.g. `partner-review@company.com`).

---

### 3.7 Decision 7: Test Strategy & The Red Control

The implementation is verified by unit, store, integration, and E2E controls.

#### A. Automated Store Control (`internal/store/invite_pseudonym_test.go`)
A table-driven integration test covering PostgreSQL and memory stores:

```go
func TestInvitePseudonymZeroLeakage(t *testing.T) {
    // 1. Setup workspace and create invite with pseudonym and lock
    inv := store.Invite{
        TenantID:          "t1",
        Email:             "invited.person@example.com",
        Role:              rbac.Developer,
        DisplayName:       "Pseudonym Person",
        DisplayNameLocked: true,
        ExpiresAt:         time.Now().Add(24 * time.Hour),
    }
    require.NoError(t, store.PutInvite(ctx, inv, time.Now()))

    // 2. Simulate IdP sign-in with sensitive real name and avatar
    realName := "Sensitive RealName"
    avatarBytes := []byte("fake-idp-photo-bytes")
    id := auth.Identity{
        Provider: "google",
        Subject:  "sub-12345",
        Email:    "invited.person@example.com",
        Name:     realName,
        Avatar:   avatarBytes,
    }

    // 3. Register user
    hum, err := authHooks.Register(ctx, id, "t1")
    require.NoError(t, err)

    // 4. Assertions on humans table
    name, err := store.DisplayName(ctx, hum)
    require.NoError(t, err)
    assert.Equal(t, "Pseudonym Person", name)

    // Verify avatar suppression
    avatarID, err := store.Avatar(ctx, hum)
    assert.Empty(t, avatarID)

    // 5. Zero-leakage database scan: assert realName does not appear anywhere
    var count int
    err = db.QueryRow(ctx, `SELECT count(*) FROM humans WHERE display_name = $1`, realName).Scan(&count)
    require.NoError(t, err)
    assert.Zero(t, count, "real name must not be stored in humans")

    // 6. Assert blob store contains NO avatar file
    sum := sha256.Sum256(avatarBytes)
    fileID := hex.EncodeToString(sum[:])
    exists, err := blobStore.Exists(ctx, "avatars/"+fileID)
    require.NoError(t, err)
    assert.False(t, exists, "avatar blob must not be stored")

    // 7. Verify rename lock
    err = authHooks.SetDisplayName(ctx, hum, "Another Name")
    assert.ErrorIs(t, err, auth.ErrDisplayNameLocked)
}
```

#### B. The Red Control (Fails on today's trunk)
Running this exact test against current `master` fails with four distinct assertions:
1. `store.DisplayName` returns `"Sensitive RealName"` instead of `"Pseudonym Person"` (`humans_postgres.go:177`).
2. `blobStore.Exists` returns `true` because `storeAvatar` unconditionally uploads `id.Avatar` (`humans_auth.go:87`).
3. `store.Avatar` returns the generated file ID because `SetAvatar` populated `idp_avatar_file_id` (`humans_postgres.go:597`).
4. `SetDisplayName` succeeds without error because `display_name_locked` does not exist on `humans`.

This guarantees that the test is an authentic, falsifiable control.

---

## 4. WUI & CLI Specifications

### 4.1 WUI UserEditPane specification
File: `csi-spl-wui/src/components/UserEditPane.vue`

1. **Invite Creation Mode (`mode === 'new'`)**:
   ```html
   <label class="users-field">
     <span>{{ t('users.first_name') }}</span>
     <input v-model="inviteFirstName" type="text" maxlength="100" autocomplete="off" data-test="users-invite-first-name">
   </label>
   <label class="users-field">
     <span>{{ t('users.last_name') }}</span>
     <input v-model="inviteLastName" type="text" maxlength="100" autocomplete="off" data-test="users-invite-last-name">
   </label>
   <label class="users-field users-field--checkbox">
     <input v-model="inviteLocked" type="checkbox" data-test="users-invite-lock">
     <span>{{ t('users.lock_display_name') }}</span>
   </label>
   ```
2. **Member Edit Mode (`member.manageable`)**:
   - Profile section includes a badge or checkbox for `display_name_locked`.
   - If `display_name_locked` is true, a lock icon appears with a button for administrators to unlock.
   - A button `{{ t('users.clear_avatar') }}` allows administrators to strip an existing member's avatar photo.
3. **Self-Service Profile (`csi-spl-wui/src/components/settings/profile.vue`)**:
   - If the user's account has `display_name_locked: true`:
     - The Display Name input is disabled.
     - An informational notice is displayed: `{{ t('profile.name_locked_by_admin') }}`.
     - The avatar upload button is disabled with notice: `{{ t('profile.avatar_locked_by_admin') }}`.

### 4.2 CLI action specification (`do_spl_hub_invite`)
File: `csi-spl-orc/src/bash/run/spl-hub-invite.func.sh`

```bash
# @param INVITE_DISPLAY_NAME (optional) - the display name/pseudonym to assign
# @param INVITE_NAME_LOCKED (optional) - 1 (default when display name is set) or 0
```
- In `DRY_RUN=1`: Prints `(display_name="FirstName LastName", locked=1)`.
- In `DRY_RUN=0`: Serializes `display_name` and `display_name_locked` into the request payload to `POST /v1/operator/invites`.

---

## 5. Security & Invariant Rules

| Invariant | Rule | Enforcement Mechanism |
|---|---|---|
| **INV-1 (Zero Initial Leak)** | An invited person's IdP name and IdP picture must never be written to persistent storage when an invite pseudonym exists. | Handled inside `Postgres.Admit` transaction before any insert into `humans`, and guarded in `AuthHooks.Register`. |
| **INV-2 (Lock Immutability)** | A locked pseudonym cannot be altered by the member. | Checked in `AuthHooks.SetDisplayName` and `Preferences.SetDisplayName`, returning `ErrDisplayNameLocked` (403). |
| **INV-3 (Avatar Lockdown)** | A locked account cannot upload a custom avatar. | Checked in `AuthHooks.SetOwnAvatar`, returning 403 `avatar_locked`. |
| **INV-4 (Admin Scope)** | Only members with `rbac.MembersInvite` / `rbac.MembersRoles` can set or alter member pseudonyms. | Checked in `targetRole` and `membersActor` in `tenant_settings.go`. |
| **INV-5 (Tenant Isolation)** | A tenant administrator cannot alter the profile of an account that belongs to multiple tenants. | Guarded by `profileEditable` (`sharedAccount` check) in `tenant_settings.go`. |
| **INV-6 (Public Anonymity)** | Member email addresses are excluded from all member-facing APIs. | Omitted from `viewHuman` in `GET /v1/view` and excluded from search/mention models. |

---

<!-- version: 1.0.0 · updated: 2026-10-15 · last-edit: 2026-10-15T16:35:00Z -->
