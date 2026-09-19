package store

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
)

// Postgres is the production Store. Its queries match the DDL in
// csi-spl-rdb/src/sql/postgres/spool-hub/ (applied by Migrate); it invents no
// table of its own.
type Postgres struct{ pool *pgxpool.Pool }

// PoolLimits sizes the connection pool (specs/027 T010). A zero field keeps
// pgx's default, and a pool_* parameter the DSN sets wins over its field, so a
// test's "&pool_max_conns=1" still gets a one-connection pool.
type PoolLimits struct {
	MaxConns        int32         // pool_max_conns
	MinConns        int32         // pool_min_conns
	MaxConnIdleTime time.Duration // pool_max_conn_idle_time
}

// OpenPostgres connects to dsn and pings it. Without limits the pool is pgx's
// default (MaxConns max(4, NumCPU)).
func OpenPostgres(ctx context.Context, dsn string, limits ...PoolLimits) (*Postgres, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("open postgres: %w", err)
	}
	for _, l := range limits {
		if l.MaxConns > 0 && !dsnSets(dsn, "pool_max_conns") {
			cfg.MaxConns = l.MaxConns
		}
		if l.MinConns > 0 && !dsnSets(dsn, "pool_min_conns") {
			cfg.MinConns = l.MinConns
		}
		if l.MaxConnIdleTime > 0 && !dsnSets(dsn, "pool_max_conn_idle_time") {
			cfg.MaxConnIdleTime = l.MaxConnIdleTime
		}
	}
	if cfg.MinConns > cfg.MaxConns {
		cfg.MinConns = cfg.MaxConns
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("open postgres: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping postgres: %w", err)
	}
	return &Postgres{pool: pool}, nil
}

// dsnSets reports whether dsn (URL or keyword/value form) names key.
func dsnSets(dsn, key string) bool {
	if strings.HasPrefix(dsn, "postgres://") || strings.HasPrefix(dsn, "postgresql://") {
		u, err := url.Parse(dsn)
		return err == nil && u.Query().Has(key)
	}
	for _, f := range strings.Fields(dsn) {
		if k, _, ok := strings.Cut(f, "="); ok && k == key {
			return true
		}
	}
	return false
}

// Pool exposes the connection pool (for the migrator and tests).
func (s *Postgres) Pool() *pgxpool.Pool { return s.pool }

func (s *Postgres) Close() { s.pool.Close() }

func (s *Postgres) CreateTenant(ctx context.Context, t Tenant) error {
	if err := normalizeTenant(&t); err != nil {
		return err
	}
	tag, err := s.execTenant(ctx, t.ID, `INSERT INTO tenants (tenant_id, root_pubkey, billing_status, plan_id,
		org, app, project_id, bought_at, seats_users, seats_bots)
		VALUES ($1, $2, $3, $4, NULLIF($5, ''), NULLIF($6, ''), NULLIF($7, ''), $8, $9, $10)
		ON CONFLICT (tenant_id) DO NOTHING`,
		t.ID, []byte(t.RootPubKey), t.BillingStatus, t.PlanID,
		t.Org, t.App, t.ProjectID, nullTime(t.BoughtAt), t.SeatsUsers, t.SeatsBots)
	if isUniqueViolation(err) {
		return ErrConflict // project_id held by another tenant (0012 partial index)
	}
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
	var bought *time.Time
	err := s.queryRowTenant(ctx, id, `SELECT tenant_id, root_pubkey, billing_status, plan_id,
		COALESCE(org, ''), COALESCE(app, ''), COALESCE(project_id, ''), bought_at, seats_users, seats_bots
		FROM tenants WHERE tenant_id = $1`,
		[]any{id}, &t.ID, &root, &t.BillingStatus, &t.PlanID,
		&t.Org, &t.App, &t.ProjectID, &bought, &t.SeatsUsers, &t.SeatsBots)
	if errors.Is(err, pgx.ErrNoRows) {
		return Tenant{}, ErrNotFound
	}
	t.RootPubKey = ed25519.PublicKey(root)
	if bought != nil {
		t.BoughtAt = bought.UTC()
	}
	return t, err
}

func (s *Postgres) SetBillingStatus(ctx context.Context, id, status string) error {
	if !billing.ValidStatus(status) {
		return fmt.Errorf("invalid billing_status %q", status)
	}
	tag, err := s.execTenant(ctx, id, `UPDATE tenants SET billing_status = $2 WHERE tenant_id = $1`, id, status)
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
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
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
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
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
	err := s.queryRowTenant(ctx, tenant, `SELECT pubkey FROM pins
		WHERE tenant_id = $1 AND box_id = $2 AND revoked_at IS NULL`,
		[]any{tenant, box}, &pub)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return ed25519.PublicKey(pub), err
}

func (s *Postgres) ListPins(ctx context.Context, tenant string) ([]Pin, error) {
	var out []Pin
	err := s.queryTenant(ctx, tenant, `SELECT box_id, pubkey FROM pins
		WHERE tenant_id = $1 AND revoked_at IS NULL ORDER BY box_id`, []any{tenant}, func(rows pgx.Rows) error {
		var p Pin
		var pub []byte
		if err := rows.Scan(&p.BoxID, &pub); err != nil {
			return err
		}
		p.PubKey = ed25519.PublicKey(pub)
		out = append(out, p)
		return nil
	})
	return out, err
}

func (s *Postgres) TouchBox(ctx context.Context, tenant, box string, now time.Time) error {
	_, err := s.execTenant(ctx, tenant, `INSERT INTO boxes (tenant_id, box_id, last_hello_at) VALUES ($1, $2, $3)
		ON CONFLICT (tenant_id, box_id) DO UPDATE SET last_hello_at = EXCLUDED.last_hello_at`, tenant, box, now)
	return mapFK(err)
}

func (s *Postgres) SetRoster(ctx context.Context, tenant, box string, agents []string, now time.Time) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if err := s.botSeatGate(ctx, tx, tenant, box, agents); err != nil {
			return err
		}
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
	out := map[string][]string{}
	err := s.queryTenant(ctx, tenant, `SELECT box_id, agent_id FROM roster WHERE tenant_id = $1`,
		[]any{tenant}, func(rows pgx.Rows) error {
			var b, a string
			if err := rows.Scan(&b, &a); err != nil {
				return err
			}
			out[b] = append(out[b], a)
			return nil
		})
	for b := range out {
		sort.Strings(out[b])
	}
	return out, err
}

func (s *Postgres) InsertMessage(ctx context.Context, m Message) (bool, error) {
	var channel, parent any
	if m.Channel != "" {
		channel = m.Channel
	}
	if m.ParentTaskID != "" {
		parent = m.ParentTaskID
	}
	tag, err := s.execTenant(ctx, m.TenantID, `INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts,
			from_box, from_id, to_box, to_id, kind, body, files, msg, env_sig, env, received_at, expires_at, parent_task_id)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18)
		ON CONFLICT (tenant_id, msg_id) DO NOTHING`,
		m.TenantID, m.MsgID, m.TaskID, channel, m.TS, m.FromBox, m.FromID, m.ToBox, m.ToID,
		m.Kind, m.Body, string(m.Files), string(m.Msg), m.EnvSig, m.Env, m.ReceivedAt, m.ExpiresAt, parent)
	if err != nil {
		return false, mapFK(err)
	}
	if tag.RowsAffected() == 1 {
		return true, nil
	}
	var old []byte
	if err := s.queryRowTenant(ctx, m.TenantID, `SELECT env FROM messages WHERE tenant_id = $1 AND msg_id = $2`,
		[]any{m.TenantID, m.MsgID}, &old); err != nil {
		return false, err
	}
	if bytes.Equal(old, m.Env) {
		return false, nil
	}
	return false, ErrConflict
}

// Enqueue is one batch, so one round trip in one implicit transaction (027
// T040: the BEGIN / scope / insert / cap / COMMIT form took five). The cap
// runs under a per-(tenant, box) transaction advisory lock: two concurrent cap
// UPDATEs lock overlapping rows in different orders and deadlock (measured on
// pg16: 195 of 2000 sends at c=50 to one over-cap box answered 500). A send
// that finds the lock held skips the cap; the holder trims, and the next send
// trims whatever this one added. With no concurrency the cap is exact as before.
func (s *Postgres) Enqueue(ctx context.Context, tenant, msgID, toBox string, now, expires time.Time, maxPerBox int) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	b := &pgx.Batch{}
	b.Queue(pgScopeTenant, tenant)
	b.Queue(`INSERT INTO deliveries (tenant_id, msg_id, to_box, state, received_at, expires_at)
		VALUES ($1, $2, $3, 'queued', $4, $5) ON CONFLICT DO NOTHING`,
		tenant, msgID, toBox, now, expires)
	if maxPerBox > 0 {
		b.Queue(`WITH capper AS (SELECT pg_try_advisory_xact_lock(hashtextextended('deliveries-cap/' || $1 || '/' || $2, 0)) AS got)
			UPDATE deliveries SET state = 'expired'
			WHERE (SELECT got FROM capper) AND (tenant_id, msg_id, to_box) IN (
				SELECT tenant_id, msg_id, to_box FROM deliveries
				WHERE tenant_id = $1 AND to_box = $2 AND state = 'queued'
				ORDER BY received_at DESC, msg_id DESC OFFSET $3)`, tenant, toBox, maxPerBox)
	}
	return s.pool.SendBatch(ctx, b).Close()
}

func (s *Postgres) ClaimSent(ctx context.Context, tenant, msgID, toBox string, now time.Time) (bool, error) {
	tag, err := s.execTenant(ctx, tenant, `UPDATE deliveries SET state = 'sent', sent_at = $4
		WHERE tenant_id = $1 AND msg_id = $2 AND to_box = $3 AND state = 'queued' AND expires_at > $4`,
		tenant, msgID, toBox, now)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

func (s *Postgres) Unclaim(ctx context.Context, tenant, msgID, toBox string) error {
	_, err := s.execTenant(ctx, tenant, `UPDATE deliveries SET state = 'queued', sent_at = NULL
		WHERE tenant_id = $1 AND msg_id = $2 AND to_box = $3 AND state = 'sent'`, tenant, msgID, toBox)
	return err
}

func (s *Postgres) DeliveryState(ctx context.Context, tenant, msgID, toBox string) (string, error) {
	var st string
	err := s.queryRowTenant(ctx, tenant, `SELECT state FROM deliveries
		WHERE tenant_id = $1 AND msg_id = $2 AND to_box = $3`,
		[]any{tenant, msgID, toBox}, &st)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	return st, err
}

func (s *Postgres) QueuedFor(ctx context.Context, tenant, toBox string, now time.Time) ([]Queued, error) {
	var out []Queued
	err := s.queryTenant(ctx, tenant, `SELECT d.msg_id::text, m.env FROM deliveries d
		JOIN messages m ON m.tenant_id = d.tenant_id AND m.msg_id = d.msg_id
		WHERE d.tenant_id = $1 AND d.to_box = $2 AND d.state = 'queued' AND d.expires_at > $3
		ORDER BY d.received_at, d.msg_id`, []any{tenant, toBox, now}, func(rows pgx.Rows) error {
		var q Queued
		if err := rows.Scan(&q.MsgID, &q.Env); err != nil {
			return err
		}
		out = append(out, q)
		return nil
	})
	return out, err
}

func (s *Postgres) TaskEnvelopes(ctx context.Context, tenant, taskID string) ([][]byte, error) {
	var out [][]byte
	err := s.queryTenant(ctx, tenant, `SELECT env FROM messages WHERE tenant_id = $1 AND task_id = $2
		ORDER BY ts, msg_id`, []any{tenant, taskID}, func(rows pgx.Rows) error {
		var e []byte
		if err := rows.Scan(&e); err != nil {
			return err
		}
		out = append(out, e)
		return nil
	})
	return out, err
}

func (s *Postgres) Sweep(ctx context.Context, now time.Time) (SweepResult, error) {
	// Retention is global by design: the one hub job that runs asOperator.
	var r SweepResult
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE deliveries SET state = 'expired'
			WHERE state = 'queued' AND expires_at <= $1`, now)
		if err != nil {
			return err
		}
		r.Expired = int(tag.RowsAffected())
		tag, err = tx.Exec(ctx, `DELETE FROM messages WHERE expires_at <= $1`, now)
		if err != nil {
			return err
		}
		r.Purged = int(tag.RowsAffected())
		return nil
	})
	if err != nil {
		return SweepResult{}, err
	}
	return r, nil
}

func (s *Postgres) CountMessagesSince(ctx context.Context, tenant string, since time.Time) (int, error) {
	var n int
	err := s.queryRowTenant(ctx, tenant, `SELECT COUNT(*) FROM messages WHERE tenant_id = $1 AND received_at >= $2`,
		[]any{tenant, since}, &n)
	return n, err
}

func (s *Postgres) HasMessage(ctx context.Context, tenant, msgID string) (bool, error) {
	var ok bool
	err := s.queryRowTenant(ctx, tenant, `SELECT EXISTS(SELECT 1 FROM messages WHERE tenant_id = $1 AND msg_id = $2)`,
		[]any{tenant, msgID}, &ok)
	return ok, err
}

func (s *Postgres) MessageTimes(ctx context.Context, tenant, msgID string) (ts, receivedAt time.Time, err error) {
	err = s.queryRowTenant(ctx, tenant, `SELECT ts, received_at FROM messages WHERE tenant_id = $1 AND msg_id = $2`,
		[]any{tenant, msgID}, &ts, &receivedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		err = ErrNotFound
	}
	return ts, receivedAt, err
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
