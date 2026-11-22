package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The evlog frame (spec 162 10.4.4, row T6): the box reader of the operator
// workspace reads its env's cursor and puts a window's error groups by
// compare-and-set; any other box is refused and nothing is written.

// evlogRig is a dev hub whose operator workspace is op, two boxes there and
// one box of another workspace.
func evlogRig(t *testing.T) (e *env, opA, opB, other *box) {
	t.Helper()
	op := newTenantID("op")
	e = newEnv(t, func(o *hub.Options) { o.OperatorTenant, o.Env = op, "dev" })
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: op, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	ot, _ := e.tenant()
	opA, opB, other = e.box(op, "box-ra"), e.box(op, "box-rb"), e.box(ot, "box-ro")
	e.pin(op, opA)
	e.pin(op, opB)
	e.pin(ot, other)
	return e, opA, opB, other
}

func evlogCall(t *testing.T, b *box, op string, body any) (wire.EvlogCursor, error) {
	t.Helper()
	raw, _ := json.Marshal(body)
	out, err := b.c.Evlog(context.Background(), op, raw)
	if err != nil {
		return wire.EvlogCursor{}, err
	}
	var c wire.EvlogCursor
	if err := json.Unmarshal(out, &c); err != nil {
		t.Fatalf("answer %s: %v", out, err)
	}
	return c, nil
}

func hubErrToken(err error) (string, int) {
	var he *hubclient.HubError
	if errors.As(err, &he) {
		return he.Token, he.Status
	}
	return "", 0
}

// evlogRows is every System row of fingerprint fp.
func evlogRows(t *testing.T, e *env, fp string) []store.LogEvent {
	t.Helper()
	rows, err := e.st.(store.LogEvents).SystemEventsPage(context.Background(), 0, store.SystemEventsKeep)
	if err != nil {
		t.Fatal(err)
	}
	var out []store.LogEvent
	for _, r := range rows {
		if r.Fingerprint == fp {
			out = append(out, r)
		}
	}
	return out
}

func evlogTestPut(c wire.EvlogCursor, fp string) wire.EvlogPutReq {
	from := c.ReadUntil
	to := time.Now().UTC().Truncate(time.Microsecond)
	if !to.After(from) {
		to = from.Add(time.Hour)
	}
	return wire.EvlogPutReq{Env: "dev", Gen: c.Gen, From: from, To: to, Groups: []wire.EvlogGroup{{
		Kind: store.LogKindErrCloudRunReq, Level: store.LogLevelError, Message: "cloud run answered <n>",
		Fingerprint: fp, FirstAt: to.Add(-time.Minute), LastAt: to.Add(-time.Second), N: 3,
		OriginRef: "cloud-run/hub-00042"}}}
}

// C36: an evlog frame from a box of a workspace that is not the operator
// workspace answers 403 operator.workspaces and writes nothing: neither the
// group nor the cursor. RED control: the operator check taken out of
// boxEvlog lets the other box's put write the group.
func TestEvlogFrameOperatorOnly(t *testing.T) {
	e, opA, _, other := evlogRig(t)
	fp := newFP()
	c0, err := evlogCall(t, opA, wire.EvlogOpCursor, wire.EvlogCursorReq{Env: "dev"})
	if err != nil {
		t.Fatalf("cursor: %v", err)
	}
	_, err = evlogCall(t, other, wire.EvlogOpPut, evlogTestPut(c0, fp))
	if tok, st := hubErrToken(err); tok != "operator.workspaces" || st != 403 {
		t.Errorf("C36 other box put: %v, want 403 operator.workspaces", err)
	}
	if _, err := evlogCall(t, other, wire.EvlogOpCursor, wire.EvlogCursorReq{Env: "dev"}); err == nil {
		t.Errorf("C36: the other box read the cursor")
	}
	if rows := evlogRows(t, e, fp); len(rows) != 0 {
		t.Fatalf("C36: a box of another workspace wrote %d rows", len(rows))
	}
	if c, _ := evlogCall(t, opA, wire.EvlogOpCursor, wire.EvlogCursorReq{Env: "dev"}); c != c0 {
		t.Fatalf("C36: the cursor moved: %+v, want %+v", c, c0)
	}
}

// C35, the hub half: a put at the read cursor moves it (gen + 1, by the
// box) and upserts the group; the second box's put of the same window
// answers 409 cursor_moved and changes no row and not the cursor.
func TestEvlogFrameCursorCAS(t *testing.T) {
	e, opA, opB, _ := evlogRig(t)
	fp := newFP()
	c0, err := evlogCall(t, opA, wire.EvlogOpCursor, wire.EvlogCursorReq{Env: "dev"})
	if err != nil || c0.Env != "dev" {
		t.Fatalf("cursor: %+v %v", c0, err)
	}
	put := evlogTestPut(c0, fp)
	c1, err := evlogCall(t, opA, wire.EvlogOpPut, put)
	if err != nil || c1.Gen != c0.Gen+1 || !c1.ReadUntil.Equal(put.To) || c1.By != "box-ra" {
		t.Fatalf("put: %+v %v", c1, err)
	}
	_, err = evlogCall(t, opB, wire.EvlogOpPut, put)
	if tok, st := hubErrToken(err); tok != "cursor_moved" || st != 409 {
		t.Fatalf("C35 stale put: %v, want 409 cursor_moved", err)
	}
	rows := evlogRows(t, e, fp)
	if len(rows) != 1 || rows[0].N != 3 || rows[0].Actor != "cloud-logging" || rows[0].OriginRef != "cloud-run/hub-00042" {
		t.Fatalf("C35: rows after a stale put: %+v (want 1 row, n 3)", rows)
	}
	if c, _ := evlogCall(t, opA, wire.EvlogOpCursor, wire.EvlogCursorReq{Env: "dev"}); c != c1 {
		t.Fatalf("C35: a stale put moved the cursor: %+v, want %+v", c, c1)
	}
}

// A malformed frame is refused before the store: another env than the
// hub's, an unknown op or field, a group of a kind that is not an error.
func TestEvlogFrameRefusals(t *testing.T) {
	_, opA, _, _ := evlogRig(t)
	c0, err := evlogCall(t, opA, wire.EvlogOpCursor, wire.EvlogCursorReq{Env: "dev"})
	if err != nil {
		t.Fatal(err)
	}
	notErr := evlogTestPut(c0, newFP())
	notErr.Groups[0].Kind = store.LogKindHubStarted
	prd := evlogTestPut(c0, newFP())
	prd.Env = "prd"
	for name, tc := range map[string]struct {
		op   string
		body any
	}{
		"prd on a dev hub": {wire.EvlogOpCursor, wire.EvlogCursorReq{Env: "prd"}},
		"prd put":          {wire.EvlogOpPut, prd},
		"unknown op":       {"steal", wire.EvlogCursorReq{Env: "dev"}},
		"unknown field":    {wire.EvlogOpCursor, map[string]string{"env": "dev", "raw": "x"}},
		"not an error":     {wire.EvlogOpPut, notErr},
	} {
		if _, err := evlogCall(t, opA, tc.op, tc.body); err == nil {
			t.Errorf("%s: accepted", name)
		} else if tok, st := hubErrToken(err); tok != "bad_frame" || st != 400 {
			t.Errorf("%s: %v, want 400 bad_frame", name, err)
		}
	}
	if c, _ := evlogCall(t, opA, wire.EvlogOpCursor, wire.EvlogCursorReq{Env: "dev"}); c != c0 {
		t.Fatalf("a refused frame moved the cursor: %+v, want %+v", c, c0)
	}
}

// newFP is a fresh 16-hex fingerprint, so a test on a shared Postgres
// never meets another run's group.
func newFP() string { return newTenantID("")[:8] + newTenantID("")[:8] }
