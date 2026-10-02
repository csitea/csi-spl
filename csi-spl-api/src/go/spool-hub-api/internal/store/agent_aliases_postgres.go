package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0101's agent_id_aliases. Every statement runs in the
// tenant scope.

const aliasCols = `old_id, new_id, kind, box_id, mapped_at`

func scanAlias(row pgx.Row) (AgentAlias, error) {
	var a AgentAlias
	if err := row.Scan(&a.OldID, &a.NewID, &a.Kind, &a.BoxID, &a.MappedAt); err != nil {
		return a, err
	}
	a.MappedAt = a.MappedAt.UTC()
	return a, nil
}

func (s *Postgres) PutAgentAlias(ctx context.Context, tenant string, a AgentAlias, now time.Time) (AgentAlias, bool, error) {
	if err := CheckAgentAlias(a); err != nil {
		return AgentAlias{}, false, err
	}
	var (
		out     AgentAlias
		created bool
	)
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `INSERT INTO agent_id_aliases (tenant_id, `+aliasCols+`)
			VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (tenant_id, old_id, box_id) DO NOTHING`,
			tenant, a.OldID, a.NewID, a.Kind, a.BoxID, now)
		if err != nil {
			return err
		}
		created = tag.RowsAffected() == 1
		out, err = scanAlias(tx.QueryRow(ctx, `SELECT `+aliasCols+` FROM agent_id_aliases
			WHERE tenant_id = $1 AND old_id = $2 AND box_id = $3`, tenant, a.OldID, a.BoxID))
		return err
	})
	return out, created, err
}

func (s *Postgres) ListAgentAliases(ctx context.Context, tenant string) ([]AgentAlias, error) {
	out := []AgentAlias{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT `+aliasCols+` FROM agent_id_aliases WHERE tenant_id = $1`, tenant)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			a, err := scanAlias(rows)
			if err != nil {
				return err
			}
			out = append(out, a)
		}
		return rows.Err()
	})
	sortAliases(out)
	return out, err
}
