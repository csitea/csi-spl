package hub

import (
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 143 taxes-tab.md S2 (SPL-6438): what the hub computes for the Taxes
// page from the two newest snapshots. Runs on any store; every value is
// invented.

func taxDay(s string) time.Time {
	d, _ := time.Parse("2006-01-02", s)
	return d
}

func taxDoc(arrival, kind, period, due, category, sha string) store.TaxDocument {
	var dd time.Time
	if due != "" {
		dd = taxDay(due)
	}
	return store.TaxDocument{ArrivalDate: taxDay(arrival), Kind: kind, DocType: "t", TaxType: "vat", Period: period,
		DueDate: dd, Category: category, ContentSHA256: strings.Repeat(sha, 64)}
}

// TestTaxOverview: new (a key not filed before), changed (same key, new
// content), unchanged; due within 30 days either way, overdue before today,
// a decision without a due date is an open question; newest arrival first.
// With no snapshot before, nothing is new or changed.
func TestTaxOverview(t *testing.T) {
	now := time.Date(2026, 3, 10, 15, 0, 0, 0, time.UTC)
	prev := store.TaxSnapshot{SnapshotID: "p", TaxYear: 2026, TakenAt: now.AddDate(0, 0, -7), Documents: []store.TaxDocument{
		taxDoc("2026-02-01", "same", "2026-01", "2026-03-20", "payments", "a"),
		taxDoc("2026-02-02", "edited", "2026-01", "", "balance", "b"),
	}}
	cur := store.TaxSnapshot{SnapshotID: "c", TaxYear: 2026, TakenAt: now, Documents: []store.TaxDocument{
		taxDoc("2026-02-01", "same", "2026-01", "2026-03-20", "payments", "a"),
		taxDoc("2026-02-02", "edited", "2026-01", "", "balance", "c"),
		taxDoc("2026-03-09", "fresh", "2026-02", "2026-03-01", "decisions", "d"),
		taxDoc("2026-03-08", "open", "2026", "", "decisions", "e"),
		taxDoc("2026-01-05", "far", "2025", "2026-06-30", "decisions", "f"),
	}}
	out := taxOverview([]store.TaxSnapshot{cur, prev}, []int{2026}, now)
	if out.TaxYear != 2026 || out.SnapshotID != "c" || out.Today != "2026-03-10" || out.PreviousTakenAt == "" || len(out.Documents) != 5 {
		t.Fatalf("head = %+v", out)
	}
	by := map[string]wire.TaxDocument{}
	for _, d := range out.Documents {
		by[d.Kind] = d
	}
	if out.Documents[0].Kind != "fresh" || out.Documents[4].Kind != "far" {
		t.Errorf("order = %v, want newest arrival first", out.Documents)
	}
	for kind, want := range map[string]wire.TaxDocument{
		"same":   {Status: "", DueSoon: true},
		"edited": {Status: "changed"},
		"fresh":  {Status: "new", DueSoon: true, Overdue: true},
		"open":   {Status: "new", OpenQuestion: true},
		"far":    {Status: "new"},
	} {
		got := by[kind]
		if got.Status != want.Status || got.DueSoon != want.DueSoon || got.Overdue != want.Overdue || got.OpenQuestion != want.OpenQuestion {
			t.Errorf("%s = %+v, want %+v", kind, got, want)
		}
	}
	first := taxOverview([]store.TaxSnapshot{cur}, []int{2026}, now)
	for _, d := range first.Documents {
		if d.Status != "" {
			t.Errorf("first snapshot: %s is %q, want no status with nothing to compare", d.Kind, d.Status)
		}
	}
	if empty := taxOverview(nil, nil, now); empty.SnapshotID != "" || len(empty.Documents) != 0 || empty.Years == nil {
		t.Errorf("no snapshot = %+v", empty)
	}
}

// TestTaxSnapshotIn: the wire snapshot's dates; the filer is the service
// account, never a body field.
func TestTaxSnapshotIn(t *testing.T) {
	in := wire.TaxSnapshotIn{SnapshotID: "x", TaxYear: 2026, TakenAt: "2026-03-10T05:00:00Z",
		Documents: []wire.TaxDocumentIn{{ArrivalDate: "2026-03-01", Category: "msgs"}}}
	snap, why := taxSnapshotIn(in, "sa@example.com")
	if why != "" || snap.FiledBy != "sa@example.com" || !snap.Documents[0].DueDate.IsZero() {
		t.Fatalf("valid = %+v %q", snap, why)
	}
	for name, mut := range map[string]func(*wire.TaxSnapshotIn){
		"taken_at": func(s *wire.TaxSnapshotIn) { s.TakenAt = "2026-03-10" },
		"arrival":  func(s *wire.TaxSnapshotIn) { s.Documents[0].ArrivalDate = "" },
		"due":      func(s *wire.TaxSnapshotIn) { s.Documents[0].DueDate = "10.3.2026" },
	} {
		c := in
		c.Documents = append([]wire.TaxDocumentIn(nil), in.Documents...)
		mut(&c)
		if _, why := taxSnapshotIn(c, "sa"); why == "" {
			t.Errorf("%s: parsed, want a refusal", name)
		}
	}
}
