package store

import (
	"context"
	"errors"
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

// sysEventCols are logEventCols plus the error group columns of rdb 0298,
// which only system_events has.
const sysEventCols = logEventCols + `, fingerprint, first_at, n, issue_key, issue_n, human_id`

func scanSystemEvent(row pgx.Row) (LogEvent, error) {
	var e LogEvent
	var first *time.Time
	err := row.Scan(&e.ID, &e.At, &e.Kind, &e.Level, &e.Actor, &e.Message, &e.OriginKind, &e.OriginRef,
		&e.Fingerprint, &first, &e.N, &e.IssueKey, &e.IssueN, &e.HumanID)
	e.At = e.At.UTC()
	if first != nil {
		e.FirstAt = first.UTC()
	}
	return e, err
}

func scanLogEvents(rows pgx.Rows, tenant string) ([]LogEvent, error) {
	defer rows.Close()
	scan := scanLogEvent
	if tenant == "" {
		scan = scanSystemEvent
	}
	out := []LogEvent{}
	for rows.Next() {
		e, err := scan(rows)
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
		VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING ` + sysEventCols
	// The error group upsert of spec 162 10.5: id = DEFAULT gives a known
	// group a new id (PostgreSQL 16 takes it on a GENERATED ALWAYS identity,
	// C34); a sighting with no person keeps the last named one.
	pgSystemErrorGroupUpsert = `INSERT INTO system_events
		(at, kind, level, actor, message, origin_kind, origin_ref, fingerprint, first_at, n, human_id)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
		ON CONFLICT (fingerprint) WHERE fingerprint <> '' DO UPDATE SET
			id = DEFAULT,
			at = GREATEST(system_events.at, EXCLUDED.at),
			first_at = LEAST(system_events.first_at, EXCLUDED.first_at),
			n = system_events.n + EXCLUDED.n,
			message = EXCLUDED.message,
			human_id = CASE WHEN EXCLUDED.human_id <> '' THEN EXCLUDED.human_id ELSE system_events.human_id END
		RETURNING ` + sysEventCols
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
	out, err := scanSystemEvent(tx.QueryRow(ctx, pgSystemEventInsert, now, e.Kind, e.Level, e.Actor, e.Message, e.OriginKind, e.OriginRef))
	if err != nil {
		return LogEvent{}, err
	}
	_, err = tx.Exec(ctx, pgSystemEventTrim, SystemEventsKeep)
	return out, err
}

// upsertErrorGroupsTx upserts each group and then trims the system log
// once, in tx, under addSystemEventTx's lock. It answers the stored rows.
func upsertErrorGroupsTx(ctx context.Context, tx pgx.Tx, groups []LogEvent) ([]LogEvent, error) {
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended('system_events', 0))`); err != nil {
		return nil, err
	}
	out := make([]LogEvent, 0, len(groups))
	for _, e := range groups {
		row, err := scanSystemEvent(tx.QueryRow(ctx, pgSystemErrorGroupUpsert, e.At, e.Kind, e.Level, e.Actor, e.Message,
			e.OriginKind, e.OriginRef, e.Fingerprint, e.FirstAt, e.N, e.HumanID))
		if err != nil {
			return nil, err
		}
		out = append(out, row)
	}
	_, err := tx.Exec(ctx, pgSystemEventTrim, SystemEventsKeep)
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
	rows, err := s.pool.Query(ctx, `SELECT `+sysEventCols+` FROM system_events
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

// UpsertSystemErrorGroup is LogEvents.UpsertSystemErrorGroup.
func (s *Postgres) UpsertSystemErrorGroup(ctx context.Context, e LogEvent) (LogEvent, error) {
	e, err := normErrorGroup(e)
	if err != nil {
		return LogEvent{}, err
	}
	var out []LogEvent
	err = pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		out, err = upsertErrorGroupsTx(ctx, tx, []LogEvent{e})
		return err
	})
	if err != nil {
		return LogEvent{}, err
	}
	return out[0], nil
}

const pgEvlogCursorCols = `env, read_until, gen, by_actor`

func scanEvlogCursor(row pgx.Row) (EvlogCursor, error) {
	var c EvlogCursor
	err := row.Scan(&c.Env, &c.ReadUntil, &c.Gen, &c.ByActor)
	c.ReadUntil = c.ReadUntil.UTC()
	return c, err
}

// SystemEventsCursor is LogEvents.SystemEventsCursor.
func (s *Postgres) SystemEventsCursor(ctx context.Context, env string) (EvlogCursor, error) {
	c, err := scanEvlogCursor(s.pool.QueryRow(ctx, `SELECT `+pgEvlogCursorCols+` FROM system_events_cursor WHERE env = $1`, env))
	if errors.Is(err, pgx.ErrNoRows) {
		return EvlogCursor{Env: env}, nil
	}
	return c, err
}

// The cursor's compare-and-set (10.4.4). The first put of an env inserts
// the row (a concurrent first put conflicts and moves nothing); every later
// one moves it only from the gen and read_until it was read at. The row
// lock of either serialises two puts: the second re-checks its WHERE on
// the first's row and matches nothing.
const (
	pgEvlogCursorFirst = `INSERT INTO system_events_cursor (env, read_until, gen, by_actor) VALUES ($1, $2, 1, $3)
		ON CONFLICT (env) DO NOTHING RETURNING ` + pgEvlogCursorCols
	pgEvlogCursorMove = `UPDATE system_events_cursor SET read_until = $2, gen = gen + 1, by_actor = $3
		WHERE env = $1 AND gen = $4 AND read_until = $5 RETURNING ` + pgEvlogCursorCols
)

// PutSystemErrorGroups is LogEvents.PutSystemErrorGroups.
func (s *Postgres) PutSystemErrorGroups(ctx context.Context, p EvlogPut) (EvlogCursor, error) {
	groups, err := checkEvlogPut(p)
	if err != nil {
		return EvlogCursor{}, err
	}
	var cur EvlogCursor
	err = pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		var row pgx.Row
		if p.Gen == 0 {
			row = tx.QueryRow(ctx, pgEvlogCursorFirst, p.Env, p.To, p.Actor)
		} else {
			row = tx.QueryRow(ctx, pgEvlogCursorMove, p.Env, p.To, p.Actor, p.Gen, p.From)
		}
		if cur, err = scanEvlogCursor(row); errors.Is(err, pgx.ErrNoRows) {
			return ErrEvlogCursorMoved
		} else if err != nil {
			return err
		}
		_, err = upsertErrorGroupsTx(ctx, tx, groups)
		return err
	})
	if err != nil {
		return EvlogCursor{}, err
	}
	return cur, nil
}

// LinkSystemErrorGroup is LogEvents.LinkSystemErrorGroup.
func (s *Postgres) LinkSystemErrorGroup(ctx context.Context, fingerprint, issueKey string) (LogEvent, error) {
	if err := checkEvlogLink(fingerprint, issueKey); err != nil {
		return LogEvent{}, err
	}
	e, err := scanSystemEvent(s.pool.QueryRow(ctx, `UPDATE system_events SET issue_key = $2, issue_n = n
		WHERE fingerprint = $1 AND fingerprint <> '' RETURNING `+sysEventCols, fingerprint, issueKey))
	if errors.Is(err, pgx.ErrNoRows) {
		return LogEvent{}, ErrNotFound
	}
	return e, err
}
