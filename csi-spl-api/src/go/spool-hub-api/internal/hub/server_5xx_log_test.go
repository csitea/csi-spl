package hub_test

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// errStoreDown is the cause the failing store answers with; the ERROR line
// must carry the site that answered, never only "internal".
var errStoreDown = errors.New("store down (test)")

// pinsDown fails the three pin store calls once armed, so GET, POST and
// DELETE /v1/pins each answer 500 from a store error.
type pinsDown struct {
	store.Store
	armed atomic.Bool
}

func (p *pinsDown) ListPins(ctx context.Context, tenant string) ([]store.Pin, error) {
	if p.armed.Load() {
		return nil, errStoreDown
	}
	return p.Store.ListPins(ctx, tenant)
}

func (p *pinsDown) PutPin(ctx context.Context, tenant, box string, pub ed25519.PublicKey, force bool, opTS, now time.Time) error {
	if p.armed.Load() {
		return errStoreDown
	}
	return p.Store.PutPin(ctx, tenant, box, pub, force, opTS, now)
}

func (p *pinsDown) RevokePin(ctx context.Context, tenant, box string, opTS, now time.Time) error {
	if p.armed.Load() {
		return errStoreDown
	}
	return p.Store.RevokePin(ctx, tenant, box, opTS, now)
}

// lockedBuf is the hub log; the access log writes from the server goroutine.
type lockedBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuf) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuf) lines(t *testing.T) []map[string]any {
	t.Helper()
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []map[string]any
	sc := bufio.NewScanner(bytes.NewReader(l.b.Bytes()))
	sc.Buffer(make([]byte, 0, 64<<10), 1<<20)
	for sc.Scan() {
		var m map[string]any
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			t.Fatalf("log line is not JSON: %v %s", err, sc.Bytes())
		}
		out = append(out, m)
	}
	return out
}

// Availability plan R05: a 500 leaves ONE ERROR line with the request id,
// method, route and the site that answered - forced by a store error on
// three routes - and a 4xx leaves none. The line keeps the access log's
// redaction: no query string, no bearer token.
func TestServerErrorLeavesOneErrorLineWithRequestID(t *testing.T) {
	var down *pinsDown
	logs := &lockedBuf{}
	e := newEnv(t, func(o *hub.Options) {
		down = &pinsDown{Store: o.Store}
		o.Store = down
		o.Log = zerolog.New(logs)
	})
	tid, root := e.tenant()
	a := e.box(tid, "box-a", "CLE-07")
	e.pin(tid, a)
	tok := e.uploadToken(tid, a)
	down.armed.Store(true)

	const secret = "q-secret-r05"
	do := func(rid, method, path string, body any, bearer string) int {
		t.Helper()
		var req *http.Request
		if body != nil {
			rd, _ := jsonBody(body)
			req, _ = http.NewRequest(method, e.url(tid)+path, rd)
			req.Header.Set("Content-Type", "application/json")
		} else {
			req, _ = http.NewRequest(method, e.url(tid)+path, nil)
		}
		req.Header.Set("X-Request-ID", rid)
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}

	ts := time.Now().UTC().Format(time.RFC3339)
	pp, _ := wire.PinPayload("box-b", a.pub, ts, false)
	rp, _ := wire.RevokePayload("box-a", ts)
	cases := []struct {
		rid, method, path, route string
		body                     any
		bearer                   string
	}{
		{"r05-list", http.MethodGet, "/v1/pins?x=" + secret, "GET /v1/pins", nil, tok},
		{"r05-pin", http.MethodPost, "/v1/pins", "POST /v1/pins",
			wire.PinRequest{BoxID: "box-b", PubKey: a.pub, TS: ts, Sig: sign.Sign(root, pp)}, ""},
		{"r05-revoke", http.MethodDelete, "/v1/pins/box-a", "DELETE /v1/pins/{box_id}",
			wire.RevokeRequest{BoxID: "box-a", TS: ts, Sig: sign.Sign(root, rp)}, ""},
	}
	for _, c := range cases {
		if code := do(c.rid, c.method, c.path, c.body, c.bearer); code != http.StatusInternalServerError {
			t.Fatalf("%s %s: want 500 from the failing store, got %d", c.method, c.path, code)
		}
	}
	if code := do("r05-4xx", http.MethodPost, "/v1/pins", map[string]int{"box_id": 1}, ""); code != http.StatusBadRequest {
		t.Fatalf("bad pin body: want 400, got %d", code)
	}

	lines := logs.lines(t)
	errs := map[string][]map[string]any{}
	for _, l := range lines {
		if l["level"] == "error" {
			rid, _ := l["request_id"].(string)
			errs[rid] = append(errs[rid], l)
		}
	}
	found := 0
	for _, c := range cases {
		got := errs[c.rid]
		if len(got) != 1 {
			t.Fatalf("%s: want 1 ERROR line with request_id %q, got %d (%v)", c.route, c.rid, len(got), got)
		}
		l := got[0]
		if l["method"] != c.method || l["route"] != c.route || l["status"] != float64(500) || l["token"] != "internal" {
			t.Fatalf("%s: ERROR line lacks method/route/status/token: %v", c.route, l)
		}
		if site, _ := l["site"].(string); !strings.HasPrefix(site, "rest.go:") {
			t.Fatalf("%s: ERROR line site is not the answering handler line: %v", c.route, l)
		}
		found++
	}
	if found != 3 {
		t.Fatalf("want 3 ERROR lines, found %d", found)
	}
	if len(errs["r05-4xx"]) != 0 {
		t.Fatalf("a 400 left an ERROR line: %v", errs["r05-4xx"])
	}
	for _, l := range lines {
		raw, _ := json.Marshal(l)
		if strings.Contains(string(raw), secret) || strings.Contains(string(raw), tok) {
			t.Fatalf("a log line carries the query string or the bearer token: %s", raw)
		}
	}
}
