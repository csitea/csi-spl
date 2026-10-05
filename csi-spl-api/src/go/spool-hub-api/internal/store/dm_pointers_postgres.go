package store

import (
	"context"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/jackc/pgx/v5"
)

// dmPointersSQL is ViewDMPointers' read (dm_pointers.go). The pair's rows
// are a MATERIALIZED candidate set, each side a range of the rdb 0001 index
// it leads with: messages_to (tenant_id, to_box, to_id) for the person's tag,
// messages_from (tenant_id, from_box, from_id) for the agent's line. So the
// read costs the agent's own traffic: without the fence the ORDER BY ..
// LIMIT tempts the planner into a backward walk of messages_received over
// the whole tenant, which finds nothing for a pair that never met in a
// channel (the rows=1 misestimate of view_postgres.go). The agent's boxes are
// the peer's box, or every pinned box of the tenant when the peer names none;
// a tag may also be stored to box-wui (a browser channel post). door is the
// read door (rdb 0028) on the line's channel, off for the door-off rig.
// Parameters: $1 tenant, $2 now, $3 viewer, $4 agent, $5 agent box ("" =
// any), $6 box-wui, $7 lobby, $8 limit, then the door's $9 public channels
// and $10 the reader's created channels.
func dmPointersSQL(door bool) string {
	boxes := `(CASE WHEN $5::text = '' THEN ARRAY(SELECT p.box_id FROM pins p WHERE p.tenant_id = $1) ELSE ARRAY[$5::text] END)`
	both := " AND m.expires_at > $2 AND m.channel IS NOT NULL"
	if door {
		both += " AND (m.channel = ANY($9::text[]) OR m.channel = ANY($10::text[]))"
	}
	return `WITH c AS MATERIALIZED (
			SELECT ` + topicMsgCols + ` FROM messages m
			WHERE m.tenant_id = $1 AND m.to_box = ANY(` + boxes + ` || $6::text) AND m.to_id = $4 AND m.from_id = $3` + both + `
			UNION ALL
			SELECT ` + topicMsgCols + ` FROM messages m
			WHERE m.tenant_id = $1 AND m.from_box = ANY(` + boxes + `) AND m.from_id = $4 AND m.to_id = $3` + both + `)
		SELECT c.msg_id::text, c.received_at, c.env, c.edited_at, c.edited_by,
			CASE WHEN c.edited_at IS NULL THEN 0 ELSE COALESCE((SELECT MAX(revision)
				FROM message_revisions r WHERE r.tenant_id = c.tenant_id AND r.msg_id = c.msg_id), 0) END,
			c.is_parent, c.typed_by, c.responsible, c.ref_task_id::text, c.mirror_of::text, c.kind, c.kind_set_at, c.kind_set_by, ` + moveCols("c") + `
		FROM c
		WHERE true` + archivedHideSQL("c", "$1", "$7::text") + `
		ORDER BY c.received_at DESC, c.msg_id::text DESC
		LIMIT $8`
}

func (s *Postgres) ViewDMPointers(ctx context.Context, tenant string, q DMPointerQuery) ([]ViewMsg, error) {
	if q.Viewer == "" || q.Agent == "" {
		return nil, nil
	}
	args := []any{tenant, q.Now, q.Viewer, q.Agent, q.AgentBox, msg.PeersToBox, q.Lobby, dmPointerLimit(q.Limit)}
	if q.Reader != "" {
		args = append(args, PublicChannels, q.ReaderChannels)
	}
	p := &topicPage{idx: map[string]int{}}
	err := s.queryTenant(ctx, tenant, dmPointersSQL(q.Reader != ""), args, func(rows pgx.Rows) error {
		v, err := scanViewMsg(rows)
		if err != nil {
			return err
		}
		p.idx[v.MsgID] = len(p.out)
		p.ids = append(p.ids, v.MsgID)
		p.out = append(p.out, v)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return p.finish(ctx, s, tenant)
}
