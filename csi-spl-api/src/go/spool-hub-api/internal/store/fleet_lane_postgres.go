package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0096. Every statement runs in the tenant scope; the
// prune, the upsert and the read-back are one transaction.

const laneCols = `agent_id, agent_box, repo, branch, scope, files, topic, state, writer_box, updated_at`

func scanLane(row pgx.Row, fleet string, now time.Time) (FleetLane, error) {
	l := FleetLane{Fleet: fleet}
	if err := row.Scan(&l.AgentID, &l.AgentBox, &l.Repo, &l.Branch, &l.Scope, &l.Files, &l.Topic, &l.State, &l.WriterBox, &l.UpdatedAt); err != nil {
		return l, err
	}
	if l.Files == nil {
		l.Files = []string{}
	}
	l.UpdatedAt = l.UpdatedAt.UTC()
	l.Age = now.Sub(l.UpdatedAt)
	return l, nil
}

func (s *Postgres) PutFleetLane(ctx context.Context, tenant string, l FleetLane, box string, now time.Time) (FleetLane, error) {
	var out FleetLane
	files := l.Files
	if files == nil {
		files = []string{}
	}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DELETE FROM fleet_lanes WHERE tenant_id = $1 AND fleet = $2
			AND state = 'done' AND updated_at < $3`, tenant, l.Fleet, now.Add(-LaneDoneTTL)); err != nil {
			return err
		}
		var err error
		out, err = scanLane(tx.QueryRow(ctx, `INSERT INTO fleet_lanes
			(tenant_id, fleet, agent_id, agent_box, repo, branch, scope, files, topic, state, writer_box, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
			ON CONFLICT (tenant_id, fleet, agent_id, agent_box) DO UPDATE SET
				repo = EXCLUDED.repo, branch = EXCLUDED.branch,
				scope = EXCLUDED.scope, files = EXCLUDED.files, topic = EXCLUDED.topic,
				state = EXCLUDED.state, writer_box = EXCLUDED.writer_box, updated_at = EXCLUDED.updated_at
			RETURNING `+laneCols,
			tenant, l.Fleet, l.AgentID, l.AgentBox, l.Repo, l.Branch, l.Scope, files, l.Topic, l.State, box, now), l.Fleet, now)
		return err
	})
	return out, err
}

func (s *Postgres) ListFleetLanes(ctx context.Context, tenant, fleet string, now time.Time) ([]FleetLane, error) {
	out := []FleetLane{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT `+laneCols+` FROM fleet_lanes
			WHERE tenant_id = $1 AND fleet = $2`, tenant, fleet)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			l, err := scanLane(rows, fleet, now)
			if err != nil {
				return err
			}
			out = append(out, l)
		}
		return rows.Err()
	})
	sortLanes(out)
	return out, err
}
