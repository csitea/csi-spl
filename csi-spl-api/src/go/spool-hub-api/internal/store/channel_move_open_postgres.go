// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"encoding/json"

	"github.com/jackc/pgx/v5"
)

// ChannelMoveOpens is what the box's pick-up reads (spec 169 T16, 8.5.5 item 3):
// the journals no P7 closed yet, in every workspace or in one <DST>.
type ChannelMoveOpens interface {
	// OpenChannelMoves are the open journals (done_at NULL), oldest first, at
	// most ChannelMoveOpenMax. dst "" = every workspace's.
	OpenChannelMoves(ctx context.Context, dst string) ([]ChannelMoveOpenRow, error)
}

var _ ChannelMoveOpens = (*Postgres)(nil)

// ChannelMoveOpenMax bounds one read: the pick-up runs the oldest first, so a
// move past the bound is read once an older one is done.
const ChannelMoveOpenMax = 200

// ChannelMoveOpenRow is one open journal. Steps is step -> "started" | "done".
// Inputs is P1's detail.inputs as stored; nil when P1 has none (R7 c-250 N4:
// its second write failed), which the pick-up must not send as {}.
type ChannelMoveOpenRow struct {
	Dst, MoveID, Src, Channel, GoMsgID string
	Steps                              map[string]string
	Inputs                             json.RawMessage
}

// OpenChannelMoves implements ChannelMoveOpens, under the operator scope.
func (s *Postgres) OpenChannelMoves(ctx context.Context, dst string) ([]ChannelMoveOpenRow, error) {
	out := []ChannelMoveOpenRow{}
	err := s.asOperatorQuery(ctx, `SELECT j.tenant_id, j.move_id::text, j.src_tenant_id, j.src_channel_id, j.go_msg_id::text,
			(SELECT COALESCE(jsonb_object_agg(st.step, CASE WHEN st.done_at IS NULL THEN 'started' ELSE 'done' END), '{}'::jsonb)
				FROM channel_move_steps st WHERE st.tenant_id = j.tenant_id AND st.move_id = j.move_id),
			p1.detail -> 'inputs'
		FROM channel_move_journal j
		LEFT JOIN channel_move_steps p1 ON p1.tenant_id = j.tenant_id AND p1.move_id = j.move_id AND p1.step = 'P1'
		WHERE j.done_at IS NULL AND ($1 = '' OR j.tenant_id = $1)
		ORDER BY j.created_at, j.move_id LIMIT $2`, []any{dst, ChannelMoveOpenMax}, func(r pgx.Rows) error {
		var row ChannelMoveOpenRow
		var steps, inputs []byte
		if err := r.Scan(&row.Dst, &row.MoveID, &row.Src, &row.Channel, &row.GoMsgID, &steps, &inputs); err != nil {
			return err
		}
		if err := json.Unmarshal(steps, &row.Steps); err != nil {
			return err
		}
		if len(inputs) > 0 && string(inputs) != "null" {
			row.Inputs = inputs
		}
		out = append(out, row)
		return nil
	})
	return out, err
}
