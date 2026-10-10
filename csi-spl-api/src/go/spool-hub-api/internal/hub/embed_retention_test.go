package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// specs/121 T106: the visitor channel retention (embed_retention.go).

// TestEmbedRetentionSweep (spec 4.4): 30 days after its last message a
// visitor channel is removed by the sweep, its token with it; a channel the
// staff marked a lead is kept, and so is one whose visitor posted inside the
// 30 days. CONTROL: at 29 days the sweep removes nothing. (The sweep counts
// every workspace's due channels, hence "at least one".)
func TestEmbedRetentionSweep(t *testing.T) {
	clk := &testClock{t: time.Now().UTC()}
	e := staffEnv(t, true, clk)
	pg := pgOnly(t, e)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	embed := seedEmbed(t, pg, tid, true)
	gone, goneCh := mint(t, e, tid, embed)
	_, leadCh := mint(t, e, tid, embed)
	busy, busyCh := mint(t, e, tid, embed)
	for _, tok := range []string{gone, busy} {
		if code, raw := embedCall(t, e, tid, http.MethodPost, "/v1/embed/"+embed+"/messages", tok, `{"body":"a question"}`); code != http.StatusCreated {
			t.Fatalf("post: %d %s", code, raw)
		}
	}
	if code, raw := call(t, e, tid, http.MethodPut, "/v1/tenant/embed-visitors/"+leadCh+"/lead", admin, map[string]any{"lead": true}); code != http.StatusNoContent {
		t.Fatalf("lead: %d %v", code, raw)
	}
	ctx := context.Background()
	clk.add(29 * 24 * time.Hour)
	if code, raw := embedCall(t, e, tid, http.MethodPost, "/v1/embed/"+embed+"/messages", busy, `{"body":"still here"}`); code != http.StatusCreated {
		t.Fatalf("busy's post on day 29: %d %s", code, raw)
	}
	if n, err := e.srv.SweepEmbedRetention(ctx); err != nil || n != 0 {
		t.Fatalf("CONTROL: the sweep on day 29 removed %d (%v), want 0", n, err)
	}
	clk.add(2 * 24 * time.Hour)
	if n, err := e.srv.SweepEmbedRetention(ctx); err != nil || n < 1 {
		t.Fatalf("the sweep on day 31 removed %d (%v), want the silent channel", n, err)
	}
	code, raw := call(t, e, tid, http.MethodGet, "/v1/tenant/embed-visitors", admin, nil)
	left := map[string]bool{}
	list, _ := raw["visitors"].([]any)
	for _, r := range list {
		row, _ := r.(map[string]any)
		ch, _ := row["channel"].(string)
		left[ch] = true
	}
	if code != http.StatusOK || left[goneCh] || !left[leadCh] || !left[busyCh] || len(left) != 2 {
		t.Errorf("after the sweep the list holds %v (%d), want the lead %s and the busy %s only", left, code, leadCh, busyCh)
	}
	if code, _ := embedCall(t, e, tid, http.MethodGet, "/v1/embed/"+embed+"/messages", gone, ""); code != http.StatusUnauthorized {
		t.Errorf("the removed visitor's token: %d, want 401", code)
	}
}

// TestEmbedRetentionFlagOff: a hub with the flag off still sweeps a due
// visitor channel. CONTROL: the channel was listed before the sweep.
func TestEmbedRetentionFlagOff(t *testing.T) {
	clk := &testClock{t: time.Now().UTC()}
	on := staffEnv(t, true, clk)
	pg := pgOnly(t, on)
	tid, _ := on.tenant()
	embed := seedEmbed(t, pg, tid, true)
	_, ch := mint(t, on, tid, embed)
	admin := seat(t, on, tid, rbac.Admin)
	if _, raw := call(t, on, tid, http.MethodGet, "/v1/tenant/embed-visitors", admin, nil); len(raw["visitors"].([]any)) != 1 {
		t.Fatalf("CONTROL: before the sweep the list is %v", raw)
	}
	clk.add(31 * 24 * time.Hour)
	off := staffEnv(t, false, clk) // the same database, the flag off
	if n, err := off.srv.SweepEmbedRetention(context.Background()); err != nil || n < 1 {
		t.Fatalf("the flag-off sweep removed %d (%v), want %s", n, err, ch)
	}
	if _, raw := call(t, on, tid, http.MethodGet, "/v1/tenant/embed-visitors", admin, nil); len(raw["visitors"].([]any)) != 0 {
		t.Errorf("after the flag-off sweep the list is %v", raw)
	}
}
