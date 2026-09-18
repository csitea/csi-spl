package store

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
)

// Postgres is the production Store. Its queries match the DDL in
// csi-spl-rdb/src/sql/postgres/spool-hub/ (applied by Migrate); it invents no
// table of its own.
type Postgres struct{ pool *pgxpool.Pool }

// OpenPostgres connects to dsn and pings it.
func OpenPostgres(ctx context.Context, dsn string) (*Postgres, error) {
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("open postgres: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping postgres: %w", err)
	}
	return &Postgres{pool: pool}, nil
}

// Pool exposes the connection pool (for the migrator and tests).
func (s *Postgres) Pool() *pgxpool.Pool { return s.pool }

func (s *Postgres) Close() { s.pool.Close() }

func (s *Postgres) CreateTenant(ctx context.Context, t Tenant) error {
	if err := normalizeTenant(&t); err != nil {
		return err
	}
	tag, err := s.pool.Exec(ctx, `INSERT INTO tenants (tenant_id, root_pubkey, billing_status, plan_id)
		VALUES ($1, $2, $3, $4) ON CONFLICT (tenant_id) DO NOTHING`,
		t.ID, []byte(t.RootPubKey), t.BillingStatus, t.PlanID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 1 {
		return nil
	}
	old, err := s.GetTenant(ctx, t.ID)
	if err != nil {
		return err
	}
	if !bytes.Equal(old.RootPubKey, t.RootPubKey) {
		return ErrConflict
	}
	return nil
}

func (s *Postgres) GetTenant(ctx context.Context, id string) (Tenant, error) {
	var t Tenant
	var root []byte
	err := s.pool.QueryRow(ctx, `SELECT tenant_id, root_pubkey, billing_status, plan_id
		FROM tenants WHERE tenant_id = $1`, id).Scan(&t.ID, &root, &t.BillingStatus, &t.PlanID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Tenant{}, ErrNotFound
	}
	t.RootPubKey = ed25519.PublicKey(root)
	return t, err
}

func (s *Postgres) SetBillingStatus(ctx context.Context, id, status string) error {
	if !billing.ValidStatus(status) {
		return fmt.Errorf("invalid billing_status %q", status)
	}
	tag, err := s.pool.Exec(ctx, `UPDATE tenants SET billing_status = $2 WHERE tenant_id = $1`, id, status)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) PutPin(ctx context.Context, tenant, box string, pub ed25519.PublicKey, force bool, opTS, now time.Time) error {
	opTS = opTS.Truncate(time.Microsecond) // timestamptz precision: compare like Postgres stores
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		var old []byte
		var revokedAt, lastOp *time.Time
		err := tx.QueryRow(ctx, `SELECT pubkey, revoked_at, last_op_ts FROM pins
			WHERE tenant_id = $1 AND box_id = $2 FOR UPDATE`, tenant, box).Scan(&old, &revokedAt, &lastOp)
		reason := "pin"
		switch {
		case errors.Is(err, pgx.ErrNoRows):
		case err != nil:
			return err
		case bytes.Equal(old, pub) && revokedAt == nil:
			return nil
		case !force:
			return ErrConflict
		case lastOp != nil && !opTS.After(*lastOp):
			return ErrStale
		default:
			reason = "force"
		}
		if _, err := tx.Exec(ctx, `INSERT INTO pins (tenant_id, box_id, pubkey, updated_at, revoked_at, last_op_ts)
			VALUES ($1, $2, $3, $4, NULL, $5)
			ON CONFLICT (tenant_id, box_id) DO UPDATE SET pubkey = EXCLUDED.pubkey,
				updated_at = EXCLUDED.updated_at, revoked_at = NULL, last_op_ts = EXCLUDED.last_op_ts`,
			tenant, box, []byte(pub), now, opTS); err != nil {
			return mapFK(err)
		}
		_, err = tx.Exec(ctx, `INSERT INTO pins_history (tenant_id, box_id, pubkey, at, reason)
			VALUES ($1, $2, $3, $4, $5)`, tenant, box, []byte(pub), now, reason)
		return err
	})
}

func (s *Postgres) RevokePin(ctx context.Context, tenant, box string, opTS, now time.Time) error {
	opTS = opTS.Truncate(time.Microsecond) // timestamptz precision: compare like Postgres stores
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		var pub []byte
		var revokedAt, lastOp *time.Time
		err := tx.QueryRow(ctx, `SELECT pubkey, revoked_at, last_op_ts FROM pins
			WHERE tenant_id = $1 AND box_id = $2 FOR UPDATE`, tenant, box).Scan(&pub, &revokedAt, &lastOp)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			return ErrNotFound
		case err != nil:
			return err
		case revokedAt != nil:
			return nil
		case lastOp != nil && !opTS.After(*lastOp):
			return ErrStale
		}
		if _, err := tx.Exec(ctx, `UPDATE pins SET revoked_at = $3, last_op_ts = $4
			WHERE tenant_id = $1 AND box_id = $2`, tenant, box, now, opTS); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO pins_history (tenant_id, box_id, pubkey, at, reason)
			VALUES ($1, $2, $3, $4, 'revoke')`, tenant, box, pub, now)
		return err
	})
}

func (s *Postgres) GetPin(ctx context.Context, tenant, box string) (ed25519.PublicKey, error) {
	var pub []byte
	err := s.pool.QueryRow(ctx, `SELECT pubkey FROM pins
		WHERE tenant_id = $1 AND box_id = $2 AND revoked_at IS NULL`, tenant, box).Scan(&pub)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return ed25519.PublicKey(pub), err
}

func (s *Postgres) ListPins(ctx context.Context, tenant string) ([]Pin, error) {
	rows, err := s.pool.Query(ctx, `SELECT box_id, pubkey FROM pins
		WHERE tenant_id = $1 AND revoked_at IS NULL ORDER BY box_id`, tenant)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Pin
	for rows.Next() {
		var p Pin
		var pub []byte
		if err := rows.Scan(&p.BoxID, &pub); err != nil {
			return nil, err
		}
		p.PubKey = ed25519.PublicKey(pub)
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Postgres) TouchBox(ctx context.Context, tenant, box string, now time.Time) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO boxes (tenant_id, box_id, last_hello_at) VALUES ($1, $2, $3)
		ON CONFLICT (tenant_id, box_id) DO UPDATE SET last_hello_at = EXCLUDED.last_hello_at`, tenant, box, now)
	return mapFK(err)
}

func (s *Postgres) SetRoster(ctx context.Context, tenant, box string, agents []string, now time.Time) error {
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO boxes (tenant_id, box_id) VALUES ($1, $2)
			ON CONFLICT (tenant_id, box_id) DO NOTHING`, tenant, box); err != nil {
			return mapFK(err)
		}
		if _, err := tx.Exec(ctx, `DELETE FROM roster WHERE tenant_id = $1 AND box_id = $2`, tenant, box); err != nil {
			return err
		}
		for _, a := range agents {
			if _, err := tx.Exec(ctx, `INSERT INTO roster (tenant_id, box_id, agent_id, announced_at)
				VALUES ($1, $2, $3, $4)`, tenant, box, a, now); err != nil {
				return err
			}
		}
		return nil
	})
}

func (s *Postgres) Roster(ctx context.Context, tenant string) (map[string][]string, error) {
	rows, err := s.pool.Query(ctx, `SELECT box_id, agent_id FROM roster WHERE tenant_id = $1`, tenant)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string][]string{}
	for rows.Next() {
		var b, a string
		if err := rows.Scan(&b, &a); err != nil {
			return nil, err
		}
		out[b] = append(out[b], a)
	}
	for b := range out {
		sort.Strings(out[b])
	}
	return out, rows.Err()
}

func (s *Postgres) InsertMessage(ctx context.Context, m Message) (bool, error) {
	var channel any
	if m.Channel != "" {
		channel = m.Channel
	}
	tag, err := s.pool.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts,
			from_box, from_id, to_box, to_id, kind, body, files, msg, env_sig, env, received_at, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17)
		ON CONFLICT (tenant_id, msg_id) DO NOTHING`,
		m.TenantID, m.MsgID, m.TaskID, channel, m.TS, m.FromBox, m.FromID, m.ToBox, m.ToID,
		m.Kind, m.Body, string(m.Files), string(m.Msg), m.EnvSig, m.Env, m.ReceivedAt, m.ExpiresAt)
	if err != nil {
		return false, mapFK(err)
	}
	if tag.RowsAffected() == 1 {
		return true, nil
	}
	var old []byte
	if err := s.pool.QueryRow(ctx, `SELECT env FROM messages WHERE tenant_id = $1 AND msg_id = $2`,
		m.TenantID, m.MsgID).Scan(&old); err != nil {
		return false, err
	}
	if bytes.Equal(old, m.Env) {
		return false, nil
	}
	return false, ErrConflict
}

func (s *Postgres) Enqueue(ctx context.Context, tenant, msgID, toBox string, now, expires time.Time, maxPerBox int) error {
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO deliveries (tenant_id, msg_id, to_box, state, received_at, expires_at)
			VALUES ($1, $2, $3, 'queued', $4, $5) ON CONFLICT DO NOTHING`,
			tenant, msgID, toBox, now, expires); err != nil {
			return err
		}
		if maxPerBox <= 0 {
			return nil
		}
		_, err := tx.Exec(ctx, `UPDATE deliveries SET state = 'expired'
			WHERE (tenant_id, msg_id, to_box) IN (
				SELECT tenant_id, msg_id, to_box FROM deliveries
				WHERE tenant_id = $1 AND to_box = $2 AND state = 'queued'
				ORDER BY received_at DESC, msg_id DESC OFFSET $3)`, tenant, toBox, maxPerBox)
		return err
	})
}

func (s *Postgres) ClaimSent(ctx context.Context, tenant, msgID, toBox string, now time.Time) (bool, error) {
	tag, err := s.pool.Exec(ctx, `UPDATE deliveries SET state = 'sent', sent_at = $4
		WHERE tenant_id = $1 AND msg_id = $2 AND to_box = $3 AND state = 'queued' AND expires_at > $4`,
		tenant, msgID, toBox, now)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

func (s *Postgres) Unclaim(ctx context.Context, tenant, msgID, toBox string) error {
	_, err := s.pool.Exec(ctx, `UPDATE deliveries SET state = 'queued', sent_at = NULL
		WHERE tenant_id = $1 AND msg_id = $2 AND to_box = $3 AND state = 'sent'`, tenant, msgID, toBox)
	return err
}

func (s *Postgres) DeliveryState(ctx context.Context, tenant, msgID, toBox string) (string, error) {
	var st string
	err := s.pool.QueryRow(ctx, `SELECT state FROM deliveries
		WHERE tenant_id = $1 AND msg_id = $2 AND to_box = $3`, tenant, msgID, toBox).Scan(&st)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	return st, err
}

func (s *Postgres) QueuedFor(ctx context.Context, tenant, toBox string, now time.Time) ([]Queued, error) {
	rows, err := s.pool.Query(ctx, `SELECT d.msg_id::text, m.env FROM deliveries d
		JOIN messages m ON m.tenant_id = d.tenant_id AND m.msg_id = d.msg_id
		WHERE d.tenant_id = $1 AND d.to_box = $2 AND d.state = 'queued' AND d.expires_at > $3
		ORDER BY d.received_at, d.msg_id`, tenant, toBox, now)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Queued
	for rows.Next() {
		var q Queued
		if err := rows.Scan(&q.MsgID, &q.Env); err != nil {
			return nil, err
		}
		out = append(out, q)
	}
	return out, rows.Err()
}

func (s *Postgres) TaskEnvelopes(ctx context.Context, tenant, taskID string) ([][]byte, error) {
	rows, err := s.pool.Query(ctx, `SELECT env FROM messages WHERE tenant_id = $1 AND task_id = $2
		ORDER BY ts, msg_id`, tenant, taskID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out [][]byte
	for rows.Next() {
		var e []byte
		if err := rows.Scan(&e); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func (s *Postgres) Sweep(ctx context.Context, now time.Time) (SweepResult, error) {
	var r SweepResult
	tag, err := s.pool.Exec(ctx, `UPDATE deliveries SET state = 'expired'
		WHERE state = 'queued' AND expires_at <= $1`, now)
	if err != nil {
		return r, err
	}
	r.Expired = int(tag.RowsAffected())
	tag, err = s.pool.Exec(ctx, `DELETE FROM messages WHERE expires_at <= $1`, now)
	if err != nil {
		return r, err
	}
	r.Purged = int(tag.RowsAffected())
	return r, nil
}

func (s *Postgres) CountMessagesSince(ctx context.Context, tenant string, since time.Time) (int, error) {
	var n int
	err := s.pool.QueryRow(ctx, `SELECT COUNT(*) FROM messages WHERE tenant_id = $1 AND received_at >= $2`,
		tenant, since).Scan(&n)
	return n, err
}

func (s *Postgres) HasMessage(ctx context.Context, tenant, msgID string) (bool, error) {
	var ok bool
	err := s.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM messages WHERE tenant_id = $1 AND msg_id = $2)`,
		tenant, msgID).Scan(&ok)
	return ok, err
}

// mapFK turns a foreign-key violation (unknown tenant) into ErrNotFound.
func mapFK(err error) error {
	if err == nil {
		return nil
	}
	var pe interface{ SQLState() string }
	if errors.As(err, &pe) && pe.SQLState() == "23503" {
		return ErrNotFound
	}
	return err
}
