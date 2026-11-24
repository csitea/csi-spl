package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"filippo.io/age"
	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 181 row B11: the web-UI sign-in relay to a CLI's terminal login on
// a private workspace's VM. The row's two red controls:
//   - a relayed input found in a hub table or log -> TestSigninRelayNeverStoresInput fails;
//   - the switch off -> the relay refuses: TestSigninRelaySwitchOff.

// relayInput is the person's pasted code in these tests; a real one is a
// vendor's, never in a test.
const relayInput = "RELAYED-INPUT-7f3c9e21"

// relayVM is box id of tid joined as dedicated (its private VM) with a
// desk recipient enrolled; it returns the box and the desk's identity.
func relayVM(t *testing.T, e *env, tid, id string) (*box, *age.X25519Identity) {
	t.Helper()
	b := e.box(tid, id, "CLE-07")
	raw, _ := base64.StdEncoding.DecodeString(b.pub)
	jt := e.st.(store.JoinTokens)
	h := make([]byte, 32)
	rand.Read(h) //nolint:errcheck
	now := time.Now()
	tok := store.JoinToken{Hash: hex.EncodeToString(h), TenantID: tid, CreatedBy: "HUM-1", CreatedAt: now, ExpiresAt: now.Add(time.Hour)}
	if err := jt.CreateJoinToken(context.Background(), tok); err != nil {
		t.Fatal(err)
	}
	if _, err := jt.RedeemJoinToken(context.Background(), tid, tok.Hash, id, ed25519.PublicKey(raw), store.BoxModeDedicated, now); err != nil {
		t.Fatal(err)
	}
	return b, enrolDesk(t, e, tid, id)
}

// relayEnv is an rbac hub with the relay switch set to kinds.
func relayEnv(t *testing.T, logs io.Writer, kinds ...string) *env {
	return rbacEnv(t, func(o *hub.Options) {
		o.SigninRelayKinds = kinds
		if logs != nil {
			o.Log = zerolog.New(logs).Level(zerolog.DebugLevel)
		}
	})
}

// signinPeer is hub instance B on e's store, with e's member door and switch,
// its RunWake running: the web-UI request lands on B, the VM's socket on A.
func signinPeer(t *testing.T, e *env, logs io.Writer, kinds ...string) *env {
	t.Helper()
	srv, err := hub.New(hub.Options{
		Store: e.st, Blob: blob.Dir{Root: e.blobs}, Log: zerolog.New(logs).Level(zerolog.DebugLevel),
		TenantHostPattern: "{tenant}" + domain, HelloSkew: 300 * time.Second, HelloTimeout: 2 * time.Second,
		UploadTokenTTL: 5 * time.Minute, QueueTTL: 7 * 24 * time.Hour, QueueMaxPerBox: 1000,
		RetentionAlerts: 7 * 24 * time.Hour, RetentionChannels: 30 * 24 * time.Hour, Version: "test-peer",
		ViewDoor: hub.ViewDoorOff, LobbyTaskID: lobby, ViewCORSOrigins: []string{wuiOrigin},
		SigninRelayKinds: kinds,
		SessionID: func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(srv.Handler())
	ctx, cancel := context.WithCancel(context.Background())
	go srv.RunWake(ctx)
	t.Cleanup(func() { cancel(); srv.Shutdown(); ts.Close() })
	addr := ts.Listener.Addr().String()
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, addr)
	}
	peer := *e
	peer.srv, peer.ts, peer.client = srv, ts, &http.Client{Transport: tr}
	return &peer
}

// listensFor waits until to's wake listener hears an announce from from (a
// probe box sample request, as samplePeer does).
func listensFor(t *testing.T, from, to *hub.Server, tid string) {
	t.Helper()
	var probes []string
	eventually(t, "the peer's wake listener is up", func() bool {
		for _, req := range probes {
			if to.PendingBoxSample(tid, "box-probe", req) {
				return true
			}
		}
		req, _ := from.AskBoxSample(context.Background(), tid, "box-probe", time.Now().Add(time.Minute))
		probes = append(probes, req)
		return false
	})
}

// relayFrames reads c in the background and hands on every signin_relay
// frame, its raw bytes too.
func relayFrames(c *websocket.Conn) (<-chan wire.Frame, func() string) {
	out := make(chan wire.Frame, 8)
	var mu sync.Mutex
	var raw bytes.Buffer
	go func() {
		defer close(out)
		for {
			_, b, err := c.Read(context.Background())
			if err != nil {
				return
			}
			mu.Lock()
			raw.Write(b)
			mu.Unlock()
			var f wire.Frame
			if json.Unmarshal(b, &f) == nil && f.Type == wire.TSigninRelay {
				out <- f
			}
		}
	}()
	return out, func() string { mu.Lock(); defer mu.Unlock(); return raw.String() }
}

// nextRelayFrame is the next signin_relay frame's lane within 5 s.
func nextRelayFrame(t *testing.T, ch <-chan wire.Frame, wantOp string) (wire.Frame, wire.SigninRelayLane) {
	t.Helper()
	select {
	case f := <-ch:
		var l wire.SigninRelayLane
		if err := json.Unmarshal(f.Lane, &l); err != nil || l.Op != wantOp || l.ID == "" {
			t.Fatalf("signin_relay frame %s: lane %+v (%v), want op %s", f.MsgID, l, err, wantOp)
		}
		return f, l
	case <-time.After(5 * time.Second):
		t.Fatalf("no signin_relay %s frame on the VM's socket", wantOp)
	}
	return wire.Frame{}, wire.SigninRelayLane{}
}

// signinReport writes the VM's signin_relay_out frame.
func signinReport(t *testing.T, c *websocket.Conn, relay string, out wire.SigninRelayOutLane) {
	t.Helper()
	raw, _ := json.Marshal(out)
	if err := wsjson.Write(context.Background(), c, wire.Frame{Type: wire.TSigninRelayOut, MsgID: relay, Lane: raw}); err != nil {
		t.Fatal(err)
	}
}

// relayState polls GET until the relay reads state.
func relayState(t *testing.T, e *env, tid, as, relay, state string) map[string]any {
	t.Helper()
	var body map[string]any
	eventually(t, "relay state "+state, func() bool {
		var code int
		code, body = call(t, e, tid, http.MethodGet, "/v1/signin-relay/"+relay, as, nil)
		return code == http.StatusOK && body["state"] == state
	})
	return body
}

// TestSigninRelaySwitchOff is red control 2: with the switch off for a
// vendor the relay refuses (403 signin_relay_off) and nothing reaches the
// VM; the same request with that vendor's switch on is answered (CONTROL).
func TestSigninRelaySwitchOff(t *testing.T) {
	for _, tc := range []struct {
		name  string
		kinds []string
	}{{"all off (the default)", nil}, {"only grok on", []string{"grok"}}} {
		t.Run(tc.name, func(t *testing.T) {
			e := relayEnv(t, nil, tc.kinds...)
			tid, _ := e.tenant()
			biz := seat(t, e, tid, rbac.BizOwner)
			vm, _ := relayVM(t, e, tid, "vm-1")
			c := e.kindsHello(tid, vm, "CLE-07", []string{wire.FeatureSigninRelay})
			defer c.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
			frames, _ := relayFrames(c)
			code, body := call(t, e, tid, http.MethodPost, "/v1/signin-relay", biz, map[string]any{"kind": "claude"})
			if code != http.StatusForbidden || body["error"] != "signin_relay_off" {
				t.Fatalf("switch off: POST = %d %v, want 403 signin_relay_off", code, body)
			}
			select {
			case f := <-frames:
				t.Fatalf("switch off, yet the VM got a frame: %+v", f)
			case <-time.After(300 * time.Millisecond):
			}
		})
	}
	e := relayEnv(t, nil, "claude")
	tid, _ := e.tenant()
	biz := seat(t, e, tid, rbac.BizOwner)
	relayVM(t, e, tid, "vm-1")
	if code, body := call(t, e, tid, http.MethodPost, "/v1/signin-relay", biz, map[string]any{"kind": "claude"}); code != http.StatusCreated {
		t.Fatalf("CONTROL switch on: POST = %d %v, want 201", code, body)
	}
}

// TestSigninRelayRefusals: who and where (spec 181 B11, 159 3).
func TestSigninRelayRefusals(t *testing.T) {
	e := relayEnv(t, nil, "claude")
	tid, _ := e.tenant()
	biz := seat(t, e, tid, rbac.BizOwner)
	member := seat(t, e, tid, rbac.Developer)
	start := func(as string, body map[string]any) (int, string) {
		code, b := call(t, e, tid, http.MethodPost, "/v1/signin-relay", as, body)
		s, _ := b["error"].(string)
		return code, s
	}
	if code, tok := start(biz, map[string]any{"kind": "claude"}); code != http.StatusConflict || tok != "no_private_vm" {
		t.Fatalf("no dedicated box: %d %s, want 409 no_private_vm", code, tok)
	}
	b := e.box(tid, "shared-1")
	e.pin(tid, b)
	if code, tok := start(biz, map[string]any{"kind": "claude"}); code != http.StatusConflict || tok != "no_private_vm" {
		t.Fatalf("only a non-dedicated box: %d %s, want 409 no_private_vm", code, tok)
	}
	relayVM(t, e, tid, "vm-1")
	for _, c := range []struct {
		as   string
		body map[string]any
		code int
		tok  string
	}{
		{member, map[string]any{"kind": "claude"}, http.StatusForbidden, "forbidden"},
		{biz, map[string]any{"kind": "nope"}, http.StatusBadRequest, "bad_kind"},
		{biz, map[string]any{"kind": "claude", "box": "shared-1"}, http.StatusConflict, "no_private_vm"},
		{biz, map[string]any{"kind": "claude", "extra": 1}, http.StatusBadRequest, "bad_request"},
	} {
		if code, tok := start(c.as, c.body); code != c.code || (c.tok != "forbidden" && tok != c.tok) {
			t.Errorf("POST %v as %s: %d %s, want %d %s", c.body, c.as, code, tok, c.code, c.tok)
		}
	}
	code, body := call(t, e, tid, http.MethodPost, "/v1/signin-relay", biz, map[string]any{"kind": "claude"})
	if code != http.StatusCreated {
		t.Fatalf("POST = %d %v", code, body)
	}
	relay, _ := body["relay"].(string)
	admin := seat(t, e, tid, rbac.Admin)
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/signin-relay/"+relay, admin, nil); code != http.StatusNotFound {
		t.Errorf("another manager reads the relay: %d, want 404", code)
	}
	other, _ := e.tenant()
	if code, _ := call(t, e, other, http.MethodGet, "/v1/signin-relay/"+relay, biz, nil); code == http.StatusOK {
		t.Errorf("the relay read from another workspace: %d", code)
	}
	for _, in := range []string{"", "two\nlines", strings.Repeat("x", 513)} {
		if code, b := call(t, e, tid, http.MethodPost, "/v1/signin-relay/"+relay+"/input", biz, map[string]any{"input": in}); code != http.StatusBadRequest {
			t.Errorf("input %q: %d %v, want 400 bad_input", in, code, b)
		}
	}
}

// TestSigninRelayNeverStoresInput is red control 1, end to end on two hub
// instances: the person starts on B, the VM's socket is on A; the VM
// reports its vendor URL, the person reads it and sends the input, the VM
// gets it sealed to its desk and opens it, then reports signed_in. The
// input is then searched for in every hub log line, every relay event
// (NOTIFY payload), every HTTP answer, every frame the VM got and every
// table of the store; it must be found nowhere. A positive control proves
// each search reads what it claims (the box id is found in the store, the
// relay id in the log and the events).
func TestSigninRelayNeverStoresInput(t *testing.T) {
	logs := &syncBuf{}
	e := relayEnv(t, logs, "claude")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go e.srv.RunWake(ctx)
	tid, _ := e.tenant()
	b := signinPeer(t, e, logs, "claude")
	listensFor(t, b.srv, e.srv, tid)
	listensFor(t, e.srv, b.srv, tid)
	var evMu sync.Mutex
	var events []string
	go e.st.(store.BoxSampleWaker).ListenAll(ctx, store.WakeHandlers{SigninRelay: func(p string) { //nolint:errcheck
		evMu.Lock()
		events = append(events, p)
		evMu.Unlock()
	}})
	biz := seat(t, e, tid, rbac.BizOwner)
	vm, desk := relayVM(t, e, tid, "vm-1")
	c := e.kindsHello(tid, vm, "CLE-07", []string{wire.FeatureSigninRelay})
	defer c.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	frames, frameText := relayFrames(c)
	var answers []string
	keep := func(code int, body map[string]any) (int, map[string]any) {
		raw, _ := json.Marshal(body)
		answers = append(answers, string(raw))
		return code, body
	}

	code, body := keep(call(t, b, tid, http.MethodPost, "/v1/signin-relay", biz, map[string]any{"kind": "claude"}))
	relay, _ := body["relay"].(string)
	if code != http.StatusCreated || relay == "" || body["state"] != "starting" {
		t.Fatalf("start on B: %d %v", code, body)
	}
	if f, _ := nextRelayFrame(t, frames, wire.SigninOpStart); f.MsgID != relay {
		t.Fatalf("start frame for relay %s, want %s", f.MsgID, relay)
	}
	vendorURL := "https://example.com/oauth/authorize?state=s1"
	signinReport(t, c, relay, wire.SigninRelayOutLane{State: wire.SigninStateURL, URL: vendorURL})
	if got := relayState(t, b, tid, biz, relay, wire.SigninStateURL); got["url"] != vendorURL {
		t.Fatalf("the person reads url %v on B, want %s", got["url"], vendorURL)
	}
	keep(call(t, b, tid, http.MethodGet, "/v1/signin-relay/"+relay, biz, nil))
	if code, body := keep(call(t, b, tid, http.MethodPost, "/v1/signin-relay/"+relay+"/input", biz, map[string]any{"input": relayInput})); code != http.StatusAccepted {
		t.Fatalf("input on B: %d %v", code, body)
	}
	_, lane := nextRelayFrame(t, frames, wire.SigninOpInput)
	if got := openSealed(t, desk, lane.Sealed); got.Relay != relay || got.Input != relayInput {
		t.Fatalf("the VM's desk opened %+v, want relay %s and the input", got, relay)
	}
	other, _ := age.GenerateX25519Identity()
	if raw, _ := base64.StdEncoding.DecodeString(lane.Sealed); decryptOK(raw, other) {
		t.Fatal("CONTROL: another identity opened the sealed input")
	}
	signinReport(t, c, relay, wire.SigninRelayOutLane{State: wire.SigninStateSignedIn})
	keep(nil200(relayState(t, b, tid, biz, relay, wire.SigninStateSignedIn)))
	if code, _ := call(t, b, tid, http.MethodDelete, "/v1/signin-relay/"+relay, biz, nil); code != http.StatusNoContent {
		t.Fatalf("end: %d", code)
	}
	nextRelayFrame(t, frames, wire.SigninOpEnd)

	evMu.Lock()
	allEvents := strings.Join(events, "\n")
	evMu.Unlock()
	for _, where := range []struct{ name, text, control string }{
		{"hub log (both instances)", logs.String(), relay},
		{"relay events (NOTIFY payloads)", allEvents, relay},
		{"HTTP answers", strings.Join(answers, "\n"), relay},
		{"frames the VM got", frameText(), relay},
	} {
		if !strings.Contains(where.text, where.control) {
			t.Fatalf("%s hold no %q: the search below proves nothing:\n%s", where.name, where.control, where.text)
		}
		if n := strings.Count(where.text, relayInput); n != 0 {
			t.Errorf("%s carry the relayed input %d times", where.name, n)
		}
	}
	if strings.Contains(logs.String(), vendorURL) {
		t.Error("the hub log carries the vendor URL")
	}
	storeHolds(t, e, tid, "vm-1", relayInput)
}

// nil200 adapts a GET body to keep's shape.
func nil200(body map[string]any) (int, map[string]any) { return http.StatusOK, body }

func openSealed(t *testing.T, id age.Identity, sealed string) wire.SigninRelaySealed {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(sealed)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), relayInput) {
		t.Fatal("the sealed input carries the input in the clear")
	}
	rd, err := age.Decrypt(bytes.NewReader(raw), id)
	if err != nil {
		t.Fatalf("the VM's desk could not open the sealed input: %v", err)
	}
	var p wire.SigninRelaySealed
	if err := json.NewDecoder(rd).Decode(&p); err != nil {
		t.Fatal(err)
	}
	return p
}

func decryptOK(raw []byte, id age.Identity) bool {
	_, err := age.Decrypt(bytes.NewReader(raw), id)
	return err == nil
}

// storeHolds fails when needle is anywhere in the store: on Postgres every
// table's rows in tid's scope (the store's own RLS) and unscoped, on
// Memory every string reachable from the Memory value. CONTROL: control
// (the VM's box id, in its pin row) must be found, else the search reads
// nothing. The Postgres run (hub-pg, PRE_PUSH_TIER=full) is the table
// check of record: a few Memory tables live in package-level maps keyed by
// the store (box_facts.go's memBoxFacts), which this walk does not reach.
func storeHolds(t *testing.T, e *env, tid, control, needle string) {
	t.Helper()
	if pg, ok := e.st.(*store.Postgres); ok {
		pgHolds(t, pg, tid, control, needle)
		return
	}
	var found, controlSeen int
	walkStrings(reflect.ValueOf(e.st), map[uintptr]bool{}, func(s string) {
		if strings.Contains(s, needle) {
			found++
		}
		if strings.Contains(s, control) {
			controlSeen++
		}
	})
	if controlSeen == 0 {
		t.Fatalf("CONTROL: the Memory store walk never saw %q: it reads nothing", control)
	}
	if found != 0 {
		t.Errorf("the Memory store holds the relayed input %d times", found)
	}
}

// walkStrings calls fn on every string and byte slice reachable from v.
func walkStrings(v reflect.Value, seen map[uintptr]bool, fn func(string)) {
	switch v.Kind() {
	case reflect.Pointer, reflect.Interface:
		if v.IsNil() {
			return
		}
		if v.Kind() == reflect.Pointer {
			if seen[v.Pointer()] {
				return
			}
			seen[v.Pointer()] = true
		}
		walkStrings(v.Elem(), seen, fn)
	case reflect.Struct:
		for i := range v.NumField() {
			walkStrings(v.Field(i), seen, fn)
		}
	case reflect.Map:
		it := v.MapRange()
		for it.Next() {
			walkStrings(it.Key(), seen, fn)
			walkStrings(it.Value(), seen, fn)
		}
	case reflect.Slice, reflect.Array:
		if v.Type().Elem().Kind() == reflect.Uint8 {
			b := make([]byte, v.Len())
			for i := range v.Len() {
				b[i] = byte(v.Index(i).Uint())
			}
			fn(string(b))
			return
		}
		for i := range v.Len() {
			walkStrings(v.Index(i), seen, fn)
		}
	case reflect.String:
		fn(v.String())
	}
}

// pgHolds searches every base table of the schema, row text, once in tid's
// tenant scope and once unscoped.
func pgHolds(t *testing.T, pg *store.Postgres, tid, control, needle string) {
	t.Helper()
	ctx := context.Background()
	rows, err := pg.Pool().Query(ctx, `SELECT quote_ident(table_schema)||'.'||quote_ident(table_name) FROM information_schema.tables
		WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema')`)
	if err != nil {
		t.Fatal(err)
	}
	var tables []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			t.Fatal(err)
		}
		tables = append(tables, n)
	}
	rows.Close()
	controlSeen := 0
	for _, tbl := range tables {
		for _, scope := range []string{tid, ""} {
			hits, ctl := pgCount(t, pg, tbl, scope, needle, control)
			if hits != 0 {
				t.Errorf("table %s (scope %q) holds the relayed input in %d rows", tbl, scope, hits)
			}
			controlSeen += ctl
		}
	}
	if len(tables) < 50 || controlSeen == 0 {
		t.Fatalf("CONTROL: %d tables searched, %q seen %d times: the search reads nothing", len(tables), control, controlSeen)
	}
}

// pgCount counts tbl's rows holding needle and control, in one read-only
// transaction scoped to tenant ("" = none); a table the role may not read
// counts 0 and is logged.
func pgCount(t *testing.T, pg *store.Postgres, tbl, tenant, needle, control string) (int, int) {
	t.Helper()
	ctx := context.Background()
	tx, err := pg.Pool().Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tenant); err != nil {
		t.Fatal(err)
	}
	var hits, ctl int
	q := `SELECT count(*) FILTER (WHERE t::text LIKE '%'||$1||'%'), count(*) FILTER (WHERE t::text LIKE '%'||$2||'%') FROM ` + tbl + ` t`
	if err := tx.QueryRow(ctx, q, needle, control).Scan(&hits, &ctl); err != nil {
		t.Logf("table %s not read (scope %q): %v", tbl, tenant, err)
		return 0, 0
	}
	return hits, ctl
}
