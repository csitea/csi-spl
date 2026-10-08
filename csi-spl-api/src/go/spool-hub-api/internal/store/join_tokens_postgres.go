package store

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// joinRowCols is the select list scanJoinToken reads.
const joinRowCols = `token_hash, tenant_id, created_by, COALESCE(for_human, ''), label, COALESCE(box_id, ''),
	created_at, expires_at, consumed_at, COALESCE(consumed_box, ''), revoked_at`

func scanJoinToken(row pgx.Row) (JoinToken, error) {
	var t JoinToken
	err := row.Scan(&t.Hash, &t.TenantID, &t.CreatedBy, &t.ForHuman, &t.Label, &t.BoxID,
		&t.CreatedAt, &t.ExpiresAt, &t.ConsumedAt, &t.ConsumedBox, &t.RevokedAt)
	return t, err
}

// nullable is "" as SQL NULL.
func nullable(v string) any {
	if v == "" {
		return nil
	}
	return v
}

func (s *Postgres) CreateJoinToken(ctx context.Context, t JoinToken) error {
	_, err := s.execTenant(ctx, t.TenantID, `INSERT INTO agent_join_tokens
		(token_hash, tenant_id, created_by, for_human, label, box_id, created_at, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6, COALESCE($7, now()), $8)`,
		t.Hash, t.TenantID, t.CreatedBy, nullable(t.ForHuman), t.Label, nullable(t.BoxID), timeOrNil(t.CreatedAt), t.ExpiresAt)
	if isUniqueViolation(err) {
		return ErrConflict
	}
	return mapFK(err)
}

// timeOrNil is a zero time as SQL NULL.
func timeOrNil(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t
}

func (s *Postgres) ListJoinTokens(ctx context.Context, tenant string, now time.Time) ([]JoinToken, error) {
	var out []JoinToken
	err := s.queryTenant(ctx, tenant, `SELECT `+joinRowCols+` FROM agent_join_tokens
		WHERE tenant_id = $1 AND expires_at > $2 ORDER BY created_at DESC LIMIT $3`,
		[]any{tenant, now, joinListMax}, func(rows pgx.Rows) error {
			t, err := scanJoinToken(rows)
			out = append(out, t)
			return err
		})
	return out, err
}

func (s *Postgres) RevokeJoinToken(ctx context.Context, tenant, id string, now time.Time) (JoinToken, error) {
	var hit JoinToken
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var hits []JoinToken
		err := eachRow(ctx, tx, `SELECT `+joinRowCols+` FROM agent_join_tokens
			WHERE tenant_id = $1 AND left(token_hash, $3) = $2 AND length($2) = $3 FOR UPDATE`,
			[]any{tenant, id, JoinTokenIDLen}, func(rows pgx.Rows) error {
				t, err := scanJoinToken(rows)
				hits = append(hits, t)
				return err
			})
		switch {
		case err != nil:
			return err
		case len(hits) != 1:
			return ErrNotFound
		}
		hit = hits[0]
		switch {
		case hit.RevokedAt != nil:
			return nil
		case hit.ConsumedAt != nil:
			return ErrJoinTokenUsed
		}
		hit.RevokedAt = &now
		_, err = tx.Exec(ctx, `UPDATE agent_join_tokens SET revoked_at = $3
			WHERE tenant_id = $1 AND token_hash = $2`, tenant, hit.Hash, now)
		return err
	})
	return hit, err
}

func (s *Postgres) RedeemJoinToken(ctx context.Context, tenant, hash, box string, pub ed25519.PublicKey, now time.Time) (JoinToken, error) {
	defer s.hot.forget()
	var tok JoinToken
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		tok, err = scanJoinToken(tx.QueryRow(ctx, `SELECT `+joinRowCols+` FROM agent_join_tokens
			WHERE tenant_id = $1 AND token_hash = $2 FOR UPDATE`, tenant, hash))
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrJoinTokenInvalid
		}
		if err != nil {
			return err
		}
		if err := tok.redeemable(box, now); err != nil {
			return err
		}
		// Two redeems of the same key into two workspaces serialise here, so
		// the read below sees the other's committed pin (spec 108 3.1).
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 73))`, hex.EncodeToString(pub)); err != nil {
			return err
		}
		if taken, err := s.keyLiveElsewhere(ctx, tenant, box, pub); err != nil {
			return err
		} else if taken {
			return ErrConflict
		}
		if err := joinPin(ctx, tx, tenant, box, pub, now); err != nil {
			return err
		}
		tok.ConsumedAt, tok.ConsumedBox = &now, box
		_, err = tx.Exec(ctx, `UPDATE agent_join_tokens SET consumed_at = $3, consumed_box = $4
			WHERE tenant_id = $1 AND token_hash = $2`, tenant, hash, now, box)
		return err
	})
	return tok, err
}

// joinPin is PutPin without force for a redeem: the same key on the active
// pin writes nothing, another key is ErrConflict, an absent or revoked pin is
// (re)seated with pins_history.reason join.
func joinPin(ctx context.Context, tx pgx.Tx, tenant, box string, pub ed25519.PublicKey, now time.Time) error {
	var old []byte
	var revokedAt *time.Time
	err := tx.QueryRow(ctx, `SELECT pubkey, revoked_at FROM pins
		WHERE tenant_id = $1 AND box_id = $2 FOR UPDATE`, tenant, box).Scan(&old, &revokedAt)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
	case err != nil:
		return err
	case revokedAt == nil && bytes.Equal(old, pub):
		return nil
	case revokedAt == nil:
		return ErrConflict
	}
	if _, err := tx.Exec(ctx, `INSERT INTO pins (tenant_id, box_id, pubkey, updated_at, revoked_at, last_op_ts)
		VALUES ($1, $2, $3, $4, NULL, $4)
		ON CONFLICT (tenant_id, box_id) DO UPDATE SET pubkey = EXCLUDED.pubkey, updated_at = EXCLUDED.updated_at,
			revoked_at = NULL, last_op_ts = GREATEST(pins.last_op_ts, EXCLUDED.last_op_ts)`,
		tenant, box, []byte(pub), now); err != nil {
		return mapFK(err)
	}
	_, err = tx.Exec(ctx, `INSERT INTO pins_history (tenant_id, box_id, pubkey, at, reason)
		VALUES ($1, $2, $3, $4, 'join')`, tenant, box, []byte(pub), now)
	return err
}

// keyLiveElsewhere reports whether pub is the live key of any other box of
// any workspace, box-wui aside (spec 108 3.1). A bool only: the caller never
// learns which workspace holds it.
func (s *Postgres) keyLiveElsewhere(ctx context.Context, tenant, box string, pub ed25519.PublicKey) (bool, error) {
	var taken bool
	err := s.asOperatorQuery(ctx, `SELECT EXISTS (SELECT 1 FROM pins
		WHERE pubkey = $1 AND revoked_at IS NULL AND box_id <> $4
		AND NOT (tenant_id = $2 AND box_id = $3))`,
		[]any{[]byte(pub), tenant, box, wuiBox}, func(rows pgx.Rows) error { return rows.Scan(&taken) })
	return taken, err
}

func (s *Postgres) RevokeSeat(ctx context.Context, tenant, box string, now time.Time) error {
	defer s.hot.forget()
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var pub []byte
		var revokedAt *time.Time
		err := tx.QueryRow(ctx, `SELECT pubkey, revoked_at FROM pins
			WHERE tenant_id = $1 AND box_id = $2 FOR UPDATE`, tenant, box).Scan(&pub, &revokedAt)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			return ErrNotFound
		case err != nil:
			return err
		case revokedAt != nil:
			return nil
		}
		// last_op_ts moves forward only: a replayed root-signed op older than
		// this revoke stays stale.
		if _, err := tx.Exec(ctx, `UPDATE pins SET revoked_at = $3,
			last_op_ts = GREATEST(last_op_ts, $3) WHERE tenant_id = $1 AND box_id = $2`, tenant, box, now); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO pins_history (tenant_id, box_id, pubkey, at, reason)
			VALUES ($1, $2, $3, $4, 'wui-revoke')`, tenant, box, pub, now)
		return err
	})
}
