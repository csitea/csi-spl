package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// human_events is hub-wide (rdb 0045): plain pool statements, no tenant scope.

const humanEventCols = `event_id, human_id, kind, error_id, occurred_at, received_at, source, method, origin, path, status, code, message, name, route`

func scanHumanEvent(row pgx.Row) (HumanEvent, error) {
	var e HumanEvent
	err := row.Scan(&e.ID, &e.HumanID, &e.Kind, &e.ErrorID, &e.OccurredAt, &e.ReceivedAt, &e.Source, &e.Method,
		&e.Origin, &e.Path, &e.Status, &e.Code, &e.Message, &e.Name, &e.Route)
	return e, err
}

func (s *Postgres) AddHumanEvents(ctx context.Context, humanID string, evs []HumanEvent, now time.Time) (int, error) {
	for _, e := range evs {
		if err := CheckHumanEvent(e); err != nil {
			return 0, err
		}
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	// Lock the human row: proves the human exists and serialises two batches
	// of one human, so the trim below sees every row it has to count.
	var hum string
	if err := tx.QueryRow(ctx, `SELECT human_id FROM humans WHERE human_id = $1 FOR UPDATE`, humanID).Scan(&hum); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, ErrNotFound
		}
		return 0, err
	}
	b := &pgx.Batch{}
	for _, e := range evs {
		b.Queue(`INSERT INTO human_events (human_id, kind, error_id, occurred_at, received_at, source, method, origin, path, status, code, message, name, route)
			VALUES ($1, 'error', $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)`,
			humanID, e.ErrorID, e.OccurredAt, now, e.Source, e.Method, e.Origin, e.Path, e.Status, e.Code, e.Message, e.Name, e.Route)
	}
	if err := tx.SendBatch(ctx, b).Close(); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM human_events WHERE human_id = $1 AND event_id < (
		SELECT event_id FROM human_events WHERE human_id = $1 ORDER BY event_id DESC OFFSET $2 LIMIT 1)`,
		humanID, HumanEventsKeep-1); err != nil {
		return 0, err
	}
	return len(evs), tx.Commit(ctx)
}

func (s *Postgres) HumanEventsPage(ctx context.Context, humanID string, before int64, limit int) ([]HumanEvent, error) {
	rows, err := s.pool.Query(ctx, `SELECT `+humanEventCols+` FROM human_events
		WHERE human_id = $1 AND ($2::bigint <= 0 OR event_id < $2) ORDER BY event_id DESC LIMIT $3`, humanID, before, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []HumanEvent{}
	for rows.Next() {
		e, err := scanHumanEvent(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func (s *Postgres) ClearHumanEvents(ctx context.Context, humanID string) (int, error) {
	tag, err := s.pool.Exec(ctx, `DELETE FROM human_events WHERE human_id = $1`, humanID)
	if err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}
