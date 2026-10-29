package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// workspace_events runs in the tenant's scope (inTenant, rdb 0240's RLS);
// system_events is hub-wide (rdb 0240, like human_events): plain pool
// statements, no tenant scope.

const logEventCols = `id, at, kind, level, actor, message, origin_kind, origin_ref`

func scanLogEvent(row pgx.Row) (LogEvent, error) {
	var e LogEvent
	err := row.Scan(&e.ID, &e.At, &e.Kind, &e.Level, &e.Actor, &e.Message, &e.OriginKind, &e.OriginRef)
	e.At = e.At.UTC()
	return e, err
}

func scanLogEvents(rows pgx.Rows, tenant string) ([]LogEvent, error) {
	defer rows.Close()
	out := []LogEvent{}
	for rows.Next() {
		e, err := scanLogEvent(rows)
		if err != nil {
			return nil, err
		}
		e.Tenant = tenant
		out = append(out, e)
	}
	return out, rows.Err()
}

// The statements of each log; $1 of a workspace statement is the tenant.
const (
	pgWorkspaceEventInsert = `INSERT INTO workspace_events (tenant_id, at, kind, level, actor, message, origin_kind, origin_ref)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING ` + logEventCols
	// Keep the newest $2 rows of $1: the id of the ($2+1)th newest is the cut.
	pgWorkspaceEventTrim = `DELETE FROM workspace_events WHERE tenant_id = $1 AND id <= (
		SELECT id FROM workspace_events WHERE tenant_id = $1 ORDER BY id DESC OFFSET $2 LIMIT 1)`
	pgSystemEventInsert = `INSERT INTO system_events (at, kind, level, actor, message, origin_kind, origin_ref)
		VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING ` + logEventCols
	pgSystemEventTrim = `DELETE FROM system_events WHERE id <= (
		SELECT id FROM system_events ORDER BY id DESC OFFSET $1 LIMIT 1)`
)

// addWorkspaceEventTx inserts e and trims tenant's log, in tx. The lock
// serialises two writers of one log, so the trim sees every row it has to
// count; it ends with tx.
func addWorkspaceEventTx(ctx context.Context, tx pgx.Tx, tenant string, e LogEvent, now time.Time) (LogEvent, error) {
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended('workspace_events|' || $1, 0))`, tenant); err != nil {
		return LogEvent{}, err
	}
	out, err := scanLogEvent(tx.QueryRow(ctx, pgWorkspaceEventInsert, tenant, now, e.Kind, e.Level, e.Actor, e.Message, e.OriginKind, e.OriginRef))
	if err != nil {
		return LogEvent{}, err
	}
	out.Tenant = tenant
	_, err = tx.Exec(ctx, pgWorkspaceEventTrim, tenant, WorkspaceEventsKeep)
	return out, err
}

// addSystemEventTx inserts e and trims the system log, in tx, under the
// same kind of lock as addWorkspaceEventTx.
func addSystemEventTx(ctx context.Context, tx pgx.Tx, e LogEvent, now time.Time) (LogEvent, error) {
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended('system_events', 0))`); err != nil {
		return LogEvent{}, err
	}
	out, err := scanLogEvent(tx.QueryRow(ctx, pgSystemEventInsert, now, e.Kind, e.Level, e.Actor, e.Message, e.OriginKind, e.OriginRef))
	if err != nil {
		return LogEvent{}, err
	}
	_, err = tx.Exec(ctx, pgSystemEventTrim, SystemEventsKeep)
	return out, err
}

// AddWorkspaceEvent is LogEvents.AddWorkspaceEvent.
func (s *Postgres) AddWorkspaceEvent(ctx context.Context, tenant string, e LogEvent, now time.Time) (LogEvent, error) {
	e, err := normLogEvent(e)
	if err != nil {
		return LogEvent{}, err
	}
	var out LogEvent
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		out, err = addWorkspaceEventTx(ctx, tx, tenant, e, now)
		return err
	})
	return out, mapFK(err) // no such workspace: the tenants FK, ErrNotFound
}

// WorkspaceEventsPage is LogEvents.WorkspaceEventsPage.
func (s *Postgres) WorkspaceEventsPage(ctx context.Context, tenant string, before int64, limit int) ([]LogEvent, error) {
	var out []LogEvent
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT `+logEventCols+` FROM workspace_events
			WHERE tenant_id = $1 AND ($2::bigint <= 0 OR id < $2) ORDER BY id DESC LIMIT $3`, tenant, before, limit)
		if err != nil {
			return err
		}
		out, err = scanLogEvents(rows, tenant)
		return err
	})
	return out, err
}

// DeleteWorkspaceEvents is LogEvents.DeleteWorkspaceEvents.
func (s *Postgres) DeleteWorkspaceEvents(ctx context.Context, tenant string, ids []int64, actor string, now time.Time) (int, error) {
	if err := checkLogEventIDs(ids); err != nil {
		return 0, err
	}
	if _, err := normLogEvent(logDeletedEvent(0, actor)); err != nil {
		return 0, err
	}
	var n int
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM workspace_events WHERE tenant_id = $1 AND id = ANY($2)`, tenant, ids)
		if err != nil {
			return err
		}
		if n = int(tag.RowsAffected()); n == 0 {
			return nil
		}
		_, err = addWorkspaceEventTx(ctx, tx, tenant, logDeletedEvent(n, actor), now)
		return err
	})
	return n, err
}

// AddSystemEvent is LogEvents.AddSystemEvent.
func (s *Postgres) AddSystemEvent(ctx context.Context, e LogEvent, now time.Time) (LogEvent, error) {
	e, err := normLogEvent(e)
	if err != nil {
		return LogEvent{}, err
	}
	var out LogEvent
	err = pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		out, err = addSystemEventTx(ctx, tx, e, now)
		return err
	})
	return out, err
}

// SystemEventsPage is LogEvents.SystemEventsPage.
func (s *Postgres) SystemEventsPage(ctx context.Context, before int64, limit int) ([]LogEvent, error) {
	rows, err := s.pool.Query(ctx, `SELECT `+logEventCols+` FROM system_events
		WHERE ($1::bigint <= 0 OR id < $1) ORDER BY id DESC LIMIT $2`, before, limit)
	if err != nil {
		return nil, err
	}
	return scanLogEvents(rows, "")
}

// DeleteSystemEvents is LogEvents.DeleteSystemEvents.
func (s *Postgres) DeleteSystemEvents(ctx context.Context, ids []int64, actor string, now time.Time) (int, error) {
	if err := checkLogEventIDs(ids); err != nil {
		return 0, err
	}
	if _, err := normLogEvent(logDeletedEvent(0, actor)); err != nil {
		return 0, err
	}
	var n int
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM system_events WHERE id = ANY($1)`, ids)
		if err != nil {
			return err
		}
		if n = int(tag.RowsAffected()); n == 0 {
			return nil
		}
		_, err = addSystemEventTx(ctx, tx, logDeletedEvent(n, actor), now)
		return err
	})
	return n, err
}
