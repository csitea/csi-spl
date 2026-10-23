package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of topic_priority.go (rdb 0214, spec 150 row B1). Every read
// and write runs in the workspace's own scope (rdb 0214's tenant_scope
// policy); the change_stamp trigger moves the tenant's stamp on a set.

// SetTopicPriority implements TopicPriorityStore: one upsert, its row back.
func (s *Postgres) SetTopicPriority(ctx context.Context, tenant, taskID string, prio int, by string, at time.Time) (TopicPriority, error) {
	key, err := checkTopicPriority(tenant, taskID, prio)
	if err != nil {
		return TopicPriority{}, err
	}
	p := TopicPriority{TenantID: tenant}
	err = s.queryRowTenant(ctx, tenant, `INSERT INTO topic_priorities (tenant_id, task_id, priority, set_by, set_at)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (tenant_id, task_id) DO UPDATE SET priority = EXCLUDED.priority,
			set_by = EXCLUDED.set_by, set_at = EXCLUDED.set_at
		RETURNING task_id::text, priority, set_by, set_at`,
		[]any{tenant, key, prio, by, at.UTC()}, &p.TaskID, &p.Priority, &p.SetBy, &p.SetAt)
	if err != nil {
		return TopicPriority{}, mapFK(err)
	}
	p.SetAt = p.SetAt.UTC()
	return p, nil
}

// TopicPriorities implements TopicPriorityStore: one probe of the primary
// key for the asked ids, none when no asked id is a uuid.
func (s *Postgres) TopicPriorities(ctx context.Context, tenant string, taskIDs []string) (map[string]int, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	out, keys := defaultTopicPriorities(taskIDs)
	if len(keys) == 0 {
		return out, nil
	}
	stored := map[string]int{}
	err := s.queryTenant(ctx, tenant, `SELECT task_id::text, priority FROM topic_priorities
		WHERE tenant_id = $1 AND task_id = ANY ($2::uuid[])`, []any{tenant, keys},
		func(r pgx.Rows) error {
			var k string
			var p int
			err := r.Scan(&k, &p)
			stored[k] = p
			return err
		})
	if err != nil {
		return nil, err
	}
	return foldTopicPriorities(out, stored), nil
}
