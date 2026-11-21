package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// SPL-5546, rdb 0285: an entry's text is its master-locale label from the
// start; the other locales are set, replaced and read back; the master's is
// never edited; a reader gets its locale, else the master's text.
func TestCostEntryLabels(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cl, ce := st.(CostLabelStore), st.(CostEntryStore)
			master, err := cl.CostLabelMaster(ctx)
			if err != nil || master != MemCostLabelMaster {
				t.Fatalf("master: %q %v, want %q (rdb 0285 seed)", master, err, MemCostLabelMaster)
			}
			text := "Salary " + uid("")[:8]
			e, err := ce.CreateCostEntry(ctx, CostEntry{Type: "hr", Label: text, Amount: 10, Currency: "EUR", Period: "2026-10", CreatedBy: "op"})
			if err != nil {
				t.Fatal(err)
			}
			all, err := cl.CostEntryLabels(ctx)
			if err != nil || len(all[e.ID]) != 1 || all[e.ID][master] != text {
				t.Fatalf("a new entry's labels: %v %v, want only {%s: %s}", all[e.ID], err, master, text)
			}
			if err := cl.SetCostEntryLabels(ctx, e.ID, map[string]string{"bg": "Заплата", "fi": "Palkka", master: text}, "acc"); err != nil {
				t.Fatal(err)
			}
			if err := cl.SetCostEntryLabels(ctx, e.ID, map[string]string{"bg": "Брутна заплата"}, "acc"); err != nil {
				t.Fatal(err)
			}
			all, _ = cl.CostEntryLabels(ctx)
			if got := all[e.ID]; len(got) != 2 || got["bg"] != "Брутна заплата" || got[master] != text {
				t.Fatalf("replaced labels: %v, want bg + the master's only (fi dropped)", got)
			}
			for want, loc := range map[string]string{"Брутна заплата": "bg", text + "|fi": "fi", text + "|": ""} {
				in, err := cl.CostLabelsIn(ctx, loc)
				if err != nil {
					t.Fatal(err)
				}
				if got, ok := in[text]; (want == "Брутна заплата") != ok || (ok && got != want) {
					t.Errorf("CostLabelsIn(%q)[text] = %q %v; want %q (the master's text is no entry)", loc, got, ok, want)
				}
			}
			for why, bad := range map[string]map[string]string{
				"the master's text changed": {master: "Other"}, "an unknown locale": {"xx": "x"},
				"an empty label": {"bg": " "}, "a 101-character label": {"bg": string(make([]rune, 101))},
			} {
				if err := cl.SetCostEntryLabels(ctx, e.ID, bad, "acc"); err == nil || errors.Is(err, ErrNotFound) {
					t.Errorf("%s: %v, want a check error", why, err)
				}
			}
			if err := cl.SetCostEntryLabels(ctx, "00000000-0000-4000-8000-000000000000", map[string]string{"en": "x"}, "acc"); !errors.Is(err, ErrNotFound) {
				t.Errorf("no entry: %v, want ErrNotFound", err)
			}
			if err := ce.DeleteCostEntry(ctx, e.ID); err != nil {
				t.Fatal(err)
			}
			if all, _ = cl.CostEntryLabels(ctx); len(all[e.ID]) != 0 {
				t.Errorf("a deleted entry's labels stay: %v", all[e.ID])
			}
		})
	}
}

// SPL-5546: a component's label is the reader's locale's, else the seed's
// English (no master-locale row is seeded).
func TestHRComponentLabelsIn(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			in, err := st.(CostLabelStore).HRComponentLabelsIn(ctx, "fi")
			if err != nil {
				t.Fatal(err)
			}
			if len(in) != len(DefaultHRComponents) {
				t.Fatalf("%d components, want %d", len(in), len(DefaultHRComponents))
			}
			for _, c := range DefaultHRComponents {
				if in[c.Component] != c.Label {
					t.Errorf("%s: %q, want the seed's %q", c.Component, in[c.Component], c.Label)
				}
			}
		})
	}
}

// SPL-6133 rdb 0303 (spec 123 16.6.4, row L1): rows from before the file are
// played by dropping NOT NULL and nulling origin in one rolled-back
// transaction, then the file applies twice. An other-language row reads
// machine with the entry's text as its source, the master row hand with no
// source, reviewed_at NULL on both; a component's other-language row the
// same; a new master row (the POST, after the file) has source_text NULL and
// origin hand; an origin outside hand/machine fails the CHECK.
func TestCostLabelsOriginMigration(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0303_cost_labels_origin.sql"))
	if err != nil {
		t.Fatal(err)
	}
	master, err := pg.CostLabelMaster(ctx)
	if err != nil || master == "" {
		t.Fatalf("master: %q %v", master, err)
	}
	text := "Rent " + uid("")[:8]
	e, err := pg.CreateCostEntry(ctx, CostEntry{Type: "hr", Label: text, Amount: 10, Currency: "EUR", Period: "2026-10", CreatedBy: "op"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = pg.DeleteCostEntry(ctx, e.ID) })
	type row struct {
		origin       string
		source       *string
		reviewedNull bool
	}
	read := func(tx pgx.Tx, sql string, args ...any) row {
		t.Helper()
		var r row
		if err := tx.QueryRow(ctx, sql, args...).Scan(&r.origin, &r.source, &r.reviewedNull); err != nil {
			t.Fatalf("%s %v: %v", sql, args, err)
		}
		return r
	}
	const entrySQL = `SELECT origin, source_text, reviewed_at IS NULL FROM cost_entry_labels WHERE entry_id = $1::uuid AND locale = $2`
	const compSQL = `SELECT origin, source_text, reviewed_at IS NULL FROM hr_cost_component_labels WHERE component = $1 AND locale = $2`
	comp := DefaultHRComponents[0]
	err = pg.asOperator(ctx, func(tx pgx.Tx) error {
		if got := read(tx, entrySQL, e.ID, master); got.origin != "hand" || got.source != nil || !got.reviewedNull {
			t.Errorf("a new master row: origin %q source %v reviewed NULL %v, want hand, NULL, NULL", got.origin, got.source, got.reviewedNull)
		}
		for _, q := range []string{
			`ALTER TABLE cost_entry_labels ALTER COLUMN origin DROP NOT NULL, ALTER COLUMN origin DROP DEFAULT`,
			`ALTER TABLE hr_cost_component_labels ALTER COLUMN origin DROP NOT NULL, ALTER COLUMN origin DROP DEFAULT`,
		} {
			if _, err := tx.Exec(ctx, q); err != nil {
				return fmt.Errorf("%s: %w", q, err)
			}
		}
		for q, args := range map[string][]any{
			`INSERT INTO cost_entry_labels (entry_id, locale, label, updated_by) VALUES ($1::uuid, 'bg', 'Наем', 'acc')`: {e.ID},
			`INSERT INTO hr_cost_component_labels (component, locale, label) VALUES ($1, 'bg', 'Компонент')
				ON CONFLICT (component, locale) DO UPDATE SET label = excluded.label`: {comp.Component},
			`UPDATE cost_entry_labels SET origin = NULL, source_text = NULL WHERE entry_id = $1::uuid`:   {e.ID},
			`UPDATE hr_cost_component_labels SET origin = NULL, source_text = NULL WHERE component = $1`: {comp.Component},
		} {
			if _, err := tx.Exec(ctx, q, args...); err != nil {
				return fmt.Errorf("%s: %w", q, err)
			}
		}
		for i := 0; i < 2; i++ {
			if _, err := tx.Exec(ctx, string(raw)); err != nil {
				return fmt.Errorf("apply %d: %w", i+1, err)
			}
		}
		if got := read(tx, entrySQL, e.ID, "bg"); got.origin != "machine" || got.source == nil || *got.source != text || !got.reviewedNull {
			t.Errorf("an existing bg row: origin %q source %v reviewed NULL %v, want machine, %q, NULL", got.origin, got.source, got.reviewedNull, text)
		}
		if got := read(tx, entrySQL, e.ID, master); got.origin != "hand" || got.source != nil || !got.reviewedNull {
			t.Errorf("an existing master row: origin %q source %v, want hand, NULL", got.origin, got.source)
		}
		if got := read(tx, compSQL, comp.Component, "bg"); got.origin != "machine" || got.source == nil || *got.source != comp.Label || !got.reviewedNull {
			t.Errorf("an existing component bg row: origin %q source %v, want machine, %q", got.origin, got.source, comp.Label)
		}
		if got := read(tx, compSQL, comp.Component, master); got.origin != "hand" || got.source != nil {
			t.Errorf("an existing component master row: origin %q source %v, want hand, NULL", got.origin, got.source)
		}
		// The refused value is last: a check violation aborts the transaction.
		_, err := tx.Exec(ctx, `INSERT INTO cost_entry_labels (entry_id, locale, label, updated_by, origin)
			VALUES ($1::uuid, 'fi', 'Vuokra', 'acc', 'x')`, e.ID)
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) || pgErr.Code != "23514" || pgErr.ConstraintName != "cost_entry_labels_origin_check" {
			t.Errorf("origin 'x': %v, want a violation of cost_entry_labels_origin_check", err)
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) {
		t.Fatal(err)
	}
}
