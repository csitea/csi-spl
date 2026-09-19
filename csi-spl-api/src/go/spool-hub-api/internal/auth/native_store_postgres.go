package auth

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// PgCredStore is the CredStore on rdb 0009 (password_credentials,
// email_verification_tokens, password_reset_tokens).
type PgCredStore struct{ Pool *pgxpool.Pool }

var tokenTable = map[string]string{TokenVerify: "email_verification_tokens", TokenReset: "password_reset_tokens"}

func (p PgCredStore) CreateCredential(ctx context.Context, c Credential, now time.Time) (bool, error) {
	tag, err := p.Pool.Exec(ctx, `
		INSERT INTO password_credentials (provider, subject, password_hash, display_name, email_verified_at, created_at, updated_at)
		VALUES ('password', $1, $2, NULLIF($3, ''), $4, $5, $5)
		ON CONFLICT (provider, subject) DO NOTHING`,
		c.Subject, c.PasswordHash, c.DisplayName, c.EmailVerifiedAt, now)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

func (p PgCredStore) GetCredential(ctx context.Context, subject string) (Credential, error) {
	var c Credential
	err := p.Pool.QueryRow(ctx, `
		SELECT subject, password_hash, COALESCE(display_name, ''), email_verified_at, created_at
		  FROM password_credentials WHERE provider = 'password' AND subject = $1`, subject).
		Scan(&c.Subject, &c.PasswordHash, &c.DisplayName, &c.EmailVerifiedAt, &c.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Credential{}, ErrCredNotFound
	}
	return c, err
}

func (p PgCredStore) IssueToken(ctx context.Context, kind, subject, tokenHash, pwHash string, now, expires time.Time, floor MailFloor) (bool, error) {
	table, ok := tokenTable[kind]
	if !ok {
		return false, errors.New("auth: unknown token kind")
	}
	if kind == TokenVerify && pwHash == "" {
		return false, errors.New("auth: verification token needs a password hash")
	}
	tx, err := p.Pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	// The credential row lock serialises concurrent issuers, so the floor is
	// exact across Cloud Run instances.
	var one int
	err = tx.QueryRow(ctx, `SELECT 1 FROM password_credentials WHERE provider = 'password' AND subject = $1 FOR UPDATE`,
		subject).Scan(&one)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, ErrCredNotFound
	}
	if err != nil {
		return false, err
	}
	var last *time.Time
	var today int
	if err := tx.QueryRow(ctx, `
		SELECT MAX(created_at), COUNT(*) FILTER (WHERE created_at > $2::timestamptz - interval '24 hours')
		  FROM `+table+` WHERE provider = 'password' AND subject = $1`, subject, now).Scan(&last, &today); err != nil {
		return false, err
	}
	if last != nil && now.Sub(*last) < floor.MinInterval {
		return false, nil
	}
	if floor.MaxPerDay > 0 && today >= floor.MaxPerDay {
		return false, nil
	}
	var err2 error
	if kind == TokenVerify {
		// Only the newest link verifies (FR-015).
		if _, err := tx.Exec(ctx, `UPDATE email_verification_tokens SET consumed_at = $2
			WHERE provider = 'password' AND subject = $1 AND consumed_at IS NULL`, subject, now); err != nil {
			return false, err
		}
		_, err2 = tx.Exec(ctx, `INSERT INTO email_verification_tokens (token_hash, provider, subject, password_hash, created_at, expires_at)
			VALUES ($1, 'password', $2, $3, $4, $5)`, tokenHash, subject, pwHash, now, expires)
	} else {
		_, err2 = tx.Exec(ctx, `INSERT INTO password_reset_tokens (token_hash, provider, subject, created_at, expires_at)
			VALUES ($1, 'password', $2, $3, $4)`, tokenHash, subject, now, expires)
	}
	if err2 != nil {
		return false, err2
	}
	return true, tx.Commit(ctx)
}

func (p PgCredStore) ConsumeVerification(ctx context.Context, tokenHash string, now time.Time) error {
	tx, err := p.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	var subject, pwHash string
	var expires time.Time
	var consumed, verified *time.Time
	err = tx.QueryRow(ctx, `
		SELECT t.subject, t.password_hash, t.expires_at, t.consumed_at, c.email_verified_at
		  FROM email_verification_tokens t
		  JOIN password_credentials c ON c.provider = t.provider AND c.subject = t.subject
		 WHERE t.token_hash = $1
		   FOR UPDATE OF t, c`, tokenHash).Scan(&subject, &pwHash, &expires, &consumed, &verified)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrTokenInvalid
	}
	if err != nil {
		return err
	}
	if verified != nil {
		return nil
	}
	if consumed != nil {
		return ErrTokenInvalid
	}
	if !expires.After(now) {
		return ErrTokenExpired
	}
	if _, err := tx.Exec(ctx, `UPDATE password_credentials SET email_verified_at = $2, password_hash = $3, updated_at = $2
		WHERE provider = 'password' AND subject = $1`, subject, now, pwHash); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE email_verification_tokens SET consumed_at = $2
		WHERE provider = 'password' AND subject = $1 AND consumed_at IS NULL`, subject, now); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (p PgCredStore) ConsumeReset(ctx context.Context, tokenHash, newHash string, now time.Time) (string, error) {
	tx, err := p.Pool.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	var subject string
	err = tx.QueryRow(ctx, `
		SELECT subject FROM password_reset_tokens
		 WHERE token_hash = $1 AND consumed_at IS NULL AND expires_at > $2
		   FOR UPDATE`, tokenHash, now).Scan(&subject)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrTokenInvalid
	}
	if err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `UPDATE password_credentials
		SET password_hash = $2, email_verified_at = COALESCE(email_verified_at, $3), updated_at = $3
		WHERE provider = 'password' AND subject = $1`, subject, newHash, now); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `UPDATE password_reset_tokens SET consumed_at = $2
		WHERE provider = 'password' AND subject = $1 AND consumed_at IS NULL`, subject, now); err != nil {
		return "", err
	}
	return subject, tx.Commit(ctx)
}

func (p PgCredStore) SetPassword(ctx context.Context, subject, newHash string, now time.Time) error {
	tag, err := p.Pool.Exec(ctx, `UPDATE password_credentials SET password_hash = $2, updated_at = $3
		WHERE provider = 'password' AND subject = $1`, subject, newHash, now)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrCredNotFound
	}
	return nil
}

func (p PgCredStore) TouchLogin(ctx context.Context, subject string, now time.Time) error {
	_, err := p.Pool.Exec(ctx, `UPDATE password_credentials SET last_login_at = $2
		WHERE provider = 'password' AND subject = $1`, subject, now)
	return err
}
