package store

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

func (s *Postgres) Admit(ctx context.Context, id Identity, tenant string, p AdmitPolicy, now time.Time) (string, error) {
	if err := normalizeIdentity(&id); err != nil {
		return "", err
	}
	// The rdb 0113 probe takes a pool connection of its own: read it before
	// the transaction holds one, or racing sign-ins on a small pool each hold
	// a connection while waiting for a second (T008's race test hung so).
	seatEnds := tenant != "" && s.hasAccessUntil(ctx)
	access := seatEnds && p.openAdmits(id, tenant)
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if tenant != "" {
		// humans / human_identities are hub-wide (no RLS); the membership
		// half below is tenant-scoped (rdb 0014).
		if _, err := tx.Exec(ctx, pgScopeTenant, tenant); err != nil {
			return "", err
		}
	}
	if err := lockIdentity(ctx, tx, id); err != nil {
		return "", err
	}
	f, err := findHuman(ctx, tx, id)
	if err != nil {
		return "", err
	}
	if f.disabled {
		return "", ErrNotAdmitted
	}
	if f.hum, err = recordIdentity(ctx, tx, id, f, now); err != nil {
		return "", err
	}
	if tenant != "" {
		open := p.openAdmits(id, tenant)
		if open && (f.known || f.linked) {
			if open, err = s.noMemberElsewhere(ctx, f.hum, tenant); err != nil {
				return "", err
			}
		}
		r := admitRule{p: p, open: open, access: open && access, seatEnds: seatEnds, account: demoAccountKey(id),
			bans: demoBanKeys(id)}
		if id.ClientIP != "" {
			r.ip = demoIPKey(id.ClientIP)
		}
		if err := s.admitTx(ctx, tx, f.hum, id.Email, tenant, r, now); err != nil {
			return "", err // rollback: a refusal writes nothing
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return "", err
	}
	return f.hum, nil
}

// lockIdentity serialises concurrent first callbacks of one identity (one
// HUM-*, not two) and, when the address is provider-verified, of one ADDRESS
// too: the linking in findHuman reads other providers' rows, so two first
// callbacks of the same address must not both mint a human. The address lock
// is always taken first, so no two transactions take the pair in opposite
// orders and deadlock. The '@' prefix cannot collide with a provider slug
// (providerRe forbids it).
func lockIdentity(ctx context.Context, tx pgx.Tx, id Identity) error {
	if id.Email != "" {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended('@email|' || $1, 0))`,
			id.Email); err != nil {
			return err
		}
	}
	_, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1 || '|' || $2, 0))`,
		id.Provider, id.Subject)
	return err
}

// foundHuman is who an identity signs in as: known (the identity exists),
// linked (a new identity joining the human of its verified address), or
// neither (a new human is minted).
type foundHuman struct {
	hum                     string
	disabled, known, linked bool
}

// findHuman looks the identity up, then (CLE-3451 defect 2) links a NEW
// identity whose PROVIDER-VERIFIED address already belongs to a human to
// that human instead of minting a second, unlinked one (which then finds no
// invite, no bootstrap, and is refused 403 not_allowed). BOTH sides must be
// verified, or this is an account takeover: id.Email is non-empty only when
// the provider asserted email_verified (auth FR-004 - idp.go / oidc.go
// refuse the sign-in otherwise), and the stored side must carry
// email_verified = true.
func findHuman(ctx context.Context, tx pgx.Tx, id Identity) (foundHuman, error) {
	var f foundHuman
	err := tx.QueryRow(ctx, `SELECT h.human_id, h.disabled_at IS NOT NULL FROM human_identities i
		JOIN humans h ON h.human_id = i.human_id WHERE i.provider = $1 AND i.subject = $2`,
		id.Provider, id.Subject).Scan(&f.hum, &f.disabled)
	f.known = err == nil
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return f, err
	}
	if f.known || id.Email == "" {
		return f, nil
	}
	var lhum string
	var ldisabled bool
	err = tx.QueryRow(ctx, `SELECT i.human_id, h.disabled_at IS NOT NULL
		FROM human_identities i JOIN humans h ON h.human_id = i.human_id
		WHERE i.email = $1 AND i.email_verified
		ORDER BY i.created_at, i.provider, i.subject LIMIT 1`, id.Email).Scan(&lhum, &ldisabled)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return f, err
	}
	if err == nil {
		f.hum, f.disabled, f.linked = lhum, ldisabled, true
	}
	return f, nil
}

// recordIdentity mints the human when neither known nor linked, inserts a
// new identity or stamps a known one's login, and for an existing human
// refreshes the address. The IdP name only seeds an empty display_name:
// once the human has one (their own, set in Settings) a sign-in keeps it.
// It answers the human id.
func recordIdentity(ctx context.Context, tx pgx.Tx, id Identity, f foundHuman, now time.Time) (string, error) {
	hum := f.hum
	switch {
	case f.known:
		if _, err := tx.Exec(ctx, `UPDATE human_identities SET last_login_at = $3,
			email = COALESCE(NULLIF($4, ''), email), email_verified = email_verified OR $4 <> ''
			WHERE provider = $1 AND subject = $2`, id.Provider, id.Subject, now, id.Email); err != nil {
			return "", err
		}
	default:
		if !f.linked {
			if err := tx.QueryRow(ctx, `INSERT INTO humans (display_name, email, created_at)
				VALUES (NULLIF($1, ''), NULLIF($2, ''), $3) RETURNING human_id`,
				id.Name, id.Email, now).Scan(&hum); err != nil {
				return "", err
			}
		}
		if _, err := tx.Exec(ctx, `INSERT INTO human_identities
			(provider, subject, human_id, email, email_verified, created_at, last_login_at)
			VALUES ($1, $2, $3, NULLIF($4, ''), $4 <> '', $5, $5)`,
			id.Provider, id.Subject, hum, id.Email, now); err != nil {
			return "", err
		}
	}
	if f.known || f.linked {
		if _, err := tx.Exec(ctx, `UPDATE humans SET email = COALESCE(NULLIF($2, ''), email),
			display_name = COALESCE(display_name, NULLIF($3, '')) WHERE human_id = $1`,
			hum, id.Email, id.Name); err != nil {
			return "", err
		}
	}
	return hum, nil
}

// admitRule is the policy for one admission: p, and whether the open demo
// rule (specs/077 T007) may seat this human in this tenant.
type admitRule struct {
	p    AdmitPolicy
	open bool
	// access: rdb 0113 access_until is there, so an ended seat is not live.
	access bool
	// seatEnds: rdb 0113 is there (probed before the transaction), so an
	// existing seat past its access_until is no membership (liveSeat).
	seatEnds bool
	// account and ip are the T010 counter keys of an open admission
	// (demoAccountKey, demoIPKey); ip "" skips the per-IP limit.
	account, ip string
	// bans are the demo ban list keys of the identity (demoBanKeys, rdb
	// 0130, T016 part B).
	bans []string
}

// noMemberElsewhere reports whether hum holds no membership outside tenant,
// so the open demo rule may seat it: the demo workspace has no real members
// (spec 3.8), and its 3-hour end must never touch a real person's data. It
// reads across tenants, so it is an operator caller (TestOperatorScopeCallers).
// A membership granted between this read and the admission is harmless: the
// person is then both, until the demo seat ends.
func (s *Postgres) noMemberElsewhere(ctx context.Context, hum, tenant string) (bool, error) {
	none := true
	err := s.asOperatorQuery(ctx, `SELECT 1 FROM tenant_memberships
		WHERE human_id = $1 AND tenant_id <> $2 LIMIT 1`, []any{hum, tenant}, func(pgx.Rows) error {
		none = false
		return nil
	})
	return none, err
}

func (s *Postgres) admitTx(ctx context.Context, tx pgx.Tx, hum, email, tenant string, r admitRule, now time.Time) error {
	// The tenant row lock serialises bootstrap (one owner, not two) and the
	// user-seat count (009 D-3: two first sign-ins cannot both take the last seat).
	var capUsers int
	err := tx.QueryRow(ctx, `SELECT seats_users FROM tenants WHERE tenant_id = $1 FOR UPDATE`, tenant).Scan(&capUsers)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotAdmitted
	}
	if err != nil {
		return err
	}
	// An existing seat admits only when the door would let it in (s077
	// LEAK-1): live (liveSeat) and not a fenced demo seat. A suspended, ended
	// or fenced seat is refused like a stranger: no cookie `t`, no sign_in row,
	// no picture under its tenant.
	var role string
	var live bool
	err = tx.QueryRow(ctx, `SELECT m.role, (TRUE`+liveSeat(r.seatEnds)+`) FROM tenant_memberships m
		JOIN humans h ON h.human_id = m.human_id
		WHERE m.tenant_id = $1 AND m.human_id = $2`, tenant, hum).Scan(&role, &live)
	if err == nil {
		if !live || auth.DemoFenced(role, tenant, r.p.OpenWorkspace) {
			return ErrNotAdmitted
		}
		return nil // re-login never consumes a seat
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	if capUsers > 0 {
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM tenant_memberships m
			JOIN humans h ON h.human_id = m.human_id
			WHERE m.tenant_id = $1 AND NOT h.technical`, tenant).Scan(&n); err != nil {
			return err
		}
		if n >= capUsers {
			// Checked before the invite/bootstrap path: a refusal writes
			// nothing, not even the invite's accepted_at.
			return ErrSeatQuota
		}
	}
	if email != "" {
		var role, by string
		err := tx.QueryRow(ctx, `UPDATE tenant_invites SET accepted_at = $3, accepted_by = $4
			WHERE tenant_id = $1 AND email = $2 AND accepted_at IS NULL AND expires_at > $3
			RETURNING role, invited_by`, tenant, email, now, hum).Scan(&role, &by)
		if err == nil {
			_, err = tx.Exec(ctx, `INSERT INTO tenant_memberships (tenant_id, human_id, role, created_at, admitted_by)
				VALUES ($1, $2, $3, $4, $5)`, tenant, hum, role, now, by)
			return err
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
	}
	if r.open {
		return seatDemoTx(ctx, tx, hum, tenant, r, now)
	}
	if r.p.bootstraps(tenant) {
		tag, err := tx.Exec(ctx, `INSERT INTO tenant_memberships (tenant_id, human_id, role, created_at, admitted_by)
			SELECT $1, $2, $4, $3, 'bootstrap'
			WHERE NOT EXISTS (SELECT 1 FROM tenant_memberships WHERE tenant_id = $1)`, tenant, hum, now, RoleTenantOwner)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 1 {
			return nil
		}
	}
	// No usable invite and no bootstrap. If the address DOES have a pending
	// invite that has merely lapsed, say so distinctly (ErrInviteExpired) so the
	// sign-in page can tell the person to ask for a fresh one, rather than the
	// blank not_allowed a stranger gets. The UPDATE above only matched
	// expires_at > now, so an unaccepted row with expires_at <= now is exactly
	// the expired case (CLE-77781).
	return refusal(ctx, tx, email, tenant, now)
}

// seatDemoTx seats hum as a demo_user (specs/077 T007) unless the demo holds
// its live cap already: ErrDemoFull (FR-006, T008). admitTx holds the tenant
// row lock, so two sign-ins cannot both take the last demo seat. The seat
// ends at now + the stay (T009, access_until); without rdb 0113 a seat could
// not end, so none is given (ErrAccessUntilUnavailable).
func seatDemoTx(ctx context.Context, tx pgx.Tx, hum, tenant string, r admitRule, now time.Time) error {
	if !r.access {
		return ErrAccessUntilUnavailable
	}
	// specs/077 T016 part B: a banned account or address is refused first.
	if banned, err := demoBannedTx(ctx, tx, tenant, r.bans); err != nil {
		return err
	} else if banned {
		return ErrDemoBanned
	}
	var live int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM tenant_memberships m
		WHERE m.tenant_id = $1 AND m.role = $2 AND (m.access_until IS NULL OR m.access_until > $3)`,
		tenant, rbac.DemoUser, now).Scan(&live); err != nil {
		return err
	}
	if live >= r.p.maxLive() {
		return ErrDemoFull
	}
	if err := takeDemoAdmissionTx(ctx, tx, tenant, r, now); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `INSERT INTO tenant_memberships (tenant_id, human_id, role, created_at, admitted_by, access_until)
		VALUES ($1, $2, $3, $4, $5, $6)`, tenant, hum, rbac.DemoUser, now, AdmittedDemo, now.Add(r.p.maxStay()).UTC())
	if err != nil {
		return err
	}
	return pseudonymTx(ctx, tx, hum) // specs/077 T011
}

// takeDemoAdmissionTx counts one demo visit for the account and, on its
// first visit today, one new account for the client IP (specs/077 Q11, 3.6,
// T010): ErrDemoVisits / ErrDemoSignups past the limits. It runs in
// admitTx's transaction, so a refusal here or later rolls the takes back
// with the seat, and a seat that is never given counts nothing.
func takeDemoAdmissionTx(ctx context.Context, tx pgx.Tx, tenant string, r admitRule, now time.Time) error {
	day := demoDay(now)
	visit, ok, err := takeQuotaTx(ctx, tx, tenant, r.account, quotaDemoVisit, day, r.p.visitsPerDay())
	if err != nil {
		return err
	}
	if !ok {
		return ErrDemoVisits
	}
	if visit > 1 || r.ip == "" {
		return nil
	}
	if _, ok, err = takeQuotaTx(ctx, tx, tenant, r.ip, quotaDemoSignup, day, r.p.signupsPerIP()); err != nil {
		return err
	}
	if !ok {
		return ErrDemoSignups
	}
	return nil
}

// takeQuotaTx is TakeQuota inside an open transaction.
func takeQuotaTx(ctx context.Context, tx pgx.Tx, tenant, key, kind string, window time.Time, limit int) (int, bool, error) {
	var n int
	err := tx.QueryRow(ctx, takeQuotaSQL, tenant, key, kind, window.UTC(), limit).Scan(&n)
	if errors.Is(err, pgx.ErrNoRows) {
		return limit, false, nil
	}
	return n, err == nil, err
}

// refusal is admitTx's answer when nothing admitted: ErrInviteExpired when
// the address holds a pending invite to tenant that merely lapsed, else
// ErrNotAdmitted.
func refusal(ctx context.Context, tx pgx.Tx, email, tenant string, now time.Time) error {
	if email == "" {
		return ErrNotAdmitted
	}
	var expired bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM tenant_invites
		WHERE tenant_id = $1 AND email = $2 AND accepted_at IS NULL AND expires_at <= $3)`,
		tenant, email, now).Scan(&expired); err != nil {
		return err
	}
	if expired {
		return ErrInviteExpired
	}
	return ErrNotAdmitted
}

// ProvisionMember seats a member by email before any sign-in (CLE-77781).
// Everything is one transaction and idempotent (ON CONFLICT DO NOTHING / the
// invite guarded by accepted_at IS NULL), so a re-run changes nothing. The
// address is advisory-locked like Admit so a concurrent first sign-in and this
// cannot both mint a human. See store.MemberProvisioner for the contract.
func (s *Postgres) ProvisionMember(ctx context.Context, in ProvisionInput, now time.Time) (string, bool, error) {
	email := strings.ToLower(strings.TrimSpace(in.Email))
	if email == "" || !strings.Contains(email, "@") {
		return "", false, errors.New("provision: a valid email is required")
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return "", false, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	// Same address lock Admit takes, so a first sign-in of this address in
	// flight cannot mint a second human next to the one this seats.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended('@email|' || $1, 0))`, email); err != nil {
		return "", false, err
	}
	// A verified identity for the address (an earlier operator row, or a real
	// one from a prior sign-in) names the human; else mint one.
	var hum string
	createdHuman := false
	err = tx.QueryRow(ctx, `SELECT i.human_id FROM human_identities i JOIN humans h ON h.human_id = i.human_id
		WHERE i.email = $1 AND i.email_verified ORDER BY i.created_at, i.provider, i.subject LIMIT 1`, email).Scan(&hum)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		if err := tx.QueryRow(ctx, `INSERT INTO humans (display_name, email, created_at)
			VALUES (NULLIF($1, ''), $2, $3) RETURNING human_id`, in.DisplayName, email, now).Scan(&hum); err != nil {
			return "", false, err
		}
		createdHuman = true
	case err != nil:
		return "", false, err
	default:
		// Seed a name only when the human has none (their own name wins).
		if in.DisplayName != "" {
			if _, err := tx.Exec(ctx, `UPDATE humans SET display_name = COALESCE(display_name, NULLIF($2, '')),
				email = COALESCE(email, $3) WHERE human_id = $1`, hum, in.DisplayName, email); err != nil {
				return "", false, err
			}
		}
	}
	// The operator identity carries the verified address so a later Google /
	// native sign-in LINKS here (findHuman), yet cannot itself sign in.
	if _, err := tx.Exec(ctx, `INSERT INTO human_identities (provider, subject, human_id, email, email_verified, created_at)
		VALUES ($1, $2, $3, $2, true, $4) ON CONFLICT (provider, subject) DO NOTHING`,
		ProviderOperator, email, hum, now); err != nil {
		return "", false, err
	}
	// Membership: tenant-scoped (rdb 0014), admitted_by 'operator'. An unknown
	// role fails the rbac_roles FK (rdb 0021) and rolls the whole thing back.
	if _, err := tx.Exec(ctx, pgScopeTenant, in.Tenant); err != nil {
		return "", false, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by, created_at)
		VALUES ($1, $2, $3, 'operator', $4) ON CONFLICT (tenant_id, human_id) DO NOTHING`,
		in.Tenant, hum, in.Role, now); err != nil {
		return "", false, err
	}
	// Accept any pending invite for the address (provenance coalesced), so the
	// list shows a member, not a dangling invite.
	if _, err := tx.Exec(ctx, `UPDATE tenant_invites SET accepted_at = $3, accepted_by = $2,
		ordered_by = COALESCE(ordered_by, NULLIF($4, '')), ordered_via = COALESCE(ordered_via, NULLIF($5, ''))
		WHERE tenant_id = $1 AND email = $6 AND accepted_at IS NULL`,
		in.Tenant, hum, now, in.OrderedBy, in.OrderedVia, email); err != nil {
		return "", false, err
	}
	if in.PasswordHash != "" {
		if err := provisionCredentialTx(ctx, tx, hum, email, in.PasswordHash, in.DisplayName, now); err != nil {
			return "", false, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return "", false, err
	}
	return hum, createdHuman, nil
}

// provisionCredentialTx writes the native email+password credential (email
// PRE-VERIFIED so no verification mail is sent) and the (password, email)
// identity native login resolves, so a first native login lands on hum with
// the membership already there. Idempotent (ON CONFLICT DO NOTHING).
func provisionCredentialTx(ctx context.Context, tx pgx.Tx, hum, email, pwHash, name string, now time.Time) error {
	if _, err := tx.Exec(ctx, `INSERT INTO password_credentials
		(provider, subject, password_hash, display_name, email_verified_at, created_at, updated_at)
		VALUES ('password', $1, $2, NULLIF($3, ''), $4, $4, $4)
		ON CONFLICT (provider, subject) DO NOTHING`, email, pwHash, name, now); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `INSERT INTO human_identities (provider, subject, human_id, email, email_verified, created_at)
		VALUES ('password', $1, $2, $1, true, $3) ON CONFLICT (provider, subject) DO NOTHING`, email, hum, now)
	return err
}

// MemberRole reads the human's role in tenant, once per request when ctx
// carries a request memo (memo.go).
func (s *Postgres) MemberRole(ctx context.Context, humanID, tenant string) (string, error) {
	// SPL-1034: the same row's channel_order rides along into the request
	// memo, so ChannelOrder in the same request costs no round trip; so do
	// the human's channels (SPL-1115, HumanChannels), in the same batch.
	// DB payload cut 5: with a memo, the whole read is served from the
	// instance's door cache (hotcache.go, 5 s, cleared by every writer).
	return memberRoleOrder(ctx, humanID, tenant, func(memo bool) (memberRead, error) {
		if memo {
			if v, ok := s.hot.door(tenant, humanID); ok {
				return v, nil
			}
		}
		gen := s.hot.generation()
		var v memberRead
		found := false
		// A membership past its access_until is no membership (rdb 0113, spec 072 A27).
		reads := []tenantRead{{sql: `SELECT m.role, m.channel_order FROM tenant_memberships m
			JOIN humans h ON h.human_id = m.human_id
			WHERE m.tenant_id = $1 AND m.human_id = $2` + liveSeat(s.hasAccessUntil(ctx)),
			args: []any{tenant, humanID}, each: func(rows pgx.Rows) error {
				found = true
				return rows.Scan(&v.role, &v.order)
			}}}
		if memo {
			reads = append(reads, humanChannelsRead(tenant, humanID, &v.chans))
		}
		if err := s.queryTenantBatch(ctx, tenant, reads...); err != nil {
			return memberRead{}, err
		}
		v.chansRead = memo
		if !found {
			return v, ErrNotFound
		}
		if memo {
			s.hot.putDoor(gen, tenant, humanID, v)
		}
		return v, nil
	})
}

func (s *Postgres) PutInvite(ctx context.Context, in Invite, now time.Time) error {
	if err := normalizeInvite(&in); err != nil {
		return err
	}
	tag, err := s.execTenant(ctx, in.TenantID, `INSERT INTO tenant_invites (tenant_id, email, role, invited_by, created_at, expires_at, ordered_by, ordered_via)
		SELECT $1, $2, $3, $4, $5, $6, $7, $8 WHERE EXISTS (SELECT 1 FROM tenants WHERE tenant_id = $1)
		ON CONFLICT (tenant_id, email) DO UPDATE SET role = EXCLUDED.role, invited_by = EXCLUDED.invited_by,
			created_at = EXCLUDED.created_at, expires_at = EXCLUDED.expires_at, accepted_at = NULL, accepted_by = NULL,
			mail_count = 0, ordered_by = EXCLUDED.ordered_by, ordered_via = EXCLUDED.ordered_via`,
		in.TenantID, in.Email, in.Role, in.InvitedBy, now, in.ExpiresAt, nullIfEmpty(in.OrderedBy), nullIfEmpty(in.OrderedVia))
	if isFKViolation(err, "tenant_invites_role_fk") {
		return ErrUnknownRole
	}
	if isFKViolation(err, "tenant_invites_ordered_by_fkey") {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) UnlinkIdentity(ctx context.Context, provider, subject string) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM human_identities WHERE provider = $1 AND subject = $2`, provider, subject)
	return err
}

func (s *Postgres) SetAvatar(ctx context.Context, humanID, fileID string) error {
	if err := checkFileID(fileID); err != nil {
		return err
	}
	return s.execHuman(ctx, `UPDATE humans SET idp_avatar_file_id = $2,
		avatar_file_id = CASE WHEN avatar_own THEN avatar_file_id ELSE $2 END WHERE human_id = $1`, humanID, fileID)
}

// SetOwnAvatar: the first upload keeps the shown IdP picture as
// idp_avatar_file_id (a row from before rdb 0150 has none recorded yet).
func (s *Postgres) SetOwnAvatar(ctx context.Context, humanID, fileID string) error {
	if fileID == "" {
		return s.execHuman(ctx, `UPDATE humans SET avatar_own = false,
			avatar_file_id = CASE WHEN avatar_own THEN idp_avatar_file_id ELSE avatar_file_id END
			WHERE human_id = $1`, humanID)
	}
	if err := checkFileID(fileID); err != nil {
		return err
	}
	return s.execHuman(ctx, `UPDATE humans SET avatar_own = true, avatar_file_id = $2,
		idp_avatar_file_id = CASE WHEN avatar_own THEN idp_avatar_file_id ELSE avatar_file_id END
		WHERE human_id = $1`, humanID, fileID)
}

func (s *Postgres) Avatar(ctx context.Context, humanID string) (string, error) {
	var id *string
	err := s.pool.QueryRow(ctx, `SELECT avatar_file_id FROM humans WHERE human_id = $1`, humanID).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil || id == nil {
		return "", err
	}
	return *id, nil
}

// humans is hub-wide (outside rdb 0014's RLS): no tenant scope, like SetAvatar.
func (s *Postgres) SetPreferredLocale(ctx context.Context, humanID, locale string) error {
	if err := checkLocale(locale); err != nil {
		return err
	}
	return s.execHuman(ctx, `UPDATE humans SET preferred_locale = NULLIF($2, '') WHERE human_id = $1`, humanID, locale)
}

func (s *Postgres) PreferredLocale(ctx context.Context, humanID string) (string, error) {
	return s.humanText(ctx, `SELECT COALESCE(preferred_locale, '') FROM humans WHERE human_id = $1`, humanID)
}

func (s *Postgres) SetPreferredTheme(ctx context.Context, humanID, theme string) error {
	if err := checkTheme(theme); err != nil {
		return err
	}
	return s.execHuman(ctx, `UPDATE humans SET preferred_theme = NULLIF($2, '') WHERE human_id = $1`, humanID, theme)
}

func (s *Postgres) PreferredTheme(ctx context.Context, humanID string) (string, error) {
	return s.humanText(ctx, `SELECT COALESCE(preferred_theme, '') FROM humans WHERE human_id = $1`, humanID)
}

func (s *Postgres) SetSubmitKey(ctx context.Context, humanID, key string) error {
	if err := checkSubmitKey(key); err != nil {
		return err
	}
	return s.execHuman(ctx, `UPDATE humans SET submit_key = NULLIF($2, '') WHERE human_id = $1`, humanID, key)
}

func (s *Postgres) SubmitKey(ctx context.Context, humanID string) (string, error) {
	return s.humanText(ctx, `SELECT COALESCE(submit_key, '') FROM humans WHERE human_id = $1`, humanID)
}

func (s *Postgres) SetRailOrder(ctx context.Context, humanID string, order []string) error {
	if err := checkRailOrder(order); err != nil {
		return err
	}
	return s.execHuman(ctx, `UPDATE humans SET rail_order = $2 WHERE human_id = $1`, humanID, order)
}

func (s *Postgres) RailOrder(ctx context.Context, humanID string) ([]string, error) {
	var order []string
	err := s.pool.QueryRow(ctx, `SELECT rail_order FROM humans WHERE human_id = $1`, humanID).Scan(&order)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return order, err
}

// SetViewPref: key names the column (rdb 0070); checkViewPref admits only
// the auth.ViewPrefs keys, so the interpolated identifier is one of those.
func (s *Postgres) SetViewPref(ctx context.Context, humanID, key, value string) error {
	if err := checkViewPref(key, value); err != nil {
		return err
	}
	tag, err := s.pool.Exec(ctx, `UPDATE humans SET `+key+` = NULLIF($2, '') WHERE human_id = $1`, humanID, value)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) ViewPref(ctx context.Context, humanID, key string) (string, error) {
	if err := checkViewPref(key, ""); err != nil {
		return "", err
	}
	var v string
	err := s.pool.QueryRow(ctx, `SELECT COALESCE(`+key+`, '') FROM humans WHERE human_id = $1`, humanID).Scan(&v)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	return v, err
}

// SetIssueColumns writes humans.issues_columns (rdb 0076); nil or empty is
// SQL NULL, never the JSON null a nil map would marshal to.
func (s *Postgres) SetIssueColumns(ctx context.Context, humanID string, cols map[string]int) error {
	if err := checkIssueColumns(cols); err != nil {
		return err
	}
	var arg any
	if len(cols) > 0 {
		arg = cols
	}
	return s.execHuman(ctx, `UPDATE humans SET issues_columns = $2::jsonb WHERE human_id = $1`, humanID, arg)
}

func (s *Postgres) IssueColumns(ctx context.Context, humanID string) (map[string]int, error) {
	var cols map[string]int
	err := s.pool.QueryRow(ctx, `SELECT issues_columns FROM humans WHERE human_id = $1`, humanID).Scan(&cols)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return copyCols(cols), err
}

// humans is hub-wide (outside rdb 0014's RLS): no tenant scope, like SetAvatar.
func (s *Postgres) SetDisplayName(ctx context.Context, humanID, name string) error {
	return s.execHuman(ctx, `UPDATE humans SET display_name = $2 WHERE human_id = $1`, humanID, name)
}

func (s *Postgres) DisplayName(ctx context.Context, humanID string) (string, error) {
	return s.humanText(ctx, `SELECT COALESCE(display_name, '') FROM humans WHERE human_id = $1`, humanID)
}

// SetInterests stores the human's free-text interests (rdb 0086). "" stores
// NULL so an unset field reads back as "". Hub-wide, like SetDisplayName.
func (s *Postgres) SetInterests(ctx context.Context, humanID, interests string) error {
	var v any
	if interests != "" {
		v = interests
	}
	return s.execHuman(ctx, `UPDATE humans SET interests = $2 WHERE human_id = $1`, humanID, v)
}

func (s *Postgres) Interests(ctx context.Context, humanID string) (string, error) {
	return s.humanText(ctx, `SELECT COALESCE(interests, '') FROM humans WHERE human_id = $1`, humanID)
}

// humans is hub-wide (outside rdb 0014's RLS): no tenant scope, like SetAvatar.
func (s *Postgres) SetDiagnosticsEnabled(ctx context.Context, humanID string, on bool) error {
	return s.execHuman(ctx, `UPDATE humans SET diagnostics_enabled = $2 WHERE human_id = $1`, humanID, on)
}

func (s *Postgres) DiagnosticsEnabled(ctx context.Context, humanID string) (bool, error) {
	var on bool
	err := s.pool.QueryRow(ctx, `SELECT diagnostics_enabled FROM humans WHERE human_id = $1`, humanID).Scan(&on)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, ErrNotFound
	}
	return on, err
}

func (s *Postgres) IdentityLocale(ctx context.Context, provider, subject string) (string, error) {
	var loc string
	err := s.pool.QueryRow(ctx, `SELECT COALESCE(h.preferred_locale, '') FROM human_identities i
		JOIN humans h ON h.human_id = i.human_id WHERE i.provider = $1 AND i.subject = $2`, provider, subject).Scan(&loc)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return loc, err
}

func (s *Postgres) TenantAvatars(ctx context.Context, tenant string) (map[string]string, error) {
	out := map[string]string{}
	r := tenantAvatarsRead(tenant, out)
	if err := s.queryTenant(ctx, tenant, r.sql, r.args, r.each); err != nil {
		return nil, err
	}
	return out, nil
}

// tenantAvatarsRead is TenantAvatars' statement, shared with ViewRoster's batch.
func tenantAvatarsRead(tenant string, out map[string]string) tenantRead {
	return tenantRead{sql: `SELECT h.human_id, coalesce(h.avatar_file_id, '') FROM tenant_memberships m
		JOIN humans h ON h.human_id = m.human_id WHERE m.tenant_id = $1 AND h.disabled_at IS NULL`,
		args: []any{tenant}, each: func(rows pgx.Rows) error {
			var id, fid string
			if err := rows.Scan(&id, &fid); err != nil {
				return err
			}
			out[id] = fid
			return nil
		}}
}

// FederatedAccount is CLE-3451 defect 1's lookup: which IdPs already carry
// this address, verified, on a human that is not disabled. The forgot-password
// route uses it to mail "you sign in with Google" instead of falling silent;
// it never changes what the route answers on the wire.
func (s *Postgres) FederatedAccount(ctx context.Context, email string) ([]string, string, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	if email == "" {
		return nil, "", nil
	}
	rows, err := s.pool.Query(ctx, `SELECT i.provider, COALESCE(h.preferred_locale, '')
		FROM human_identities i JOIN humans h ON h.human_id = i.human_id
		WHERE i.email = $1 AND i.email_verified AND i.provider <> $2 AND h.disabled_at IS NULL
		ORDER BY i.provider`, email, ProviderNative)
	if err != nil {
		return nil, "", err
	}
	defer rows.Close()
	var provs []string
	locale := ""
	for rows.Next() {
		var p, loc string
		if err := rows.Scan(&p, &loc); err != nil {
			return nil, "", err
		}
		provs = append(provs, p)
		if locale == "" {
			locale = loc
		}
	}
	return provs, locale, rows.Err()
}

// execHuman runs a one-row UPDATE of humans keyed by human_id ($1); a missing
// human is ErrNotFound. humans is hub-wide (outside rdb 0014's RLS).
func (s *Postgres) execHuman(ctx context.Context, sql string, args ...any) error {
	tag, err := s.pool.Exec(ctx, sql, args...)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// humanText reads one COALESCEd text column of the human keyed by $1; a
// missing human is ErrNotFound.
func (s *Postgres) humanText(ctx context.Context, sql, humanID string) (string, error) {
	var v string
	err := s.pool.QueryRow(ctx, sql, humanID).Scan(&v)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	return v, err
}
