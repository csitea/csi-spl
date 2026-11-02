package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// SPL-4666 rdb 0252 (spec 170 row B0): both columns are on humans, nullable
// and of the spec's types, a new human reads NULL in both, the off switch
// takes only 'on', 'off' or NULL, and the file applies twice. Raw SQL on
// purpose: no store code reads these columns before row B5.
func TestDayTasksReminderMigration(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0252_humans_day_tasks_reminder.sql"))
	if err != nil {
		t.Fatal(err)
	}
	hum, err := pg.Admit(ctx, Identity{Provider: "google", Subject: uid("dtr-")}, "", AdmitPolicy{}, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	err = pgx.BeginFunc(ctx, pg.Pool(), func(tx pgx.Tx) error {
		for i := 0; i < 2; i++ {
			if _, err := tx.Exec(ctx, string(raw)); err != nil {
				return fmt.Errorf("apply %d: %w", i+1, err)
			}
		}
		for col, want := range map[string]string{"day_tasks_seen_on": "date", "day_tasks_reminder": "text"} {
			var typ, nullable string
			if err := tx.QueryRow(ctx, `SELECT data_type, is_nullable FROM information_schema.columns
				WHERE table_schema = current_schema() AND table_name = 'humans' AND column_name = $1`, col).Scan(&typ, &nullable); err != nil {
				return fmt.Errorf("%s: %w", col, err)
			}
			if typ != want || nullable != "YES" {
				t.Errorf("humans.%s: %s nullable=%s, want %s nullable=YES", col, typ, nullable, want)
			}
		}
		var seenNull, reminderNull bool
		if err := tx.QueryRow(ctx, `SELECT day_tasks_seen_on IS NULL, day_tasks_reminder IS NULL
			FROM humans WHERE human_id = $1`, hum).Scan(&seenNull, &reminderNull); err != nil {
			return err
		}
		if !seenNull || !reminderNull {
			t.Errorf("new human: seen NULL=%v, reminder NULL=%v, want both NULL", seenNull, reminderNull)
		}
		for _, v := range []any{"on", "off", nil} {
			if _, err := tx.Exec(ctx, `UPDATE humans SET day_tasks_reminder = $2 WHERE human_id = $1`, hum, v); err != nil {
				return fmt.Errorf("day_tasks_reminder %v: %w", v, err)
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE humans SET day_tasks_seen_on = '2026-11-02' WHERE human_id = $1`, hum); err != nil {
			return err
		}
		var seen string
		if err := tx.QueryRow(ctx, `SELECT day_tasks_seen_on::text FROM humans WHERE human_id = $1`, hum).Scan(&seen); err != nil {
			return err
		}
		if seen != "2026-11-02" {
			t.Errorf("day_tasks_seen_on: %q, want 2026-11-02", seen)
		}
		// The refused value is last: a check violation aborts the transaction.
		_, err := tx.Exec(ctx, `UPDATE humans SET day_tasks_reminder = 'maybe' WHERE human_id = $1`, hum)
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) || pgErr.Code != "23514" || pgErr.ConstraintName != "humans_day_tasks_reminder_check" {
			t.Errorf("day_tasks_reminder 'maybe': %v, want a violation of humans_day_tasks_reminder_check", err)
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) {
		t.Fatal(err)
	}
}
