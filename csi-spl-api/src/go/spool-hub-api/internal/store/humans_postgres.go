package store

import (
	"context"
	"errors"
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
	// Serialise concurrent first callbacks of one identity (one HUM-*, not two).
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1 || '|' || $2, 0))`,
		id.Provider, id.Subject); err != nil {
		return "", err
	}
	var hum string
	var disabled bool
	err = tx.QueryRow(ctx, `SELECT h.human_id, h.disabled_at IS NOT NULL FROM human_identities i
		JOIN humans h ON h.human_id = i.human_id WHERE i.provider = $1 AND i.subject = $2`,
		id.Provider, id.Subject).Scan(&hum, &disabled)
	known := err == nil
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return "", err
	}
	if disabled {
		return "", ErrNotAdmitted
	}
	if !known {
		if err := tx.QueryRow(ctx, `INSERT INTO humans (display_name, email, created_at)
			VALUES (NULLIF($1, ''), NULLIF($2, ''), $3) RETURNING human_id`,
			id.Name, id.Email, now).Scan(&hum); err != nil {
			return "", err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO human_identities
			(provider, subject, human_id, email, email_verified, created_at, last_login_at)
			VALUES ($1, $2, $3, NULLIF($4, ''), $4 <> '', $5, $5)`,
			id.Provider, id.Subject, hum, id.Email, now); err != nil {
			return "", err
		}
	} else {
		if _, err := tx.Exec(ctx, `UPDATE human_identities SET last_login_at = $3,
			email = COALESCE(NULLIF($4, ''), email), email_verified = email_verified OR $4 <> ''
			WHERE provider = $1 AND subject = $2`, id.Provider, id.Subject, now, id.Email); err != nil {
			return "", err
		}
		if _, err := tx.Exec(ctx, `UPDATE humans SET email = COALESCE(NULLIF($2, ''), email),
			display_name = COALESCE(NULLIF($3, ''), display_name) WHERE human_id = $1`,
			hum, id.Email, id.Name); err != nil {
			return "", err
		}
	}
	if tenant != "" {
		if err := s.admitTx(ctx, tx, hum, id.Email, tenant, p, now); err != nil {
			return "", err // rollback: a refusal writes nothing
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return "", err
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

func (s *Postgres) MemberRole(ctx context.Context, humanID, tenant string) (string, error) {
	var role string
	err := s.queryRowTenant(ctx, tenant, `SELECT m.role FROM tenant_memberships m
		JOIN humans h ON h.human_id = m.human_id
		WHERE m.tenant_id = $1 AND m.human_id = $2 AND h.disabled_at IS NULL`,
		[]any{tenant, humanID}, &role)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	return role, err
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

// disableHuman is a test hook (humans.disabled_at); no production caller yet.
func (s *Postgres) disableHuman(humanID string) {
	s.pool.Exec(context.Background(), `UPDATE humans SET disabled_at = now() WHERE human_id = $1`, humanID) //nolint:errcheck
}
