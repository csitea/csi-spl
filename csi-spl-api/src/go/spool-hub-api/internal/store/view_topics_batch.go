package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// TopicsMsgQuery reads the newest messages of several topics at once: the
// per_topic= page of GET /v1/view/topics (CLE-34985). Per topic it answers
// exactly what ViewTopic answers for TopicMsgQuery{TaskID, Desc: true,
// Limit: PerTopic} with the same Reader door.
type TopicsMsgQuery struct {
	TaskIDs        []string
	PerTopic       int
	Reader         string // "" = no door (the door-off rig), as TopicMsgQuery
	ReaderChannels []string
	Now            time.Time
}

// TopicsMessager is the batch read a store may offer. Without it the hub
// falls back to one ViewTopic per topic (the memory store).
type TopicsMessager interface {
	ViewTopicsMessages(ctx context.Context, tenant string, q TopicsMsgQuery) (map[string][]ViewMsg, map[string][]StoredReaction, error)
}

var _ TopicsMessager = (*Postgres)(nil)

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
	// The per-message read door (rdb 0028), the same predicate as ViewTopic.
	door, args := "true", []any{tenant, tasks, q.Now, pgLimit(q.PerTopic)}
	if q.Reader != "" {
		door = `((m.channel IS NULL AND (m.from_id = $5 OR m.to_id = $5))
			OR m.channel = ANY($6::text[]) OR m.channel = ANY($7::text[]))`
		args = append(args, q.Reader, DefaultChannels, q.ReaderChannels)
	}
	where := map[string]*ViewMsg{}
	var ids []string
	err := s.queryTenant(ctx, tenant, `SELECT t.task_id::text, m.msg_id::text, m.received_at, m.env, m.edited_at, m.edited_by,
			CASE WHEN m.edited_at IS NULL THEN 0 ELSE COALESCE((SELECT MAX(revision)
				FROM message_revisions r WHERE r.tenant_id = m.tenant_id AND r.msg_id = m.msg_id), 0) END,
			m.is_parent, m.typed_by
		FROM unnest($2::uuid[]) WITH ORDINALITY AS t(task_id, n)
		CROSS JOIN LATERAL (
			SELECT * FROM messages m
			WHERE m.tenant_id = $1 AND m.task_id = t.task_id AND m.expires_at > $3 AND `+door+`
			ORDER BY m.received_at DESC, m.msg_id::text DESC
			LIMIT $4) m
		ORDER BY t.n, m.received_at DESC, m.msg_id::text DESC`, args,
		func(rows pgx.Rows) error {
			var task string
			v := ViewMsg{Deliveries: []ViewDelivery{}}
			var editedBy, typedBy *string
			var editedAt *time.Time
			if err := rows.Scan(&task, &v.MsgID, &v.ReceivedAt, &v.Env, &editedAt, &editedBy, &v.Revision, &v.IsParent, &typedBy); err != nil {
				return err
			}
			v.TypedBy, v.EditedBy = deref(typedBy), deref(editedBy)
			if editedAt != nil {
				v.EditedAt = *editedAt
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
	for task := range msgs {
		for i := range msgs[task] {
			where[msgs[task][i].MsgID] = &msgs[task][i]
		}
	}
	err = s.queryTenantBatch(ctx, tenant,
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
	if err != nil {
		return nil, nil, err
	}
	return msgs, react, nil
}
