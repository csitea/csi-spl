package store

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// The operator password reset (SPL-1635): the local private hub has no mail,
// so a forgotten owner password cannot go through the reset link
// (auth.AdminPasswordReset refuses with ErrMailUndeliverable). The operator
// CLI (`spool hub-reset-password --password-stdin`) replaces the native
// credential's hash with one typed on the operator's terminal and revokes
// every session of its human, so neither the old password nor an open
// browser still gets in.

// ErrNotTenantMember: the credential's human is no member of the tenant the
// reset was scoped to; nothing changed.
var ErrNotTenantMember = errors.New("not a member of that tenant")

// PasswordResetter replaces a native password and signs its human out.
type PasswordResetter interface {
	// ResetNativePassword sets the (password, email) credential's hash to
	// pwHash and revokes every session its human holds at now. A non-empty
	// tenant limits it to a member of that tenant (ErrNotTenantMember).
	// auth.ErrCredNotFound when the email has no password credential.
	ResetNativePassword(ctx context.Context, tenant, email, pwHash string, now time.Time) (humanID string, err error)
}

// ResetNativePassword does the whole reset in one transaction: a failure
// leaves both the old hash and the sessions as they were.
func (s *Postgres) ResetNativePassword(ctx context.Context, tenant, email, pwHash string, now time.Time) (string, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	if email == "" || pwHash == "" {
		return "", errors.New("reset: an email and a password hash are required")
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	var hum string
	err = tx.QueryRow(ctx, `SELECT human_id FROM human_identities WHERE provider = $1 AND subject = $2`,
		ProviderNative, email).Scan(&hum)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", auth.ErrCredNotFound
	}
	if err != nil {
		return "", err
	}
	if tenant != "" {
		if _, err := tx.Exec(ctx, pgScopeTenant, tenant); err != nil {
			return "", err
		}
		var one int
		err = tx.QueryRow(ctx, `SELECT 1 FROM tenant_memberships WHERE tenant_id = $1 AND human_id = $2`,
			tenant, hum).Scan(&one)
		if errors.Is(err, pgx.ErrNoRows) {
			return "", ErrNotTenantMember
		}
		if err != nil {
			return "", err
		}
	}
	tag, err := tx.Exec(ctx, `UPDATE password_credentials SET password_hash = $2, updated_at = $3
		WHERE provider = 'password' AND subject = $1`, email, pwHash, now)
	if err != nil {
		return "", err
	}
	if tag.RowsAffected() == 0 {
		return "", auth.ErrCredNotFound
	}
	if _, err := tx.Exec(ctx, `INSERT INTO session_revocations (human_id, revoked_at) VALUES ($1, $2)
		ON CONFLICT (human_id) DO UPDATE SET revoked_at = GREATEST(session_revocations.revoked_at, EXCLUDED.revoked_at)`,
		hum, now); err != nil {
		return "", err
	}
	return hum, tx.Commit(ctx)
}

// ResetNativePassword on the memory store: it keeps no credentials table
// (see ProvisionMember), so it resolves the (password, email) identity,
// checks the tenant and revokes the sessions; the hash itself is the
// Postgres store's.
func (s *Memory) ResetNativePassword(_ context.Context, tenant, email, pwHash string, now time.Time) (string, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	if email == "" || pwHash == "" {
		return "", errors.New("reset: an email and a password hash are required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	id, ok := s.hum.identities[[2]string{ProviderNative, email}]
	if !ok {
		return "", auth.ErrCredNotFound
	}
	if tenant != "" {
		if _, ok := s.hum.members[[2]string{tenant, id.human}]; !ok {
			return "", ErrNotTenantMember
		}
	}
	if s.revokedAt == nil {
		s.revokedAt = map[string]time.Time{}
	}
	if now.After(s.revokedAt[id.human]) {
		s.revokedAt[id.human] = now
	}
	return id.human, nil
}
