package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"flag"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 153 sections 3.22.3, 3.22.4 and the hold part of 3.22.8, row Q3
// (SPL-6596): GET /v1/operator/fleet-queue, its lane field and ask_op
// holds. Cases C102-C104 and C122 of 3.22.10, on the memory store and on
// Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).
//
// RED on origin/master: no route (C102-C104 answer 404), no op (C122: the
// default branch refuses "holds" as an unknown ask_op). C103's red control
// is the bash half (csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh case
// 23): a planted class filter makes the route and spl_spawn_q_rows differ.

const fleetQueuePath = "/v1/operator/fleet-queue"

var updateFleetQueue = flag.Bool("update-fleet-queue", false, "rewrite testdata/fleet-queue-c103.json")

type queueView struct {
	Fleet string `json:"fleet"`
	Total int    `json:"total"`
	Rows  []struct {
		AskID          string `json:"ask_id"`
		State          string `json:"state"`
		Position       int    `json:"position"`
		Priority       int    `json:"priority"`
		PrioritySource string `json:"priority_source"`
		Class          string `json:"class"`
		Vendor         string `json:"vendor"`
		HoldReason     string `json:"hold_reason"`
		Reason         string `json:"reason"`
		Lane           string `json:"lane"`
	} `json:"rows"`
}

func getQueue(t *testing.T, r *orderRig, query string) queueView {
	t.Helper()
	code, body := call(t, r.e, r.op, http.MethodGet, fleetQueuePath+query, r.admin, nil)
	if code != http.StatusOK {
		t.Fatalf("GET %s%s as the operator admin: %d %v", fleetQueuePath, query, code, body)
	}
	raw, _ := json.Marshal(body)
	var v queueView
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func (v queueView) ids() []string {
	out := []string{}
	for _, row := range v.Rows {
		out = append(out, row.AskID)
	}
	return out
}

// seedAsk puts one ask of role at at with a fixed id, then applies ops
// (queue:<class>, ack, done:<reason>, dead:<reason>) one second apart.
func seedAsk(t *testing.T, r *orderRig, id, role, disc string, at time.Time, ops ...string) {
	t.Helper()
	ctx := context.Background()
	if _, _, err := r.e.st.PutFleetAsk(ctx, r.op, store.FleetAsk{Fleet: "main", AskID: id, Role: role, Kind: "task",
		From: "c-002@box-b", Topic: "dispatch-0000abcd", Discussion: disc, Summary: "SPAWN REQUEST " + id[:8]}, "box-b", at); err != nil {
		t.Fatal(err)
	}
	for i, op := range ops {
		name, arg, _ := strings.Cut(op, ":")
		u := store.AskUpdate{Fleet: "main", AskID: id, Op: name, By: "c-001@sat"}
		switch name {
		case store.AskQueue:
			u.Class = arg
		case "done", "dead":
			u.Reason = arg
		}
		if _, err := r.e.st.UpdateFleetAsk(ctx, r.op, u, "sat", at.Add(time.Duration(i+1)*time.Second)); err != nil {
			t.Fatalf("%s %s: %v", id[:8], op, err)
		}
	}
}

// C102: the operator admin reads the rows; a member of the operator
// workspace and an admin of another workspace are 403. RED: no route (404).
func TestFleetQueueWho(t *testing.T) {
	r := newOrderRig(t)
	id := r.queue(t, "bug", "")
	if v := getQueue(t, r, ""); len(v.Rows) != 1 || v.Rows[0].AskID != id || v.Total != 1 || v.Fleet != "main" {
		t.Fatalf("the admin's view: %+v, want the one queued ask", v)
	}
	if code, body := call(t, r.e, r.op, http.MethodGet, fleetQueuePath, r.dev, nil); code != http.StatusForbidden {
		t.Errorf("a member of the operator workspace: %d %v, want 403", code, body)
	}
	other := newTenantID("ws")
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := r.e.st.CreateTenant(context.Background(), store.Tenant{ID: other, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	if code, body := call(t, r.e, other, http.MethodGet, fleetQueuePath, seat(t, r.e, other, rbac.Admin), nil); code != http.StatusForbidden {
		t.Errorf("an admin of another workspace: %d %v, want 403", code, body)
	}
	if code, _ := call(t, r.e, r.op, http.MethodGet, fleetQueuePath+"?fleet=Main", r.admin, nil); code != http.StatusBadRequest {
		t.Errorf("a bad fleet: %d, want 400", code)
	}
}

// The C103 seed: fixed ids and times, so the golden is the same on both
// drivers and on every run.
var c103T0 = time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)

const (
	c103Bug      = "c1030000-0000-4000-8000-000000000001"
	c103Feature  = "c1030000-0000-4000-8000-000000000002"
	c103CI       = "c1030000-0000-4000-8000-000000000003"
	c103Placing1 = "c1030000-0000-4000-8000-000000000004"
	c103Placing2 = "c1030000-0000-4000-8000-000000000005"
	c103Open     = "c1030000-0000-4000-8000-000000000006"
	c103AckedNoQ = "c1030000-0000-4000-8000-000000000007"
	c103Dispatch = "c1030000-0000-4000-8000-000000000008"
	c103Placed   = "c1030000-0000-4000-8000-000000000009"
	c103Bug2     = "c1030000-0000-4000-8000-00000000000a"
	c103Disc     = "c103d15c-0000-4000-8000-000000000001"
)

func seedC103(t *testing.T, r *orderRig) {
	t.Helper()
	at := func(m int) time.Time { return c103T0.Add(time.Duration(m) * time.Minute) }
	seedAsk(t, r, c103Bug, "orch", "", at(0), "queue:bug")
	seedAsk(t, r, c103Feature, "orch", c103Disc, at(1), "queue:feature")
	seedAsk(t, r, c103CI, "orch", "", at(2), "queue:ci")
	seedAsk(t, r, c103Placing1, "orch", "", at(3), "queue:refactor", "ack")
	seedAsk(t, r, c103Placing2, "orch", "", at(4), "queue:bug", "ack")
	seedAsk(t, r, c103Open, "orch", "", at(5))
	seedAsk(t, r, c103AckedNoQ, "orch", "", at(6), "ack")
	seedAsk(t, r, c103Dispatch, "dispatch", "", at(7), "queue:bug")
	seedAsk(t, r, c103Placed, "orch", "", at(8), "queue:bug", "ack", "done:placed: c-101@box-a")
	seedAsk(t, r, c103Bug2, "orch", "", at(9), "queue:bug")
	r.setTopic(t, c103Disc, 1, at(10))
}

// c103Golden is what both halves of C103 read: list is the hub's answer to
// `spool ask list --role orch` (the fields spl_spawn_q_rows reads), route
// the route's ask ids in order.
type c103Golden struct {
	List struct {
		Asks []map[string]any `json:"asks"`
	} `json:"list"`
	Route []string `json:"route"`
}

// C103: the route's rows, order and count, are the line spl_spawn_q_rows
// reads from the same hub list: here the route is pinned to the golden, and
// the bash half (spl-spawn-queue.tst.sh case 23) pins spl_spawn_q_rows on
// the golden's list to the same ids.
func TestFleetQueueMatchesTheQueue(t *testing.T) {
	r := newOrderRig(t)
	seedC103(t, r)
	raw, err := r.b.c.Ask(context.Background(), "list", "main", json.RawMessage(`{"role":"orch"}`))
	if err != nil {
		t.Fatal(err)
	}
	var list struct {
		Asks []map[string]any `json:"asks"`
	}
	if err := json.Unmarshal(raw, &list); err != nil {
		t.Fatal(err)
	}
	var g c103Golden
	g.List.Asks = []map[string]any{}
	for _, a := range list.Asks {
		keep := map[string]any{}
		for _, k := range []string{"ask_id", "role", "state", "class", "enqueued_at", "position", "queue_len", "priority"} {
			if v, ok := a[k]; ok {
				keep[k] = v
			}
		}
		g.List.Asks = append(g.List.Asks, keep)
	}
	g.Route = getQueue(t, r, "").ids()
	got, _ := json.MarshalIndent(g, "", "  ")
	got = append(got, '\n')
	path := filepath.Join("testdata", "fleet-queue-c103.json")
	if *updateFleetQueue {
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("the route or the list on the C103 seed differs from %s (go test -run TestFleetQueueMatchesTheQueue -update-fleet-queue rewrites it; the bash half must agree):\n%s", path, got)
	}
	// the line by hand: the placing rows first in list order, then the
	// queue (ci first, the priority 1 feature, then the bugs by age)
	wantIDs := []string{c103Placing1, c103Placing2, c103CI, c103Feature, c103Bug, c103Bug2}
	if strings.Join(g.Route, " ") != strings.Join(wantIDs, " ") {
		t.Fatalf("route order %v, want %v", g.Route, wantIDs)
	}
}

// C104: a row closed "placed: c-101@box-a" sends lane, listed with placed=1
// only; "dead: c-101@box-a" and "placed: nonsense" send none. RED: no field.
func TestFleetQueueLane(t *testing.T) {
	r := newOrderRig(t)
	placed, dead, nonsense, waiting := uuidV4(), uuidV4(), uuidV4(), uuidV4()
	at := time.Now().UTC().Add(-time.Hour)
	seedAsk(t, r, placed, "orch", "", at, "queue:bug", "ack", "done:placed: c-101@box-a")
	seedAsk(t, r, dead, "orch", "", at.Add(time.Minute), "queue:bug", "ack", "dead:dead: c-101@box-a")
	seedAsk(t, r, nonsense, "orch", "", at.Add(2*time.Minute), "queue:bug", "done:placed: nonsense")
	seedAsk(t, r, waiting, "orch", "", at.Add(3*time.Minute), "queue:feature")
	if v := getQueue(t, r, ""); strings.Join(v.ids(), " ") != waiting {
		t.Fatalf("without placed=1: %v, want the one queued ask", v.ids())
	}
	v := getQueue(t, r, "?placed=1")
	lanes := map[string]string{}
	for _, row := range v.Rows {
		lanes[row.AskID] = row.State + " " + row.Lane
	}
	for id, want := range map[string]string{placed: "done c-101@box-a", dead: "dead ", nonsense: "done ", waiting: "queued "} {
		if lanes[id] != want {
			t.Errorf("ask %s: %q, want %q (all %v)", id[:8], lanes[id], want, lanes)
		}
	}
	if len(v.Rows) != 4 || v.Rows[0].AskID != waiting || v.Total != 1 {
		t.Errorf("placed=1: the line first, then the closed rows: %v total %d", v.ids(), v.Total)
	}
}

// C122: ask_op holds sets hold_reason from the map, a second same map writes
// nothing (the store answers the rows it wrote: none), a row left out is
// cleared; the route's hold_reason reads it. RED: no op.
func TestFleetAskOpHolds(t *testing.T) {
	r := newOrderRig(t)
	a, b, c := r.queue(t, "bug", ""), r.queue(t, "feature", ""), r.queue(t, "feature", "")
	send := func(holds map[string]string) ([]any, error) {
		raw, _ := json.Marshal(map[string]any{"by": "c-001", "holds": holds})
		out, err := r.b.c.Ask(context.Background(), "holds", "main", raw)
		got := map[string]any{}
		json.Unmarshal(out, &got) //nolint:errcheck
		asks, _ := got["asks"].([]any)
		return asks, err
	}
	m := map[string]string{a: "pinned to sat: claude weekly 94% >= 90%", b: "agy is out of quota until 21:31Z"}
	if w, err := send(m); err != nil || len(w) != 2 {
		t.Fatalf("first map: wrote %d rows, %v; want 2", len(w), err)
	}
	if w, err := send(m); err != nil || len(w) != 0 {
		t.Fatalf("the same map again: wrote %d rows, %v; want none", len(w), err)
	}
	holds := func() map[string]string {
		out := map[string]string{}
		for _, row := range getQueue(t, r, "").Rows {
			out[row.AskID] = row.HoldReason
		}
		return out
	}
	if h := holds(); h[a] != m[a] || h[b] != m[b] || h[c] != "" {
		t.Fatalf("the route's hold_reason: %v", h)
	}
	if w, err := send(map[string]string{b: m[b]}); err != nil || len(w) != 1 {
		t.Fatalf("a left out: wrote %d rows, %v; want 1 (the clear)", len(w), err)
	}
	if h := holds(); h[a] != "" || h[b] != m[b] {
		t.Fatalf("after a was left out: %v", h)
	}
	if w, err := send(map[string]string{uuidV4(): "not in line"}); err != nil || len(w) != 1 {
		t.Fatalf("an unknown key: wrote %d rows, %v; want 1 (b cleared, the key ignored)", len(w), err)
	}
	for name, bad := range map[string]map[string]string{
		"a key that is no uuid": {"nope": "x"},
		"an empty reason":       {a: ""},
		"a two-line reason":     {a: "one\ntwo"},
	} {
		if _, err := send(bad); err == nil {
			t.Errorf("%s was taken", name)
		}
	}
}
