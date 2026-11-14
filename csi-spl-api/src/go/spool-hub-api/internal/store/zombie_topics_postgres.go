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

// ZombieTopic is one idle topic head: its task id, its latest line's time and
// msg_id. LastMsgID lets a box whose own tail misses that line (a post routed
// only to another box) see that it does (spec 041 section 7, SPL-5520 R7 W1).
type ZombieTopic struct {
	TaskID    string    `json:"task_id"`
	LastAt    time.Time `json:"last_at"`
	LastMsgID string    `json:"last_msg_id"`
}

// ZombieTopicLister is implemented by Postgres only: the heads exist there.
type ZombieTopicLister interface {
	// ZombieTopics answers at most limit topics of tenant, oldest last_at
	// first (newest first when newest is set), whose head is not
	// card-archived, whose latest line is before idleBefore, that are no DM
	// thread (dm_last_at IS NULL) and that have no topic_priorities row.
	// open keeps only the topics any agent may post in (zombieTopicsOpen).
	ZombieTopics(ctx context.Context, tenant string, idleBefore time.Time, limit int, newest, open bool) ([]ZombieTopic, error)
}

var _ ZombieTopicLister = (*Postgres)(nil)

// zombieTopicsWhere is conditions 1, 2 and 6 of spec 166 3.2.
const zombieTopicsWhere = `SELECT h.task_id::text, h.last_at, h.last_msg_id::text FROM topic_heads h
	WHERE h.tenant_id = $1 AND h.last_at < $2 AND NOT h.card_archived AND h.dm_last_at IS NULL
	  AND NOT EXISTS (SELECT 1 FROM topic_priorities p WHERE p.tenant_id = h.tenant_id AND p.task_id = h.task_id)`

// zombieTopicsOpen is scope=open (spec 041 section 7, SPL-5520 R7 W4): the
// archive suggestion polls only a topic any desk agent may post in. Out: a
// topic in no channel; one with a part in #lobby (a welcome topic: the desk
// answers it in a DM), in a member-only (is_private), humans-only, AI-off
// (its own switch, else the workspace default channel_ai_agents) or
// private-scope channel; one with a private-scope line (topic scope, rdb 0219).
const zombieTopicsOpen = `
	  AND EXISTS (SELECT 1 FROM topic_head_parts p WHERE p.tenant_id = h.tenant_id AND p.task_id = h.task_id AND p.channel IS NOT NULL)
	  AND NOT EXISTS (SELECT 1 FROM topic_head_parts p
	        LEFT JOIN channels c ON c.tenant_id = p.tenant_id AND c.channel_id = p.channel
	        WHERE p.tenant_id = h.tenant_id AND p.task_id = h.task_id AND p.channel IS NOT NULL
	          AND (p.channel = 'lobby' OR c.is_private OR c.humans_only_at IS NOT NULL OR c.is_private_scope
	            OR COALESCE(c.ai_agents, (SELECT tn.settings->'channel_ai_agents' <> 'false'::jsonb
	                 FROM tenants tn WHERE tn.tenant_id = h.tenant_id), true) IS FALSE))
	  AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.tenant_id = h.tenant_id AND m.task_id = h.task_id AND m.is_private_scope)`

// zombieTopicsSQL walks topic_heads_last (tenant_id, last_at DESC) from the
// old end; zombieTopicsNewestSQL from the young end (spec 041 section 7, the
// archive suggestion: a backlog over the limit hid the newest idle topics).
const (
	zombieTopicsOldest = "\n\tORDER BY h.last_at, h.task_id\n\tLIMIT $3"
	zombieTopicsNewest = "\n\tORDER BY h.last_at DESC, h.task_id DESC\n\tLIMIT $3"
)

// ZombieTopics implements ZombieTopicLister, in the workspace's own scope.
func (s *Postgres) ZombieTopics(ctx context.Context, tenant string, idleBefore time.Time, limit int, newest, open bool) ([]ZombieTopic, error) {
	out := []ZombieTopic{}
	q, order := zombieTopicsWhere, zombieTopicsOldest
	if open {
		q += zombieTopicsOpen
	}
	if newest {
		order = zombieTopicsNewest
	}
	q += order
	err := s.queryTenant(ctx, tenant, q, []any{tenant, idleBefore.UTC(), limit}, func(r pgx.Rows) error {
		var z ZombieTopic
		err := r.Scan(&z.TaskID, &z.LastAt, &z.LastMsgID)
		z.LastAt = z.LastAt.UTC()
		out = append(out, z)
		return err
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}
