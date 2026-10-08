package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 073 T003 (agent join tokens) and spec 108 3.1 / 3.2 hub-side pairs.
// Every case states its n and carries its control.

const joinPath = "/v1/tenant/agents/join-tokens"

// defaultJoinTTL is config.Hub's envDefault for SPOOL_HUB_JOIN_TOKEN_TTL, so
// the hub tests run on the default the cnf ships (AC2), not a copy of it.
func defaultJoinTTL(t *testing.T) time.Duration {
	t.Helper()
	f, ok := reflect.TypeOf(config.Hub{}).FieldByName("JoinTokenTTL")
	if !ok {
		t.Fatal("config.Hub has no JoinTokenTTL")
	}
	d, err := time.ParseDuration(f.Tag.Get("envDefault"))
	if err != nil || d != time.Hour {
		t.Fatalf("JoinTokenTTL envDefault %q: %v (spec 073 4.1 says 1h)", f.Tag.Get("envDefault"), err)
	}
	return d
}

func joinEnv(t *testing.T, mut ...func(*hub.Options)) *env {
	ttl := defaultJoinTTL(t)
	return rbacEnv(t, append([]func(*hub.Options){func(o *hub.Options) { o.JoinTokenTTL = ttl }}, mut...)...)
}

// mintToken mints as hum and answers the plain token and the mint answer.
func mintToken(t *testing.T, e *env, tid, hum string, body map[string]any) (string, map[string]any) {
	t.Helper()
	code, out := call(t, e, tid, http.MethodPost, joinPath, hum, body)
	tok, _ := out["token"].(string)
	if code != http.StatusCreated || !strings.HasPrefix(tok, "spj1."+tid+".") {
		t.Fatalf("mint %v: %d %v", body, code, out)
	}
	return tok, out
}

func tokenHash(tok string) string {
	sum := sha256.Sum256([]byte(tok[strings.LastIndex(tok, ".")+1:]))
	return hex.EncodeToString(sum[:])
}

// redeem posts POST /v1/pins/join on the api host, signed by priv at ts.
func redeem(t *testing.T, e *env, hdr http.Header, tok, box string, priv ed25519.PrivateKey, ts time.Time) (int, wire.ErrorBody) {
	t.Helper()
	pub := base64.StdEncoding.EncodeToString(priv.Public().(ed25519.PublicKey))
	at := ts.UTC().Format(time.RFC3339)
	p, _ := wire.JoinPayload(tokenHash(tok), box, pub, at)
	raw, _ := json.Marshal(wire.JoinRequest{Token: tok, BoxID: box, PubKey: pub, TS: at, Sig: sign.Sign(priv, p)})
	req, _ := http.NewRequest(http.MethodPost, "http://"+apiLabel+domain+"/v1/pins/join", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	for k, v := range hdr {
		req.Header[k] = v
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	var eb wire.ErrorBody
	json.Unmarshal(body, &eb) //nolint:errcheck
	return resp.StatusCode, eb
}

func newKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	return priv
}

func boxKey(t *testing.T, b *box) ed25519.PrivateKey {
	t.Helper()
	priv, err := sign.LoadPrivate(b.cfg.KeysDir, b.id)
	if err != nil {
		t.Fatal(err)
	}
	return priv
}

func tokenState(t *testing.T, e *env, tid, admin, id string) string {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, joinPath, admin, nil)
	if code != http.StatusOK {
		t.Fatalf("list: %d %v", code, out)
	}
	toks, _ := out["tokens"].([]any)
	for _, x := range toks {
		m := x.(map[string]any)
		if _, leaked := m["token"]; leaked {
			t.Fatalf("list answers a token: %v", m)
		}
		if m["id"] == id {
			return m["state"].(string)
		}
	}
	return ""
}

// AC1 + AC7: mint -> redeem -> GET /v1/pins lists the box, and the hub log of
// the run never carries a token. n = 1 flow. CONTROL: the log captured the
// mint and the redeem lines (an empty log cannot pass), and the box was not
// listed before the redeem.
func TestJoinMintRedeemListsPin(t *testing.T) {
	logs := &lockedBuf{}
	e := joinEnv(t, func(o *hub.Options) { o.Log = zerolog.New(logs) })
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	b := e.box(tid, "box-join", "CLE-31")
	if _, err := e.st.GetPin(context.Background(), tid, b.id); err == nil {
		t.Fatal("CONTROL: box pinned before the redeem")
	}
	tok, out := mintToken(t, e, tid, admin, map[string]any{"label": "laptop"})
	if line, _ := out["join_line"].(string); line != "SPOOL_JOIN_TOKEN="+tok+" spool join http://"+tid+domain {
		t.Fatalf("join_line %q", line)
	}
	exp, err := time.Parse(time.RFC3339Nano, out["expires_at"].(string))
	if err != nil || exp.Sub(time.Now()) < 59*time.Minute || exp.Sub(time.Now()) > time.Hour {
		t.Fatalf("expires_at %v (%v), want about now + 1h", out["expires_at"], err)
	}
	if code, eb := redeem(t, e, nil, tok, b.id, boxKey(t, b), time.Now()); code != http.StatusOK {
		t.Fatalf("redeem: %d %+v", code, eb)
	}
	req, _ := http.NewRequest(http.MethodGet, e.url(tid)+"/v1/pins", nil)
	req.Header.Set("Authorization", "Bearer "+e.uploadToken(tid, b))
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var pl wire.PinList
	json.NewDecoder(resp.Body).Decode(&pl) //nolint:errcheck
	resp.Body.Close()
	if len(pl.Pins) != 1 || pl.Pins[0].BoxID != b.id || pl.Pins[0].PubKey != b.pub {
		t.Fatalf("GET /v1/pins after redeem: %+v", pl)
	}
	if st := tokenState(t, e, tid, admin, out["id"].(string)); st != "used" {
		t.Fatalf("state after redeem %q", st)
	}
	logs.mu.Lock()
	l := logs.b.String()
	logs.mu.Unlock()
	if !strings.Contains(l, "join token minted") || !strings.Contains(l, "join token redeemed") {
		t.Fatalf("CONTROL: the log did not capture the run:\n%s", l)
	}
	if n := strings.Count(l, "spj1."); n != 0 {
		t.Fatalf("AC7: the hub log carries %d join tokens", n)
	}
}

// AC2: a fake clock, the default TTL. Redeem at 61 min -> 410 expired; a
// second redeem of a used token -> 410 used; both name Tenant settings ->
// Agents. A second hub at 5m expires at 5 min. CONTROL: at 59 min (and 4 min)
// the same kind of token redeems. n = 2 lifetimes x (control + refusal).
func TestJoinTokenExpiryAndReuse(t *testing.T) {
	for _, c := range []struct {
		ttl        time.Duration
		ok, expire time.Duration
	}{{0, 59 * time.Minute, 61 * time.Minute}, {5 * time.Minute, 4 * time.Minute, 5 * time.Minute}} {
		var mu sync.Mutex
		now := time.Now()
		clock := func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
		step := func(d time.Duration) { mu.Lock(); now = now.Add(d); mu.Unlock() }
		e := joinEnv(t, func(o *hub.Options) {
			o.Now = clock
			if c.ttl > 0 {
				o.JoinTokenTTL = c.ttl
			}
		})
		tid, _ := e.tenant()
		admin := seat(t, e, tid, rbac.Admin)
		start := clock()
		tokOK, _ := mintToken(t, e, tid, admin, nil)
		tokLate, _ := mintToken(t, e, tid, admin, nil)

		step(c.ok)
		if code, eb := redeem(t, e, nil, tokOK, "box-ok", newKey(t), clock()); code != http.StatusOK {
			t.Fatalf("ttl %v CONTROL at %v: %d %+v", c.ttl, c.ok, code, eb)
		}
		code, eb := redeem(t, e, nil, tokOK, "box-ok", newKey(t), clock())
		if code != http.StatusGone || eb.Error != "join_token_used" || !strings.Contains(eb.Detail, "Tenant settings -> Agents") {
			t.Fatalf("ttl %v second redeem: %d %+v", c.ttl, code, eb)
		}
		step(c.expire - c.ok)
		code, eb = redeem(t, e, nil, tokLate, "box-late", newKey(t), clock())
		want := start.Add(map[bool]time.Duration{true: c.ttl, false: time.Hour}[c.ttl > 0]).UTC().Format(time.RFC3339)
		if code != http.StatusGone || eb.Error != "join_token_expired" || !strings.Contains(eb.Detail, "Tenant settings -> Agents") ||
			!strings.Contains(eb.Detail, "(expired at "+want+")") {
			t.Fatalf("ttl %v redeem at %v: %d %+v (want expired at %s)", c.ttl, c.expire, code, eb, want)
		}
	}
}

// AC3: two concurrent redeems of one token -> one 200, one 410. n = 5 races.
// CONTROL: exactly one box is pinned after each race.
func TestJoinConcurrentRedeemSeatsOne(t *testing.T) {
	e := joinEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	for i := 0; i < 5; i++ {
		tok, _ := mintToken(t, e, tid, admin, nil)
		codes := make([]int, 2)
		var wg sync.WaitGroup
		for j := range codes {
			wg.Add(1)
			go func() {
				defer wg.Done()
				codes[j], _ = redeem(t, e, nil, tok, "box-r"+string(rune('a'+i))+string(rune('0'+j)), newKey(t), time.Now())
			}()
		}
		wg.Wait()
		if codes[0]+codes[1] != http.StatusOK+http.StatusGone {
			t.Fatalf("race %d: %v, want one 200 and one 410", i, codes)
		}
		pins, _ := e.st.ListPins(context.Background(), tid)
		if len(pins) != i+1 {
			t.Fatalf("race %d: %d pins, want %d", i, len(pins), i+1)
		}
	}
}

// AC4: a redeem onto a box id pinned to another key -> 409 pin_conflict and
// the token stays unused; box-wui -> refused. CONTROL: the same token then
// seats a free box id, and the same key again is idempotent (200). n = 1.
func TestJoinPinConflictKeepsToken(t *testing.T) {
	e := joinEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	held := newKey(t)
	e.pinKey(tid, "box-held", held.Public().(ed25519.PublicKey))
	tok, out := mintToken(t, e, tid, admin, nil)
	if code, eb := redeem(t, e, nil, tok, "box-held", newKey(t), time.Now()); code != http.StatusConflict || eb.Error != "pin_conflict" {
		t.Fatalf("redeem onto a held box: %d %+v", code, eb)
	}
	if st := tokenState(t, e, tid, admin, out["id"].(string)); st != "open" {
		t.Fatalf("token after a refused pin: %q, want open", st)
	}
	if code, eb := redeem(t, e, nil, tok, hub.WUIBox, newKey(t), time.Now()); code != http.StatusBadRequest || eb.Error != "reserved_box" {
		t.Fatalf("redeem onto box-wui: %d %+v", code, eb)
	}
	if code, eb := redeem(t, e, nil, tok, "box-free", newKey(t), time.Now()); code != http.StatusOK {
		t.Fatalf("CONTROL: the kept token seats a free box: %d %+v", code, eb)
	}
	tok2, _ := mintToken(t, e, tid, admin, nil)
	if code, eb := redeem(t, e, nil, tok2, "box-held", held, time.Now()); code != http.StatusOK {
		t.Fatalf("CONTROL: the held key again is idempotent: %d %+v", code, eb)
	}
}

// AC5: revoke one of two seats from an admin session -> that box's socket
// closes unpinned_box, the other stays open. n = 1. CONTROL: the other box
// still answers a hello after the revoke.
func TestJoinSeatRevokeClosesOneBox(t *testing.T) {
	e := joinEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	a, b := e.box(tid, "box-a", "CLE-41"), e.box(tid, "box-b", "CLE-42")
	for _, x := range []*box{a, b} {
		tok, _ := mintToken(t, e, tid, admin, nil)
		if code, eb := redeem(t, e, nil, tok, x.id, boxKey(t, x), time.Now()); code != http.StatusOK {
			t.Fatalf("seat %s: %d %+v", x.id, code, eb)
		}
	}
	ctx := context.Background()
	sa, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	sb, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/tenant/agents/pins/box-a", admin, nil); code != http.StatusOK {
		t.Fatalf("seat revoke: %d %v", code, out)
	}
	select {
	case <-sa.Done():
		if sa.CloseCode() != wire.CloseUnauthorized {
			t.Fatalf("revoked seat closed %d, want 4401", sa.CloseCode())
		}
	case <-time.After(3 * time.Second):
		t.Fatal("revoked seat's session stayed open")
	}
	select {
	case <-sb.Done():
		t.Fatal("CONTROL: the other seat's session closed")
	case <-time.After(300 * time.Millisecond):
	}
	if _, err := b.c.Sync(ctx); err != nil {
		t.Fatalf("CONTROL: the other seat no longer says hello: %v", err)
	}
	c, n := e.raw(tid)
	wsjson.Write(ctx, c, helloFrame(a, n, time.Now().UTC().Format(time.RFC3339), wire.RoleCLI)) //nolint:errcheck
	if code, why := closeReason(t, c); code != wire.CloseUnauthorized || why != "unpinned_box" {
		t.Fatalf("hello after seat revoke: %d %q", code, why)
	}
}

// AC6: the token is no credential anywhere but the redeem: on POST /v1/pins,
// DELETE /v1/pins/{id} and the mint route it is refused. n = 3 routes.
// CONTROL: the same token then still redeems.
func TestJoinTokenGrantsNothingElse(t *testing.T) {
	e := joinEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	e.pinKey(tid, "box-x", newKey(t).Public().(ed25519.PublicKey))
	tok, _ := mintToken(t, e, tid, admin, nil)
	do := func(method, path string, body any) int {
		raw, _ := json.Marshal(body)
		req, _ := http.NewRequest(method, e.url(tid)+path, bytes.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+tok)
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	ts := time.Now().UTC().Format(time.RFC3339)
	pub := base64.StdEncoding.EncodeToString(newKey(t).Public().(ed25519.PublicKey))
	if c := do(http.MethodPost, "/v1/pins", wire.PinRequest{BoxID: "box-y", PubKey: pub, TS: ts, Sig: tok}); c == http.StatusOK {
		t.Fatal("a join token pinned through POST /v1/pins")
	}
	if c := do(http.MethodDelete, "/v1/pins/box-x", wire.RevokeRequest{BoxID: "box-x", TS: ts, Sig: tok}); c == http.StatusOK {
		t.Fatal("a join token revoked through DELETE /v1/pins/{box_id}")
	}
	if c := do(http.MethodPost, joinPath, map[string]any{}); c != http.StatusForbidden {
		t.Fatalf("a join token on the mint route: %d, want 403", c)
	}
	if _, err := e.st.GetPin(context.Background(), tid, "box-x"); err != nil {
		t.Fatalf("box-x lost its pin: %v", err)
	}
	if code, eb := redeem(t, e, nil, tok, "box-y", newKey(t), time.Now()); code != http.StatusOK {
		t.Fatalf("CONTROL: the token still redeems: %d %+v", code, eb)
	}
}

// AC10: a biz_owner session (keys.manage, no agents.join) gets 403 naming
// agents.join on mint, list, revoke-token and seat revoke; the admin session
// is allowed on each; the root-key DELETE /v1/pins/{box_id} still succeeds.
// n = 4 routes x 2 roles + 1 root revoke.
func TestJoinRoutesAdminOnly(t *testing.T) {
	e := joinEnv(t)
	tid, root := e.tenant()
	admin, owner := seat(t, e, tid, rbac.Admin), seat(t, e, tid, rbac.BizOwner)
	tok, out := mintToken(t, e, tid, admin, nil)
	id := out["id"].(string)
	e.pinKey(tid, "box-s", newKey(t).Public().(ed25519.PublicKey))
	routes := []struct{ method, path string }{
		{http.MethodPost, joinPath}, {http.MethodGet, joinPath},
		{http.MethodDelete, joinPath + "/" + id}, {http.MethodDelete, "/v1/tenant/agents/pins/box-s"},
	}
	for _, r := range routes {
		code, body := call(t, e, tid, r.method, r.path, owner, map[string]any{})
		if code != http.StatusForbidden || body["permission"] != rbac.AgentsJoin {
			t.Fatalf("biz_owner %s %s: %d %v", r.method, r.path, code, body)
		}
	}
	for _, r := range routes {
		var body any
		if r.method == http.MethodPost {
			body = map[string]any{}
		}
		if code, out := call(t, e, tid, r.method, r.path, admin, body); code >= 300 {
			t.Fatalf("CONTROL: admin %s %s: %d %v", r.method, r.path, code, out)
		}
	}
	if code, eb := redeem(t, e, nil, tok, "box-t", newKey(t), time.Now()); code != http.StatusGone || eb.Error != "join_token_revoked" {
		t.Fatalf("revoked token: %d %+v", code, eb)
	}
	rk := newKey(t)
	if code, eb := e.postPin(tid, root, "box-root", base64.StdEncoding.EncodeToString(rk.Public().(ed25519.PublicKey))); code != http.StatusOK {
		t.Fatalf("root pin: %d %+v", code, eb)
	}
	ts := time.Now().Add(time.Second).UTC().Format(time.RFC3339)
	rp, _ := wire.RevokePayload("box-root", ts)
	raw, _ := json.Marshal(wire.RevokeRequest{BoxID: "box-root", TS: ts, Sig: sign.Sign(root, rp)})
	req, _ := http.NewRequest(http.MethodDelete, e.url(tid)+"/v1/pins/box-root", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	resp, err := e.client.Do(req)
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("root-key revoke: %v %v", err, resp)
	}
	resp.Body.Close()
}

// The rest of the refusal table (spec 4.3): an unknown token 401, a bound
// token on another box id 409, a for_human who is not a member 400, a used
// token cannot be revoked, and the redeem flood 429. n = 1 each. CONTROL for
// each: the bound token seats its own box, a current member is accepted as
// for_human, and the 20 redeems before the flood were answered on their merits.
func TestJoinRefusalTable(t *testing.T) {
	e := joinEnv(t)
	tid, _ := e.tenant()
	admin, dev := seat(t, e, tid, rbac.Admin), seat(t, e, tid, rbac.Developer)
	bogus := "spj1." + tid + "." + base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	if code, eb := redeem(t, e, nil, bogus, "box-u", newKey(t), time.Now()); code != http.StatusUnauthorized || eb.Error != "join_token_invalid" ||
		!strings.Contains(eb.Detail, "Tenant settings -> Agents") {
		t.Fatalf("unknown token: %d %+v", code, eb)
	}
	bound, out := mintToken(t, e, tid, admin, map[string]any{"box_id": "box-bound"})
	if code, eb := redeem(t, e, nil, bound, "box-other", newKey(t), time.Now()); code != http.StatusConflict ||
		eb.Error != "join_token_box_mismatch" || !strings.Contains(eb.Detail, "box-bound only") {
		t.Fatalf("bound token on another box: %d %+v", code, eb)
	}
	if code, eb := redeem(t, e, nil, bound, "box-bound", newKey(t), time.Now()); code != http.StatusOK {
		t.Fatalf("CONTROL: bound token on its box: %d %+v", code, eb)
	}
	if code, body := call(t, e, tid, http.MethodDelete, joinPath+"/"+out["id"].(string), admin, nil); code != http.StatusConflict || body["error"] != "join_token_used" {
		t.Fatalf("revoke a used token: %d %v", code, body)
	}
	if code, body := call(t, e, tid, http.MethodPost, joinPath, admin, map[string]any{"for_human": "HUM-999999"}); code != http.StatusBadRequest ||
		body["error"] != "join_token_member" {
		t.Fatalf("for_human not a member: %d %v", code, body)
	}
	if _, out := mintToken(t, e, tid, admin, map[string]any{"for_human": dev}); out["for_human"] != dev {
		t.Fatalf("CONTROL: for_human a member: %v", out)
	}
	// 3 redeems above; 17 more fill the per-address window of 20.
	for i := 0; i < 17; i++ {
		if code, _ := redeem(t, e, nil, bogus, "box-u", newKey(t), time.Now()); code != http.StatusUnauthorized {
			t.Fatalf("CONTROL: redeem %d inside the window: %d", i+4, code)
		}
	}
	if code, eb := redeem(t, e, nil, bogus, "box-u", newKey(t), time.Now()); code != http.StatusTooManyRequests || eb.Error != "rate_limited" {
		t.Fatalf("redeem 21: %d %+v", code, eb)
	}
}

// Spec 108 (b): the workspace is the one the credential proves; a name for
// another is refused. n = 2: a box with a valid pin in A says hello naming B,
// and a token of A is redeemed naming B. CONTROL: the same hello and the
// same kind of redeem naming A are accepted.
func TestSpec108HeaderPinMismatch(t *testing.T) {
	e := joinEnv(t)
	a, _ := e.tenant()
	b, _ := e.tenant()
	admin := seat(t, e, a, rbac.Admin)
	bx := e.box(a, "box-a", "CLE-51")
	e.pin(a, bx)
	hello := func(named string) (wire.Frame, error) {
		t.Helper()
		c, code := e.dialWS(apiLabel, "/v1/ws", http.Header{hub.TenantHeader: {named}})
		if c == nil {
			t.Fatalf("dial naming %s: %d", named, code)
		}
		defer c.CloseNow()
		ctx := context.Background()
		var ch wire.Frame
		if err := wsjson.Read(ctx, c, &ch); err != nil {
			t.Fatal(err)
		}
		wsjson.Write(ctx, c, helloFrame(bx, ch.Nonce, time.Now().UTC().Format(time.RFC3339), wire.RoleCLI)) //nolint:errcheck
		var f wire.Frame
		return f, wsjson.Read(ctx, c, &f)
	}
	if f, err := hello(b); err == nil || websocket.CloseStatus(err) != wire.CloseUnauthorized {
		t.Fatalf("pin of A, hello naming B: %+v %v", f, err)
	}
	if f, err := hello(a); err != nil || f.Type != wire.TWelcome {
		t.Fatalf("CONTROL: hello naming A: %+v %v", f, err)
	}
	tok, _ := mintToken(t, e, a, admin, nil)
	if code, eb := redeem(t, e, http.Header{hub.TenantHeader: {b}}, tok, "box-j", newKey(t), time.Now()); code != http.StatusForbidden ||
		eb.Error != "tenant_mismatch" {
		t.Fatalf("token of A naming B: %d %+v", code, eb)
	}
	if code, eb := redeem(t, e, http.Header{hub.TenantHeader: {a}}, tok, "box-j", newKey(t), time.Now()); code != http.StatusOK {
		t.Fatalf("CONTROL: token of A naming A: %d %+v", code, eb)
	}
}

// Spec 108 (c): one public key is live in one workspace only. n = 3 keys
// seated in A, each refused in B with pin_conflict whose text never names A.
// CONTROL: a unique key seats in B with a token of the same kind.
func TestSpec108SameKeyOneWorkspace(t *testing.T) {
	e := joinEnv(t)
	a, _ := e.tenant()
	b, _ := e.tenant()
	adminA, adminB := seat(t, e, a, rbac.Admin), seat(t, e, b, rbac.Admin)
	for i := 0; i < 3; i++ {
		k := newKey(t)
		box := "box-k" + string(rune('0'+i))
		tokA, _ := mintToken(t, e, a, adminA, nil)
		if code, eb := redeem(t, e, nil, tokA, box, k, time.Now()); code != http.StatusOK {
			t.Fatalf("key %d into A: %d %+v", i, code, eb)
		}
		tokB, out := mintToken(t, e, b, adminB, nil)
		code, eb := redeem(t, e, nil, tokB, box, k, time.Now())
		if code != http.StatusConflict || eb.Error != "pin_conflict" || strings.Contains(eb.Detail, a) {
			t.Fatalf("key %d into B: %d %+v", i, code, eb)
		}
		if st := tokenState(t, e, b, adminB, out["id"].(string)); st != "open" {
			t.Fatalf("key %d: B's token after the refusal %q, want open", i, st)
		}
		if code, eb := redeem(t, e, nil, tokB, box, newKey(t), time.Now()); code != http.StatusOK {
			t.Fatalf("CONTROL %d: a unique key into B: %d %+v", i, code, eb)
		}
	}
	if pins, _ := e.st.ListPins(context.Background(), b); len(pins) != 3 {
		t.Fatalf("B holds %d pins, want 3", len(pins))
	}
	var _ store.JoinTokens = e.st.(store.JoinTokens)
}
