package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// PreviewRow is one stored message as a link preview card prints it (topic
// e1f8f797): who wrote it, when, and the start of its body. The hub applies
// the reader's door to it (Channel, FromID, ToID) before anything leaves.
type PreviewRow struct {
	TaskID     string
	MsgID      string
	Channel    string // "" = a DM row
	FromID     string
	FromBox    string
	ToID       string
	ReceivedAt time.Time
	Body       string // at most PreviewBodyMax runes
}

// PreviewBodyMax is how much of a body a preview reads: enough for a title
// line and three excerpt lines, never a whole long post.
const PreviewBodyMax = 1200

// LinkPreviews is implemented by Memory and Postgres. A hub caller asks for
// it with a type assertion.
type LinkPreviews interface {
	// PreviewRows returns, in one round trip, the first message (by
	// received_at, then msg_id) of each live topic in tasks, keyed by task
	// id, and each live message in msgs, keyed by msg id. Ids that name no
	// live row are absent. Both lists hold canonical uuids.
	PreviewRows(ctx context.Context, tenantID string, tasks, msgs []string, now time.Time) (starters, messages map[string]PreviewRow, err error)
}

var (
	_ LinkPreviews = (*Memory)(nil)
	_ LinkPreviews = (*Postgres)(nil)
)

func previewRowOf(m *Message) PreviewRow {
	body := m.Body
	if r := []rune(body); len(r) > PreviewBodyMax {
		body = string(r[:PreviewBodyMax])
	}
	return PreviewRow{TaskID: m.TaskID, MsgID: m.MsgID, Channel: m.Channel, FromID: m.FromID, FromBox: m.FromBox,
		ToID: m.ToID, ReceivedAt: m.ReceivedAt, Body: body}
}

// ---- Memory ---------------------------------------------------------------

func (s *Memory) PreviewRows(_ context.Context, tenant string, tasks, msgs []string, now time.Time) (map[string]PreviewRow, map[string]PreviewRow, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	wantTask, wantMsg := map[string]bool{}, map[string]bool{}
	for _, id := range tasks {
		wantTask[id] = true
	}
	for _, id := range msgs {
		wantMsg[id] = true
	}
	starters, messages := map[string]PreviewRow{}, map[string]PreviewRow{}
	first := map[string]*Message{}
	for _, m := range s.liveLocked(tenant, now) {
		if wantTask[m.TaskID] {
			if f := first[m.TaskID]; f == nil || newer(f.ReceivedAt, f.MsgID, m.ReceivedAt, m.MsgID) {
				first[m.TaskID] = m
			}
		}
		if wantMsg[m.MsgID] {
			messages[m.MsgID] = previewRowOf(m)
		}
	}
	for id, m := range first {
		starters[id] = previewRowOf(m)
	}
	return starters, messages, nil
}

// ---- Postgres -------------------------------------------------------------

// previewRowsSQL: $1 tenant, $2 task uuids, $3 now, $4 msg uuids, $5 the
// body cut. The starter is each topic's earliest live row on its
// messages_task range (the topic list's first_msg order); the second half is
// the asked messages by primary key.
const previewRowsSQL = `SELECT 's', f.task_id::text, f.msg_id::text, COALESCE(f.channel, ''), f.from_id, f.from_box, f.to_id,
	f.received_at, left(f.body, $5)
FROM unnest($2::uuid[]) AS t (id) CROSS JOIN LATERAL (
	SELECT m.task_id, m.msg_id, m.channel, m.from_id, m.from_box, m.to_id, m.received_at, m.body FROM messages m
	WHERE m.tenant_id = $1 AND m.task_id = t.id AND m.expires_at > $3
	ORDER BY m.received_at, m.msg_id::text LIMIT 1) f
UNION ALL
SELECT 'm', m.task_id::text, m.msg_id::text, COALESCE(m.channel, ''), m.from_id, m.from_box, m.to_id,
	m.received_at, left(m.body, $5)
FROM messages m
WHERE m.tenant_id = $1 AND m.msg_id = ANY($4::uuid[]) AND m.expires_at > $3`

func (s *Postgres) PreviewRows(ctx context.Context, tenant string, tasks, msgs []string, now time.Time) (map[string]PreviewRow, map[string]PreviewRow, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, nil, err
	}
	starters, messages := map[string]PreviewRow{}, map[string]PreviewRow{}
	if len(tasks) == 0 && len(msgs) == 0 {
		return starters, messages, nil
	}
	if tasks == nil {
		tasks = []string{}
	}
	if msgs == nil {
		msgs = []string{}
	}
	err := s.queryTenant(ctx, tenant, previewRowsSQL, []any{tenant, tasks, now, msgs, PreviewBodyMax}, func(r pgx.Rows) error {
		var which string
		var p PreviewRow
		if err := r.Scan(&which, &p.TaskID, &p.MsgID, &p.Channel, &p.FromID, &p.FromBox, &p.ToID, &p.ReceivedAt, &p.Body); err != nil {
			return err
		}
		if which == "s" {
			starters[p.TaskID] = p
		} else {
			messages[p.MsgID] = p
		}
		return nil
	})
	if err != nil {
		return nil, nil, err
	}
	return starters, messages, nil
}
