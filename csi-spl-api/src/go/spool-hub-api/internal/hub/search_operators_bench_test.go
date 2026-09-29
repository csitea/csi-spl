package hub

import (
	"encoding/json"
	"io"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/search"
)

// buildSearchOperatorsOld is the pre-perf per-request builder + map envelope,
// kept only so the benchmark shows the work the sync.Once removed.
func buildSearchOperatorsOld() any {
	type ty struct {
		Type    search.Type `json:"type"`
		Group   string      `json:"group"`
		Aliases []string    `json:"aliases"`
	}
	types := []ty{}
	for _, t := range search.Types {
		types = append(types, ty{t, t.Group(), search.Aliases(t)})
	}
	ops := make([]search.Operator, len(search.Operators))
	copy(ops, search.Operators)
	for i := range ops {
		if ops[i].Aliases == nil {
			ops[i].Aliases = []string{}
		}
		if ops[i].Name == search.OpStatus {
			ops[i].Doc = search.StatusDoc()
		}
	}
	return map[string]any{"version": search.Version, "types": types, "operators": ops}
}

// BenchmarkSearchOperatorsOld builds and encodes the grammar every call (the
// old handler's per-request cost).
func BenchmarkSearchOperatorsOld(b *testing.B) {
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = json.NewEncoder(io.Discard).Encode(buildSearchOperatorsOld())
	}
}

// BenchmarkSearchOperatorsNew only encodes the once-built payload (the new
// handler's per-request cost after the first request).
func BenchmarkSearchOperatorsNew(b *testing.B) {
	searchOperatorsOnce.Do(buildSearchOperators)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = json.NewEncoder(io.Discard).Encode(searchOperatorsData)
	}
}
