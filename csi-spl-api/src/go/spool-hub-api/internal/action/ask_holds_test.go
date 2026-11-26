package action

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// TestAskBodyHolds pins the holds op's body (spec 153 3.22.8): the placer's
// whole map goes to the hub as is, and what the client refuses before
// dialling: no or a bad --by, and a map over store.AskHoldsMax.
func TestAskBodyHolds(t *testing.T) {
	good := AskArgs{Op: "holds", By: "c-001@sat", Role: "orch", Holds: map[string]string{askID: "waits for room"}}
	over := map[string]string{}
	for i := 0; i <= store.AskHoldsMax; i++ {
		over[fmt.Sprintf("id-%d", i)] = "r"
	}
	refused := []struct {
		name string
		edit func(*AskArgs)
		want string
	}{
		{"no by", func(a *AskArgs) { a.By = "" }, "holds needs --by"},
		{"bad by", func(a *AskArgs) { a.By = "no spaces allowed" }, "holds needs --by"},
		{"too many", func(a *AskArgs) { a.Holds = over }, fmt.Sprintf("at most %d asks", store.AskHoldsMax)},
	}
	for _, c := range refused {
		t.Run(c.name, func(t *testing.T) {
			in := good
			c.edit(&in)
			if raw, err := askBody(in); err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("body %s, err %v: want %q", raw, err, c.want)
			}
		})
	}
	raw, err := askBody(good)
	if err != nil {
		t.Fatal(err)
	}
	got := holdsDecode(t, raw)
	h, ok := got["holds"].(map[string]any)
	if got["by"] != good.By || got["role"] != good.Role || !ok || len(h) != 1 || h[askID] != "waits for room" {
		t.Fatalf("body %v", got)
	}
	empty := good
	empty.Holds = nil
	raw, err = askBody(empty)
	if err != nil {
		t.Fatal(err)
	}
	if h, ok := holdsDecode(t, raw)["holds"].(map[string]any); !ok || len(h) != 0 {
		t.Fatalf("nil holds: body %s, want an empty map (every row waits for room)", raw)
	}
}

// holdsDecode reads a holds body, whose "holds" is an object, not a string.
func holdsDecode(t *testing.T, raw json.RawMessage) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("%s: %v", raw, err)
	}
	return m
}
