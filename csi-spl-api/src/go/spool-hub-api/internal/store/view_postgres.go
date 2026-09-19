package store

import (
	"context"
	"crypto/ed25519"
	"time"
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
	rows, err := s.pool.Query(ctx, `SELECT p.box_id, p.pubkey, p.revoked_at IS NOT NULL, b.last_hello_at,
			COALESCE(array_agg(r.agent_id ORDER BY r.agent_id) FILTER (WHERE r.agent_id IS NOT NULL), '{}')
		FROM pins p
		LEFT JOIN boxes b ON b.tenant_id = p.tenant_id AND b.box_id = p.box_id
		LEFT JOIN roster r ON r.tenant_id = p.tenant_id AND r.box_id = p.box_id
		WHERE p.tenant_id = $1
		GROUP BY p.box_id, p.pubkey, p.revoked_at, b.last_hello_at
		ORDER BY p.box_id`, tenant)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ViewBox
	for rows.Next() {
		var v ViewBox
		var pub []byte
		var hello *time.Time
		if err := rows.Scan(&v.BoxID, &pub, &v.Revoked, &hello, &v.Agents); err != nil {
			return nil, err
		}
		v.PubKey = ed25519.PublicKey(pub)
		if hello != nil {
			v.LastHelloAt = *hello
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func (s *Postgres) ViewThreads(ctx context.Context, tenant string, q ThreadQuery) ([]ThreadRow, error) {
	rows, err := s.pool.Query(ctx, `WITH m AS (
			SELECT task_id::text AS task_id, msg_id::text AS msg_id, received_at, kind,
				from_id, from_box, to_id, to_box, COALESCE(channel, '') AS channel,
				COALESCE(parent_task_id::text, '') AS parent, msg
			FROM messages
			WHERE tenant_id = $1 AND expires_at > $2 AND ($3::text = '' OR channel = $3::text)
				AND (NOT $8::bool OR channel IS NULL)
		), sel AS (
			SELECT task_id FROM m GROUP BY task_id
			HAVING ($4::text = '' OR bool_or((from_id = $4::text AND ($9::text = '' OR from_box = $9::text))
					OR (to_id = $4::text AND ($9::text = '' OR to_box = $9::text))))
				AND ($10::text = '' OR bool_or(from_id = $10::text OR to_id = $10::text))
		), agg AS (
			SELECT m.task_id,
				(array_agg(m.channel ORDER BY m.received_at, m.msg_id))[1] AS channel,
				(array_agg(m.parent ORDER BY m.received_at, m.msg_id))[1] AS parent,
				min(m.received_at) AS first_at, max(m.received_at) AS last_at, count(*)::int AS n,
				array_agg(m.kind ORDER BY m.received_at, m.msg_id) AS kinds,
				array_agg(m.from_id || '@' || m.from_box) || array_agg(m.to_id || '@' || m.to_box) AS parties,
				(array_agg(m.msg ORDER BY m.received_at, m.msg_id))[1] AS first_msg
			FROM m JOIN sel ON sel.task_id = m.task_id
			GROUP BY m.task_id
		)
		SELECT task_id, channel, parent, first_at, last_at, n, kinds, parties, first_msg FROM agg
		WHERE ($5::timestamptz IS NULL OR (last_at, task_id) < ($5::timestamptz, $6::text))
			AND (NOT $11::bool OR parent = '') AND ($12::text = '' OR parent = $12::text)
		ORDER BY last_at DESC, task_id DESC
		LIMIT $7`, tenant, q.Now, q.Channel, q.Agent, optTime(q.BeforeAt), q.BeforeTask, pgLimit(q.Limit),
		q.DM, q.AgentBox, q.Viewer, q.Roots, q.Parent)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ThreadRow
	for rows.Next() {
		var r ThreadRow
		if err := rows.Scan(&r.TaskID, &r.Channel, &r.Parent, &r.FirstAt, &r.LastAt, &r.Count,
			&r.Kinds, &r.Parties, &r.FirstMsg); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Postgres) ViewThread(ctx context.Context, tenant string, q ThreadMsgQuery) ([]ViewMsg, error) {
	order := "ORDER BY received_at, msg_id::text"
	if q.Desc {
		order = "ORDER BY received_at DESC, msg_id::text DESC"
	}
	rows, err := s.pool.Query(ctx, `SELECT msg_id::text, received_at, env FROM messages
		WHERE tenant_id = $1 AND task_id::text = $2 AND expires_at > $3
			AND ($4::timestamptz IS NULL OR (received_at, msg_id::text) > ($4::timestamptz, $5::text))
			AND ($7::timestamptz IS NULL OR (received_at, msg_id::text) < ($7::timestamptz, $8::text))
		`+order+`
		LIMIT $6`, tenant, q.TaskID, q.Now, optTime(q.AfterAt), q.AfterID, pgLimit(q.Limit), optTime(q.BeforeAt), q.BeforeID)
	if err != nil {
		return nil, err
	}
	var out []ViewMsg
	idx := map[string]int{}
	var ids []string
	for rows.Next() {
		v := ViewMsg{Deliveries: []ViewDelivery{}}
		if err := rows.Scan(&v.MsgID, &v.ReceivedAt, &v.Env); err != nil {
			rows.Close()
			return nil, err
		}
		idx[v.MsgID] = len(out)
		ids = append(ids, v.MsgID)
		out = append(out, v)
	}
	rows.Close()
	if err := rows.Err(); err != nil || len(ids) == 0 {
		return out, err
	}
	drows, err := s.pool.Query(ctx, `SELECT msg_id::text, to_box, state FROM deliveries
		WHERE tenant_id = $1 AND msg_id::text = ANY($2) ORDER BY msg_id, to_box`, tenant, ids)
	if err != nil {
		return nil, err
	}
	defer drows.Close()
	for drows.Next() {
		var id string
		var d ViewDelivery
		if err := drows.Scan(&id, &d.ToBox, &d.State); err != nil {
			return nil, err
		}
		if i, ok := idx[id]; ok {
			out[i].Deliveries = append(out[i].Deliveries, d)
		}
	}
	return out, drows.Err()
}

func (s *Postgres) ViewChannels(ctx context.Context, tenant string, now time.Time) ([]ChannelRow, error) {
	rows, err := s.pool.Query(ctx, `SELECT channel, count(*)::int, max(received_at) FROM messages
		WHERE tenant_id = $1 AND channel IS NOT NULL AND expires_at > $2
		GROUP BY channel ORDER BY channel`, tenant, now)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ChannelRow{}
	for rows.Next() {
		var r ChannelRow
		if err := rows.Scan(&r.Channel, &r.Count, &r.LastAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
