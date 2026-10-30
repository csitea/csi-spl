package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// The idle topic heads of a workspace (spec 166 section 3.2, build row B5,
// SPL-4323): the hub's read-only half of the zombie sweep. Conditions 1, 2
// and 6 of 3.2 are this query; 3-5 (asks, lanes, issues) are the box sweep's
// (row B6). It reads topic_heads (rdb 0144) and topic_priorities (rdb 0214)
// and writes nothing.

// ZombieTopic is one idle topic head: its task id and its latest line's time.
type ZombieTopic struct {
	TaskID string    `json:"task_id"`
	LastAt time.Time `json:"last_at"`
}

// ZombieTopicLister is implemented by Postgres only: the heads exist there.
type ZombieTopicLister interface {
	// ZombieTopics answers at most limit topics of tenant, oldest last_at
	// first, whose head is not card-archived, whose latest line is before
	// idleBefore, that are no DM thread (dm_last_at IS NULL) and that have no
	// topic_priorities row.
	ZombieTopics(ctx context.Context, tenant string, idleBefore time.Time, limit int) ([]ZombieTopic, error)
}

var _ ZombieTopicLister = (*Postgres)(nil)

// zombieTopicsSQL walks topic_heads_last (tenant_id, last_at DESC) from the
// old end: conditions 1, 2 and 6 of spec 166 3.2.
const zombieTopicsSQL = `SELECT h.task_id::text, h.last_at FROM topic_heads h
	WHERE h.tenant_id = $1 AND h.last_at < $2 AND NOT h.card_archived AND h.dm_last_at IS NULL
	  AND NOT EXISTS (SELECT 1 FROM topic_priorities p WHERE p.tenant_id = h.tenant_id AND p.task_id = h.task_id)
	ORDER BY h.last_at, h.task_id
	LIMIT $3`

// ZombieTopics implements ZombieTopicLister, in the workspace's own scope.
func (s *Postgres) ZombieTopics(ctx context.Context, tenant string, idleBefore time.Time, limit int) ([]ZombieTopic, error) {
	out := []ZombieTopic{}
	err := s.queryTenant(ctx, tenant, zombieTopicsSQL, []any{tenant, idleBefore.UTC(), limit}, func(r pgx.Rows) error {
		var z ZombieTopic
		err := r.Scan(&z.TaskID, &z.LastAt)
		z.LastAt = z.LastAt.UTC()
		out = append(out, z)
		return err
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}
