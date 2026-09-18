package hub_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

const wuiOrigin = "http://wui.test"

func viewGet(t *testing.T, e *env, tenant, path string, hdr ...string) (int, http.Header, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, e.url(tenant)+path, nil)
	for i := 0; i+1 < len(hdr); i += 2 {
		req.Header.Set(hdr[i], hdr[i+1])
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("GET %s: %v", path, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, body
}

func errToken(b []byte) string {
	var eb wire.ErrorBody
	json.Unmarshal(b, &eb) //nolint:errcheck
	return eb.Error
}

type threadsResp struct {
	Threads []struct {
		TaskID       string         `json:"task_id"`
		Count        int            `json:"count"`
		Kinds        map[string]int `json:"kinds"`
		Participants []string       `json:"participants"`
		Subject      string         `json:"subject"`
	} `json:"threads"`
	Next *string `json:"next"`
}

type threadResp struct {
	TaskID   string `json:"task_id"`
	Messages []struct {
		Cursor     string          `json:"cursor"`
		Env        json.RawMessage `json:"env"`
		Deliveries []struct {
			ToBox string `json:"to_box"`
			State string `json:"state"`
		} `json:"deliveries"`
	} `json:"messages"`
	Next *string `json:"next"`
}

// US7 (contracts/view-v1.md): roster, threads, one thread, paging, reads
// that change nothing, tenant scoping, 405, CORS allow-list.
func TestViewAPI(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.ViewCORSOrigins = []string{wuiOrigin}
	})
	tid, _ := e.tenant()
	other, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	if _, err := b.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := a.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	out := send(t, a, "GRK-03", "CLE-07", "task", "please review\nthe diff", "")
	if out.Delivery != wire.DeliveryQueued {
		t.Fatalf("delivery %q", out.Delivery)
	}

	// Roster: both pinned, nobody holds a role=box socket.
	code, _, body := viewGet(t, e, tid, "/v1/view/roster")
	var roster struct {
		Boxes []struct {
			BoxID  string   `json:"box_id"`
			Online bool     `json:"online"`
			Agents []string `json:"agents"`
		} `json:"boxes"`
	}
	json.Unmarshal(body, &roster) //nolint:errcheck
	if code != 200 || len(roster.Boxes) != 2 || roster.Boxes[1].BoxID != "box-b" || roster.Boxes[1].Online ||
		len(roster.Boxes[1].Agents) != 1 {
		t.Fatalf("roster %d %s", code, body)
	}
	c, n := e.raw(tid)
	h := helloFrame(a, n, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
	h.Agents = []string{"GRK-03"}
	wsjson.Write(ctx, c, h) //nolint:errcheck
	var wel wire.Frame
	if err := wsjson.Read(ctx, c, &wel); err != nil || wel.Type != wire.TWelcome {
		t.Fatalf("welcome %v %+v", err, wel)
	}
	defer c.CloseNow() //nolint:errcheck
	_, _, body = viewGet(t, e, tid, "/v1/view/roster")
	json.Unmarshal(body, &roster) //nolint:errcheck
	if !roster.Boxes[0].Online {
		t.Fatalf("box-a with a live role=box socket not online: %s", body)
	}

	// Threads list.
	code, _, body = viewGet(t, e, tid, "/v1/view/threads")
	var th threadsResp
	json.Unmarshal(body, &th) //nolint:errcheck
	if code != 200 || len(th.Threads) != 1 || th.Threads[0].TaskID != out.TaskID || th.Threads[0].Count != 1 ||
		th.Threads[0].Kinds["task"] != 1 || th.Threads[0].Subject != "please review" || len(th.Threads[0].Participants) != 2 || th.Next != nil {
		t.Fatalf("threads %d %s", code, body)
	}

	// One thread: the stored envelope byte-for-byte, delivery queued.
	code, _, body = viewGet(t, e, tid, "/v1/view/threads/"+out.TaskID)
	var one threadResp
	json.Unmarshal(body, &one) //nolint:errcheck
	stored, _ := e.st.TaskEnvelopes(ctx, tid, out.TaskID)
	if code != 200 || len(one.Messages) != 1 || string(one.Messages[0].Env) != string(stored[0]) ||
		len(one.Messages[0].Deliveries) != 1 || one.Messages[0].Deliveries[0].State != store.StateQueued {
		t.Fatalf("thread %d %s", code, body)
	}

	// US7-1: the reads changed nothing; box-b still drains its queued message.
	if st, _ := e.st.DeliveryState(ctx, tid, out.MsgID, "box-b"); st != store.StateQueued {
		t.Fatalf("state after reads %q", st)
	}
	if r, err := b.c.Sync(ctx); err != nil || r.Delivered != 1 {
		t.Fatalf("drain after reads: %+v %v", r, err)
	}
	_, _, body = viewGet(t, e, tid, "/v1/view/threads/"+out.TaskID)
	json.Unmarshal(body, &one) //nolint:errcheck
	if one.Messages[0].Deliveries[0].State != store.StateSent {
		t.Fatalf("after drain: %s", body)
	}

	// Paging: a second thread (the reply starts its own task), limit=1 / before=next;
	// polling one thread with after=<its last cursor> returns nothing new.
	send(t, b, "CLE-07", "GRK-03", "result", "done", "box-a")
	_, _, body = viewGet(t, e, tid, "/v1/view/threads/"+out.TaskID+"?after="+one.Messages[0].Cursor)
	var tail threadResp
	json.Unmarshal(body, &tail) //nolint:errcheck
	if len(tail.Messages) != 0 || tail.Next != nil {
		t.Fatalf("after last cursor: %s", body)
	}
	_, _, body = viewGet(t, e, tid, "/v1/view/threads?limit=1")
	var p1 threadsResp
	json.Unmarshal(body, &p1) //nolint:errcheck
	if len(p1.Threads) != 1 || p1.Next == nil {
		t.Fatalf("page 1: %s", body)
	}
	_, _, body = viewGet(t, e, tid, "/v1/view/threads?limit=1&before="+*p1.Next)
	var p2 threadsResp
	json.Unmarshal(body, &p2) //nolint:errcheck
	if len(p2.Threads) != 1 || p2.Threads[0].TaskID == p1.Threads[0].TaskID || p2.Next != nil {
		t.Fatalf("page 2: %s", body)
	}
	if code, _, body = viewGet(t, e, tid, "/v1/view/threads?before=AAAA"); code != 400 || errToken(body) != "bad_cursor" {
		t.Fatalf("bad cursor: %d %s", code, body)
	}

	// US7-3: another tenant's Host cannot see the thread; unknown host 404s.
	if code, _, body = viewGet(t, e, other, "/v1/view/threads/"+out.TaskID); code != 404 || errToken(body) != "not_found" {
		t.Fatalf("cross-tenant: %d %s", code, body)
	}
	if code, _, body = viewGet(t, e, "nosuch", "/v1/view/threads"); code != 404 || errToken(body) != "unknown_tenant" {
		t.Fatalf("unknown tenant: %d %s", code, body)
	}
	if code, _, _ = viewGet(t, e, tid, "/v1/view/threads/not-a-uuid"); code != 404 {
		t.Fatalf("non-uuid task: %d", code)
	}

	// US7-4: read-only.
	resp, _ := e.client.Post(e.url(tid)+"/v1/view/threads", "application/json", strings.NewReader(`{}`))
	resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("POST: %d", resp.StatusCode)
	}

	// US7-5 / FR-021: CORS only for listed origins, only on view + file GET.
	_, hd, _ := viewGet(t, e, tid, "/v1/view/threads", "Origin", wuiOrigin)
	if hd.Get("Access-Control-Allow-Origin") != wuiOrigin || hd.Get("Access-Control-Allow-Credentials") != "" {
		t.Fatalf("listed origin headers: %v", hd)
	}
	if _, hd, _ = viewGet(t, e, tid, "/v1/view/threads", "Origin", "http://evil.test"); hd.Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("unlisted origin got CORS: %v", hd)
	}
	if _, hd, _ = viewGet(t, e, tid, "/v1/pins", "Origin", wuiOrigin); hd.Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("/v1/pins answered CORS: %v", hd)
	}
	pre, _ := http.NewRequest(http.MethodOptions, e.url(tid)+"/v1/view/threads", nil)
	pre.Header.Set("Origin", wuiOrigin)
	pre.Header.Set("Access-Control-Request-Method", "GET")
	resp, err := e.client.Do(pre)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent || resp.Header.Get("Access-Control-Allow-Headers") != "Authorization" {
		t.Fatalf("preflight: %d %v", resp.StatusCode, resp.Header)
	}
}

// FR-020: the default token door admits nobody until OQ-16 fixes the format.
func TestViewDoorTokenFailsClosed(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	for _, p := range []string{"/v1/view/roster", "/v1/view/threads", "/v1/view/channels"} {
		code, _, body := viewGet(t, e, tid, p, "Authorization", "Bearer anything")
		if code != http.StatusUnauthorized || errToken(body) != "view_door" {
			t.Fatalf("%s: %d %s", p, code, body)
		}
	}
}

// Spec 010 T010: the auth routes are mounted and answer on any Host, with no
// tenant resolution (the callback host is the WUI origin via a rewrite).
func TestAuthMountedWithoutTenant(t *testing.T) {
	ac, err := auth.LoadFrom("lde", map[string]string{})
	if err != nil {
		t.Fatal(err)
	}
	e := newEnv(t, func(o *hub.Options) { o.Auth = auth.New(ac, zerolog.Nop(), auth.Options{}) })
	code, _, body := viewGet(t, e, "nosuch", "/api/v1/auth/providers")
	if code != http.StatusOK || !strings.Contains(string(body), `"providers":[]`) {
		t.Fatalf("providers on an unknown tenant host: %d %s", code, body)
	}
}

// With auth mounted but no membership check (today's default) a session door
// still refuses: every view read is 401 view_door (010 SEC-001, OQ-A1 gate).
func TestViewSessionDoorFailsClosedWithoutMembership(t *testing.T) {
	ac, err := auth.LoadFrom("lde", map[string]string{})
	if err != nil {
		t.Fatal(err)
	}
	e := newEnv(t, func(o *hub.Options) { o.Auth = auth.New(ac, zerolog.Nop(), auth.Options{}) })
	tid, _ := e.tenant()
	code, _, body := viewGet(t, e, tid, "/v1/view/threads", "Cookie", "spool_session=forged")
	if code != http.StatusUnauthorized || errToken(body) != "view_door" {
		t.Fatalf("session door without membership: %d %s", code, body)
	}
}

// The access log never carries Cookie, Authorization or query strings (010
// OQ-A4: a prd session cookie can reach dev hosts; it must not reach a log).
func TestAccessLogCarriesNoCredentials(t *testing.T) {
	var buf strings.Builder
	var mu = new(sync.Mutex)
	w := zerolog.SyncWriter(writerFunc(func(p []byte) (int, error) { mu.Lock(); defer mu.Unlock(); return buf.WriteString(string(p)) }))
	e := newEnv(t, func(o *hub.Options) { o.Log = zerolog.New(w) })
	tid, _ := e.tenant()
	viewGet(t, e, tid, "/v1/view/threads?before=SECRET-QUERY", "Cookie", "spool_session=SECRET-COOKIE", "Authorization", "Bearer SECRET-TOKEN")
	viewGet(t, e, tid, "/v1/pins", "Cookie", "spool_session_dev=SECRET-COOKIE", "Authorization", "Bearer SECRET-TOKEN")
	mu.Lock()
	logged := buf.String()
	mu.Unlock()
	if !strings.Contains(logged, `"path":"/v1/view/threads"`) {
		t.Fatalf("access log line missing: %s", logged)
	}
	for _, secret := range []string{"SECRET-COOKIE", "SECRET-TOKEN", "SECRET-QUERY"} {
		if strings.Contains(logged, secret) {
			t.Fatalf("%s reached the log: %s", secret, logged)
		}
	}
}

type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(p []byte) (int, error) { return f(p) }
