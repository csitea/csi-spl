package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// human_keys is hub-wide (rdb 0018): plain pool statements, no tenant scope.

const humanKeyCols = `key_id, human_id, public_key, fingerprint, source, label, created_at, revoked_at, revoked_reason`

func scanHumanKey(row pgx.Row) (HumanKey, error) {
	var k HumanKey
	err := row.Scan(&k.ID, &k.HumanID, &k.PublicKey, &k.Fingerprint, &k.Source, &k.Label, &k.CreatedAt, &k.RevokedAt, &k.RevokedReason)
	if errors.Is(err, pgx.ErrNoRows) {
		return HumanKey{}, ErrNotFound
	}
	return k, err
}

func (s *Postgres) AddHumanKey(ctx context.Context, k HumanKey, now time.Time) (HumanKey, error) {
	if err := checkHumanKey(k); err != nil {
		return HumanKey{}, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return HumanKey{}, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	// Lock the human row: serialises two adds of one human (one active key)
	// and proves the human exists.
	var hum string
	if err := tx.QueryRow(ctx, `SELECT human_id FROM humans WHERE human_id = $1 FOR UPDATE`, k.HumanID).Scan(&hum); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return HumanKey{}, ErrNotFound
		}
		return HumanKey{}, err
	}
	if _, err := tx.Exec(ctx, `UPDATE human_keys SET revoked_at = $2, revoked_reason = 'replaced'
		WHERE human_id = $1 AND revoked_at IS NULL`, k.HumanID, now); err != nil {
		return HumanKey{}, err
	}
	out, err := scanHumanKey(tx.QueryRow(ctx, `INSERT INTO human_keys (human_id, public_key, fingerprint, source, label, created_at)
		VALUES ($1, $2, $3, $4, $5, $6) RETURNING `+humanKeyCols,
		k.HumanID, k.PublicKey, k.Fingerprint, k.Source, k.Label, now))
	if isUniqueViolation(err) {
		return HumanKey{}, ErrConflict
	}
	if err != nil {
		return HumanKey{}, err
	}
	return out, tx.Commit(ctx)
}

func (s *Postgres) HumanKeys(ctx context.Context, humanID string) ([]HumanKey, error) {
	rows, err := s.pool.Query(ctx, `SELECT `+humanKeyCols+` FROM human_keys WHERE human_id = $1 ORDER BY key_id DESC`, humanID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []HumanKey{}
	for rows.Next() {
		k, err := scanHumanKey(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

func (s *Postgres) HumanKey(ctx context.Context, humanID string, id int64) (HumanKey, error) {
	return scanHumanKey(s.pool.QueryRow(ctx, `SELECT `+humanKeyCols+` FROM human_keys WHERE key_id = $1 AND human_id = $2`, id, humanID))
}

func (s *Postgres) RevokeHumanKey(ctx context.Context, humanID string, id int64, now time.Time) (HumanKey, error) {
	if _, err := s.pool.Exec(ctx, `UPDATE human_keys SET revoked_at = $3, revoked_reason = 'revoked'
		WHERE key_id = $1 AND human_id = $2 AND revoked_at IS NULL`, id, humanID, now); err != nil {
		return HumanKey{}, err
	}
	return s.HumanKey(ctx, humanID, id)
}
