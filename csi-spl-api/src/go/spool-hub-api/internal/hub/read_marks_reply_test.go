package hub_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Perf edition 20261004 E11: PUT /v1/me/reads answers the marks it wrote, as
// stored, not the member's whole map (prd 24 h n=11 113 PUTs at p50 16.7 KB
// each). A member with 150 stored marks moves one: the reply is that one mark
// and under 1 KB; a later mark another device stored for the same key still
// wins in the reply; ?full=1 still answers every mark; GET is unchanged.
func TestReadMarksPutAnswersOnlyWhatItWrote(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	rm, ok := e.st.(store.ReadMarks)
	if !ok {
		t.Fatal("store has no read marks")
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	seed := map[string]store.ReadMark{}
	for i := range 150 {
		seed[fmt.Sprintf("f:%08x-0000-4000-8000-%012x", i, i)] = store.ReadMark{At: now.Add(-time.Hour), MsgID: fmt.Sprintf("m-%d", i)}
	}
	seed["ch:lobby"] = store.ReadMark{At: now.Add(-time.Minute), MsgID: "later-device"}
	if err := rm.SaveReadMarks(context.Background(), tid, "HUM-2", seed, now); err != nil {
		t.Fatal(err)
	}
	put := func(path string, marks map[string]any) (int, map[string]any) {
		t.Helper()
		raw, _ := json.Marshal(map[string]any{"marks": marks})
		req, _ := http.NewRequest(http.MethodPut, e.url(tid)+path, bytes.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set(memberHeader, "HUM-2")
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		var out map[string]any
		_ = json.Unmarshal(body, &out)
		got, _ := out["marks"].(map[string]any)
		return len(body), got
	}
	ts := now.Add(-30 * time.Second).Format(time.RFC3339Nano)
	older := now.Add(-2 * time.Hour).Format(time.RFC3339Nano)
	n, got := put("/v1/me/reads", map[string]any{"t:task-1": map[string]any{"ts": ts, "id": "x", "count": 3}, "ch:lobby": map[string]any{"ts": older, "id": "stale"}})
	if len(got) != 2 || got["t:task-1"] == nil {
		t.Fatalf("PUT answered %d marks, want the 2 it wrote", len(got))
	}
	if n >= 1024 {
		t.Errorf("PUT reply is %d bytes, want < 1 KB", n)
	}
	if m, _ := got["ch:lobby"].(map[string]any); m == nil || m["id"] != "later-device" {
		t.Errorf("a stale write's reply must carry the stored later mark: %v", got["ch:lobby"])
	}
	full, all := put("/v1/me/reads?full=1", map[string]any{"t:task-1": map[string]any{"ts": ts, "id": "x"}})
	if len(all) != 152 {
		t.Errorf("?full=1 answered %d marks, want all 152", len(all))
	}
	code, g := call(t, e, tid, http.MethodGet, "/v1/me/reads", "HUM-2", nil)
	if gm, _ := g["marks"].(map[string]any); code != http.StatusOK || len(gm) != 152 {
		t.Errorf("GET /v1/me/reads: %d, %d marks, want 152", code, len(gm))
	}
	t.Logf("PUT reply %d B (delta) vs %d B (?full=1, 152 marks)", n, full)
}
