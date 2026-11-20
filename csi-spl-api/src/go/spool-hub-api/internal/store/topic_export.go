package store

import (
	"context"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// TopicExports is the store half of the topic export (spec 183 row P1): the
// rows of one topic and the humans a box acts for. The hub applies the door;
// the store only reads.
type TopicExports interface {
	// TopicExportRows is every live (not expired) message of taskID, oldest
	// first by (ts, msg_id), less a loop prompt message (rdb 0299, spec 182
	// 5.2: shown to nobody, so in no export), with no reader filter: the fields the read door
	// decides on and the render prints. Deliveries and the revision number
	// are not read.
	TopicExportRows(ctx context.Context, tenantID, taskID string, now time.Time) ([]EditableMessage, error)
	// BoxOperatorHumans is the members bound as operators of box (rdb 0040),
	// sorted.
	BoxOperatorHumans(ctx context.Context, tenantID, boxID string) ([]string, error)
}

// ---- Memory driver -----------------------------------------------------------

// TopicExportRows implements TopicExports on the in-memory store.
func (s *Memory) TopicExportRows(_ context.Context, tenant, taskID string, now time.Time) ([]EditableMessage, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var ms []*Message
	for k, m := range s.messages {
		if k[0] == tenant && m.TaskID == taskID && m.ExpiresAt.After(now) && m.LoopID == "" {
			ms = append(ms, m)
		}
	}
	sort.Slice(ms, func(i, j int) bool {
		if !ms[i].TS.Equal(ms[j].TS) {
			return ms[i].TS.Before(ms[j].TS)
		}
		return ms[i].MsgID < ms[j].MsgID
	})
	out := make([]EditableMessage, len(ms))
	for i, m := range ms {
		out[i] = EditableMessage{
			MsgID: m.MsgID, TaskID: m.TaskID, Channel: m.Channel, ParentTaskID: m.ParentTaskID,
			FromBox: m.FromBox, FromID: m.FromID, ToBox: m.ToBox, ToID: m.ToID, Kind: m.Kind,
			Body: m.Body, Msg: m.Msg, Env: m.Env, EnvSig: m.EnvSig, TS: m.TS, ReceivedAt: m.ReceivedAt,
			EditedAt: m.EditedAt, EditedBy: m.EditedBy, TypedBy: m.TypedBy,
		}
	}
	return out, nil
}

// BoxOperatorHumans implements TopicExports on the in-memory store.
func (s *Memory) BoxOperatorHumans(_ context.Context, tenant, box string) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	var out []string
	for k := range s.operators {
		if k[0] != tenant || k[1] != box {
			continue
		}
		if _, member := s.hum.members[[2]string{tenant, k[2]}]; member { // the FK cascade, as BoxOperatorBound
			out = append(out, k[2])
		}
	}
	sort.Strings(out)
	return out, nil
}

// ---- Postgres driver ---------------------------------------------------------

// TopicExportRows implements TopicExports on Postgres.
func (s *Postgres) TopicExportRows(ctx context.Context, tenant, taskID string, now time.Time) ([]EditableMessage, error) {
	if !canonUUIDRe.MatchString(taskID) {
		return nil, nil
	}
	var out []EditableMessage
	err := s.queryTenant(ctx, tenant, `SELECT msg_id::text, task_id::text, channel, parent_task_id::text,
			from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, ts, received_at, edited_at, edited_by, typed_by
		FROM messages
		WHERE tenant_id = $1 AND task_id = $2::uuid AND expires_at > $3 AND loop_id IS NULL
		ORDER BY ts, msg_id`, []any{tenant, taskID, now}, func(rows pgx.Rows) error {
		var m EditableMessage
		var channel, parent, editedBy, typedBy *string
		var editedAt *time.Time
		if err := rows.Scan(&m.MsgID, &m.TaskID, &channel, &parent, &m.FromBox, &m.FromID, &m.ToBox, &m.ToID,
			&m.Kind, &m.Body, &m.Msg, &m.EnvSig, &m.Env, &m.TS, &m.ReceivedAt, &editedAt, &editedBy, &typedBy); err != nil {
			return err
		}
		m.Channel, m.ParentTaskID, m.EditedBy, m.TypedBy = deref(channel), deref(parent), deref(editedBy), deref(typedBy)
		if editedAt != nil {
			m.EditedAt = *editedAt
		}
		out = append(out, m)
		return nil
	})
	return out, err
}

// BoxOperatorHumans implements TopicExports on Postgres.
func (s *Postgres) BoxOperatorHumans(ctx context.Context, tenant, box string) ([]string, error) {
	var out []string
	err := s.queryTenant(ctx, tenant, `SELECT human_id FROM box_operators
		WHERE tenant_id = $1 AND box_id = $2 ORDER BY human_id`, []any{tenant, box}, func(rows pgx.Rows) error {
		var h string
		if err := rows.Scan(&h); err != nil {
			return err
		}
		out = append(out, h)
		return nil
	})
	return out, err
}
