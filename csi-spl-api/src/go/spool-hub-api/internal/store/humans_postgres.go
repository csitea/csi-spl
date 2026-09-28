package store

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

func (s *Postgres) Admit(ctx context.Context, id Identity, tenant string, p AdmitPolicy, now time.Time) (string, error) {
	if err := normalizeIdentity(&id); err != nil {
		return "", err
	}
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
		if err := s.admitTx(ctx, tx, f.hum, id.Email, tenant, p, now); err != nil {
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

func (s *Postgres) admitTx(ctx context.Context, tx pgx.Tx, hum, email, tenant string, p AdmitPolicy, now time.Time) error {
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
	var member bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM tenant_memberships
		WHERE tenant_id = $1 AND human_id = $2)`, tenant, hum).Scan(&member); err != nil {
		return err
	}
	if member {
		return nil // re-login never consumes a seat
	}
	if capUsers > 0 {
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM tenant_memberships WHERE tenant_id = $1`,
			tenant).Scan(&n); err != nil {
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
	if p.BootstrapOwner {
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
	return ErrNotAdmitted
}

// MemberRole reads the human's role in tenant, once per request when ctx
// carries a request memo (memo.go).
func (s *Postgres) MemberRole(ctx context.Context, humanID, tenant string) (string, error) {
	// SPL-1034: the same row's channel_order rides along into the request
	// memo, so ChannelOrder in the same request costs no round trip.
	return memberRoleOrder(ctx, humanID, tenant, func() (string, []string, error) {
		var role string
		var order []string
		err := s.queryRowTenant(ctx, tenant, `SELECT m.role, m.channel_order FROM tenant_memberships m
			JOIN humans h ON h.human_id = m.human_id
			WHERE m.tenant_id = $1 AND m.human_id = $2 AND h.disabled_at IS NULL AND m.disabled_at IS NULL`,
			[]any{tenant, humanID}, &role, &order)
		if errors.Is(err, pgx.ErrNoRows) {
			return "", nil, ErrNotFound
		}
		return role, order, err
	})
}

func (s *Postgres) PutInvite(ctx context.Context, in Invite, now time.Time) error {
	if err := normalizeInvite(&in); err != nil {
		return err
	}
	tag, err := s.execTenant(ctx, in.TenantID, `INSERT INTO tenant_invites (tenant_id, email, role, invited_by, created_at, expires_at)
		SELECT $1, $2, $3, $4, $5, $6 WHERE EXISTS (SELECT 1 FROM tenants WHERE tenant_id = $1)
		ON CONFLICT (tenant_id, email) DO UPDATE SET role = EXCLUDED.role, invited_by = EXCLUDED.invited_by,
			created_at = EXCLUDED.created_at, expires_at = EXCLUDED.expires_at, accepted_at = NULL, accepted_by = NULL,
			mail_count = 0`,
		in.TenantID, in.Email, in.Role, in.InvitedBy, now, in.ExpiresAt)
	if isFKViolation(err, "tenant_invites_role_fk") {
		return ErrUnknownRole
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
	tag, err := s.pool.Exec(ctx, `UPDATE humans SET avatar_file_id = $2 WHERE human_id = $1`, humanID, fileID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
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
	tag, err := s.pool.Exec(ctx, `UPDATE humans SET preferred_locale = NULLIF($2, '') WHERE human_id = $1`, humanID, locale)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) PreferredLocale(ctx context.Context, humanID string) (string, error) {
	var loc string
	err := s.pool.QueryRow(ctx, `SELECT COALESCE(preferred_locale, '') FROM humans WHERE human_id = $1`, humanID).Scan(&loc)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	return loc, err
}

func (s *Postgres) SetPreferredTheme(ctx context.Context, humanID, theme string) error {
	if err := checkTheme(theme); err != nil {
		return err
	}
	tag, err := s.pool.Exec(ctx, `UPDATE humans SET preferred_theme = NULLIF($2, '') WHERE human_id = $1`, humanID, theme)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) PreferredTheme(ctx context.Context, humanID string) (string, error) {
	var theme string
	err := s.pool.QueryRow(ctx, `SELECT COALESCE(preferred_theme, '') FROM humans WHERE human_id = $1`, humanID).Scan(&theme)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	return theme, err
}

func (s *Postgres) SetSubmitKey(ctx context.Context, humanID, key string) error {
	if err := checkSubmitKey(key); err != nil {
		return err
	}
	tag, err := s.pool.Exec(ctx, `UPDATE humans SET submit_key = NULLIF($2, '') WHERE human_id = $1`, humanID, key)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) SubmitKey(ctx context.Context, humanID string) (string, error) {
	var key string
	err := s.pool.QueryRow(ctx, `SELECT COALESCE(submit_key, '') FROM humans WHERE human_id = $1`, humanID).Scan(&key)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	return key, err
}

func (s *Postgres) SetRailOrder(ctx context.Context, humanID string, order []string) error {
	if err := checkRailOrder(order); err != nil {
		return err
	}
	tag, err := s.pool.Exec(ctx, `UPDATE humans SET rail_order = $2 WHERE human_id = $1`, humanID, order)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
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

// humans is hub-wide (outside rdb 0014's RLS): no tenant scope, like SetAvatar.
func (s *Postgres) SetDisplayName(ctx context.Context, humanID, name string) error {
	tag, err := s.pool.Exec(ctx, `UPDATE humans SET display_name = $2 WHERE human_id = $1`, humanID, name)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) DisplayName(ctx context.Context, humanID string) (string, error) {
	var name string
	err := s.pool.QueryRow(ctx, `SELECT COALESCE(display_name, '') FROM humans WHERE human_id = $1`, humanID).Scan(&name)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	return name, err
}

// humans is hub-wide (outside rdb 0014's RLS): no tenant scope, like SetAvatar.
func (s *Postgres) SetDiagnosticsEnabled(ctx context.Context, humanID string, on bool) error {
	tag, err := s.pool.Exec(ctx, `UPDATE humans SET diagnostics_enabled = $2 WHERE human_id = $1`, humanID, on)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
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
	err := s.queryTenant(ctx, tenant, `SELECT h.human_id, coalesce(h.avatar_file_id, '') FROM tenant_memberships m
		JOIN humans h ON h.human_id = m.human_id WHERE m.tenant_id = $1 AND h.disabled_at IS NULL`,
		[]any{tenant}, func(rows pgx.Rows) error {
			var id, fid string
			if err := rows.Scan(&id, &fid); err != nil {
				return err
			}
			out[id] = fid
			return nil
		})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// unverifyIdentity is a test hook: see Memory.unverifyIdentity.
func (s *Postgres) unverifyIdentity(provider, subject string) {
	s.pool.Exec(context.Background(), //nolint:errcheck
		`UPDATE human_identities SET email_verified = false WHERE provider = $1 AND subject = $2`, provider, subject)
}

// disableHuman is a test hook (humans.disabled_at); no production caller yet.
func (s *Postgres) disableHuman(humanID string) {
	s.pool.Exec(context.Background(), `UPDATE humans SET disabled_at = now() WHERE human_id = $1`, humanID) //nolint:errcheck
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
