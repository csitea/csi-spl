package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Spec 143 taxes-tab.md S1 (SPL-6438): the tax index store and rdb 0326's
// RLS. Postgres only (rlsStore skips without SPOOL_TEST_PG_DSN; hub-pg.tst.sh
// runs it under PRE_PUSH_TIER=full). Every value here is invented.

var taxTableList = []string{"tax_snapshots", "tax_documents"}

// taxSHA is an invented content hash.
func taxSHA(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

// taxSnap is one invented 2026 snapshot taken at now: a decision with a
// due date and a message without one; kind carries marker (cut to 80).
func taxSnap(now time.Time, marker string) TaxSnapshot {
	if len(marker) > TaxMaxText {
		marker = marker[:TaxMaxText]
	}
	day := time.Date(2026, 3, 2, 0, 0, 0, 0, time.UTC)
	return TaxSnapshot{SnapshotID: uuid4(), TaxYear: 2026, TakenAt: now.Truncate(time.Microsecond), FiledBy: "sa@example.com",
		Documents: []TaxDocument{
			{ArrivalDate: day, Kind: marker, DocType: "decision", TaxType: "vat", Period: "2026-01",
				DueDate: day.AddDate(0, 0, 12), Category: "decisions", ContentSHA256: taxSHA("a" + marker)},
			{ArrivalDate: day.AddDate(0, 0, 1), Kind: "letter", DocType: "msg", TaxType: "income", Period: "2026",
				Category: "msgs", ContentSHA256: taxSHA("b" + marker)},
		}}
}

// taxCounts counts each rdb 0326 table's rows under scope, in one
// transaction rolled back after setup ran in it.
func taxCounts(t *testing.T, pg *Postgres, setup, scope string, args ...any) map[string]int {
	t.Helper()
	ctx := context.Background()
	out := map[string]int{}
	tx, err := pg.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if setup != "" {
		if _, err := tx.Exec(ctx, setup); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := tx.Exec(ctx, scope, args...); err != nil {
		t.Fatal(err)
	}
	for _, tb := range taxTableList {
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM `+pgx.Identifier{tb}.Sanitize()).Scan(&n); err != nil {
			t.Fatal(err)
		}
		out[tb] = n
	}
	return out
}

// TestTaxStoreRead: a person seated in the workspace reads the newest
// snapshot and its documents; an agent seat, a time accountant, a channel
// guest, an act-as clone, a suspended seat, a person of another workspace,
// the tenant alone, the operator and no scope read 0 rows.
func TestTaxStoreRead(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	a, b := newTenant(t, pg), newTenant(t, pg)
	want, err := pg.TaxIngest(ctx, a, taxSnap(now, "kind-a"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pg.TaxIngest(ctx, b, taxSnap(now, "kind-b")); err != nil {
		t.Fatal(err)
	}
	person := seatMember(t, pg, a, "developer")
	got, years, err := pg.TaxLatest(ctx, a, person, 0, 2)
	if err != nil || len(got) != 1 || got[0].SnapshotID != want.SnapshotID || len(got[0].Documents) != 2 ||
		len(years) != 1 || years[0] != 2026 {
		t.Fatalf("person's latest = %+v %v %v, want %s with 2 documents", got, years, err, want.SnapshotID)
	}
	d := got[0].Documents
	if d[0].Kind != "kind-a" || !d[0].DueDate.Equal(time.Date(2026, 3, 14, 0, 0, 0, 0, time.UTC)) || !d[1].DueDate.IsZero() ||
		d[1].Category != "msgs" || d[1].ContentSHA256 != taxSHA("bkind-a") {
		t.Errorf("documents = %+v", d)
	}
	if n := taxCounts(t, pg, "", pgScopeTaxReader, a, person); n["tax_snapshots"] != 1 || n["tax_documents"] != 2 {
		t.Errorf("control: the person reads %v, want its workspace's 1 + 2 rows", n)
	}

	suspended := seatMember(t, pg, a, "developer")
	if err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE tenant_memberships SET disabled_at = now() WHERE tenant_id = $1 AND human_id = $2`, a, suspended)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	blind := map[string]string{
		"agent seat":                     seatMember(t, pg, a, "pure_agent"),
		"time accountant":                seatMember(t, pg, a, "time_accountant"),
		"channel guest":                  seatMember(t, pg, a, "channel_guest"),
		"technical human (act-as clone)": nvsSeatTechnical(t, pg, a, "developer"),
		"suspended seat":                 suspended,
		"person of another workspace":    seatMember(t, pg, b, "admin"),
		"human seated nowhere":           nvsOther,
	}
	for name, hum := range blind {
		if n := taxCounts(t, pg, "", pgScopeTaxReader, a, hum); n["tax_snapshots"]+n["tax_documents"] != 0 {
			t.Errorf("%s reads %v, want 0 rows", name, n)
		}
		if got, years, err := pg.TaxLatest(ctx, a, hum, 0, 2); err != nil || len(got) != 0 || len(years) != 0 {
			t.Errorf("TaxLatest(%s) = %d snapshot(s) %v %v, want none", name, len(got), years, err)
		}
	}
	none := map[string]struct {
		scope string
		args  []any
	}{
		"tenant alone":          {pgScopeTenant, []any{a}},
		"operator":              {pgScopeOperator, nil},
		"no scope":              {`SELECT 1`, nil},
		"human id empty":        {pgScopeTaxReader, []any{a, ""}},
		"operator + human only": {`SELECT set_config('app.rls_scope', 'operator', true), set_config('app.human_id', $1, true)`, []any{person}},
		"ingest, other tenant":  {pgScopeTaxIngest, []any{newTenant(t, pg)}},
	}
	for name, c := range none {
		if n := taxCounts(t, pg, "", c.scope, c.args...); n["tax_snapshots"]+n["tax_documents"] != 0 {
			t.Errorf("%s reads %v, want 0 rows", name, n)
		}
	}
	for _, h := range []string{"", "CLE-01", "c-376", "HUM-"} {
		if _, _, err := pg.TaxLatest(ctx, a, h, 0, 2); !errors.Is(err, ErrNoHuman) {
			t.Errorf("TaxLatest(human %q) = %v, want ErrNoHuman", h, err)
		}
	}
}

// TestTaxStoreRLSControl is the red control: with rdb 0326's tax_read
// dropped (in a rolled-back transaction) the tenant alone and an agent seat
// read the rows; with it, none.
func TestTaxStoreRLSControl(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a := newTenant(t, pg)
	if _, err := pg.TaxIngest(ctx, a, taxSnap(time.Now().UTC(), "k")); err != nil {
		t.Fatal(err)
	}
	agent := seatMember(t, pg, a, "pure_agent")
	drop := `DROP POLICY tax_read ON tax_snapshots; DROP POLICY tax_read ON tax_documents;`
	for name, c := range map[string]struct {
		scope string
		args  []any
	}{"tenant alone": {pgScopeTenant, []any{a}}, "agent seat": {pgScopeTaxReader, []any{a, agent}}} {
		leaked := taxCounts(t, pg, drop, c.scope, c.args...)
		held := taxCounts(t, pg, "", c.scope, c.args...)
		for _, tb := range taxTableList {
			if leaked[tb] == 0 {
				t.Errorf("control is void: %s: without tax_read %s should read the rows", tb, name)
			}
			if held[tb] != 0 {
				t.Errorf("%s: %s reads %d row(s) with tax_read, want 0", tb, name, held[tb])
			}
		}
	}
}

// TestTaxStoreWrites: a person's scope writes nothing (42501 on insert, 0
// rows on delete); a duplicate snapshot id and values outside rdb 0326's
// CHECKs are refused; the ingest prunes a year's snapshots older than
// TaxKeepWeeks before the newest, always keeping the two newest; another
// year is untouched and is read by its year.
func TestTaxStoreWrites(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	a := newTenant(t, pg)
	person := seatMember(t, pg, a, "admin")
	first, err := pg.TaxIngest(ctx, a, taxSnap(now.AddDate(0, 0, -7*40), "k"))
	if err != nil {
		t.Fatal(err)
	}
	var pe *pgconn.PgError
	err = pg.inTaxReader(ctx, a, person, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO tax_snapshots (tenant_id, snapshot_id, tax_year, taken_at, row_count, filed_by)
			VALUES ($1, $2::uuid, 2026, now(), 0, 'x')`, a, uuid4())
		return err
	})
	if !errors.As(err, &pe) || pe.Code != "42501" {
		t.Errorf("a person's snapshot insert = %v, want 42501", err)
	}
	var deleted int64
	if err := pg.inTaxReader(ctx, a, person, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM tax_snapshots`)
		deleted = tag.RowsAffected()
		return err
	}); err != nil || deleted != 0 {
		t.Errorf("a person's delete = %d %v, want 0 rows", deleted, err)
	}
	if _, err := pg.TaxIngest(ctx, a, first); !errors.Is(err, ErrTaxDuplicate) {
		t.Errorf("the same snapshot again = %v, want ErrTaxDuplicate", err)
	}
	for name, mut := range map[string]func(*TaxSnapshot){
		"snapshot id": func(s *TaxSnapshot) { s.SnapshotID = "x" },
		"year":        func(s *TaxSnapshot) { s.TaxYear = 1999 },
		"taken_at":    func(s *TaxSnapshot) { s.TakenAt = time.Time{} },
		"filed_by":    func(s *TaxSnapshot) { s.FiledBy = "" },
		"category":    func(s *TaxSnapshot) { s.Documents[0].Category = "amounts" },
		"sha256":      func(s *TaxSnapshot) { s.Documents[0].ContentSHA256 = "abc" },
		"arrival":     func(s *TaxSnapshot) { s.Documents[0].ArrivalDate = time.Time{} },
		"long text":   func(s *TaxSnapshot) { s.Documents[0].TaxType = strings.Repeat("x", TaxMaxText+1) },
		"newline":     func(s *TaxSnapshot) { s.Documents[0].Period = "a\nb" },
	} {
		s := taxSnap(now, "k")
		mut(&s)
		if _, err := pg.TaxIngest(ctx, a, s); !errors.Is(err, ErrBadTax) {
			t.Errorf("%s: %v, want ErrBadTax", name, err)
		}
	}
	second, err := pg.TaxIngest(ctx, a, taxSnap(now.AddDate(0, 0, -7*30), "k"))
	if err != nil {
		t.Fatal(err)
	}
	third, err := pg.TaxIngest(ctx, a, taxSnap(now, "k"))
	if err != nil {
		t.Fatal(err)
	}
	old := taxSnap(now, "k")
	old.TaxYear = 2025
	if _, err := pg.TaxIngest(ctx, a, old); err != nil {
		t.Fatal(err)
	}
	got, years, err := pg.TaxLatest(ctx, a, person, 2026, 4)
	if err != nil || len(got) != 2 || got[0].SnapshotID != third.SnapshotID || got[1].SnapshotID != second.SnapshotID {
		t.Fatalf("after the prune = %+v %v, want %s then %s (the 40-week-old %s pruned)", got, err, third.SnapshotID,
			second.SnapshotID, first.SnapshotID)
	}
	if len(years) != 2 || years[0] != 2026 || years[1] != 2025 {
		t.Errorf("years = %v, want [2026 2025]", years)
	}
	if n := taxCounts(t, pg, "", pgScopeTaxIngest, a); n["tax_snapshots"] != 3 || n["tax_documents"] != 6 {
		t.Errorf("rows after the prune = %v, want 3 snapshots and their 6 documents", n)
	}
	if got, _, err := pg.TaxLatest(ctx, a, person, 2025, 2); err != nil || len(got) != 1 || got[0].TaxYear != 2025 {
		t.Errorf("year 2025 = %+v %v", got, err)
	}
	if _, _, err := pg.TaxLatest(ctx, a, person, 0, 0); !errors.Is(err, ErrBadTax) {
		t.Errorf("n = 0: %v, want ErrBadTax", err)
	}
}
