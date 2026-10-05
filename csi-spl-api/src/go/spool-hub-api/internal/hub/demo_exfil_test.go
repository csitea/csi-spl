package hub_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
	"github.com/csitea/csi-spl/spool-hub-api/internal/edge"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/077 T015, the exfiltration control (spec 3.8): a demo_user signed in
// through the real session door walks EVERY read route the hub registers
// (read from its source, not hand-listed) on the demo host, the api host and
// workspace B's host, with every path value naming B's rows and B named in
// the query and the X-Spool-Tenant header. B holds a topic, a message, a
// file, a channel, an issue, a workspace doc and members, each carrying a
// marker; no answer carries any of them. The visitor also holds a stray
// demo_user seat IN B, the strongest case: only the 077 fence (demoFenced)
// stands between that seat and B's rows.

// exfilB is crossB plus the rows a demo session could reach besides a topic.
type exfilB struct {
	crossB
	issueRef, doc, email string
	chanTask, chanMsg    string // a channel topic: what B's members all read
}

func seedExfilB(t *testing.T, e *env, docs *hub.WorkspaceDocs) exfilB {
	t.Helper()
	ctx := context.Background()
	b := exfilB{crossB: seedCrossB(t, e)}
	is, err := e.st.(store.Issues).CreateIssue(ctx, store.Issue{TenantID: b.tenant, Title: "issue " + b.marker,
		Description: "body " + b.marker, TaskID: uuidV4(), CreatedBy: b.owner}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	b.issueRef = is.Key()
	b.chanTask, b.chanMsg = putChannelFile(t, e, b.tenant, b.owner, "channel "+b.marker, b.fileID)
	b.doc = "bdoc" + strings.TrimPrefix(b.tenant, "t") + ".md"
	st, err := docs.Store(ctx, b.tenant)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.PutReader(ctx, b.doc, strings.NewReader("doc of "+b.marker)); err != nil {
		t.Fatal(err)
	}
	b.email = "bmember" + strings.TrimPrefix(b.tenant, "t") + "@example.com"
	invite(t, e, b.tenant, b.email, rbac.Developer)
	admit(t, e, b.tenant, b.email)
	return b
}

// putChannelFile posts body with fileID attached as from in tenant's
// lobby, a public channel: a topic every member reads: its task and msg ids.
func putChannelFile(t *testing.T, e *env, tenant, from, body, fileID string) (string, string) {
	t.Helper()
	task, id, at := uuidV4(), uuidV4(), time.Now().UTC()
	files := `[{"mode":"blob","kind":"file","file_id":"` + fileID + `","name":"b.txt","bytes":1}]`
	inner := `{"v":1,"msg_id":"` + id + `","task_id":"` + task + `","from":"` + from + `","to":"` + from +
		`","kind":"note","body":"` + body + `","files":` + files + `}`
	m := store.Message{TenantID: tenant, MsgID: id, TaskID: task, Channel: store.ChannelLobby, TS: at, FromBox: "box-wui",
		FromID: from, ToBox: "box-wui", ToID: from, Kind: "note", Body: body, Files: []byte(files), Msg: []byte(inner),
		Env:        []byte(`{"from_box":"box-wui","to_box":"box-wui","channel":"` + store.ChannelLobby + `","msg":` + inner + `,"sig":""}`),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
	if _, err := e.st.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
	return task, id
}

func invite(t *testing.T, e *env, tid, email, role string) {
	t.Helper()
	now := time.Now()
	if err := e.st.(store.Humans).PutInvite(context.Background(), store.Invite{TenantID: tid, Email: email, Role: role,
		InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
}

// admit takes the invite of email to tid, as the identity s-<email>.
func admit(t *testing.T, e *env, tid, email string) {
	t.Helper()
	if _, err := e.st.(store.Humans).Admit(context.Background(), store.Identity{Provider: "google", Subject: "s-" + email,
		Email: email}, tid, store.AdmitPolicy{}, time.Now()); err != nil {
		t.Fatal(err)
	}
}

// authSessionGap is the one answer allowed to name B's tenant id: the auth
// session lists every membership, the visitor's fenced demo seat in B
// included, and the tenant switch accepts it (internal/auth, outside this
// lane: reported to the orchestrator under specs/077 T015). Every hub read
// after that switch is still refused, and the session carries none of B's
// rows: its markers are still checked.
const authSessionGap = "GET /api/v1/auth/session"

// leak is the first of B's strings in body, "" when none. With cut, what
// the request itself named is cut out first: the search query's echo before
// the content markers (each holds B's tenant id, so a wider cut would erase
// them), then B's ids (an error names the id it refused).
func (b exfilB) leak(body string, cut bool) string {
	if cut {
		for _, q := range []string{`"query":"` + b.marker + `"`, `"query":"in:` + b.channel + ` plan"`} {
			body = strings.ReplaceAll(body, q, "<echo>")
		}
	}
	for _, s := range []string{b.marker, b.email} {
		if strings.Contains(body, s) {
			return s
		}
	}
	ids := []string{b.tenant, b.taskID, b.msgID, b.chanTask, b.chanMsg, b.fileID, b.channel, b.owner, b.doc,
		"box-b1", "box-b2", "CLE-31", "CLE-32"}
	if cut {
		for _, e := range append(ids[1:9:9], b.issueRef, b.taskID[:8], b.chanTask[:8]) {
			body = strings.ReplaceAll(body, e, "<echo>")
		}
	}
	for _, s := range ids {
		if strings.Contains(body, s) {
			return s
		}
	}
	return ""
}

var readRouteRe = regexp.MustCompile(`HandleFunc\("(GET [^"]*)"((?:\+(?:[\w.]+|"[^"]*"))*)`)

// routeConsts resolves the constants a route pattern is built from.
var routeConsts = map[string]string{"eventsPrefix": "/api/v1/auth/events", "keysPrefix": "/api/v1/auth/keys",
	"edge.PathProbe": edge.PathProbe, "edge.PathProbeAuth": edge.PathProbeAuth, "RoutePrefix": auth.RoutePrefix,
	"ProviderFacebook": auth.ProviderFacebook}

// signInFlow is the sign-in itself, not a read: walking it would sign the
// browser in again (T007 and T008 test it).
var signInFlow = map[string]bool{"GET /api/v1/auth/{provider}/start": true, "GET /api/v1/auth/{provider}/callback": true}

// readRoutes is every GET route on the hub's mux, read from the source of
// the hub and of the auth handler it mounts, constants resolved, plus the
// two POST reads a demo_user may call.
func readRoutes(t *testing.T) []string {
	t.Helper()
	seen := map[string]bool{"POST /v1/view/ids": true, "POST /v1/view/previews": true}
	for _, dir := range []string{".", "../auth"} {
		files, _ := os.ReadDir(dir)
		for _, f := range files {
			n := f.Name()
			if !strings.HasSuffix(n, ".go") || strings.HasSuffix(n, "_test.go") {
				continue
			}
			src, err := os.ReadFile(dir + "/" + n)
			if err != nil {
				t.Fatal(err)
			}
			for _, m := range readRouteRe.FindAllStringSubmatch(string(src), -1) {
				seen[m[1]+resolveRoute(t, n, m[2])] = true
			}
		}
	}
	out := make([]string, 0, len(seen))
	for r := range seen {
		if !signInFlow[r] {
			out = append(out, r)
		}
	}
	sort.Strings(out)
	if len(out) < 50 || !seen["GET /api/v1/auth/session"] {
		t.Fatalf("found only %d read routes: the source scan is broken", len(out))
	}
	return out
}

// resolveRoute is a pattern's tail (+Const+"lit"...) as a string.
func resolveRoute(t *testing.T, file, tail string) string {
	t.Helper()
	var out strings.Builder
	for _, part := range strings.Split(tail, "+")[1:] {
		if lit, ok := strings.CutPrefix(part, `"`); ok {
			out.WriteString(strings.TrimSuffix(lit, `"`))
			continue
		}
		v, ok := routeConsts[part]
		if !ok {
			t.Fatalf("%s: unknown route constant %s", file, part)
		}
		out.WriteString(v)
	}
	return out.String()
}

// exfilReq is one request of the walk: the route it walks, the filled path
// with its query, and the body of a POST read.
type exfilReq struct {
	route, method, path, body string
}

// requests fills every route with B's ids, once per id of B's a path value
// may name, each path bare and with B in the query; a POST read asks B's
// full ids and their 8-hex starts.
func (b exfilB) requests(routes []string) []exfilReq {
	vals := map[string][]string{"{msg_id}": {b.msgID, b.chanMsg}, "{task_id}": {b.taskID, b.chanTask},
		"{id}": {b.taskID, b.msgID, b.chanTask, b.tenant}, "{file_id}": {b.fileID}, "{channel}": {b.channel, store.ChannelLobby},
		"{human_id}": {b.owner}, "{ref}": {b.issueRef}, "{path...}": {b.doc, hub.DocsIndex}, "{box}": {"box-b1"},
		"{box_id}": {"box-b1"}, "{$}": {""}}
	full := []string{b.taskID, b.msgID, b.chanTask, b.chanMsg}
	bodies := []string{`{"ids":["` + strings.Join(full, `","`) + `"]}`, `{"ids":["` + b.taskID[:8] + `","` + b.chanTask[:8] + `"]}`}
	queries := []string{"", "?q=" + url.QueryEscape(b.marker) + "&channel=" + b.channel + "&task_id=" + b.taskID +
		"&topic=" + b.taskID + "&after=" + b.msgID + "&tenant=" + b.tenant, "?q=" + url.QueryEscape("in:"+b.channel+" plan")}
	var out []exfilReq
	for _, route := range routes {
		method, path, _ := strings.Cut(route, " ")
		for _, p := range expand(path, vals) {
			for _, q := range queries {
				if method != http.MethodPost {
					out = append(out, exfilReq{route: route, method: method, path: p + q})
					continue
				}
				for _, body := range bodies {
					out = append(out, exfilReq{route: route, method: method, path: p + q, body: body})
				}
			}
		}
	}
	return out
}

// expand is path with each {name} replaced by each of its values in turn.
func expand(path string, vals map[string][]string) []string {
	for name, vs := range vals {
		if !strings.Contains(path, name) {
			continue
		}
		var out []string
		for _, v := range vs {
			out = append(out, expand(strings.ReplaceAll(path, name, v), vals)...)
		}
		return out
	}
	return []string{path}
}

// walk runs every request on host and answers the routes whose answer
// carried something of B's (route -> the request, the code and the body).
// cut: drop the echoes first (the demo walk); the control keeps them, as a
// member's answer naming B's ids IS B's data.
func (b exfilB) walk(t *testing.T, r *doorRig, host string, reqs []exfilReq, cut bool) map[string]string {
	t.Helper()
	hdr := http.Header{"X-Spool-Tenant": {b.tenant}, "Content-Type": {"application/json"}}
	leaked := map[string]string{}
	for _, rq := range reqs {
		code, body := r.req(t, rq.method, host, rq.path, hdr, strings.NewReader(rq.body))
		if cut && rq.route == authSessionGap {
			body = strings.ReplaceAll(body, `"`+b.tenant+`"`, `"<fenced seat>"`)
		}
		if s := b.leak(body, cut); s != "" && leaked[rq.route] == "" {
			leaked[rq.route] = rq.method + " " + rq.path + ": " + http.StatusText(code) + " carries " + s + ": " + body
		}
	}
	return leaked
}

// signInAs swaps the rig's browser for a fresh one signed in to tid as p.
func signInAs(t *testing.T, r *doorRig, tid string, p fakeidp.Person) {
	t.Helper()
	jar, _ := cookiejar.New(nil)
	c := *r.browser
	c.Jar = jar
	r.browser = &c
	r.fake.Set(p, false)
	if landed := r.signIn(t, tid); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in of %s to %s: %s", p.Email, tid, landed)
	}
}

// demoSocketReadsNothingOfB: the visitor's WUI socket subscribes to B's
// channel, B's task and everything, while B's boxes talk in B's task; no
// frame carries B's data. Positive control last: the visitor's own note is
// acked, so every frame pushed before it has been read.
func demoSocketReadsNothingOfB(t *testing.T, r *doorRig, b exfilB, demo string) {
	t.Helper()
	ctx := context.Background()
	c, _, err := websocket.Dial(ctx, "ws://"+demo+domain+"/v1/wui/ws", &websocket.DialOptions{HTTPClient: r.browser})
	if err != nil {
		t.Fatal(err)
	}
	defer c.CloseNow() //nolint:errcheck
	var all []string
	read := func(want string) {
		t.Helper()
		rctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		for {
			var raw json.RawMessage
			if err := wsjson.Read(rctx, c, &raw); err != nil {
				t.Fatalf("waiting for %s: %v (frames so far: %v)", want, err, all)
			}
			all = append(all, string(raw))
			var f wuiFrame
			json.Unmarshal(raw, &f) //nolint:errcheck
			if f.Type == want || f.Type == "error" {
				return
			}
		}
	}
	w := func(v any) { wsjson.Write(ctx, c, v) } //nolint:errcheck
	w(map[string]string{"type": "hello"})
	read("welcome")
	w(map[string]string{"type": "subscribe", "channel": b.channel})
	read("subscribed")
	w(map[string]string{"type": "subscribe", "task_id": b.taskID})
	read("subscribed")
	w(map[string]any{"type": "subscribe", "all": true})
	read("subscribed")
	if _, err := action.SendCtx(ctx, b.b1.cfg, action.SendArgs{From: "CLE-31", To: "CLE-32", TaskID: b.taskID,
		Kind: "result", Body: "more " + b.marker, ToBox: "box-b2", Hub: b.b1.c}); err != nil {
		t.Fatalf("B's second send: %v", err)
	}
	w(map[string]any{"type": "send", "task_id": lobby, "body": "the visitor's own"})
	read("ack")
	if s := b.leak(strings.Join(all, "\n"), true); s != "" {
		t.Errorf("the visitor's WUI socket carries B's %q: %v", s, all)
	}
}

// TestDemoExfiltration: zero rows and zero markers of workspace B reach a
// demo_user through any read route, on any host, by any id of B's.
// CONTROLS: the visitor's own demo session reads (the refusals are not a
// dead session's); B's own member walking the same requests on B's host
// reads B's markers through the core routes (the plant and the fill are
// real). Remove the demoFenced guard and the stray seat in B reads B's rows:
// this test fails (run by hand, recorded in the T015 row).
func TestDemoExfiltration(t *testing.T) {
	rb := make([]byte, 4)
	rand.Read(rb) //nolint:errcheck
	demo := "t" + hex.EncodeToString(rb)
	docs := wsDocs(t, t.TempDir())
	r := newDoorRig(t, func(o *hub.Options) { o.DemoWorkspace = demo; o.WorkspaceDocs = docs })
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := r.e.st.CreateTenant(context.Background(), store.Tenant{ID: demo, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	b := seedExfilB(t, r.e, docs)
	ownedBy(t, r.e, demo, "owner-of-"+demo)
	visitor := "visitor" + strings.TrimPrefix(demo, "t") + "@example.com"
	invite(t, r.e, demo, visitor, rbac.DemoUser)
	invite(t, r.e, b.tenant, visitor, rbac.DemoUser) // the stray seat in B
	admit(t, r.e, b.tenant, visitor)
	signInAs(t, r, demo, fakeidp.Person{Subject: "s-" + visitor, Email: visitor, EmailVerified: true, Name: "FirstName LastName"})
	if code, body := r.req(t, http.MethodGet, demo, "/v1/view/me", nil, nil); code != http.StatusOK || !strings.Contains(body, `"role":"`+rbac.DemoUser+`"`) {
		t.Fatalf("CONTROL: the visitor's demo session: %d %s", code, body)
	}
	routes := readRoutes(t)
	reqs := b.requests(routes)
	t.Logf("walking %d read routes, %d requests per host", len(routes), len(reqs))
	for _, host := range []string{demo, apiLabel, b.tenant} {
		for route, why := range b.walk(t, r, host, reqs, true) {
			t.Errorf("%s %s: a demo_user read B's data: %s", host, route, why)
		}
	}
	demoSocketReadsNothingOfB(t, r, b, demo)
	// The stray seat: switching the session into B is refused, or reads nothing.
	code, body := r.req(t, http.MethodPost, "login", "/api/v1/auth/tenant", http.Header{"Content-Type": {"application/json"}},
		strings.NewReader(`{"tenant":"`+b.tenant+`"}`))
	if code/100 == 2 {
		for route, why := range b.walk(t, r, apiLabel, reqs, true) {
			t.Errorf("switched into B (%d %s), %s: a demo_user read B's data: %s", code, body, route, why)
		}
	}

	// CONTROL: B's owner reads B's markers through the same requests.
	signInAs(t, r, b.tenant, fakeidp.Person{Subject: "owner-of-" + b.tenant, Email: "owner-of-" + b.tenant + "@example.com",
		EmailVerified: true, Name: "FirstName LastName"})
	got := b.walk(t, r, b.tenant, reqs, false)
	for _, route := range []string{"GET /v1/view/topics/{task_id}", "GET /v1/view/search", "GET /v1/files/{file_id}",
		"GET /v1/view/issues", "GET /v1/view/issues/{ref}", "GET /v1/workspace/docs/{path...}", "GET /v1/members",
		"POST /v1/view/previews"} {
		if got[route] == "" {
			t.Errorf("CONTROL: B's owner read nothing of B's through %s: the plant or the fill is broken", route)
		}
	}
}
