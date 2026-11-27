// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"fmt"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/search"
)

// mvTaskQuery: a task whose scope_query holds an in: (channel:) term that
// names the channel ($2): in:#x, in:x, in=x, in:"#x", any case. The
// catalogue's scheduled_tasks Refs (channelmove/catalogue.go) holds the same
// test with @channel, so the P7 proofs find the rows this rewrite changes.
const mvTaskQuery = `scope_query ~* ('(^|[[:space:](-])(in|channel)[:=]"?#?' || $2::text || '"?($|[[:space:])])')`

// rewriteTaskQueries is spec 187 8.1 on a staying task's scope_query
// (SPL-6692, owner HUM-10 answer A, msg b65adfcd): the in: terms that name
// the moved channel are dropped (search.DropChannel, grammar-aware), and a
// task the term limited to that channel is paused, reason channel_moved, as
// rewriteTasks pauses one it leaves with no channel; a deleted task only
// loses the term. Runs in the move's transaction, after rewriteTasks.
func (m *pgMove) rewriteTaskQueries() error {
	type row struct{ id, query, state string }
	rows, err := m.tx.Query(m.ctx, `SELECT task_id::text, scope_query, state FROM scheduled_tasks
		WHERE tenant_id = $1 AND `+mvTaskQuery, m.req.Src, m.req.Channel)
	if err != nil {
		return fmt.Errorf("scheduled_tasks scope_query: %w", err)
	}
	tasks, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (row, error) {
		var x row
		return x, r.Scan(&x.id, &x.query, &x.state)
	})
	if err != nil {
		return fmt.Errorf("scheduled_tasks scope_query: %w", err)
	}
	for _, x := range tasks {
		out, limited, err := search.DropChannel(x.query, m.req.Channel)
		if err != nil {
			return fmt.Errorf("scheduled_tasks %s: %w", x.id, err)
		}
		if out == x.query {
			continue
		}
		pause := limited && x.state != TaskDeleted
		if _, err := m.exec(`UPDATE scheduled_tasks SET scope_query = $3,
				state = CASE WHEN $4 THEN 'paused' ELSE state END,
				paused_reason = CASE WHEN $4 THEN 'channel_moved' ELSE paused_reason END,
				next_due_at = CASE WHEN $4 THEN NULL ELSE next_due_at END
			WHERE tenant_id = $1 AND task_id = $2::uuid`, m.req.Src, x.id, out, pause); err != nil {
			return fmt.Errorf("scheduled_tasks %s: %w", x.id, err)
		}
	}
	return nil
}
