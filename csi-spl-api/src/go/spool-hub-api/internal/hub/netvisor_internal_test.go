package hub

import (
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 125 B5: the wire snapshot's dates. Runs on any store. CONTROL: the
// valid snapshot parses, so each refusal is its one bad field's.
func TestNetvisorSnapshotIn(t *testing.T) {
	valid := func() wire.NetvisorSnapshotIn {
		return wire.NetvisorSnapshotIn{SnapshotID: "x", AsOf: "2026-11-03", MonthEnd: "2026-11-30",
			FetchedAt: "2026-11-03T05:00:00Z",
			Items:     []wire.NetvisorForecastItem{{Category: "receivable", Sign: 1, Amount: "1.00", DueDate: "2026-11-20"}},
			CardLines: []wire.NetvisorCardCostLine{{Month: "2026-11-01", Route: "debit_ledger", AccountNumber: "4000", Amount: "1.00"}}}
	}
	snap, why := nvsSnapshotIn(valid())
	if why != "" || !snap.AsOf.Equal(time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC)) || !snap.NewestBankVoucherDate.IsZero() ||
		snap.Items[0].DueDate.Day() != 20 || snap.CardLines[0].Month.Day() != 1 || snap.FetchedAt.Hour() != 5 {
		t.Fatalf("CONTROL: %q %+v", why, snap)
	}
	for name, mut := range map[string]func(*wire.NetvisorSnapshotIn){
		"no as_of":      func(s *wire.NetvisorSnapshotIn) { s.AsOf = "" },
		"dotted date":   func(s *wire.NetvisorSnapshotIn) { s.MonthEnd = "30.11.2026" },
		"voucher":       func(s *wire.NetvisorSnapshotIn) { s.NewestBankVoucherDate = "yesterday" },
		"fetched_at":    func(s *wire.NetvisorSnapshotIn) { s.FetchedAt = "2026-11-03" },
		"item due date": func(s *wire.NetvisorSnapshotIn) { s.Items[0].DueDate = "2026-13-01" },
		"no card month": func(s *wire.NetvisorSnapshotIn) { s.CardLines[0].Month = "" },
	} {
		in := valid()
		mut(&in)
		if _, why := nvsSnapshotIn(in); why == "" {
			t.Errorf("%s: parsed, want a refusal", name)
		}
	}
	if d := nvsDateOut(time.Time{}); d != "" {
		t.Errorf("zero date = %q, want empty", d)
	}
	if v := nvsTimeOut(nil); v != nil {
		t.Errorf("nil time = %v, want null", *v)
	}
}
