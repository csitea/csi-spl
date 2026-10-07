package store

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0146. Every statement runs in the tenant scope; an add
// is one transaction: insert the new lesson, or lock the existing row and
// merge into it.

const lessonCols = `title_key, title, body, merges, writer_box, created_at, updated_at`

func scanLesson(row pgx.Row) (Lesson, error) {
	var l Lesson
	if err := row.Scan(&l.Key, &l.Title, &l.Body, &l.Merges, &l.WriterBox, &l.CreatedAt, &l.UpdatedAt); err != nil {
		return l, err
	}
	l.CreatedAt, l.UpdatedAt = l.CreatedAt.UTC(), l.UpdatedAt.UTC()
	return l, nil
}

func (s *Postgres) AddLesson(ctx context.Context, tenant, title, text, box string, now time.Time) (Lesson, bool, error) {
	var out Lesson
	merged := false
	key := LessonKey(title)
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		// A concurrent first add of the same key waits here for the other
		// transaction and then inserts nothing, so the row below is there.
		l, err := scanLesson(tx.QueryRow(ctx, `INSERT INTO shared_memory_lessons
			(tenant_id, title_key, title, body, writer_box, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, $6)
			ON CONFLICT (tenant_id, title_key) DO NOTHING
			RETURNING `+lessonCols, tenant, key, strings.TrimSpace(title), strings.TrimSpace(text), box, now))
		if err == nil {
			out = l
			return nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		merged = true
		if out, err = scanLesson(tx.QueryRow(ctx, `SELECT `+lessonCols+` FROM shared_memory_lessons
			WHERE tenant_id = $1 AND title_key = $2 FOR UPDATE`, tenant, key)); err != nil {
			return err
		}
		body, changed, err := mergeLessonBody(out.Body, text)
		if err != nil || !changed {
			return err
		}
		out, err = scanLesson(tx.QueryRow(ctx, `UPDATE shared_memory_lessons
			SET body = $3, merges = merges + 1, writer_box = $4, updated_at = $5
			WHERE tenant_id = $1 AND title_key = $2
			RETURNING `+lessonCols, tenant, key, body, box, now))
		return err
	})
	return out, merged, err
}

func (s *Postgres) GetLesson(ctx context.Context, tenant, title string) (Lesson, bool, error) {
	var out Lesson
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		out, err = scanLesson(tx.QueryRow(ctx, `SELECT `+lessonCols+` FROM shared_memory_lessons
			WHERE tenant_id = $1 AND title_key = $2`, tenant, LessonKey(title)))
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return Lesson{}, false, nil
	}
	return out, err == nil, err
}

func (s *Postgres) ListLessons(ctx context.Context, tenant string) ([]Lesson, error) {
	out := []Lesson{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT `+lessonCols+` FROM shared_memory_lessons
			WHERE tenant_id = $1 ORDER BY title_key COLLATE "C"`, tenant)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			l, err := scanLesson(rows)
			if err != nil {
				return err
			}
			out = append(out, l)
		}
		return rows.Err()
	})
	return out, err
}
