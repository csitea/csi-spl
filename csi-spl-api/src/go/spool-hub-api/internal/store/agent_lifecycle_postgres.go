package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0105. Every statement runs in the tenant scope except
// the retention prune, which is the operator's (every tenant at once). The
// column names come from LifecycleKeys, constants, never from a request.

func lifecycleCols() string {
	cols := make([]string, len(LifecycleKeys))
	for i, k := range LifecycleKeys {
		cols[i] = k.Key
	}
	return strings.Join(cols, ", ")
}

// readLifecycleConfig reads the row (optionally FOR UPDATE); no row = defaults.
func readLifecycleConfig(ctx context.Context, tx pgx.Tx, tenant, suffix string) (LifecycleConfig, error) {
	nums := make([]*int32, len(LifecycleKeys))
	enums := make([]*string, len(LifecycleKeys))
	dst := make([]any, 0, len(LifecycleKeys)+2)
	for i, k := range LifecycleKeys {
		if k.Enum != nil {
			dst = append(dst, &enums[i])
		} else {
			dst = append(dst, &nums[i])
		}
	}
	var c LifecycleConfig
	dst = append(dst, &c.UpdatedBy, &c.UpdatedAt)
	err := tx.QueryRow(ctx, `SELECT `+lifecycleCols()+`, updated_by, updated_at
		FROM agent_lifecycle_config WHERE tenant_id = $1`+suffix, tenant).Scan(dst...)
	c.Stored = map[string]any{}
	if errors.Is(err, pgx.ErrNoRows) {
		return LifecycleConfig{Stored: map[string]any{}}, nil
	}
	if err != nil {
		return LifecycleConfig{}, err
	}
	for i, k := range LifecycleKeys {
		switch {
		case nums[i] != nil:
			c.Stored[k.Key] = int(*nums[i])
		case enums[i] != nil:
			c.Stored[k.Key] = *enums[i]
		}
	}
	c.UpdatedAt = c.UpdatedAt.UTC()
	return c, nil
}

func (s *Postgres) AgentLifecycleConfig(ctx context.Context, tenant string) (LifecycleConfig, error) {
	var c LifecycleConfig
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		c, err = readLifecycleConfig(ctx, tx, tenant, "")
		return err
	})
	return c, err
}

func (s *Postgres) PatchAgentLifecycleConfig(ctx context.Context, tenant string, p LifecyclePatch, by string, now time.Time) (LifecycleConfig, LifecycleConfig, error) {
	if k, why := CheckLifecyclePatch(p); k != "" {
		return LifecycleConfig{}, LifecycleConfig{}, fmt.Errorf("%w: %s %s", ErrBadLifecycleKey, k, why)
	}
	now = now.UTC().Truncate(time.Microsecond)
	var old, cur LifecycleConfig
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO agent_lifecycle_config (tenant_id, updated_at)
			VALUES ($1, $2) ON CONFLICT (tenant_id) DO NOTHING`, tenant, now); err != nil {
			return err
		}
		var err error
		if old, err = readLifecycleConfig(ctx, tx, tenant, " FOR UPDATE"); err != nil {
			return err
		}
		sets := []string{"updated_by = $2", "updated_at = $3"}
		args := []any{tenant, by, now}
		for _, k := range LifecycleKeys { // fixed order, so the statement is stable
			v, named := p[k.Key]
			if !named {
				continue
			}
			args = append(args, v)
			sets = append(sets, fmt.Sprintf("%s = $%d", k.Key, len(args)))
		}
		if _, err := tx.Exec(ctx, `UPDATE agent_lifecycle_config SET `+strings.Join(sets, ", ")+
			` WHERE tenant_id = $1`, args...); err != nil {
			return err
		}
		if cur, err = readLifecycleConfig(ctx, tx, tenant, ""); err != nil {
			return err
		}
		return insertLifecycleEvent(ctx, tx, tenant, configChange(p, old, cur, by, now))
	})
	return old, cur, err
}

const lifecycleEventCols = `at, fleet, agent_id, agent_box, writer_box, role, event, reason, rid,
	ctx_before_k, ctx_after_k, age_s, turns, tokens_read_m, handoff_lines, handoff_bytes, notes_lines,
	refetch, config, outcome, detail`

// insertLifecycleEvent is the one single-row INSERT of spec 063 12.1.
func insertLifecycleEvent(ctx context.Context, tx pgx.Tx, tenant string, e LifecycleEvent) error {
	var refetch, cfg any
	if e.Refetch != nil {
		raw, err := json.Marshal(e.Refetch)
		if err != nil {
			return err
		}
		refetch = string(raw)
	}
	if len(e.Config) > 0 {
		cfg = string(e.Config)
	}
	_, err := tx.Exec(ctx, `INSERT INTO agent_lifecycle_events (tenant_id, `+lifecycleEventCols+`)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19::jsonb, $20::jsonb, $21, $22)`,
		tenant, e.At.UTC(), e.Fleet, e.AgentID, e.AgentBox, e.WriterBox, e.Role, e.Event, e.Reason, e.RID,
		e.CtxBeforeK, e.CtxAfterK, e.AgeS, e.Turns, e.TokensReadM, e.HandoffLn, e.HandoffB, e.NotesLines,
		refetch, cfg, e.Outcome, e.Detail)
	return err
}

func (s *Postgres) AppendLifecycleEvent(ctx context.Context, tenant string, e LifecycleEvent) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return insertLifecycleEvent(ctx, tx, tenant, e)
	})
}

func (s *Postgres) ListLifecycleEvents(ctx context.Context, tenant string, since time.Time, limit int) ([]LifecycleEvent, error) {
	out := []LifecycleEvent{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT `+lifecycleEventCols+` FROM agent_lifecycle_events
			WHERE tenant_id = $1 AND at >= $2 ORDER BY at DESC LIMIT $3`, tenant, since, ClampLifecycleLimit(limit))
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var e LifecycleEvent
			var refetch, cfg []byte
			if err := rows.Scan(&e.At, &e.Fleet, &e.AgentID, &e.AgentBox, &e.WriterBox, &e.Role, &e.Event, &e.Reason, &e.RID,
				&e.CtxBeforeK, &e.CtxAfterK, &e.AgeS, &e.Turns, &e.TokensReadM, &e.HandoffLn, &e.HandoffB, &e.NotesLines,
				&refetch, &cfg, &e.Outcome, &e.Detail); err != nil {
				return err
			}
			if refetch != nil {
				if err := json.Unmarshal(refetch, &e.Refetch); err != nil {
					return err
				}
			}
			if cfg != nil {
				e.Config = json.RawMessage(cfg)
			}
			e.At = e.At.UTC()
			out = append(out, e)
		}
		return rows.Err()
	})
	return out, err
}

// LifecycleAggregates computes on read, in one statement (spec 063 12.1: only
// the admin view pays for it). percentile_cont is aggregateLifecycle's
// interpolation; a refetch is the sum of its counts ('{}' = 0, NULL = no
// sample).
func (s *Postgres) LifecycleAggregates(ctx context.Context, tenant string, since time.Time) ([]LifecycleAggregate, error) {
	out := []LifecycleAggregate{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT role, event, count(*)::int,
				percentile_cont(0.5) WITHIN GROUP (ORDER BY ctx_before_k),
				percentile_cont(0.9) WITHIN GROUP (ORDER BY ctx_before_k),
				percentile_cont(0.5) WITHIN GROUP (ORDER BY ctx_after_k),
				percentile_cont(0.9) WITHIN GROUP (ORDER BY ctx_after_k),
				count(*) FILTER (WHERE outcome = 'fail')::int,
				avg(CASE WHEN refetch IS NULL THEN NULL ELSE
					(SELECT coalesce(sum(value::numeric), 0) FROM jsonb_each_text(refetch)) END)::float8
			FROM agent_lifecycle_events
			WHERE tenant_id = $1 AND at >= $2
			GROUP BY role, event ORDER BY role COLLATE "C", event COLLATE "C"`, tenant, since)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var a LifecycleAggregate
			if err := rows.Scan(&a.Role, &a.Event, &a.Count, &a.CtxBeforeMedian, &a.CtxBeforeP90,
				&a.CtxAfterMedian, &a.CtxAfterP90, &a.Failed, &a.RefetchMean); err != nil {
				return err
			}
			out = append(out, a)
		}
		return rows.Err()
	})
	return out, err
}

func (s *Postgres) PruneLifecycleEvents(ctx context.Context, before time.Time) (int, error) {
	n := 0
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM agent_lifecycle_events WHERE at < $1`, before)
		if err != nil {
			return err
		}
		n = int(tag.RowsAffected())
		return nil
	})
	return n, err
}
