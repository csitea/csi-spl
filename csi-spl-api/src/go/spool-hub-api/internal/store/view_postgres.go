package store

import (
	"context"
	"crypto/ed25519"
	"regexp"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of the read-only viewer queries (view.go). SELECT only.

// optTime is NULL for the zero time (no cursor).
func optTime(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}

func pgLimit(n int) int {
	if n <= 0 {
		return 1_000_000
	}
	return n
}

func (s *Postgres) ViewBoxes(ctx context.Context, tenant string) ([]ViewBox, error) {
	var out []ViewBox
	err := s.queryTenant(ctx, tenant, `SELECT p.box_id, p.pubkey, p.revoked_at IS NOT NULL, b.last_hello_at,
			COALESCE(array_agg(r.agent_id ORDER BY r.agent_id) FILTER (WHERE r.agent_id IS NOT NULL), '{}')
		FROM pins p
		LEFT JOIN boxes b ON b.tenant_id = p.tenant_id AND b.box_id = p.box_id
		LEFT JOIN roster r ON r.tenant_id = p.tenant_id AND r.box_id = p.box_id
		WHERE p.tenant_id = $1
		GROUP BY p.box_id, p.pubkey, p.revoked_at, b.last_hello_at
		ORDER BY p.box_id`, []any{tenant}, func(rows pgx.Rows) error {
		var v ViewBox
		var pub []byte
		var hello *time.Time
		if err := rows.Scan(&v.BoxID, &pub, &v.Revoked, &hello, &v.Agents); err != nil {
			return err
		}
		v.PubKey = ed25519.PublicKey(pub)
		if hello != nil {
			v.LastHelloAt = *hello
		}
		out = append(out, v)
		return nil
	})
	return out, err
}

// canonUUIDRe is a uuid as Postgres prints it (uuid::text). A task or parent
// filter that is not in this form matches no row, so it never reaches a
// ::uuid cast (which would fail) and the uuid indexes stay usable.
var canonUUIDRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// ViewThreads (027 T030) costs the page, not the tenant. It walks the tenant's
// messages newest first (rdb 0022 messages_received / messages_dm_received,
// or 0008 messages_channel for a channel) and keeps each thread's LATEST message only (no later one in the
// same thread passes the same filters: messages_task_received), so that walk
// yields each thread once, in (last_at DESC, task_id DESC) order. The walk is
// a recursive CTE whose every step is "the next such message below the
// previous one" (ORDER BY ... LIMIT 1, an ordered index scan whatever the
// planner estimates), and it stops after Limit threads; only those threads are
// aggregated (LATERAL).
// Message filters (expiry, channel, DM) apply to the walk, the latest check
// and the aggregate alike; thread filters (agent, viewer, roots, parent)
// apply to the aggregate. Rows are those of the pre-027 whole-tenant CTE,
// which view_threads_test.go keeps as the oracle.
func (s *Postgres) ViewThreads(ctx context.Context, tenant string, q ThreadQuery) ([]ThreadRow, error) {
	if q.Parent != "" && !canonUUIDRe.MatchString(q.Parent) {
		return nil, nil
	}
	sql, args := viewThreadsSQL(tenant, q)
	var out []ThreadRow
	err := s.queryTenantNoJIT(ctx, tenant, sql, args, func(rows pgx.Rows) error {
		var r ThreadRow
		if err := rows.Scan(&r.TaskID, &r.Channel, &r.Parent, &r.FirstAt, &r.LastAt, &r.Count,
			&r.Kinds, &r.Parties, &r.FirstMsg); err != nil {
			return err
		}
		out = append(out, r)
		return nil
	})
	return out, err
}

// pgScopeTenantNoJIT is pgScopeTenant plus jit off for the same implicit
// transaction. The thread walk's cost estimate is the whole tenant's (the
// planner cannot see that LIMIT stops the walk early), which is above
// jit_above_cost: measured on pg 16.14 at 200k messages, JIT compiled for
// 311 ms around a 22 ms execution.
const pgScopeTenantNoJIT = `SELECT set_config('app.tenant_id', $1, true), set_config('jit', 'off', true)`

// queryTenantNoJIT is queryTenant (one round trip, rls.go) with JIT off.
func (s *Postgres) queryTenantNoJIT(ctx context.Context, tenant, sql string, args []any, each func(pgx.Rows) error) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	b := &pgx.Batch{}
	b.Queue(pgScopeTenantNoJIT, tenant)
	b.Queue(sql, args...)
	br := s.pool.SendBatch(ctx, b)
	defer br.Close()
	if _, err := br.Exec(); err != nil {
		return err
	}
	rows, err := br.Query()
	if err != nil {
		return err
	}
	if err := scanRows(rows, each); err != nil {
		return err
	}
	return br.Close()
}

// viewThreadsSQL builds the statement for q. Only the filters q sets reach the
// SQL, so the planner sees concrete predicates (a channel walk takes
// messages_channel) instead of "$n = '' OR ..." shapes. Every thread filter
// is a probe on that one thread inside the walk step.
func viewThreadsSQL(tenant string, q ThreadQuery) (string, []any) {
	c := &sqlc{}
	tn, now := c.arg(tenant), c.arg(q.Now)
	msgs := func(a string) string { // the message filters, on alias a
		w := a + ".tenant_id = " + tn + " AND " + a + ".expires_at > " + now
		if q.Channel != "" {
			w += " AND " + a + ".channel = " + c.arg(q.Channel)
		}
		if q.DM {
			w += " AND " + a + ".channel IS NULL"
		}
		return w
	}
	thread := func(a string) string { // a's messages in l's thread
		return msgs(a) + " AND " + a + ".task_id = l.task_id"
	}
	// Every probe is a boolean scalar subquery on l's thread: it is never
	// pulled up into a (hash) join over the whole tenant, and the planner
	// rates a boolean qual at 1/2, not at the 1/rows of an equality on a
	// unique column, so each LIMIT 1 step stays an ordered index scan.
	// l is its thread's latest message (the cheapest probe, run first):
	walk := msgs("l") + ` AND (SELECT x.msg_id = l.msg_id FROM messages x WHERE ` + thread("x") + `
			ORDER BY x.received_at DESC, x.msg_id DESC LIMIT 1)`
	if !q.BeforeAt.IsZero() {
		at := c.arg(q.BeforeAt)
		walk += " AND l.received_at <= " + at + " AND (l.received_at, l.task_id::text) < (" + at + ", " + c.arg(q.BeforeTask) + ")"
	}
	if q.Agent != "" {
		id, fromBox, toBox := c.arg(q.Agent), "", ""
		if q.AgentBox != "" {
			b := c.arg(q.AgentBox)
			fromBox, toBox = " AND g.from_box = "+b, " AND g.to_box = "+b
		}
		walk += " AND (SELECT true FROM messages g WHERE " + thread("g") +
			" AND ((g.from_id = " + id + fromBox + ") OR (g.to_id = " + id + toBox + ")) LIMIT 1)"
	}
	if q.Viewer != "" {
		v := c.arg(q.Viewer)
		walk += " AND (SELECT true FROM messages v WHERE " + thread("v") +
			" AND (v.from_id = " + v + " OR v.to_id = " + v + ") LIMIT 1)"
	}
	first := func(test string) string { // the thread's first message's parent passes test
		return " AND (SELECT f.parent_task_id " + test + " FROM messages f WHERE " + thread("f") +
			" ORDER BY f.received_at, f.msg_id::text LIMIT 1)"
	}
	if q.Roots {
		walk += first("IS NULL")
	}
	if q.Parent != "" {
		p := c.arg(q.Parent)
		walk += " AND l.task_id IN (SELECT p.task_id FROM messages p WHERE p.tenant_id = " + tn +
			" AND p.parent_task_id = " + p + "::uuid)" + first("IS NOT DISTINCT FROM "+p+"::uuid")
	}
	lim := c.arg(pgLimit(q.Limit))
	order := " ORDER BY l.received_at DESC, l.task_id::text DESC LIMIT 1"
	sql := `WITH RECURSIVE w (task_id, received_at, n) AS (
			(SELECT l.task_id, l.received_at, 1 FROM messages l WHERE ` + walk + order + `)
			UNION ALL
			SELECT s.task_id, s.received_at, w.n + 1 FROM w CROSS JOIN LATERAL (
				SELECT l.task_id, l.received_at FROM messages l
				WHERE ` + walk + ` AND l.received_at <= w.received_at
					AND (l.received_at, l.task_id::text) < (w.received_at, w.task_id::text)` + order + `
			) s
			WHERE w.n < ` + lim + `
		)
		SELECT w.task_id::text, a.channel, a.parent, a.first_at, w.received_at, a.n, a.kinds, a.parties, a.first_msg
		FROM w CROSS JOIN LATERAL (
			SELECT (array_agg(COALESCE(m.channel, '') ORDER BY m.received_at, m.msg_id::text))[1] AS channel,
				(array_agg(COALESCE(m.parent_task_id::text, '') ORDER BY m.received_at, m.msg_id::text))[1] AS parent,
				min(m.received_at) AS first_at, count(*)::int AS n,
				array_agg(m.kind ORDER BY m.received_at, m.msg_id::text) AS kinds,
				array_agg(m.from_id || '@' || m.from_box ORDER BY m.received_at, m.msg_id::text)
					|| array_agg(m.to_id || '@' || m.to_box ORDER BY m.received_at, m.msg_id::text) AS parties,
				(array_agg(m.msg ORDER BY m.received_at, m.msg_id::text))[1] AS first_msg
			FROM messages m
			WHERE ` + msgs("m") + ` AND m.task_id = w.task_id
		) a
		ORDER BY w.received_at DESC, w.task_id::text DESC`
	return sql, c.args
}

// ViewThread reads one thread by task_id = $2::uuid (027 T030: the pre-027
// task_id::text = $2 could not use an index and scanned every message of the
// tenant). A task id that is not a canonical uuid matched no row then and
// matches none now.
func (s *Postgres) ViewThread(ctx context.Context, tenant string, q ThreadMsgQuery) ([]ViewMsg, error) {
	if !canonUUIDRe.MatchString(q.TaskID) {
		return nil, nil
	}
	order := "ORDER BY received_at, msg_id::text"
	if q.Desc {
		order = "ORDER BY received_at DESC, msg_id::text DESC"
	}
	var out []ViewMsg
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		idx := map[string]int{}
		var ids []string
		err := eachRow(ctx, tx, `SELECT msg_id::text, received_at, env FROM messages
			WHERE tenant_id = $1 AND task_id = $2::uuid AND expires_at > $3
				AND ($4::timestamptz IS NULL OR (received_at, msg_id::text) > ($4::timestamptz, $5::text))
				AND ($7::timestamptz IS NULL OR (received_at, msg_id::text) < ($7::timestamptz, $8::text))
			`+order+`
			LIMIT $6`, []any{tenant, q.TaskID, q.Now, optTime(q.AfterAt), q.AfterID, pgLimit(q.Limit), optTime(q.BeforeAt), q.BeforeID},
			func(rows pgx.Rows) error {
				v := ViewMsg{Deliveries: []ViewDelivery{}}
				if err := rows.Scan(&v.MsgID, &v.ReceivedAt, &v.Env); err != nil {
					return err
				}
				idx[v.MsgID] = len(out)
				ids = append(ids, v.MsgID)
				out = append(out, v)
				return nil
			})
		if err != nil || len(ids) == 0 {
			return err
		}
		return eachRow(ctx, tx, `SELECT msg_id::text, to_box, state FROM deliveries
			WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[]) ORDER BY msg_id, to_box`, []any{tenant, ids},
			func(rows pgx.Rows) error {
				var id string
				var d ViewDelivery
				if err := rows.Scan(&id, &d.ToBox, &d.State); err != nil {
					return err
				}
				if i, ok := idx[id]; ok {
					out[i].Deliveries = append(out[i].Deliveries, d)
				}
				return nil
			})
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

func (s *Postgres) ViewChannels(ctx context.Context, tenant string, now time.Time) ([]ChannelRow, error) {
	out := []ChannelRow{}
	err := s.queryTenant(ctx, tenant, `SELECT channel, count(*)::int, max(received_at) FROM messages
		WHERE tenant_id = $1 AND channel IS NOT NULL AND expires_at > $2
		GROUP BY channel ORDER BY channel`, []any{tenant, now}, func(rows pgx.Rows) error {
		var r ChannelRow
		if err := rows.Scan(&r.Channel, &r.Count, &r.LastAt); err != nil {
			return err
		}
		out = append(out, r)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}
