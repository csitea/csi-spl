package hub_test

import (
	"net/http"
	"testing"
)

// CLE-77889 (owner, t1 99905c80: "they should be shown as new for the receiver
// of those msgs, but not me"): GET /v1/view/channels counts unread for the
// member reading it, so HUM-1's own #lobby post is not unread for HUM-1 - and
// stays unread for HUM-2 (the control: a listing that dropped every count
// would pass the first half alone).
func TestViewChannelsOwnPostNotUnread(t *testing.T) {
	r := newPrivacyRig(t)
	lobbyUnread := func(as string) float64 {
		t.Helper()
		code, out := call(t, r.e, r.tid, http.MethodGet, "/v1/view/channels", as, nil)
		if code != http.StatusOK {
			t.Fatalf("GET /v1/view/channels as %s: %d %v", as, code, out)
		}
		rows, _ := out["channels"].([]any)
		for _, row := range rows {
			if m, ok := row.(map[string]any); ok && m["channel"] == "lobby" {
				n, _ := m["unread"].(float64)
				return n
			}
		}
		t.Fatalf("no #lobby row for %s: %v", as, out)
		return 0
	}
	if n := lobbyUnread("HUM-1"); n != 0 {
		t.Errorf("HUM-1's own #lobby post counts as unread for HUM-1: %v", n)
	}
	if n := lobbyUnread("HUM-2"); n != 1 {
		t.Errorf("CONTROL: HUM-1's #lobby post must be unread for HUM-2: %v", n)
	}
}
