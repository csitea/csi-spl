package store

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// TopicsMsgQuery reads the newest messages of several topics at once: the
// per_topic= page of GET /v1/view/topics. Per topic it answers
// exactly what ViewTopic answers for TopicMsgQuery{TaskID, Desc: true,
// Limit: PerTopic} with the same Reader door.
type TopicsMsgQuery struct {
	TaskIDs        []string
	PerTopic       int
	Reader         string // "" = no door (the door-off rig), as TopicMsgQuery
	ReaderChannels []string
	// HideArchivedIn is a task whose archived rows are left out (the
	// lobby's, specs/041); "" = none.
	HideArchivedIn string
	Now            time.Time
}

// TopicsMessager is the batch read a store may offer. Without it the hub
// falls back to one ViewTopic per topic (the memory store).
type TopicsMessager interface {
	ViewTopicsMessages(ctx context.Context, tenant string, q TopicsMsgQuery) (map[string][]ViewMsg, map[string][]StoredReaction, error)
}

var _ TopicsMessager = (*Postgres)(nil)

// topicMsgCols are the messages columns the per-topic LATERAL hands to the
// outer select of ViewTopicsMessages: exactly what it reads (the revision
// subquery's tenant_id and msg_id, the row fields, moveCols), not SELECT *,
// so a new messages column is not dragged through every card read.
const topicMsgCols = `m.tenant_id, m.msg_id, m.received_at, m.env, m.edited_at, m.edited_by, m.is_parent, m.typed_by, m.responsible,
				m.ref_task_id, m.mirror_of, m.kind, m.kind_set_at, m.kind_set_by, m.moved_at, m.moved_by, m.moved_from_channel, m.moved_from_task,
				m.channel, m.task_id, m.parent_task_id`

// ViewTopicsMessages is two round trips whatever the number of topics: the
// messages (one LATERAL walk per topic, newest first, on
// messages_task_received), then their deliveries and reactions in one batch.
// A channel page used to be one browser request per topic.
func (s *Postgres) ViewTopicsMessages(ctx context.Context, tenant string, q TopicsMsgQuery) (map[string][]ViewMsg, map[string][]StoredReaction, error) {
	msgs := map[string][]ViewMsg{}
	react := map[string][]StoredReaction{}
	tasks := make([]string, 0, len(q.TaskIDs))
	for _, t := range q.TaskIDs {
		if canonUUIDRe.MatchString(t) {
			tasks = append(tasks, t)
		}
	}
	if len(tasks) == 0 || q.PerTopic <= 0 {
		return msgs, react, nil
	}
	door, args := topicsDoor(q, []any{tenant, tasks, q.Now, pgLimit(q.PerTopic)})
	var ids []string
	err := s.queryTenant(ctx, tenant, `SELECT t.task_id::text, m.msg_id::text, m.received_at, m.env, m.edited_at, m.edited_by,
			CASE WHEN m.edited_at IS NULL THEN 0 ELSE COALESCE((SELECT MAX(revision)
				FROM message_revisions r WHERE r.tenant_id = m.tenant_id AND r.msg_id = m.msg_id), 0) END,
			m.is_parent, m.typed_by, m.responsible, m.ref_task_id::text, m.mirror_of::text, m.kind, m.kind_set_at, m.kind_set_by, `+moveCols("m")+`
		FROM unnest($2::uuid[]) WITH ORDINALITY AS t(task_id, n)
		CROSS JOIN LATERAL (
			SELECT `+topicMsgCols+` FROM messages m
			WHERE m.tenant_id = $1 AND m.task_id = t.task_id AND m.expires_at > $3 AND `+door+`
			ORDER BY m.received_at DESC, m.msg_id::text DESC
			LIMIT $4) m
		ORDER BY t.n, m.received_at DESC, m.msg_id::text DESC`, args,
		func(rows pgx.Rows) error {
			var task string
			v, err := scanViewMsg(rows, &task)
			if err != nil {
				return err
			}
			msgs[task] = append(msgs[task], v)
			ids = append(ids, v.MsgID)
			return nil
		})
	if err != nil {
		return nil, nil, err
	}
	if len(ids) == 0 {
		return msgs, react, nil
	}
	if err := s.attachDeliveriesAndReactions(ctx, tenant, ids, msgs, react); err != nil {
		return nil, nil, err
	}
	return msgs, react, nil
}

// topicsDoor is the per-message read door (rdb 0028, the same predicate as
// ViewTopic) and the lobby's archived rows (specs/041) as SQL over m, with
// its arguments appended after args ($1..$4).
func topicsDoor(q TopicsMsgQuery, args []any) (string, []any) {
	door := "true"
	if q.Reader != "" {
		door = `((m.channel IS NULL AND (m.from_id = $5 OR m.to_id = $5))
			OR m.channel = ANY($6::text[]) OR m.channel = ANY($7::text[]))`
		args = append(args, q.Reader, PublicChannels, q.ReaderChannels)
	}
	if canonUUIDRe.MatchString(q.HideArchivedIn) {
		args = append(args, q.HideArchivedIn)
		door += " AND (m.archived_at IS NULL OR m.task_id <> $" + strconv.Itoa(len(args)) + "::uuid)"
	}
	return door, args
}

// attachDeliveriesAndReactions reads the deliveries and reactions of ids in
// one batch (one round trip) into msgs and react.
func (s *Postgres) attachDeliveriesAndReactions(ctx context.Context, tenant string, ids []string,
	msgs map[string][]ViewMsg, react map[string][]StoredReaction) error {
	where := map[string]*ViewMsg{}
	for task := range msgs {
		for i := range msgs[task] {
			where[msgs[task][i].MsgID] = &msgs[task][i]
		}
	}
	return s.queryTenantBatch(ctx, tenant,
		tenantRead{`SELECT msg_id::text, to_box, state FROM deliveries
			WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[]) ORDER BY msg_id, to_box`, []any{tenant, ids},
			func(rows pgx.Rows) error {
				var id string
				var d ViewDelivery
				if err := rows.Scan(&id, &d.ToBox, &d.State); err != nil {
					return err
				}
				if v := where[id]; v != nil {
					v.Deliveries = append(v.Deliveries, d)
				}
				return nil
			}},
		tenantRead{`SELECT msg_id::text, emoji, actor FROM message_reactions
			WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[])
			ORDER BY created_at, actor`, []any{tenant, ids},
			func(rows pgx.Rows) error {
				var id, emoji, actor string
				if err := rows.Scan(&id, &emoji, &actor); err != nil {
					return err
				}
				react[id] = append(react[id], StoredReaction{Emoji: emoji, Actor: actor})
				return nil
			}})
}

// TopicsDMCounter is the DM counts a store may offer for the topic list
// (dm_counts=true). Without it the hub falls back to one ViewTopic per topic
// and DMPageCounts.
type TopicsDMCounter interface {
	ViewTopicsDMCounts(ctx context.Context, tenant string, q TopicsMsgQuery, reads map[string]DMRead) (map[string]TopicDMCounts, error)
}

var _ TopicsDMCounter = (*Postgres)(nil)

// dmTS is a received_at as the hub sends it (time.RFC3339Nano in UTC: no
// trailing zero, no dot on a whole second), so the read cursor compares to
// it as the WUI's string did. to_json prints ISO 8601 whatever the session
// DateStyle; Postgres holds microseconds.
const dmTS = `((to_json(l.received_at AT TIME ZONE 'UTC') #>> '{}') || 'Z')`

// dmEnd is dmPeerOf's label of one end (id, box) when it is not us ($S),
// not empty and not the broadcast id.
func dmEnd(id, box string) string {
	return `WHEN ` + id + ` NOT IN ('', $S, 'ALL-0') THEN ` + id + ` || CASE WHEN ` + box + ` <> '' THEN '@' || ` + box + ` ELSE '' END`
}

// ViewTopicsDMCounts is DMPageCounts in SQL (DB payload round 2, R2-4): the
// same page as ViewTopicsMessages (door, order, PerTopic), counted with one
// GROUP BY per (topic, peer) in one round trip, so the hub reads ~24 rows
// instead of every line's metadata. The rules are DMPageCounts' line for
// line: own lines and own terminal lines (CLE-77889) are never new, a
// channel row is no DM, the cursor compares as strings (CLE-77873), and the
// total counts every DM line under its peer (CLE-77845).
func (s *Postgres) ViewTopicsDMCounts(ctx context.Context, tenant string, q TopicsMsgQuery, reads map[string]DMRead) (map[string]TopicDMCounts, error) {
	out := map[string]TopicDMCounts{}
	tasks := make([]string, 0, len(q.TaskIDs))
	for _, t := range q.TaskIDs {
		if canonUUIDRe.MatchString(t) {
			tasks = append(tasks, t)
		}
	}
	if len(tasks) == 0 || q.PerTopic <= 0 {
		return out, nil
	}
	door, args := topicsDoor(q, []any{tenant, tasks, q.Now, pgLimit(q.PerTopic)})
	peers := make([]string, 0, len(reads))
	tss := make([]string, 0, len(reads))
	ids := make([]string, 0, len(reads))
	for p, c := range reads {
		peers, tss, ids = append(peers, p), append(tss, c.TS), append(ids, c.MsgID)
	}
	n := len(args)
	args = append(args, q.Reader, peers, tss, ids)
	arg := func(i int) string { return "$" + strconv.Itoa(n+i) }
	// The page is MATERIALIZED so the cursors join it once, not once per
	// topic inside the LATERAL loop (1.6 -> 1.0 ms local, 24 topics).
	sql := strings.NewReplacer("$S", arg(1)+"::text").Replace(`WITH l AS MATERIALIZED (
			SELECT t.task_id, m.msg_id, m.received_at, m.from_id, m.typed_by, m.channel,
				CASE ` + dmEnd("m.from_id", "m.from_box") + ` ` + dmEnd("m.to_id", "m.to_box") + ` ELSE '' END AS peer
			FROM unnest($2::uuid[]) AS t(task_id)
			CROSS JOIN LATERAL (
				SELECT m.msg_id, m.received_at, m.from_id, m.from_box, m.to_id, m.to_box, m.typed_by, m.channel
				FROM messages m
				WHERE m.tenant_id = $1 AND m.task_id = t.task_id AND m.expires_at > $3 AND ` + door + `
				ORDER BY m.received_at DESC, m.msg_id::text DESC
				LIMIT $4) m)
		SELECT l.task_id, l.peer,
			count(*) FILTER (WHERE l.channel IS NULL AND l.peer <> '' AND l.from_id <> ''
				AND NOT (split_part($S, '@', 1) <> '' AND (split_part(l.from_id, '@', 1) = split_part($S, '@', 1)
					OR (l.typed_by IS NOT NULL AND split_part(l.typed_by, '@', 1) ~ '^HUM-[0-9]+$'
						AND split_part(l.typed_by, '@', 1) = split_part($S, '@', 1))))
				AND (r.ts IS NULL OR r.ts = '' OR CASE WHEN ` + dmTS + ` <> r.ts
					THEN ` + dmTS + ` COLLATE "C" > r.ts COLLATE "C" ELSE l.msg_id::text <> r.id END)),
			count(*) FILTER (WHERE l.channel IS NULL AND l.peer <> ''),
			count(*)
		FROM l
		LEFT JOIN unnest(` + arg(2) + `::text[], ` + arg(3) + `::text[], ` + arg(4) + `::text[]) AS r(peer, ts, id) ON r.peer = l.peer
		GROUP BY l.task_id, l.peer`)
	err := s.queryTenant(ctx, tenant, sql, args, func(rows pgx.Rows) error {
		var task, peer string
		var unread, total, lines int
		if err := rows.Scan(&task, &peer, &unread, &total, &lines); err != nil {
			return err
		}
		c, ok := out[task]
		if !ok {
			c = TopicDMCounts{Unread: map[string]int{}, Total: map[string]int{}}
		}
		c.Page += lines
		if unread > 0 {
			c.Unread[peer] = unread
		}
		if total > 0 {
			c.Total[peer] = total
		}
		out[task] = c
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}
