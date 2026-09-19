package hub_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
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
	if resp.StatusCode != http.StatusNoContent || resp.Header.Get("Access-Control-Allow-Headers") != "Authorization, X-Locale" {
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

// GET / is a public hello on any Host (ORC goal 2026-09-18); other unknown
// paths still 404.
func TestRootHello(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.Env = "dev" })
	for _, host := range []string{"nosuch", "t1"} {
		code, hd, body := viewGet(t, e, host, "/")
		if code != http.StatusOK || string(body) != "spool-hub dev ok\n" || !strings.HasPrefix(hd.Get("Content-Type"), "text/plain") {
			t.Fatalf("GET / on %s: %d %q %v", host, code, body, hd)
		}
	}
	if code, _, _ := viewGet(t, e, "t1", "/nope"); code != http.StatusNotFound {
		t.Fatalf("GET /nope: %d", code)
	}
}

// T037: GET /version is public JSON {version, commit, built_at} on any Host.
func TestVersionBody(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.Commit, o.BuiltAt = "abc123", "2026-09-18T19:45:00Z" })
	code, _, body := viewGet(t, e, "nosuch", "/version")
	var v map[string]string
	if err := json.Unmarshal(body, &v); err != nil || code != 200 ||
		v["version"] != "test" || v["commit"] != "abc123" || v["built_at"] != "2026-09-18T19:45:00Z" {
		t.Fatalf("/version: %d %s", code, body)
	}
}

// Reserved labels (api, www, dev; msg.ValidTenantID) are never a tenant: the
// API host serves the non-tenant routes, and a tenant-scoped route there
// needs a credential that names the tenant (specs/026: 401 without one).
func TestReservedHostIsAPIHostNotTenant(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.Env = "dev" })
	for _, host := range []string{"api", "www", "dev", "dev.api", "api.dev"} {
		for _, p := range []string{"/", "/version", "/v1/health", "/healthz"} {
			if code, _, _ := viewGet(t, e, host, p); code != http.StatusOK {
				t.Fatalf("%s%s: %d, want 200", host, p, code)
			}
		}
		for _, p := range []string{"/v1/pins", "/v1/view/threads", "/v1/files/" + strings.Repeat("0", 64)} {
			if code, _, body := viewGet(t, e, host, p); code != http.StatusUnauthorized {
				t.Fatalf("%s%s: %d %s, want 401", host, p, code, body)
			}
		}
	}
}

// Chat-reverse windows (view-v1 §4.4): order=desc returns the newest N first,
// next pages strictly older; after/before are each tied to one order.
func TestViewThreadDescWindows(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff })
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	b.c.Sync(ctx) //nolint:errcheck
	a.c.Sync(ctx) //nolint:errcheck
	first := send(t, a, "GRK-03", "CLE-07", "task", "m1", "")
	for _, body := range []string{"m2", "m3", "m4", "m5"} {
		out, err := action.SendCtx(ctx, a.cfg, action.SendArgs{From: "GRK-03", To: "CLE-07", Kind: "note", Body: body, TaskID: first.TaskID, Hub: a.c})
		if err != nil || out.TaskID != first.TaskID {
			t.Fatalf("send %s: %v %+v", body, err, out)
		}
	}
	bodies := func(tr threadResp) []string {
		var out []string
		for _, m := range tr.Messages {
			var env struct {
				Msg struct {
					Body string `json:"body"`
				} `json:"msg"`
			}
			json.Unmarshal(m.Env, &env) //nolint:errcheck
			out = append(out, env.Msg.Body)
		}
		return out
	}
	base := "/v1/view/threads/" + first.TaskID
	var p1, p2, p3 threadResp
	_, _, body := viewGet(t, e, tid, base+"?order=desc&limit=2")
	json.Unmarshal(body, &p1) //nolint:errcheck
	if got := strings.Join(bodies(p1), ","); got != "m5,m4" || p1.Next == nil {
		t.Fatalf("window 1: %s %s", got, body)
	}
	_, _, body = viewGet(t, e, tid, base+"?order=desc&limit=2&before="+*p1.Next)
	json.Unmarshal(body, &p2) //nolint:errcheck
	if got := strings.Join(bodies(p2), ","); got != "m3,m2" || p2.Next == nil {
		t.Fatalf("window 2: %s %s", got, body)
	}
	_, _, body = viewGet(t, e, tid, base+"?order=desc&limit=2&before="+*p2.Next)
	json.Unmarshal(body, &p3) //nolint:errcheck
	if got := strings.Join(bodies(p3), ","); got != "m1" || p3.Next != nil {
		t.Fatalf("window 3: %s %s", got, body)
	}
	for _, bad := range []string{"?order=desc&after=" + *p1.Next, "?before=" + *p1.Next, "?order=sideways"} {
		if code, _, b := viewGet(t, e, tid, base+bad); code != http.StatusBadRequest {
			t.Fatalf("%s: %d %s", bad, code, b)
		}
	}
	// asc + after unchanged
	_, _, body = viewGet(t, e, tid, base+"?limit=10")
	var asc threadResp
	json.Unmarshal(body, &asc) //nolint:errcheck
	if got := strings.Join(bodies(asc), ","); got != "m1,m2,m3,m4,m5" {
		t.Fatalf("asc: %s", got)
	}
}

// A5 (view-v1 §4.1, 010 T044): the roster lists the tenant's member HUM-*
// with the IdP picture the sign-in stored, and the WUI loads it with GET
// /v1/files/{id} on the same tenant host under the view CORS allow-list.
// CONTROLS: a human with no picture is null; tenant B's human never appears
// in A's roster, and B's avatar file_id is 404 through A's host; a signed-in
// A member is refused B's roster (the only place B's file_id is listed).
func TestViewRosterHumanAvatar(t *testing.T) {
	r := newDoorRig(t)
	mine, _ := r.e.tenant()
	theirs, _ := r.e.tenant()
	ctx := context.Background()
	h := r.e.st.(store.Humans)

	// B's owner: a picture stored under B only.
	bob, err := h.Admit(ctx, store.Identity{Provider: "google", Subject: "bob-sub"}, theirs, store.AdmitPolicy{BootstrapOwner: true}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	bobPic := fakeidp.Avatar("bob-sub")
	bobFID := sha256Hex(bobPic)
	if err := (blob.Dir{Root: r.e.blobs}).Put(ctx, "t/"+theirs+"/files/"+bobFID, bobPic); err != nil {
		t.Fatal(err)
	}
	if err := h.SetAvatar(ctx, bob, bobFID); err != nil {
		t.Fatal(err)
	}
	// A: alice signs in through the fake IdP (bootstrap owner, picture fetched).
	if landed := r.signIn(t, mine); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in landed on %s", landed)
	}
	// A second member of A without a picture.
	if err := h.PutInvite(ctx, store.Invite{TenantID: mine, Email: "carol@example.com", Role: store.RoleDefault,
		InvitedBy: store.AdmittedOperator, ExpiresAt: time.Now().Add(time.Hour)}, time.Now()); err != nil {
		t.Fatal(err)
	}
	carol, err := h.Admit(ctx, store.Identity{Provider: "google", Subject: "carol-sub", Email: "carol@example.com"}, mine, store.AdmitPolicy{}, time.Now())
	if err != nil {
		t.Fatal(err)
	}

	code, hdr, body := r.get(t, mine, "/v1/view/roster")
	var roster struct {
		Humans []struct {
			HumanID      string  `json:"human_id"`
			AvatarFileID *string `json:"avatar_file_id"`
		} `json:"humans"`
	}
	if err := json.Unmarshal([]byte(body), &roster); err != nil || code != http.StatusOK || hdr.Get("Access-Control-Allow-Origin") != wuiOrigin {
		t.Fatalf("roster %d %v %s", code, hdr, body)
	}
	byID := map[string]*string{}
	for _, x := range roster.Humans {
		byID[x.HumanID] = x.AvatarFileID
	}
	alice := r.session(t).HumanID
	if len(byID) != 2 || byID[alice] == nil || byID[carol] != nil {
		t.Fatalf("roster humans %s (alice %s, carol %s)", body, alice, carol)
	}
	if _, listed := byID[bob]; listed {
		t.Fatalf("tenant B's human in A's roster: %s", body)
	}
	fid := *byID[alice]
	code, hdr, pic := r.get(t, mine, "/v1/files/"+fid)
	if code != http.StatusOK || pic != string(fakeidp.Avatar("alice-sub")) || hdr.Get("Access-Control-Allow-Origin") != wuiOrigin {
		t.Fatalf("avatar GET %d %v (%d bytes)", code, hdr, len(pic))
	}
	// CONTROL: B's avatar through A's host is 404; B's roster refuses alice.
	if code, _, body := r.get(t, mine, "/v1/files/"+bobFID); code != http.StatusNotFound {
		t.Fatalf("tenant B's avatar via tenant A: %d %s", code, body)
	}
	if code, _, body := r.get(t, theirs, "/v1/view/roster"); code != http.StatusForbidden || errToken([]byte(body)) != "tenant_mismatch" {
		t.Fatalf("B's roster to an A member: %d %s", code, body)
	}
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
