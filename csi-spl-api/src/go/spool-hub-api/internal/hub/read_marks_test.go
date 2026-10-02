package hub_test

import (
	"net/http"
	"testing"
	"time"
)

// CLE-77930 (owner, t1 bf737f3f: unread is "for me and me only ... not the new
// messages which I have seen"): what a member reads on one device is read on
// every other. HUM-2 reads #lobby on device A (PUT /v1/me/reads with the
// row's cursor); device B, which sends no read= at all, then sees #lobby with
// nothing unread. HUM-3 (the control) still has it unread, and an older write
// from a stale tab never rewinds the mark.
func TestReadMarksFollowTheMemberAcrossDevices(t *testing.T) {
	r := newPrivacyRig(t)
	lobby := func(as string) map[string]any {
		t.Helper()
		code, out := call(t, r.e, r.tid, http.MethodGet, "/v1/view/channels", as, nil)
		if code != http.StatusOK {
			t.Fatalf("GET /v1/view/channels as %s: %d %v", as, code, out)
		}
		rows, _ := out["channels"].([]any)
		for _, row := range rows {
			if m, ok := row.(map[string]any); ok && m["channel"] == "lobby" {
				return m
			}
		}
		t.Fatalf("no #lobby row for %s: %v", as, out)
		return nil
	}
	row := lobby("HUM-2")
	if n, _ := row["unread"].(float64); n != 1 {
		t.Fatalf("before: HUM-2 #lobby unread = %v, want 1", row["unread"])
	}
	cur, _ := row["last_cursor"].(string)
	if cur == "" {
		t.Fatalf("#lobby row has no last_cursor: %v", row)
	}
	put := func(as string, marks map[string]any) (int, map[string]any) {
		t.Helper()
		return call(t, r.e, r.tid, http.MethodPut, "/v1/me/reads", as, map[string]any{"marks": marks})
	}
	if code, out := put("HUM-2", map[string]any{"ch:lobby": map[string]any{"cursor": cur}}); code != http.StatusOK {
		t.Fatalf("PUT /v1/me/reads: %d %v", code, out)
	}
	if n, _ := lobby("HUM-2")["unread"].(float64); n != 0 {
		t.Errorf("device B: HUM-2 #lobby unread = %v after reading it on device A, want 0", n)
	}
	if n, _ := lobby("HUM-3")["unread"].(float64); n != 1 {
		t.Errorf("CONTROL: HUM-3 never read #lobby, unread = %v, want 1", n)
	}
	// a stale tab writes an older position: the mark stays
	old := time.Now().Add(-48 * time.Hour).UTC().Format(time.RFC3339Nano)
	code, out := put("HUM-2", map[string]any{"ch:lobby": map[string]any{"ts": old, "id": "x"}, "t:" + r.public: map[string]any{"ts": old, "count": 2}})
	if code != http.StatusOK {
		t.Fatalf("PUT stale: %d %v", code, out)
	}
	marks, _ := out["marks"].(map[string]any)
	if m, _ := marks["ch:lobby"].(map[string]any); m == nil || m["cursor"] != cur {
		t.Errorf("a stale write rewound ch:lobby: %v (want cursor %s)", marks["ch:lobby"], cur)
	}
	if m, _ := marks["t:"+r.public].(map[string]any); m == nil || m["count"] != float64(2) {
		t.Errorf("thread mark not stored: %v", marks)
	}
	if n, _ := lobby("HUM-2")["unread"].(float64); n != 0 {
		t.Errorf("after the stale write: HUM-2 #lobby unread = %v, want 0", n)
	}
	code, got := call(t, r.e, r.tid, http.MethodGet, "/v1/me/reads", "HUM-2", nil)
	if gm, _ := got["marks"].(map[string]any); code != http.StatusOK || len(gm) != 2 {
		t.Errorf("GET /v1/me/reads: %d %v, want 2 marks", code, got)
	}
	for what, body := range map[string]map[string]any{
		"bad key":   {"x:lobby": map[string]any{"ts": old}},
		"no ts":     {"ch:lobby": map[string]any{"id": "x"}},
		"bad count": {"t:a": map[string]any{"ts": old, "count": -1}},
	} {
		if code, _ := put("HUM-2", body); code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", what, code)
		}
	}
}
