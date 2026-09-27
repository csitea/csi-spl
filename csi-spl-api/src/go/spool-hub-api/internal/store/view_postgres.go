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

// ViewTopics (027 T030) costs the page, not the tenant. It walks the tenant's
// messages newest first (rdb 0022 messages_received / messages_dm_received,
// or 0008 messages_channel for a channel) and keeps each topic's LATEST message only (no later one in the
// same topic passes the same filters: messages_task_received), so that walk
// yields each topic once, in (last_at DESC, task_id DESC) order. The walk is
// a recursive CTE whose every step is "the next such message below the
// previous one" (ORDER BY ... LIMIT 1, an ordered index scan whatever the
// planner estimates), and it stops after Limit topics; only those topics are
// aggregated (LATERAL).
// Message filters (expiry, channel, DM) apply to the walk, the latest check
// and the aggregate alike; topic filters (agent, viewer, roots, parent)
// apply to the aggregate. Rows are those of the pre-027 whole-tenant CTE,
// which view_topics_test.go keeps as the oracle.
func (s *Postgres) ViewTopics(ctx context.Context, tenant string, q TopicQuery) ([]TopicRow, error) {
	if q.Parent != "" && !canonUUIDRe.MatchString(q.Parent) {
		return nil, nil
	}
	sql, args := viewTopicsSQL(tenant, q)
	var out []TopicRow
	err := s.queryTenantNoJIT(ctx, tenant, sql, args, func(rows pgx.Rows) error {
		var r TopicRow
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
// transaction. The topic walk's cost estimate is the whole tenant's (the
// planner cannot see that LIMIT stops the walk early), which is above
// jit_above_cost: measured on pg 16.14 at 200k messages, JIT compiled for
// 311 ms around a 22 ms execution.
//
// Bitmap scans are off for the same reason (SPL-984): each recursive step is
// ORDER BY .. LIMIT 1 behind boolean probes rated rows=1, so the planner took
// a Bitmap Heap Scan of every older message per step plus a top-N sort. prd
// t1 2026-09-26: 3 488 rows and ~3 400 probe runs per step, 1.0-1.6 s per
// page. Without bitmap scans each step is an ordered index scan that stops
// at its first passing row (lab: 1 977 -> 21.5 ms at 11.7k messages). Local
// to this batch's implicit transaction: no other statement sees it.
//
// And a custom plan on every run (CLE-35061): pgx prepares the walk once per
// pooled connection, and after five runs Postgres may keep a GENERIC plan,
// built without the tenant, the time or the reader's channels. prd t1
// 2026-09-27 (do_spl_db_hot_measure, n=15, execution only): generic 71 ms
// p50, custom 27 ms (plus ~4 ms planning). plan_cache_mode is read at every
// Bind, so a transaction-local setting sent first in the batch applies.
const pgScopeTenantNoJIT = `SELECT set_config('app.tenant_id', $1, true), set_config('jit', 'off', true),
	set_config('enable_bitmapscan', 'off', true), set_config('plan_cache_mode', 'force_custom_plan', true)`

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

// viewTopicsSQL builds the statement for q. Only the filters q sets reach the
// SQL, so the planner sees concrete predicates (a channel walk takes
// messages_channel) instead of "$n is empty OR ..." shapes. Every topic filter
// is a probe on that one topic inside the walk step.
func viewTopicsSQL(tenant string, q TopicQuery) (string, []any) {
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
	topic := func(a string) string { // a's messages in l's topic
		return msgs(a) + " AND " + a + ".task_id = l.task_id"
	}
	// Every probe is a boolean scalar subquery on l's topic: it is never
	// pulled up into a (hash) join over the whole tenant, and the planner
	// rates a boolean qual at 1/2, not at the 1/rows of an equality on a
	// unique column, so each LIMIT 1 step stays an ordered index scan.
	// l is its topic's latest message (the cheapest probe, run first):
	walk := msgs("l") + ` AND (SELECT x.msg_id = l.msg_id FROM messages x WHERE ` + topic("x") + `
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
		walk += " AND (SELECT true FROM messages g WHERE " + topic("g") +
			" AND ((g.from_id = " + id + fromBox + ") OR (g.to_id = " + id + toBox + ")) LIMIT 1)"
	}
	if q.Viewer != "" {
		v := c.arg(q.Viewer)
		walk += " AND (SELECT true FROM messages v WHERE " + topic("v") +
			" AND (v.from_id = " + v + " OR v.to_id = " + v + ") LIMIT 1)"
	}
	// The read door (rdb 0028): the topic must hold at least one message
	// this reader may see - one in a public channel, one in a channel they
	// belong to, or a DM they are an end of. Same probe shape as Viewer, so
	// it stays a LIMIT 1 index step inside the walk rather than a join.
	// aggDoor is the same rule PER MESSAGE for the summary below (CLE-34986):
	// the door above only decides whether a topic is listed, so without it a
	// topic mixing a DM with a #lobby reply was listed with the DM's first
	// line as its subject and the DM's ends among its parties.
	aggDoor := ""
	if q.Reader != "" {
		rd, pub, mine := c.arg(q.Reader), c.arg(PublicChannels), c.arg(q.ReaderChannels)
		walk += " AND (SELECT true FROM messages d WHERE " + topic("d") + " AND (" +
			"d.channel = ANY(" + pub + "::text[]) OR d.channel = ANY(" + mine + "::text[]) OR " +
			"(d.channel IS NULL AND (d.from_id = " + rd + " OR d.to_id = " + rd + "))) LIMIT 1)"
		aggDoor = " AND (m.channel = ANY(" + pub + "::text[]) OR m.channel = ANY(" + mine + "::text[]) OR " +
			"(m.channel IS NULL AND (m.from_id = " + rd + " OR m.to_id = " + rd + ")))"
	}
	first := func(test string) string { // the topic's first message's parent passes test
		return " AND (SELECT f.parent_task_id " + test + " FROM messages f WHERE " + topic("f") +
			" ORDER BY f.received_at, f.msg_id::text LIMIT 1)"
	}
	if q.Roots {
		walk += first("IS NULL")
	}
	if q.NoIssues { // rdb 0047: a probe on the (tenant_id, task_id) unique index
		walk += " AND (SELECT true FROM issues i WHERE i.tenant_id = " + tn + " AND i.task_id = l.task_id LIMIT 1) IS NULL"
	}
	if q.Parent != "" {
		p := c.arg(q.Parent)
		walk += " AND l.task_id IN (SELECT p.task_id FROM messages p WHERE p.tenant_id = " + tn +
			" AND p.parent_task_id = " + p + "::uuid)" + first("IS NOT DISTINCT FROM "+p+"::uuid")
	}
	walk += archivedTopicHideSQL("l", tn, c.arg(q.Lobby)) // specs/041
	lim := c.arg(pgLimit(q.Limit))
	order := " ORDER BY l.received_at DESC, l.task_id::text DESC LIMIT 1"
	// The topic's first message (subject, channel, parent) is ONE ordered
	// row, f, not (array_agg(m.msg ...))[1] in a: that read and copied every
	// body of the topic to keep one (CLE-35061, prd t1 2026-09-27, custom
	// plan, n=15: 27 -> 13 ms a page).
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
		SELECT w.task_id::text, f.channel, f.parent, f.first_at, w.received_at, a.n, a.kinds, a.parties, f.first_msg
		FROM w CROSS JOIN LATERAL (
			SELECT count(*)::int AS n,
				array_agg(m.kind ORDER BY m.received_at, m.msg_id::text) AS kinds,
				array_agg(m.from_id || '@' || m.from_box ORDER BY m.received_at, m.msg_id::text)
					|| array_agg(m.to_id || '@' || m.to_box ORDER BY m.received_at, m.msg_id::text) AS parties
			FROM messages m
			WHERE ` + msgs("m") + ` AND m.task_id = w.task_id` + aggDoor + `
		) a LEFT JOIN LATERAL (
			SELECT COALESCE(m.channel, '') AS channel, COALESCE(m.parent_task_id::text, '') AS parent,
				m.received_at AS first_at, m.msg AS first_msg
			FROM messages m
			WHERE ` + msgs("m") + ` AND m.task_id = w.task_id` + aggDoor + `
			ORDER BY m.received_at, m.msg_id::text LIMIT 1
		) f ON true
		ORDER BY w.received_at DESC, w.task_id::text DESC`
	return sql, c.args
}

// ViewTopic reads one topic by task_id = $2::uuid (027 T030: the pre-027
// task_id::text = $2 could not use an index and scanned every message of the
// tenant). A task id that is not a canonical uuid matched no row then and
// matches none now.
func (s *Postgres) ViewTopic(ctx context.Context, tenant string, q TopicMsgQuery) ([]ViewMsg, error) {
	if !canonUUIDRe.MatchString(q.TaskID) {
		return nil, nil
	}
	order := "ORDER BY received_at, msg_id::text"
	if q.Desc {
		order = "ORDER BY received_at DESC, msg_id::text DESC"
	}
	// The per-message read door (rdb 0028). In the statement, not after it,
	// so LIMIT counts only messages this reader may see and a page is never
	// short because the rest of it was filtered away afterwards.
	door, doorArgs := "true", []any{}
	if q.Reader != "" {
		door = `((channel IS NULL AND (from_id = $9 OR to_id = $9))
			OR channel = ANY($10::text[]) OR channel = ANY($11::text[]))`
		doorArgs = []any{q.Reader, PublicChannels, q.ReaderChannels}
	}
	archived := ""
	if q.HideArchived { // specs/041: the lobby feed
		archived = " AND archived_at IS NULL"
	}
	// Two single-statement batches, two round trips (CLE-34985; it was a
	// BEGIN .. COMMIT transaction, five). Under READ COMMITTED each statement
	// of that transaction already took its own snapshot, so the answer is the
	// same: a delivery row is read at least as late as its message.
	var out []ViewMsg
	idx := map[string]int{}
	var ids []string
	err := s.queryTenant(ctx, tenant, `SELECT msg_id::text, received_at, env, edited_at, edited_by,
				CASE WHEN edited_at IS NULL THEN 0 ELSE COALESCE((SELECT MAX(revision)
					FROM message_revisions r WHERE r.tenant_id = messages.tenant_id AND r.msg_id = messages.msg_id), 0) END,
				is_parent, typed_by, kind, kind_set_at, kind_set_by
			FROM messages
			WHERE tenant_id = $1 AND task_id = $2::uuid AND expires_at > $3
				AND ($4::timestamptz IS NULL OR (received_at, msg_id::text) > ($4::timestamptz, $5::text))
				AND ($7::timestamptz IS NULL OR (received_at, msg_id::text) < ($7::timestamptz, $8::text))
				AND `+door+archived+`
			`+order+`
			LIMIT $6`, append([]any{tenant, q.TaskID, q.Now, optTime(q.AfterAt), q.AfterID, pgLimit(q.Limit), optTime(q.BeforeAt), q.BeforeID}, doorArgs...),
		func(rows pgx.Rows) error {
			v := ViewMsg{Deliveries: []ViewDelivery{}}
			var editedBy, typedBy, kindSetBy *string
			var editedAt, kindSetAt *time.Time
			var kind string
			if err := rows.Scan(&v.MsgID, &v.ReceivedAt, &v.Env, &editedAt, &editedBy, &v.Revision, &v.IsParent, &typedBy,
				&kind, &kindSetAt, &kindSetBy); err != nil {
				return err
			}
			v.TypedBy = deref(typedBy)
			if kindSetAt != nil { // SPL-952: an override only once someone changed it
				v.Kind, v.KindSetAt, v.KindSetBy = kind, *kindSetAt, deref(kindSetBy)
			}
			// The register probe is paid only by an edited row: an
			// unedited one (the overwhelming majority) short-circuits on
			// the NULL and costs nothing.
			v.EditedBy = deref(editedBy)
			if editedAt != nil {
				v.EditedAt = *editedAt
			}
			idx[v.MsgID] = len(out)
			ids = append(ids, v.MsgID)
			out = append(out, v)
			return nil
		})
	if err != nil {
		return nil, err
	}
	if len(ids) == 0 {
		return out, nil
	}
	err = s.queryTenant(ctx, tenant, `SELECT msg_id::text, to_box, state FROM deliveries
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
