package hub_test

// CLE-3425 — the owner's order of 2026-09-20: newest first in EVERY listing, and
// a new item appears at the top in real time. These are the hub's two halves of
// it: the order the view API answers in, and the one event the message fan-out
// cannot carry (a channel created in another session has no message yet).

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// channelRows is GET /v1/view/channels in the order the hub answers in.
func channelRows(t *testing.T, e *env, tenant string) []map[string]any {
	t.Helper()
	resp, err := e.client.Get(e.url(tenant) + "/v1/view/channels")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("view channels: %v %v", err, resp)
	}
	defer resp.Body.Close()
	var v struct {
		Channels []map[string]any `json:"channels"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&v); err != nil {
		t.Fatal(err)
	}
	return v.Channels
}

func channelOrder(rows []map[string]any) []string {
	out := make([]string, 0, len(rows))
	for _, c := range rows {
		out = append(out, c["channel"].(string))
	}
	return out
}

// GET /v1/view/channels answers newest activity first, and an EMPTY channel
// created seconds ago ranks by its created_at (which the row now carries).
func TestViewChannelsNewestActivityFirst(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()

	// Before any post: the three default channels were all seeded with the
	// tenant, so they tie and keep the stable a-z tail (CONTROL for the order
	// asserted below - nothing here is sorted by name).
	if got := channelOrder(channelRows(t, e, tid)); strings.Join(got, ",") != "alerts,lobby,tasks" {
		t.Fatalf("idle defaults: %v", got)
	}

	w := dialWUI(t, e, tid, "HUM-1")
	post := func(body string) {
		req, _ := http.NewRequest(http.MethodPost, e.url(tid)+"/v1/channels", strings.NewReader(body))
		req.Header.Set("Origin", wuiOrigin)
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusCreated {
			raw, _ := io.ReadAll(resp.Body)
			t.Fatalf("create %s: %d %s", body, resp.StatusCode, raw)
		}
	}
	post(`{"channel":"releases","name":"Releases"}`)
	w.send(map[string]any{"type": "send", "task_id": newTask(), "channel": "releases", "body": "release cut"})
	w.read("ack")
	w.send(map[string]any{"type": "send", "task_id": "lobby", "body": "hello lobby"})
	w.read("ack")

	// #lobby posted LAST, so it leads; #releases next; the two idle defaults a-z.
	rows := channelRows(t, e, tid)
	if got := channelOrder(rows); strings.Join(got, ",") != "lobby,releases,alerts,tasks" {
		t.Fatalf("newest activity first: %v", got)
	}

	// A channel created now has no message, so only created_at can rank it -
	// and it must rank ABOVE the channel posted in a moment ago.
	post(`{"channel":"newest","name":"Newest"}`)
	rows = channelRows(t, e, tid)
	if got := channelOrder(rows); got[0] != "newest" {
		t.Fatalf("a channel created seconds ago must lead: %v", got)
	}
	var fresh map[string]any
	for _, c := range rows {
		if c["channel"] == "newest" {
			fresh = c
		}
	}
	if fresh["created_at"] == nil || fresh["last_ts"] != nil {
		t.Fatalf("created_at carried, last_ts empty: %+v", fresh)
	}
	if at, err := time.Parse(time.RFC3339, fresh["created_at"].(string)); err != nil || at.IsZero() {
		t.Fatalf("created_at %v: %v", fresh["created_at"], err)
	}
	// CONTROL: an idle channel never outranks one with a message, however it
	// was created - the two defaults seeded with the tenant stay at the tail.
	got := channelOrder(rows)
	tail := strings.Join(got[len(got)-2:], ",")
	if tail != "alerts,tasks" {
		t.Fatalf("idle channels must stay at the tail: %v", got)
	}
}

// A channel created in one session reaches every other browser socket of the
// SAME tenant at once, as a `channel` frame - the message fan-out cannot carry
// it, because a fresh channel holds no message.
func TestWUIChannelFrameOnCreate(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()
	other, _ := e.tenant()
	a := dialWUI(t, e, tid, "HUM-1")
	b := dialWUI(t, e, tid, "HUM-2")
	outsider := dialWUI(t, e, other, "HUM-3")

	req, _ := http.NewRequest(http.MethodPost, e.url(tid)+"/v1/channels", strings.NewReader(`{"channel":"releases","name":"Releases"}`))
	req.Header.Set("Origin", wuiOrigin)
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create: %d", resp.StatusCode)
	}

	for name, c := range map[string]*wuiClient{"A": a, "B": b} {
		f := c.read("channel")
		if f.Channel != "releases" || f.Name != "Releases" || f.CreatedAt == "" {
			t.Fatalf("%s channel frame: %+v", name, f)
		}
		if _, err := time.Parse(time.RFC3339, f.CreatedAt); err != nil {
			t.Fatalf("%s created_at %q: %v", name, f.CreatedAt, err)
		}
	}
	// CONTROL: a socket of ANOTHER tenant never learns of it. (Its own presence
	// echo is expected traffic; only a `channel` frame is a leak.)
	noChannelFrame(t, outsider)
}

// noChannelFrame asserts that no `channel` frame reaches c within 400 ms.
func noChannelFrame(t *testing.T, c *wuiClient) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	for {
		var f wuiFrame
		if err := wsjson.Read(ctx, c.c, &f); err != nil {
			return // the deadline passed with no channel frame
		}
		if f.Type == "channel" {
			t.Fatalf("another tenant's socket got a channel frame: %+v", f)
		}
	}
}

// view-v1 §4.1 humans (the avatars list) and the search `humans` group are
// newest member first, counting the HUM-<n> the hub hands out in order - so
// HUM-10 leads HUM-2, which a plain string sort gets backwards.
func TestViewRosterHumansNewestFirst(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	h, ok := e.st.(store.Humans)
	if !ok {
		t.Skip("store without the 010 human tables")
	}
	var ids []string
	for i := 0; i < 11; i++ {
		email := fmt.Sprintf("member%02d@example.com", i)
		if i > 0 { // only the first sign-in on an empty tenant may bootstrap
			if err := h.PutInvite(ctx, store.Invite{TenantID: tid, Email: email, Role: store.RoleDefault,
				InvitedBy: ids[0], ExpiresAt: time.Now().Add(time.Hour)}, time.Now()); err != nil {
				t.Fatal(err)
			}
		}
		id, err := h.Admit(ctx, store.Identity{Provider: "google", Subject: fmt.Sprintf("sub-%02d", i), Email: email},
			tid, store.AdmitPolicy{BootstrapOwner: i == 0}, time.Now())
		if err != nil {
			t.Fatalf("admit %s: %v", email, err)
		}
		ids = append(ids, id)
	}
	resp, err := e.client.Get(e.url(tid) + "/v1/view/roster")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("roster: %v %v", err, resp)
	}
	defer resp.Body.Close()
	var v struct {
		Humans []struct {
			HumanID string `json:"human_id"`
		} `json:"humans"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&v); err != nil {
		t.Fatal(err)
	}
	if len(v.Humans) != len(ids) {
		t.Fatalf("humans %d, admitted %d", len(v.Humans), len(ids))
	}
	if v.Humans[0].HumanID != ids[len(ids)-1] {
		t.Fatalf("newest first: got %s, last admitted %s (all %+v)", v.Humans[0].HumanID, ids[len(ids)-1], v.Humans)
	}
	// Strictly descending by the number, so HUM-10 really is above HUM-2.
	for i := 1; i < len(v.Humans); i++ {
		if humNum(v.Humans[i-1].HumanID) <= humNum(v.Humans[i].HumanID) {
			t.Fatalf("not descending at %d: %+v", i, v.Humans)
		}
	}
}

func humNum(id string) int {
	n := 0
	for _, r := range strings.TrimPrefix(id, "HUM-") {
		if r < '0' || r > '9' {
			return 0
		}
		n = n*10 + int(r-'0')
	}
	return n
}
