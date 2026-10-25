package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of dm_agents.go (rdb 0228, spec 151 4.1). Every call runs in
// the workspace's own scope; rdb 0228's tenant_scope policy is FOR ALL.

const dmPairWhere = `tenant_id = $1 AND a_id = $2 AND a_box = $3 AND b_id = $4 AND b_box = $5`

func dmPairArgs(tenant string, p DMPair) []any {
	return []any{tenant, p.A.ID, p.A.Box, p.B.ID, p.B.Box}
}

// AddDMAgent implements DMAgentStore: a live row is left as it is, a removed
// one comes back with by and now.
func (s *Postgres) AddDMAgent(ctx context.Context, tenant string, pair DMPair, agent DMEnd, by string, now time.Time) error {
	if err := checkDMAgentCall(tenant, pair, &agent); err != nil {
		return err
	}
	args := append(dmPairArgs(tenant, pair), agent.ID, agent.Box, by, now.UTC())
	_, err := s.execTenant(ctx, tenant, `INSERT INTO dm_agents
			(tenant_id, a_id, a_box, b_id, b_box, agent_id, agent_box, origin, invited_by, added_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, 'invite', $8, $9)
		ON CONFLICT (tenant_id, a_id, a_box, b_id, b_box, agent_id, agent_box) DO UPDATE
		SET origin = 'invite', invited_by = EXCLUDED.invited_by, added_at = EXCLUDED.added_at, removed_at = NULL
		WHERE dm_agents.origin = 'removed'`, args...)
	return err
}

// RemoveDMAgent implements DMAgentStore.
func (s *Postgres) RemoveDMAgent(ctx context.Context, tenant string, pair DMPair, agent DMEnd, now time.Time) error {
	if err := checkDMAgentCall(tenant, pair, &agent); err != nil {
		return err
	}
	args := append(dmPairArgs(tenant, pair), agent.ID, agent.Box, now.UTC())
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE dm_agents SET origin = 'removed', removed_at = $8
			WHERE `+dmPairWhere+` AND agent_id = $6 AND agent_box = $7 AND origin = 'invite'`, args...)
		if err != nil || tag.RowsAffected() > 0 {
			return err
		}
		var found bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM dm_agents WHERE `+dmPairWhere+`
			AND agent_id = $6 AND agent_box = $7)`, args[:7]...).Scan(&found); err != nil {
			return err
		}
		if !found {
			return ErrNotFound
		}
		return nil
	})
}

// DMAgents implements DMAgentStore.
func (s *Postgres) DMAgents(ctx context.Context, tenant string, pair DMPair) ([]DMAgent, error) {
	if err := checkDMAgentCall(tenant, pair, nil); err != nil {
		return nil, err
	}
	out := []DMAgent{}
	err := s.queryTenant(ctx, tenant, `SELECT agent_id, agent_box, origin, invited_by, added_at, removed_at
		FROM dm_agents WHERE `+dmPairWhere, dmPairArgs(tenant, pair), func(r pgx.Rows) error {
		var a DMAgent
		var removed *time.Time
		if err := r.Scan(&a.Agent.ID, &a.Agent.Box, &a.Origin, &a.InvitedBy, &a.AddedAt, &removed); err != nil {
			return err
		}
		a.AddedAt = a.AddedAt.UTC()
		if removed != nil {
			a.RemovedAt = removed.UTC()
		}
		out = append(out, a)
		return nil
	})
	sortDMAgents(out)
	return out, err
}

// dmAgentDoorSQL is the read door's DM agent case (spec 151 4.1) on the
// messages alias m ("messages" when the statement has none), for the reader
// placeholder rd: m is a DM message written by an agent added to a pair of
// which rd is an end, to one of the pair's ends, while the agent was in, in
// a topic that holds a message between the pair's two ends. Memory twin:
// readableByDMAgentLocked. The dm_agents probe goes first: it is an index
// step on (tenant_id, agent_id, agent_box), and a DM from no added agent
// stops there.
func dmAgentDoorSQL(m, rd string) string {
	return `(` + m + `.channel IS NULL AND EXISTS (SELECT 1 FROM dm_agents da
		WHERE da.tenant_id = ` + m + `.tenant_id AND da.agent_id = ` + m + `.from_id AND da.agent_box = ` + m + `.from_box
		AND (da.a_id = ` + rd + ` OR da.b_id = ` + rd + `)
		AND ((` + m + `.to_id = da.a_id AND ` + m + `.to_box = da.a_box) OR (` + m + `.to_id = da.b_id AND ` + m + `.to_box = da.b_box))
		AND ` + m + `.received_at >= da.added_at AND (da.removed_at IS NULL OR ` + m + `.received_at < da.removed_at)
		AND EXISTS (SELECT 1 FROM messages dp WHERE dp.tenant_id = ` + m + `.tenant_id AND dp.task_id = ` + m + `.task_id
			AND dp.channel IS NULL
			AND ((dp.from_id = da.a_id AND dp.from_box = da.a_box AND dp.to_id = da.b_id AND dp.to_box = da.b_box)
				OR (dp.from_id = da.b_id AND dp.from_box = da.b_box AND dp.to_id = da.a_id AND dp.to_box = da.a_box)))))`
}
