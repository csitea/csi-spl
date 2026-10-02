package store

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// viewChangesSQL is ViewChanges in one statement. Each branch is one signal
// on its own index, never a scan of the tenant's messages:
//   - new: messages_received (tenant_id, received_at) range;
//   - edit: message_revisions (one row per edit; revision 1 is stamped with
//     the message's received_at, so an old message's first edit is listed
//     by its revision 2);
//   - kind: message_kind_changes (one row per change);
//   - move / archive: the partial indexes messages_moved and
//     messages_archived (only moved / archived rows; "x > $2" implies the
//     index's "x IS NOT NULL");
//   - react: message_reactions created after since, plus each held message
//     whose current count is not the one the caller holds (a removal).
//
// The join keeps rows inside retention and reads where each row is now.
const viewChangesSQL = `SELECT c.kind, m.msg_id::text, m.task_id::text, COALESCE(m.channel, ''), m.from_id, m.to_id,
		CASE WHEN m.moved_at IS NULL THEN '' ELSE COALESCE(m.moved_from_channel, '') END,
		COALESCE(m.moved_from_task::text, '')
	FROM (
		SELECT 1 AS o, 'new' AS kind, msg_id FROM messages WHERE tenant_id = $1 AND received_at > $2
		UNION ALL SELECT 2, 'edit', msg_id FROM message_revisions WHERE tenant_id = $1 AND edited_at > $2 AND revision > 1
		UNION ALL SELECT 3, 'kind', msg_id FROM message_kind_changes WHERE tenant_id = $1 AND set_at > $2
		UNION ALL SELECT 4, 'move', msg_id FROM messages WHERE tenant_id = $1 AND moved_at > $2
		UNION ALL SELECT 5, 'archive', msg_id FROM messages WHERE tenant_id = $1 AND archived_at > $2
		UNION ALL SELECT 6, 'react', r.msg_id FROM (
			SELECT msg_id FROM message_reactions WHERE tenant_id = $1 AND created_at > $2
			UNION
			SELECT h.msg_id FROM unnest($3::uuid[], $4::bigint[]) AS h (msg_id, n)
			WHERE h.n <> (SELECT count(*) FROM message_reactions x WHERE x.tenant_id = $1 AND x.msg_id = h.msg_id)
		) r
	) c
	JOIN messages m ON m.tenant_id = $1 AND m.msg_id = c.msg_id AND m.expires_at > $5
	ORDER BY c.o, m.received_at, m.msg_id
	LIMIT $6`

func (s *Postgres) ViewChanges(ctx context.Context, tenant string, q ChangeQuery) ([]TopicChange, error) {
	ids, ns := make([]string, 0, len(q.Held)), make([]int64, 0, len(q.Held))
	for id, n := range q.Held {
		if canonUUIDRe.MatchString(id) {
			ids, ns = append(ids, id), append(ns, int64(n))
		}
	}
	var out []TopicChange
	err := s.queryTenant(ctx, tenant, viewChangesSQL, []any{tenant, q.Since, ids, ns, q.Now, pgLimit(q.Max)},
		func(rows pgx.Rows) error {
			var c TopicChange
			var kind string
			if err := rows.Scan(&kind, &c.MsgID, &c.TaskID, &c.Channel, &c.FromID, &c.ToID, &c.HomeChan, &c.HomeTask); err != nil {
				return err
			}
			c.Kind = ChangeKind(kind)
			out = append(out, c)
			return nil
		})
	return out, err
}
