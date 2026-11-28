package store

import (
	"context"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// DropAgentInvites implements AgentInvites on Postgres: one UPDATE of the
// agent's rows on that box, in the tenant scope.
func (s *Postgres) DropAgentInvites(ctx context.Context, tenant, box, agent string, _ time.Time) ([]string, error) {
	var out []string
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `UPDATE channel_subscriptions SET origin = 'removed'
			WHERE tenant_id = $1 AND box_id = $2 AND agent_id = $3 AND origin <> 'removed'
			RETURNING channel_id`, tenant, box, agent)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, pgx.RowTo[string])
		return err
	})
	if err != nil || len(out) == 0 {
		return nil, err
	}
	sort.Strings(out)
	return out, nil
}
