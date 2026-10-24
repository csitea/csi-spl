package store

import (
	"context"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0096. Every statement runs in the tenant scope; the
// prune, the upsert and the read-back are one transaction.

const laneCols = `agent_id, agent_box, repo, branch, scope, files, topic, issue_key, state, writer_box, updated_at`

func scanLane(row pgx.Row, fleet string, now time.Time) (FleetLane, error) {
	l := FleetLane{Fleet: fleet}
	if err := row.Scan(&l.AgentID, &l.AgentBox, &l.Repo, &l.Branch, &l.Scope, &l.Files, &l.Topic, &l.IssueKey, &l.State, &l.WriterBox, &l.UpdatedAt); err != nil {
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
			(tenant_id, fleet, agent_id, agent_box, repo, branch, scope, files, topic, issue_key, state, writer_box, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
			ON CONFLICT (tenant_id, fleet, agent_id, agent_box) DO UPDATE SET
				repo = EXCLUDED.repo, branch = EXCLUDED.branch,
				scope = EXCLUDED.scope, files = EXCLUDED.files, topic = EXCLUDED.topic, issue_key = EXCLUDED.issue_key,
				state = EXCLUDED.state, writer_box = EXCLUDED.writer_box, updated_at = EXCLUDED.updated_at
			RETURNING `+laneCols,
			tenant, l.Fleet, l.AgentID, l.AgentBox, l.Repo, l.Branch, l.Scope, files, l.Topic, l.IssueKey, l.State, box, now), l.Fleet, now)
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

// fleetLaneIssuesSQL: $1 tenant, $2 the topics (uuid[]), $3 the own numbers
// (int[]). The first half is one issue_discussions_task range per topic;
// the second the issues primary key. A row's task is "" for an own number.
const fleetLaneIssuesSQL = `SELECT d.task_id::text, i.number, i.status
	FROM issue_discussions d JOIN issues i ON i.tenant_id = d.tenant_id AND i.number = d.number
	WHERE d.tenant_id = $1 AND d.task_id = ANY($2::uuid[]) AND i.deleted_at IS NULL AND i.archived_at IS NULL
	UNION ALL
	SELECT '', number, status FROM issues
	WHERE tenant_id = $1 AND number = ANY($3::int[]) AND deleted_at IS NULL AND archived_at IS NULL
	ORDER BY 2`

// FleetLaneIssues reads the lanes view's issue links in one tenant read (on Postgres).
func (s *Postgres) FleetLaneIssues(ctx context.Context, tenant string, topics []string, numbers []int) (map[string][]int, map[int]string, error) {
	byTopic, status := map[string][]int{}, map[int]string{}
	ids := []string{}
	for _, t := range topics {
		if canonUUIDRe.MatchString(t) { // the column is uuid: a cast of anything else throws 22P02
			ids = append(ids, t)
		}
	}
	if numbers == nil {
		numbers = []int{}
	}
	err := s.queryTenant(ctx, tenant, fleetLaneIssuesSQL, []any{tenant, ids, numbers}, func(r pgx.Rows) error {
		var task, st string
		var n int
		if err := r.Scan(&task, &n, &st); err != nil {
			return err
		}
		status[n] = st
		if task != "" && !slices.Contains(byTopic[task], n) {
			byTopic[task] = append(byTopic[task], n)
		}
		return nil
	})
	return byTopic, status, err
}
