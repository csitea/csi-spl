package store

import (
	"context"
	"sort"
	"sync"
	"time"
)

// Box facts (rdb 0140, t1 950d5562 "the sat box has a lot of box info
// unreported"): the last fact sheet each box sent on its hello, so the hub
// still has it after a restart or a Cloud Run roll. The hub kept the sheet
// in process memory only, and a fresh revision, which answers every new
// roster read, showed "not reported yet" until the box redialled onto it.
// One row per box, overwritten; the sheet is the hub's CLEANED wire.BoxHost
// as JSON (hub/box_facts.go), so the store never sees what a box sent raw.

// BoxFactsMaxBytes caps one stored sheet (rdb 0140 CHECK): the hub's caps
// keep a cleaned sheet near 2 KiB.
const BoxFactsMaxBytes = 16384

// BoxFactSheet is one box's stored sheet and when the box collected it.
type BoxFactSheet struct {
	Box        string
	ReportedAt time.Time
	Sheet      []byte
}

// BoxFacts is the store half of rdb 0140. Optional: on a store without it
// the hub keeps the sheets in memory only, as before.
type BoxFacts interface {
	// PutBoxFacts stores (or replaces) one box's sheet.
	PutBoxFacts(ctx context.Context, tenantID string, f BoxFactSheet) error
	// ListBoxFacts is every stored sheet of the tenant, by box.
	ListBoxFacts(ctx context.Context, tenantID string) ([]BoxFactSheet, error)
}

// The Memory driver keeps its sheets beside the store, like memBoxStats.
var (
	memBoxFactsMu sync.Mutex
	memBoxFacts   = map[*Memory]map[string]map[string]BoxFactSheet{} // tenant -> box -> sheet
)

func (s *Memory) PutBoxFacts(_ context.Context, tenant string, f BoxFactSheet) error {
	memBoxFactsMu.Lock()
	defer memBoxFactsMu.Unlock()
	if memBoxFacts[s] == nil {
		memBoxFacts[s] = map[string]map[string]BoxFactSheet{}
	}
	if memBoxFacts[s][tenant] == nil {
		memBoxFacts[s][tenant] = map[string]BoxFactSheet{}
	}
	f.ReportedAt = f.ReportedAt.UTC()
	f.Sheet = append([]byte(nil), f.Sheet...)
	memBoxFacts[s][tenant][f.Box] = f
	return nil
}

func (s *Memory) ListBoxFacts(_ context.Context, tenant string) ([]BoxFactSheet, error) {
	memBoxFactsMu.Lock()
	defer memBoxFactsMu.Unlock()
	out := []BoxFactSheet{}
	for _, f := range memBoxFacts[s][tenant] {
		f.Sheet = append([]byte(nil), f.Sheet...)
		out = append(out, f)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Box < out[j].Box })
	return out, nil
}
