# Spec 124: Multi-email Sign-in

## 1. Owner's Words
- t1 f265541a-086b-4c84-acf8-02ede6380675, HUM-10, msg da3054b0-f344-40fa-9325-2c2a7c586a6a:
  "Allowing the Spool Hub users to log in with one or more emails"
- Follow-up, msg 0284771c-893e-436b-bb44-8dfb777ae4d3:
  "How big of an architectural change is it to allow the users to log in with one or more of their emails?"

## 2. What Exists
This is not an architectural change. `human_identities` already holds many sign-ins per human. As defined in `csi-spl-rdb/src/sql/postgres/spool-hub/0006_users_and_memberships.sql:10`, a person is keyed by `(provider, subject)`, one human may carry several identities, and it states "a new identity is never linked to an existing human by email alone". Native accounts use provider `'password'` with subject = `lower(email)` (rdb 0009).

Furthermore, `findHuman` (`csi-spl-api/src/go/spool-hub-api/internal/store/humans_postgres.go:106`) auto-links only the SAME provider-verified email. This spec agrees with the assessment in m/c18731df: the core architecture supports multiple identities, and what is missing is the signed-in add/verify/list/remove flow, invite matching on any verified email, and designating a main email.

## 3. Design: Multi-email Flow

### 3.1. Adding an Identity
A signed-in user can add a second email or sign-in (e.g., social provider) to their own account, proven by verification.
- Native email: the user inputs an email, receives a verification link, and upon clicking it, the email is verified and added.
- Social (Google/Facebook/LinkedIn): the user completes the OAuth flow. The identity is added, carrying any emails provided by the IdP.

### 3.2. List and Remove
The Web UI will list all identities/emails linked to the user's account.
Users can remove any identity, except the last one (a user must always have at least one valid identity).

### 3.3. Primary Email
One of the verified emails must be designated as primary. The primary email is used to receive mail and invites by default. If a user removes their primary email, they must first designate another verified email as primary.

### 3.4. Invite Matching
When a user is invited to a workspace, the system will match the invite against ANY verified email associated with their account, not just the primary one.

### 3.5. Collisions
If an added email or identity is already verified on another human (HUM-*), a collision occurs.
The system will refuse the addition and display an error. Merging accounts is not supported.

### 3.6. Social Identities
Google/Facebook/LinkedIn identities carry their own emails. When a user links a social identity, the provider-verified email from that identity is added to the user's account and acts as another email that can receive invites.

## 4. Owner Questions

1. **Collision with another account**
   - **Question**: What happens if a user tries to add an email that is already verified on another account?
   - **Recommendation**: Refuse the action and do not merge accounts. Account merges introduce severe security and data ownership complexities.
2. **Admin visibility of secondary emails**
   - **Question**: Should workspace administrators see all of a user's verified emails or just the primary one?
   - **Recommendation**: Workspace admins should only see the email that was invited to the workspace or the primary email, to preserve privacy of the user's secondary identities.

## 5. Build Lanes
- rdb
- hub
- WUI
