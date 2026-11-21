package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
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

// costLabelsAll is a label in every locale but the master's, "<word> <loc>".
func costLabelsAll(word string) map[string]string {
	out := map[string]string{}
	for _, loc := range costLabelOthers(MemCostLabelMaster) {
		out[loc] = word + " " + loc
	}
	return out
}

// costLabelEntry stores a cloud entry with text and answers it.
func costLabelEntry(t *testing.T, ce CostEntryStore, text string) CostEntry {
	t.Helper()
	e, err := ce.CreateCostEntry(context.Background(), CostEntry{Type: "cloud", Label: text, Amount: 5, Currency: "EUR", Period: "2026-11", CreatedBy: "op"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ce.DeleteCostEntry(context.Background(), e.ID) })
	return e
}

// SPL-6141, spec 123 16.6.4 row L2: the machine write never touches a hand
// row (RED CONTROL: drop "WHERE cost_entry_labels.origin = 'machine'" from
// pgCostLabelMachineEntry and the postgres run fails here), writes the
// others as machine, marks a reviewed one, and refuses a bad key.
func TestCostLabelsMachineWriteLeavesHandRow(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cl, ce := st.(CostLabelStore), st.(CostEntryStore)
			text := "Hosting " + uid("")[:8]
			e := costLabelEntry(t, ce, text)
			if err := cl.SetCostEntryLabels(ctx, e.ID, map[string]string{"bg": "Хостинг ръчно"}, "acc"); err != nil {
				t.Fatal(err)
			}
			n, err := cl.SetMachineCostLabels(ctx, CostLabelKey{Text: text}, map[string]string{"bg": "Хостинг машина", "fi": "Ylläpito"}, false, "hub")
			if err != nil || n != 1 {
				t.Fatalf("machine write: %d %v, want 1 row (fi; bg is a person's)", n, err)
			}
			all, _ := cl.CostEntryLabels(ctx)
			marks, _ := cl.CostEntryLabelMarks(ctx)
			if all[e.ID]["bg"] != "Хостинг ръчно" || marks[e.ID]["bg"].Origin != CostLabelHand {
				t.Errorf("the hand row: %q %+v, want the person's text, hand", all[e.ID]["bg"], marks[e.ID]["bg"])
			}
			if all[e.ID]["fi"] != "Ylläpito" || marks[e.ID]["fi"] != (CostLabelMark{Origin: CostLabelMachine}) {
				t.Errorf("the machine row: %q %+v, want Ylläpito, machine, not stale", all[e.ID]["fi"], marks[e.ID]["fi"])
			}
			if marks[e.ID][MemCostLabelMaster] != (CostLabelMark{Origin: CostLabelHand}) {
				t.Errorf("the master row: %+v, want hand", marks[e.ID][MemCostLabelMaster])
			}
			if n, err := cl.SetMachineCostLabels(ctx, CostLabelKey{Text: text}, map[string]string{"fi": "Palvelin"}, true, "agy"); err != nil || n != 1 {
				t.Fatalf("review write: %d %v", n, err)
			}
			if marks, _ = cl.CostEntryLabelMarks(ctx); marks[e.ID]["fi"].Origin != CostLabelReviewed {
				t.Errorf("a reviewed machine row: %+v, want reviewed", marks[e.ID]["fi"])
			}
			for why, key := range map[string]CostLabelKey{"no key": {}, "both keys": {Text: text, Component: DefaultHRComponents[0].Component}} {
				if _, err := cl.SetMachineCostLabels(ctx, key, map[string]string{"fi": "x"}, false, "hub"); err == nil || errors.Is(err, ErrNotFound) {
					t.Errorf("%s: %v, want a check error", why, err)
				}
			}
			if _, err := cl.SetMachineCostLabels(ctx, CostLabelKey{Text: text}, map[string]string{MemCostLabelMaster: text}, false, "hub"); err == nil {
				t.Error("a master-locale machine label is written")
			}
			if _, err := cl.SetMachineCostLabels(ctx, CostLabelKey{Text: "No such " + uid("")[:8]}, map[string]string{"fi": "x"}, false, "hub"); !errors.Is(err, ErrNotFound) {
				t.Errorf("an unknown text: %v, want ErrNotFound", err)
			}
		})
	}
}

// SPL-6141, spec 123 16.6.4 row L2: a person's PATCH of one entry keeps a
// machine row sent unchanged machine, makes a changed one hand, drops one
// left out, and writes the same rows on every entry with the same text and
// on no other (owner answer 5 "T").
func TestCostLabelsPatchPerRowEveryEntryOfText(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cl, ce := st.(CostLabelStore), st.(CostEntryStore)
			text, other := "Storage "+uid("")[:8], "Network "+uid("")[:8]
			a, b, c := costLabelEntry(t, ce, text), costLabelEntry(t, ce, text), costLabelEntry(t, ce, other)
			for _, k := range []string{text, other} {
				if _, err := cl.SetMachineCostLabels(ctx, CostLabelKey{Text: k}, map[string]string{"bg": "Съхранение", "fi": "Tallennus", "sv": "Lagring"}, false, "hub"); err != nil {
					t.Fatal(err)
				}
			}
			if err := cl.SetCostEntryLabels(ctx, b.ID, map[string]string{"bg": "Съхранение", "fi": "Tallennustila", MemCostLabelMaster: text}, "acc"); err != nil {
				t.Fatal(err)
			}
			all, _ := cl.CostEntryLabels(ctx)
			marks, _ := cl.CostEntryLabelMarks(ctx)
			for _, e := range []CostEntry{a, b} {
				want := map[string]string{"bg": "Съхранение", "fi": "Tallennustila", MemCostLabelMaster: text}
				if fmt.Sprint(all[e.ID]) != fmt.Sprint(want) {
					t.Errorf("entry %s labels %v, want %v (sv left out is dropped)", e.ID, all[e.ID], want)
				}
				if marks[e.ID]["bg"].Origin != CostLabelMachine || marks[e.ID]["fi"].Origin != CostLabelHand {
					t.Errorf("entry %s marks %+v, want bg machine (sent unchanged), fi hand", e.ID, marks[e.ID])
				}
			}
			if len(all[c.ID]) != 4 || marks[c.ID]["fi"].Origin != CostLabelMachine || all[c.ID]["fi"] != "Tallennus" {
				t.Errorf("another text's entry: %v %+v, want its 3 machine rows and its master row untouched", all[c.ID], marks[c.ID])
			}
		})
	}
}

// SPL-6141, spec 123 16.6.2 point 1 row L2: a POST of a known text lands
// with its 19 rows, each origin kept; a new text has its master row only.
func TestCostLabelsPostOfKnownTextCopiesRows(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cl, ce := st.(CostLabelStore), st.(CostEntryStore)
			text := "Backup " + uid("")[:8]
			a := costLabelEntry(t, ce, text)
			if _, err := cl.SetMachineCostLabels(ctx, CostLabelKey{Text: text}, costLabelsAll("Backup"), false, "hub"); err != nil {
				t.Fatal(err)
			}
			hand := costLabelsAll("Backup")
			hand["fi"], hand[MemCostLabelMaster] = "Varmuuskopio", text
			if err := cl.SetCostEntryLabels(ctx, a.ID, hand, "acc"); err != nil {
				t.Fatal(err)
			}
			b := costLabelEntry(t, ce, text)
			all, _ := cl.CostEntryLabels(ctx)
			marks, _ := cl.CostEntryLabelMarks(ctx)
			if len(all[b.ID]) != len(i18n.Supported) || fmt.Sprint(all[b.ID]) != fmt.Sprint(all[a.ID]) {
				t.Fatalf("the new entry of a known text: %d rows %v, want the %d of %v", len(all[b.ID]), all[b.ID], len(i18n.Supported), all[a.ID])
			}
			if marks[b.ID]["fi"].Origin != CostLabelHand || marks[b.ID]["bg"].Origin != CostLabelMachine {
				t.Errorf("copied marks %+v, want fi hand, bg machine", marks[b.ID])
			}
			fresh := costLabelEntry(t, ce, "Fresh "+uid("")[:8])
			if all, _ = cl.CostEntryLabels(ctx); len(all[fresh.ID]) != 1 {
				t.Errorf("a new text's entry: %v, want its master row only", all[fresh.ID])
			}
		})
	}
}

// costLabelWorkOf is the work of key in works, false when none.
func costLabelWorkOf(works []CostLabelWork, key CostLabelKey) (CostLabelWork, bool) {
	for _, w := range works {
		if w.Key == key {
			return w, true
		}
	}
	return CostLabelWork{}, false
}

// SPL-6141, spec 123 16.6.2 points 3 and 6 row L2: a new text is missing in
// every other locale until the machine rows exist; then it is unreviewed
// until agy's write marks them reviewed. A component the same.
func TestCostLabelsMissingAndUnreviewed(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cl, ce := st.(CostLabelStore), st.(CostEntryStore)
			text := "Licence " + uid("")[:8]
			costLabelEntry(t, ce, text)
			key, others := CostLabelKey{Text: text}, costLabelOthers(MemCostLabelMaster)
			miss, err := cl.MissingCostLabels(ctx)
			if w, ok := costLabelWorkOf(miss, key); err != nil || !ok || w.Source != text || fmt.Sprint(w.Locales) != fmt.Sprint(others) {
				t.Fatalf("a new text's missing work: %+v %v %v, want all %d other locales", w, ok, err, len(others))
			}
			if _, err := cl.SetMachineCostLabels(ctx, key, costLabelsAll("Licence"), false, "hub"); err != nil {
				t.Fatal(err)
			}
			miss, _ = cl.MissingCostLabels(ctx)
			unrev, _ := cl.UnreviewedCostLabels(ctx)
			if _, ok := costLabelWorkOf(miss, key); ok {
				t.Error("a text with its 18 machine rows is still missing")
			}
			if w, ok := costLabelWorkOf(unrev, key); !ok || fmt.Sprint(w.Drafts) != fmt.Sprint(costLabelsAll("Licence")) {
				t.Errorf("unreviewed: %+v %v, want the 18 drafts", w, ok)
			}
			if _, err := cl.SetMachineCostLabels(ctx, key, costLabelsAll("Licence"), true, "agy"); err != nil {
				t.Fatal(err)
			}
			if unrev, _ = cl.UnreviewedCostLabels(ctx); func() bool { _, ok := costLabelWorkOf(unrev, key); return ok }() {
				t.Error("a reviewed text is still unreviewed")
			}
			comp := DefaultHRComponents[len(DefaultHRComponents)-1]
			ck := CostLabelKey{Component: comp.Component}
			if n, err := cl.SetMachineCostLabels(ctx, ck, map[string]string{"sv": "Komponent"}, false, "hub"); err != nil || n != 1 {
				t.Fatalf("a component's machine write: %d %v", n, err)
			}
			costLabelCompCleanup(t, st, comp.Component, "sv")
			unrev, _ = cl.UnreviewedCostLabels(ctx)
			miss, _ = cl.MissingCostLabels(ctx)
			if w, ok := costLabelWorkOf(unrev, ck); !ok || w.Drafts["sv"] != "Komponent" || w.Source != comp.Label {
				t.Errorf("the component's unreviewed work: %+v %v", w, ok)
			}
			if w, ok := costLabelWorkOf(miss, ck); !ok || slices.Contains(w.Locales, "sv") {
				t.Errorf("the component's missing work: %+v %v, want every other locale but sv", w, ok)
			}
			if in, _ := cl.HRComponentLabelsIn(ctx, "sv"); in[comp.Component] != "Komponent" {
				t.Errorf("the component in sv reads %q", in[comp.Component])
			}
		})
	}
}

// costLabelCompCleanup removes component's label in locale on Postgres after
// the test: the components are shared by every test of the package.
func costLabelCompCleanup(t *testing.T, st Store, component, locale string) {
	pg, ok := st.(*Postgres)
	if !ok {
		return
	}
	t.Cleanup(func() {
		_ = pg.asOperator(context.Background(), func(tx pgx.Tx) error {
			_, err := tx.Exec(context.Background(), `DELETE FROM hr_cost_component_labels WHERE component = $1 AND locale = $2`, component, locale)
			return err
		})
	})
}

// SPL-6141, spec 123 16.6.2 point 5: a machine row made from another text
// is stale: missing again and marked; a stale hand row is marked, not missing.
func TestCostLabelsStaleRowsPostgres(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	text := "Domain " + uid("")[:8]
	e := costLabelEntry(t, pg, text)
	if _, err := pg.SetMachineCostLabels(ctx, CostLabelKey{Text: text}, costLabelsAll("Domain"), false, "hub"); err != nil {
		t.Fatal(err)
	}
	edit := costLabelsAll("Domain")
	edit["bg"] = "Домейн"
	if err := pg.SetCostEntryLabels(ctx, e.ID, edit, "acc"); err != nil {
		t.Fatal(err)
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE cost_entry_labels SET source_text = 'an older text' WHERE entry_id = $1::uuid AND locale IN ('bg', 'fi')`, e.ID)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	marks, _ := pg.CostEntryLabelMarks(ctx)
	if !marks[e.ID]["bg"].Stale || !marks[e.ID]["fi"].Stale || marks[e.ID]["bg"].Origin != CostLabelHand {
		t.Errorf("marks %+v, want bg hand stale, fi machine stale", marks[e.ID])
	}
	miss, _ := pg.MissingCostLabels(ctx)
	if w, ok := costLabelWorkOf(miss, CostLabelKey{Text: text}); !ok || fmt.Sprint(w.Locales) != "[fi]" {
		t.Errorf("missing %+v %v, want [fi] (a stale hand row is never re-made)", w, ok)
	}
}
