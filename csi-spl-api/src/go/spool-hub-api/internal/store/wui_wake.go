package store

import (
	"context"
	"database/sql"
	"errors"

	"github.com/jackc/pgx/v5"
)

// Spec 059 §11 S3: browsers on another hub process. Every newly stored
// message is announced on WUIWakeChannel by the statement that stores it (no
// extra round trip; Postgres delivers it on commit), and each hub process
// fans it out to the browser sockets it holds, as the storing process does
// for its own. Edits, reactions and deletes are not carried yet.

// WUIWakeChannel is the Postgres NOTIFY channel; the payload is "<tenant>|<msg_id>".
const WUIWakeChannel = "spool_wui"

// WUIWaker is implemented by stores that announce every newly stored message.
type WUIWaker interface {
	// ListenWakes is ListenWake plus wui, called for every newly stored
	// message (tenant, msg_id), on the same listen connection. A nil fn is
	// not listened for. fn must not block.
	ListenWakes(ctx context.Context, box func(tenant, box string), wui func(tenant, msgID string)) error
	// FanoutRow reads what the browser fan-out of a stored message needs:
	// ids, parties, channel, received_at, env, is_parent, typed_by.
	// ErrNotFound when absent.
	FanoutRow(ctx context.Context, tenant, msgID string) (Message, error)
}

func (s *Memory) FanoutRow(_ context.Context, tenant, msgID string) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, ok := s.messages[[2]string{tenant, msgID}]
	if !ok {
		return Message{}, ErrNotFound
	}
	return *m, nil
}

func (s *Postgres) FanoutRow(ctx context.Context, tenant, msgID string) (Message, error) {
	m := Message{TenantID: tenant, MsgID: msgID}
	var channel, typedBy sql.NullString
	err := s.queryRowTenant(ctx, tenant, `SELECT task_id::text, channel, from_box, from_id, to_box, to_id,
			received_at, env, is_parent, typed_by
		FROM messages WHERE tenant_id = $1 AND msg_id = $2`, []any{tenant, msgID},
		&m.TaskID, &channel, &m.FromBox, &m.FromID, &m.ToBox, &m.ToID, &m.ReceivedAt, &m.Env, &m.IsParent, &typedBy)
	if errors.Is(err, pgx.ErrNoRows) {
		return Message{}, ErrNotFound
	}
	if err != nil {
		return Message{}, err
	}
	m.Channel, m.TypedBy = channel.String, typedBy.String
	return m, nil
}
