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
//
// clock is the store's wall clock for its TTL caches and catalogue probes
// (opCache, seats, wsState, opFlag); nil = time.Now. Tests set it to step
// past a TTL without sleeping.
type Postgres struct {
	pool  *pgxpool.Pool
	clock func() time.Time
	hot   hotCache // pins and tenant rows of the send path (hotcache.go)
	// seats: is rdb 0107 agent_seats there yet (agent_seats.go)
	seats seatsProbe
	// access: is rdb 0113 tenant_memberships.access_until there yet (access_until.go)
	access seatsProbe
	// wsState: is rdb 0115 tenants.suspended_at there yet (operator_workspaces.go)
	wsState seatsProbe
	// opFlag: is rdb 0116 tenants.is_operator there yet; opCache: the flagged
	// workspace (operator_flag.go)
	opFlag  seatsProbe
	opCache operatorCache
	// cal: is rdb 0125 calendar_events there yet (calendar_postgres.go)
	cal seatsProbe
	// calEdit: are rdb 0139's calendar_events columns there yet (calendar_postgres.go)
	calEdit seatsProbe
	// sig: is rdb 0135 messages.search_sig there yet (search_postgres.go)
	sig seatsProbe
	// idx: is rdb 0143 spool_search_candidates there and executable (search_postgres.go)
	idx seatsProbe
	// humStatus: is rdb 0141 human_status there yet (human_status.go)
	humStatus seatsProbe
	// kv: is rdb 0136 tenants.settings there yet (tenant_kv.go)
	kv seatsProbe
	// heads: the head read switch and the rdb 0144 probe (view_topics_head.go)
	heads topicHeads
}

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
	cfg.ShouldPing = shouldPing
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

// now reads s.clock, or time.Now when no clock is set.
func (s *Postgres) now() time.Time {
	if s.clock != nil {
		return s.clock()
	}
	return time.Now()
}

// pingIdle is how long a connection may sit idle before Acquire pings it
// (db-payload audit cut 8). pgx's default pings after 1 s, so the first
// request of nearly every burst paid one extra round trip; the background
// HealthCheckPeriod (pgx default 1 min) still checks idle connections.
const pingIdle = 30 * time.Second

func shouldPing(_ context.Context, p pgxpool.ShouldPingParams) bool {
	return p.IdleDuration > pingIdle
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
	defer s.hot.forget()
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
	old, err := s.getTenant(ctx, t.ID) // fresh: the conflict check must not read the cache
	if err != nil {
		return err
	}
	if !bytes.Equal(old.RootPubKey, t.RootPubKey) {
		return ErrConflict
	}
	return nil
}

func (s *Postgres) GetTenant(ctx context.Context, id string) (Tenant, error) {
	if t, ok := s.hot.tenant(id); ok {
		return t, nil
	}
	gen := s.hot.generation()
	t, err := s.getTenant(ctx, id)
	if err == nil {
		s.hot.putTenant(gen, t)
	}
	return t, err
}

func (s *Postgres) getTenant(ctx context.Context, id string) (Tenant, error) {
	var t Tenant
	var root []byte
	var bought, sus, arc *time.Time
	var kv []byte
	err := s.queryRowTenant(ctx, id, `SELECT tenant_id, root_pubkey, billing_status, plan_id,
		COALESCE(org, ''), COALESCE(app, ''), COALESCE(project_id, ''), bought_at, seats_users, seats_bots,
		COALESCE(topic_archive_policy, ''), `+workspaceStateCols(s.hasWorkspaceState(ctx))+`,
		`+tenantSettingsCol(s.hasTenantSettings(ctx))+`
		FROM tenants WHERE tenant_id = $1`,
		[]any{id}, &t.ID, &root, &t.BillingStatus, &t.PlanID,
		&t.Org, &t.App, &t.ProjectID, &bought, &t.SeatsUsers, &t.SeatsBots, &t.TopicArchivePolicy, &sus, &arc, &kv)
	if errors.Is(err, pgx.ErrNoRows) {
		return Tenant{}, ErrNotFound
	}
	t.RootPubKey = ed25519.PublicKey(root)
	t.Settings = decodeTenantSettings(kv)
	t.SuspendedAt, t.ArchivedAt = timeOf(sus), timeOf(arc)
	if bought != nil {
		t.BoughtAt = bought.UTC()
	}
	return t, err
}

func (s *Postgres) SetBillingStatus(ctx context.Context, id, status string) error {
	defer s.hot.forget()
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
	defer s.hot.forget()
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
	defer s.hot.forget()
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
	if pub, ok := s.hot.pin(tenant, box); ok {
		return pub, nil
	}
	gen := s.hot.generation()
	pub, err := s.getPin(ctx, tenant, box)
	if err == nil {
		s.hot.putPin(gen, tenant, box, pub)
	}
	return pub, err
}

func (s *Postgres) getPin(ctx context.Context, tenant, box string) (ed25519.PublicKey, error) {
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
		// One round trip for the replace: box row, clear, one multi-row insert
		// (027 T010: it was one INSERT per agent).
		b := &pgx.Batch{}
		b.Queue(`INSERT INTO boxes (tenant_id, box_id) VALUES ($1, $2)
			ON CONFLICT (tenant_id, box_id) DO NOTHING`, tenant, box)
		if len(agents) > 0 && s.hasAgentSeats(ctx) {
			// rdb 0107 (spec 061 3.6): an id that is not in the box's
			// current roster is a new holder's seat. Read before the clear.
			b.Queue(`INSERT INTO agent_seats (tenant_id, box_id, agent_id, seated_at)
				SELECT $1, $2, a, $4 FROM unnest($3::text[]) AS a
				WHERE NOT EXISTS (SELECT 1 FROM roster r WHERE r.tenant_id = $1 AND r.box_id = $2 AND r.agent_id = a)
				ON CONFLICT (tenant_id, box_id, agent_id) DO UPDATE SET seated_at = EXCLUDED.seated_at`,
				tenant, box, agents, now)
		}
		b.Queue(`DELETE FROM roster WHERE tenant_id = $1 AND box_id = $2`, tenant, box)
		if len(agents) > 0 {
			b.Queue(`INSERT INTO roster (tenant_id, box_id, agent_id, announced_at)
				SELECT $1, $2, a, $4 FROM unnest($3::text[]) AS a`, tenant, box, agents, now)
		}
		br := tx.SendBatch(ctx, b)
		defer br.Close()
		if _, err := br.Exec(); err != nil {
			return mapFK(err)
		}
		for i := 1; i < b.Len(); i++ {
			if _, err := br.Exec(); err != nil {
				return err
			}
		}
		return br.Close()
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

// insertMessageSQL stores a message and, when it was already stored, returns
// the stored envelope in the same round trip (DB payload cut 7): the CTE's
// INSERT .. ON CONFLICT DO NOTHING RETURNING says whether this call wrote the
// row, and `old` reads the statement's snapshot, which holds a row committed
// before it and never the one ins writes. `nfy` announces a stored row to
// the browser sockets of every hub process (spec 059 S3, store/wui_wake.go):
// Postgres sends it only on commit, and the outer SELECT reads it so it runs.
// %s is the delivery CTE, or "".
const insertMessageSQL = `WITH ins AS (
		INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts,
			from_box, from_id, to_box, to_id, kind, body, files, msg, env_sig, env, received_at, expires_at, parent_task_id, is_parent, typed_by,
			ref_task_id, mirror_of)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21::uuid, $22::uuid)
		ON CONFLICT (tenant_id, msg_id) DO NOTHING
		RETURNING 1),
	old AS (SELECT env FROM messages WHERE tenant_id = $1 AND msg_id = $2),
	nfy AS (SELECT pg_notify('` + WUIWakeChannel + `', $1 || '|' || $2::text) FROM ins)%s
	SELECT EXISTS (SELECT 1 FROM ins), (SELECT env FROM old), (SELECT count(*) FROM nfy)`

// sentDeliveryClaim makes a delivery insert claim a row left queued, as
// ClaimSent would; the row it inserts is already sent and acked.
const sentDeliveryClaim = `
		ON CONFLICT (tenant_id, msg_id, to_box) DO UPDATE SET state = 'sent', sent_at = EXCLUDED.sent_at, acked_at = EXCLUDED.acked_at
		WHERE deliveries.state = 'queued' AND deliveries.expires_at > EXCLUDED.sent_at`

var (
	// Both forms carry the flow write (spec 062, flowInsertCTE): its four
	// parameters follow the insert's.
	insertMessageOnly = fmt.Sprintf(insertMessageSQL, flowInsertCTE(23))
	// insertMessageSent adds the (msg_id, to_box) delivery row, sent and
	// acked at received_at, $23 its expiry, for a new message or a resend of
	// the identical envelope ($15) - never for a conflicting one.
	insertMessageSent = fmt.Sprintf(insertMessageSQL, `,
	del AS (INSERT INTO deliveries (tenant_id, msg_id, to_box, state, received_at, expires_at, sent_at, acked_at)
		SELECT $1, $2, $8, 'sent', $16, $23::timestamptz, $16, $16
		WHERE EXISTS (SELECT 1 FROM ins) OR (SELECT env FROM old) = $15`+sentDeliveryClaim+`)`+flowInsertCTE(24))
)

// insertSentDelivery is that delivery leg alone, for the resend that raced
// its original's commit.
const insertSentDelivery = `INSERT INTO deliveries (tenant_id, msg_id, to_box, state, received_at, expires_at, sent_at, acked_at)
		VALUES ($1, $2, $3, 'sent', $4, $5, $4, $4)` + sentDeliveryClaim

func (s *Postgres) InsertMessage(ctx context.Context, m Message) (bool, error) {
	return s.insertMessage(ctx, m, time.Time{})
}

// InsertMessageSent: see SentInserter.
func (s *Postgres) InsertMessageSent(ctx context.Context, m Message, deliveryExpires time.Time) (bool, error) {
	return s.insertMessage(ctx, m, deliveryExpires)
}

// insertMessage is InsertMessage, plus the sent delivery row when
// sentExpires is set; one round trip for a new message and for a resend.
func (s *Postgres) insertMessage(ctx context.Context, m Message, sentExpires time.Time) (bool, error) {
	sql, args := insertMessageArgs(m, sentExpires)
	sent := !sentExpires.IsZero()
	var inserted bool
	var old []byte
	var notified int64
	if err := s.queryRowTenant(ctx, m.TenantID, sql, args, &inserted, &old, &notified); err != nil {
		return false, mapFK(err)
	}
	if inserted {
		return true, nil
	}
	if old == nil {
		// The row's writer committed after this statement's snapshot (ON
		// CONFLICT waited for it), so neither `old` nor the delivery leg saw it.
		if err := s.queryRowTenant(ctx, m.TenantID, `SELECT env FROM messages WHERE tenant_id = $1 AND msg_id = $2`,
			[]any{m.TenantID, m.MsgID}, &old); err != nil {
			return false, err
		}
		if sent && bytes.Equal(old, m.Env) {
			if _, err := s.execTenant(ctx, m.TenantID, insertSentDelivery,
				m.TenantID, m.MsgID, m.ToBox, m.ReceivedAt, sentExpires); err != nil {
				return false, err
			}
		}
	}
	if bytes.Equal(old, m.Env) {
		return false, nil
	}
	return false, ErrConflict
}

// insertMessageArgs is insertMessage's statement and parameters: the plain
// insert, or with sentExpires set the insert plus its sent delivery row.
func insertMessageArgs(m Message, sentExpires time.Time) (string, []any) {
	var channel, parent, typedBy, refTask, mirrorOf any
	if m.Channel != "" {
		channel = m.Channel
	}
	if m.ParentTaskID != "" {
		parent = m.ParentTaskID
	}
	if m.TypedBy != "" {
		typedBy = m.TypedBy
	}
	if m.RefTaskID != "" { // spec 067, rdb 0112
		refTask = m.RefTaskID
	}
	if m.MirrorOf != "" {
		mirrorOf = m.MirrorOf
	}
	args := []any{m.TenantID, m.MsgID, m.TaskID, channel, m.TS, m.FromBox, m.FromID, m.ToBox, m.ToID,
		m.Kind, m.Body, string(m.Files), string(m.Msg), m.EnvSig, m.Env, m.ReceivedAt, m.ExpiresAt, parent, parentBit(m.IsParent), typedBy,
		refTask, mirrorOf}
	sql := insertMessageOnly
	if !sentExpires.IsZero() {
		sql, args = insertMessageSent, append(args, sentExpires)
	}
	return sql, append(args, flowInsertArgs(m)...)
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
	// spec 059 S1: Postgres sends it only when this batch's transaction
	// commits, so a listener never wakes for a row it cannot read yet.
	b.Queue(`SELECT pg_notify('`+WakeChannel+`', $1 || '|' || $2)`, tenant, toBox)
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
	tag, err := s.execTenant(ctx, tenant, `UPDATE deliveries SET state = 'sent', sent_at = $4, acked_at = $4
		WHERE tenant_id = $1 AND msg_id = $2 AND to_box = $3 AND state = 'queued' AND expires_at > $4`,
		tenant, msgID, toBox, now)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

func (s *Postgres) Unclaim(ctx context.Context, tenant, msgID, toBox string) error {
	_, err := s.execTenant(ctx, tenant, `UPDATE deliveries SET state = 'queued', sent_at = NULL, acked_at = NULL
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
	err := s.queryTenant(ctx, tenant, `SELECT d.msg_id::text, m.env, m.task_id::text FROM deliveries d
		JOIN messages m ON m.tenant_id = d.tenant_id AND m.msg_id = d.msg_id
		WHERE d.tenant_id = $1 AND d.to_box = $2 AND d.state = 'queued' AND d.expires_at > $3
		ORDER BY d.received_at, d.msg_id`, []any{tenant, toBox, now}, func(rows pgx.Rows) error {
		var q Queued
		if err := rows.Scan(&q.MsgID, &q.Env, &q.TaskID); err != nil {
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

func (s *Postgres) BoxTaskEnvelopes(ctx context.Context, tenant, taskID, box string, now time.Time) ([][]byte, error) {
	var out [][]byte
	err := s.queryTenant(ctx, tenant, `SELECT m.env FROM messages m
		WHERE m.tenant_id = $1 AND m.task_id = $2 AND m.expires_at > $4
		  AND (m.from_box = $3 OR m.to_box = $3 OR EXISTS (SELECT 1 FROM deliveries d
		       WHERE d.tenant_id = m.tenant_id AND d.msg_id = m.msg_id AND d.to_box = $3))
		ORDER BY m.ts, m.msg_id`, []any{tenant, taskID, box, now}, func(rows pgx.Rows) error {
		var e []byte
		if err := rows.Scan(&e); err != nil {
			return err
		}
		out = append(out, e)
		return nil
	})
	return out, err
}

// sweepChunk bounds one retention transaction (027 T010): a backlog of
// expired rows is removed sweepChunk rows at a time, each chunk committing on
// its own, never in one long transaction.
const sweepChunk = 5000

// Sweep applies retention. It is global by design: the one hub job that runs
// asOperator. Each chunk is a range scan on rdb 0024's (expires_at) indexes,
// so an idle sweep costs two index probes whatever the tenant count.
func (s *Postgres) Sweep(ctx context.Context, now time.Time) (SweepResult, error) {
	// chunks runs sql ($1 now, $2 limit) one transaction at a time until a
	// chunk comes back short, and returns the rows it changed.
	chunks := func(sql string) (int, error) {
		total := 0
		for {
			var n int64
			if err := s.asOperator(ctx, func(tx pgx.Tx) error {
				tag, err := tx.Exec(ctx, sql, now, sweepChunk)
				n = tag.RowsAffected()
				return err
			}); err != nil {
				return 0, err
			}
			total += int(n)
			if n < sweepChunk {
				return total, nil
			}
		}
	}
	var r SweepResult
	var err error
	if r.Expired, err = chunks(`UPDATE deliveries SET state = 'expired'
		WHERE state = 'queued' AND expires_at <= $1 AND (tenant_id, msg_id, to_box) IN (
			SELECT tenant_id, msg_id, to_box FROM deliveries
			WHERE state = 'queued' AND expires_at <= $1 LIMIT $2)`); err != nil {
		return SweepResult{}, err
	}
	if r.Purged, err = chunks(`DELETE FROM messages WHERE expires_at <= $1 AND (tenant_id, msg_id) IN (
			SELECT tenant_id, msg_id FROM messages WHERE expires_at <= $1 LIMIT $2)`); err != nil {
		return SweepResult{}, err
	}
	if _, err := chunks(flowMarkSweepSQL); err != nil { // spec 062: f:<msg_id> marks go with their line
		return SweepResult{}, err
	}
	if s.hasSearchSig(ctx) {
		if err := s.backfillSearchSig(ctx); err != nil {
			return SweepResult{}, err
		}
	}
	return s.pruneCommitted(ctx, now, r)
}

// searchSigChunk bounds one search_sig backfill transaction: ~0.4 s of
// signing at 0.25 vCPU (scratch pg 16, ~3 KB bodies).
const searchSigChunk = 500

// searchSigBackfillSQL signs the long rows (1024+ characters, rdb 0135)
// written before the trigger, from their stored search_tsv (a NULL one signs
// as all zeros, so no row is picked twice).
// SKIP LOCKED: a row another transaction holds (a claim, an edit) waits for
// the next sweep instead of stalling this one.
const searchSigBackfillSQL = `UPDATE messages SET search_sig = coalesce(spool_search_sig(search_tsv), B'0'::bit(1024))
	WHERE (tenant_id, msg_id) IN (SELECT tenant_id, msg_id FROM messages
		WHERE search_sig IS NULL AND length(body) >= 1024 LIMIT $1 FOR UPDATE SKIP LOCKED)`

// backfillSearchSig fills search_sig (rdb 0135) chunk by chunk until a chunk
// comes back short; once every row is signed it is one probe of the empty
// messages_search_sig_todo index.
func (s *Postgres) backfillSearchSig(ctx context.Context) error {
	for {
		var n int64
		if err := s.asOperator(ctx, func(tx pgx.Tx) error {
			tag, err := tx.Exec(ctx, searchSigBackfillSQL, searchSigChunk)
			n = tag.RowsAffected()
			return err
		}); err != nil {
			return err
		}
		if n < searchSigChunk {
			return nil
		}
	}
}

// CountMessagesSince reads the trigger-kept counters (rdb 0023) when since is a
// billing period start, the quota's only question: the SUM of at most 16 rows
// per period instead of a COUNT over every message of the period (027 T040).
// Any other since counts the rows.
func (s *Postgres) CountMessagesSince(ctx context.Context, tenant string, since time.Time) (int, error) {
	var n int
	if since.Equal(billing.PeriodStart(since)) {
		err := s.queryRowTenant(ctx, tenant, `SELECT COALESCE(SUM(messages), 0) FROM message_period_counts
			WHERE tenant_id = $1 AND period_start >= $2`, []any{tenant, since}, &n)
		return n, err
	}
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

// HasTopicOrMessage: see Store. Two EXISTS, each on its own index
// (messages_task_received, the msg_id key), never one OR scan.
func (s *Postgres) HasTopicOrMessage(ctx context.Context, tenant, id string) (bool, error) {
	var ok bool
	err := s.queryRowTenant(ctx, tenant, `SELECT EXISTS(SELECT 1 FROM messages WHERE tenant_id = $1 AND task_id = $2)
		OR EXISTS(SELECT 1 FROM messages WHERE tenant_id = $1 AND msg_id = $2)`, []any{tenant, id}, &ok)
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

// TopicChannel: see Store. Walks messages_task_received for one row.
func (s *Postgres) TopicChannel(ctx context.Context, tenant, taskID string) (string, error) {
	var channel string
	err := s.queryRowTenant(ctx, tenant, `SELECT COALESCE(channel, '') FROM messages
		WHERE tenant_id = $1 AND task_id = $2 AND is_parent = 1
		ORDER BY received_at, msg_id LIMIT 1`, []any{tenant, taskID}, &channel)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return channel, err
}

// TaskFirstChannel: see Store. The earliest row of the task at ANY level.
func (s *Postgres) TaskFirstChannel(ctx context.Context, tenant, taskID string) (string, error) {
	var channel string
	err := s.queryRowTenant(ctx, tenant, `SELECT COALESCE(channel, '') FROM messages
		WHERE tenant_id = $1 AND task_id = $2
		ORDER BY received_at, msg_id LIMIT 1`, []any{tenant, taskID}, &channel)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return channel, err
}

// mapFK turns a foreign-key violation (unknown tenant) into ErrNotFound.
func mapFK(err error) error {
	if err == nil {
		return nil
	}
	if sqlState(err) == "23503" {
		return ErrNotFound
	}
	return err
}
