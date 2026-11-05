package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// The Postgres lane console (lane_console.go, rdb 0262). Every statement
// runs in the tenant's scope and names tenant_id in its WHERE.

const laneConsoleCols = `tenant_id, agent_box, agent_id, demand_until, demanded_by, screen, lines, redactions, captured_at`

func scanLaneConsole(r pgx.Row) (LaneConsole, error) {
	var c LaneConsole
	var red []byte
	if err := r.Scan(&c.Tenant, &c.AgentBox, &c.AgentID, &c.DemandUntil, &c.DemandedBy, &c.Screen, &c.Lines, &red, &c.CapturedAt); err != nil {
		return c, err
	}
	c.Redactions = map[string]int64{}
	return c, json.Unmarshal(red, &c.Redactions)
}

// DemandLaneConsole is LaneConsoleStore.DemandLaneConsole.
func (s *Postgres) DemandLaneConsole(ctx context.Context, tenant, box, agent, by string, until, now time.Time) (LaneConsole, error) {
	var c LaneConsole
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DELETE FROM lane_console WHERE tenant_id = $1 AND demand_until < $2`,
			tenant, now.Add(-LaneConsoleKeep)); err != nil {
			return err
		}
		var err error
		c, err = scanLaneConsole(tx.QueryRow(ctx, `INSERT INTO lane_console (tenant_id, agent_box, agent_id, demand_until, demanded_by)
			VALUES ($1, $2, $3, $4, $5)
			ON CONFLICT (tenant_id, agent_box, agent_id) DO UPDATE SET demand_until = EXCLUDED.demand_until, demanded_by = EXCLUDED.demanded_by
			RETURNING `+laneConsoleCols, tenant, box, agent, until.UTC(), by))
		return err
	})
	return c, err
}

// LaneConsoleOf is LaneConsoleStore.LaneConsoleOf.
func (s *Postgres) LaneConsoleOf(ctx context.Context, tenant, box, agent string) (LaneConsole, error) {
	var c LaneConsole
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		c, err = scanLaneConsole(tx.QueryRow(ctx, `SELECT `+laneConsoleCols+` FROM lane_console
			WHERE tenant_id = $1 AND agent_box = $2 AND agent_id = $3`, tenant, box, agent))
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return LaneConsole{}, ErrNotFound
	}
	return c, err
}

// LaneConsoleDemands is LaneConsoleStore.LaneConsoleDemands.
func (s *Postgres) LaneConsoleDemands(ctx context.Context, tenant, box string, now time.Time) ([]string, error) {
	out := []string{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `SELECT agent_id FROM lane_console
			WHERE tenant_id = $1 AND agent_box = $2 AND demand_until > $3 ORDER BY agent_id`,
			[]any{tenant, box, now}, func(r pgx.Rows) error {
				var a string
				err := r.Scan(&a)
				out = append(out, a)
				return err
			})
	})
	return out, err
}

// PutLaneConsole is LaneConsoleStore.PutLaneConsole.
func (s *Postgres) PutLaneConsole(ctx context.Context, tenant, box string, shot LaneConsoleShot, now time.Time) error {
	red := []byte("{}")
	if len(shot.Redactions) > 0 {
		var err error
		if red, err = json.Marshal(shot.Redactions); err != nil {
			return err
		}
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE lane_console SET screen = $4, lines = $5, redactions = $6::jsonb, captured_at = $7
			WHERE tenant_id = $1 AND agent_box = $2 AND agent_id = $3 AND demand_until > $7`,
			tenant, box, shot.AgentID, shot.Screen, shot.Lines, red, now.UTC())
		if err == nil && tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return err
	})
}
