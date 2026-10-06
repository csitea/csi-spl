package hub

import (
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// TestSearchBudgetDefault pins the owner's 5 s search budget (t1 6d5bd334,
// 2026-10-06: "2 seconds is a bit too optimistic, should be 5 seconds";
// search-v1 §5.1). An explicit Options.SearchBudget still wins.
func TestSearchBudgetDefault(t *testing.T) {
	for _, c := range []struct {
		set, want time.Duration
	}{{0, 5 * time.Second}, {750 * time.Millisecond, 750 * time.Millisecond}} {
		s, err := New(Options{Store: store.NewMemory(), Blob: blob.Dir{Root: t.TempDir()},
			TenantHostPattern: "{tenant}.example.test", SearchBudget: c.set})
		if err != nil {
			t.Fatal(err)
		}
		if s.o.SearchBudget != c.want {
			t.Fatalf("SearchBudget %v: got %v, want %v", c.set, s.o.SearchBudget, c.want)
		}
	}
}
