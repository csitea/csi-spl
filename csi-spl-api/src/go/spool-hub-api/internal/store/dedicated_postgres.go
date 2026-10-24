package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of dedicated.go (rdb 0219, spec 144 T002). Every statement
// runs in the tenant scope, so rdb 0219's tenant_scope policy holds it to
// the tenant's rows; no statement sets app.agent_id (the hub writes
// bindings, never the agent).

const dedicatedCols = `tenant_id, agent_id, box_id, scope_type, scope_id, bound_by, bound_at`

func scanDedicated(r pgx.Row, b *DedicatedBinding) error {
	if err := r.Scan(&b.TenantID, &b.AgentID, &b.BoxID, &b.ScopeType, &b.ScopeID, &b.BoundBy, &b.BoundAt); err != nil {
		return err
	}
	b.BoundAt = b.BoundAt.UTC()
	return nil
}

// GetDedicatedBinding implements DedicatedStore.
func (s *Postgres) GetDedicatedBinding(ctx context.Context, tenant, agent, box string) (DedicatedBinding, error) {
	var b DedicatedBinding
	err := s.tenantBatch(ctx, tenant, `SELECT `+dedicatedCols+` FROM dedicated_agents
		WHERE tenant_id = $1 AND agent_id = $2 AND box_id = $3`, []any{tenant, agent, box}, func(br pgx.BatchResults) error {
		return scanDedicated(br.QueryRow(), &b)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return DedicatedBinding{}, ErrNotFound
	}
	return b, err
}

// SetDedicatedBinding implements DedicatedStore: insert unless the agent has
// a row, then read the row back in the same transaction and compare scopes.
func (s *Postgres) SetDedicatedBinding(ctx context.Context, b DedicatedBinding) (DedicatedBinding, error) {
	if err := checkBinding(&b, s.now()); err != nil {
		return DedicatedBinding{}, err
	}
	var got DedicatedBinding
	err := s.inTenant(ctx, b.TenantID, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO dedicated_agents (`+dedicatedCols+`)
			VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT (tenant_id, agent_id, box_id) DO NOTHING`,
			b.TenantID, b.AgentID, b.BoxID, b.ScopeType, b.ScopeID, b.BoundBy, b.BoundAt); err != nil {
			return mapFK(err)
		}
		return scanDedicated(tx.QueryRow(ctx, `SELECT `+dedicatedCols+` FROM dedicated_agents
			WHERE tenant_id = $1 AND agent_id = $2 AND box_id = $3`, b.TenantID, b.AgentID, b.BoxID), &got)
	})
	if err != nil {
		return DedicatedBinding{}, err
	}
	if got.ScopeType != b.ScopeType || got.ScopeID != b.ScopeID {
		return got, ErrDedicatedRebind
	}
	return got, nil
}

// RemoveDedicatedBinding implements DedicatedStore.
func (s *Postgres) RemoveDedicatedBinding(ctx context.Context, tenant, agent, box string) error {
	tag, err := s.execTenant(ctx, tenant, `DELETE FROM dedicated_agents
		WHERE tenant_id = $1 AND agent_id = $2 AND box_id = $3`, tenant, agent, box)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ListDedicatedAgentsByScope implements DedicatedStore (idx_dedicated_agents_scope).
func (s *Postgres) ListDedicatedAgentsByScope(ctx context.Context, tenant, scopeType, scopeID string) ([]DedicatedBinding, error) {
	if err := checkScope(scopeType, scopeID); err != nil {
		return nil, err
	}
	out := []DedicatedBinding{}
	err := s.queryTenant(ctx, tenant, `SELECT `+dedicatedCols+` FROM dedicated_agents
		WHERE tenant_id = $1 AND scope_type = $2 AND scope_id = $3 ORDER BY agent_id, box_id`,
		[]any{tenant, scopeType, scopeID}, func(r pgx.Rows) error {
			var b DedicatedBinding
			if err := scanDedicated(r, &b); err != nil {
				return err
			}
			out = append(out, b)
			return nil
		})
	return out, err
}

// isPrivateTopicSQL: a message of the topic is flagged or lives in a private channel.
const isPrivateTopicSQL = `SELECT EXISTS (SELECT 1 FROM messages m
	WHERE m.tenant_id = $1 AND m.task_id = $2::uuid
	  AND (m.is_private_scope OR EXISTS (SELECT 1 FROM channels c
	       WHERE c.tenant_id = m.tenant_id AND c.channel_id = m.channel AND c.is_private_scope)))`

// IsPrivateScope implements DedicatedStore.
func (s *Postgres) IsPrivateScope(ctx context.Context, tenant, scopeType, scopeID string) (bool, error) {
	if err := checkScope(scopeType, scopeID); err != nil {
		return false, err
	}
	sql := `SELECT EXISTS (SELECT 1 FROM channels WHERE tenant_id = $1 AND channel_id = $2 AND is_private_scope)`
	if scopeType == ScopeTopic {
		sql = isPrivateTopicSQL
	}
	var ok bool
	err := s.queryRowTenant(ctx, tenant, sql, []any{tenant, scopeID}, &ok)
	return ok, err
}

// SetPrivateScope implements DedicatedStore.
func (s *Postgres) SetPrivateScope(ctx context.Context, tenant, scopeType, scopeID string, private bool, now time.Time) error {
	if err := checkScope(scopeType, scopeID); err != nil {
		return err
	}
	sql := `UPDATE channels SET is_private_scope = $3, private_scope_at = CASE WHEN $3 THEN $4::timestamptz END
		WHERE tenant_id = $1 AND channel_id = $2`
	args := []any{tenant, scopeID, private, now.UTC()}
	if scopeType == ScopeTopic {
		sql = `UPDATE messages SET is_private_scope = $3 WHERE tenant_id = $1 AND task_id = $2::uuid`
		args = args[:3]
	}
	tag, err := s.execTenant(ctx, tenant, sql, args...)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// boxTaskDedicatedSQL is BoxTaskEnvelopes' private-scope predicate on m
// ($1 tenant, $2 task, $3 box, $5 the reading agent, empty for none): rdb 0219's
// spool_agent_scope_ok. An agent bound on box $3 reads only its scope; any
// other reader reads no envelope that is flagged or in a private channel.
// The first EXISTS is uncorrelated: one probe of pk_dedicated_agents.
const boxTaskDedicatedSQL = `
		  AND CASE WHEN EXISTS (SELECT 1 FROM dedicated_agents d
		                        WHERE d.tenant_id = $1 AND d.agent_id = $5 AND d.box_id = $3)
		      THEN EXISTS (SELECT 1 FROM dedicated_agents d
		                   WHERE d.tenant_id = $1 AND d.agent_id = $5 AND d.box_id = $3
		                     AND ((d.scope_type = 'channel' AND d.scope_id = m.channel)
		                       OR (d.scope_type = 'topic' AND d.scope_id = m.task_id::text)))
		      ELSE NOT (m.is_private_scope OR EXISTS (SELECT 1 FROM channels c
		                WHERE c.tenant_id = m.tenant_id AND c.channel_id = m.channel AND c.is_private_scope))
		      END`
