package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// demoEnv is rbacEnv with the demo on (specs/077): it answers the env and
// the id of its demo workspace, created up front.
func demoEnv(t *testing.T, mut ...func(*hub.Options)) (*env, string) {
	t.Helper()
	b := make([]byte, 4)
	rand.Read(b) //nolint:errcheck
	demo := "t" + hex.EncodeToString(b)
	cfg, err := auth.LoadFrom("lde", map[string]string{"SPOOL_HUB_AUTH_SESSION_KEY": strings.Repeat("k", 32)})
	if err != nil {
		t.Fatal(err)
	}
	e := rbacEnv(t, append([]func(*hub.Options){func(o *hub.Options) {
		o.DemoWorkspace = demo
		o.Auth = auth.New(cfg, zerolog.Nop(), auth.Options{}) // registers keys and events
		o.WorkspaceDocs = wsDocs(t, t.TempDir())              // the docs writes are walked too
	}}, mut...)...)
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: demo, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	return e, demo
}

// uploadToken asks the WUI socket of member for its upload token.
func uploadToken(t *testing.T, e *env, tid, member string) string {
	t.Helper()
	c := dialMember(t, e, tid, "", member)
	wsjson.Write(context.Background(), c, map[string]string{"type": "token"}) //nolint:errcheck
	f := readType(t, c, "token")
	tok, _ := f["upload_token"].(string)
	if tok == "" {
		t.Fatalf("no upload token: %v", f)
	}
	return tok
}

func putFile(t *testing.T, e *env, tid, tok string) int {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, e.url(tid)+"/v1/files", bytes.NewReader([]byte("demo bytes")))
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

// FR-009: with the demo off (the default, dev and prd) GET /v1/demo is 404
// and a demo_user membership grants nothing, not even a read.
// CONTROL: a developer of the same tenant reads.
func TestDemoOffFencesDemoUser(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	demo, dev := seat(t, e, tid, rbac.DemoUser), seat(t, e, tid, rbac.Developer)
	if code, body := call(t, e, tid, http.MethodGet, "/v1/demo", "", nil); code != http.StatusNotFound {
		t.Fatalf("GET /v1/demo with the demo off: %d %v", code, body)
	}
	if code, body := call(t, e, tid, http.MethodGet, "/v1/view/me", demo, nil); code != http.StatusForbidden {
		t.Fatalf("demo_user read with the demo off: %d %v", code, body)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/me", dev, nil); code != http.StatusOK {
		t.Fatalf("CONTROL: developer read: %d", code)
	}
}

// 3.1: with the demo on, demo_user acts in the demo workspace only, and holds
// exactly topics.read, notes.send, agents.command and docs.read there.
// CONTROL: the same role in another workspace is no membership.
func TestDemoOnlyInDemoWorkspace(t *testing.T) {
	e, demo := demoEnv(t)
	other, _ := e.tenant()
	in, out := seat(t, e, demo, rbac.DemoUser), seat(t, e, other, rbac.DemoUser)
	code, body := call(t, e, demo, http.MethodGet, "/v1/demo", "", nil)
	if code != http.StatusOK || body["workspace"] != demo || body["max_live"] != float64(9) || body["max_stay"] != "3h" {
		t.Fatalf("GET /v1/demo: %d %v", code, body)
	}
	code, me := call(t, e, demo, http.MethodGet, "/v1/view/me", in, nil)
	got := perms(me)
	if code != http.StatusOK || me["role"] != rbac.DemoUser || len(got) != 4 ||
		!got[rbac.TopicsRead] || !got[rbac.NotesSend] || !got[rbac.AgentsCommand] || !got[rbac.DocsRead] {
		t.Fatalf("demo_user /v1/view/me: %d %v", code, me)
	}
	if code, body := call(t, e, other, http.MethodGet, "/v1/view/me", out, nil); code != http.StatusForbidden {
		t.Fatalf("CONTROL: demo_user outside the demo workspace read: %d %v", code, body)
	}
}

// 3.2: no member route grants demo_user (only the open admission of T007
// will), and the Users page does not offer it. The same for channel_guest
// (specs/121 4.2): it holds no permission, so every role would cover it.
func TestDemoUserNotGrantable(t *testing.T) {
	e, demo := demoEnv(t)
	admin := seat(t, e, demo, rbac.Admin)
	victim := seat(t, e, demo, rbac.Tester)
	for _, role := range []string{rbac.DemoUser, rbac.ChannelGuest} {
		if code, body := call(t, e, demo, http.MethodPost, "/v1/members/invites", admin,
			map[string]string{"email": "v@example.com", "role": role}); code != http.StatusBadRequest || body["error"] != "bad_role" {
			t.Fatalf("invite as %s: %d %v", role, code, body)
		}
		if code, body := call(t, e, demo, http.MethodPut, "/v1/members/"+victim+"/role", admin,
			map[string]string{"role": role}); code != http.StatusBadRequest || body["error"] != "bad_role" {
			t.Fatalf("re-role to %s: %d %v", role, code, body)
		}
		_, body := call(t, e, demo, http.MethodGet, "/v1/members", admin, nil)
		for _, r := range body["roles"].([]any) {
			if r.(map[string]any)["id"] == role {
				t.Fatalf("the Users page offers %s: %v", role, body["roles"])
			}
		}
	}
	// CONTROL: the same admin still grants tester.
	if code, body := call(t, e, demo, http.MethodPut, "/v1/members/"+victim+"/role", admin,
		map[string]string{"role": rbac.Developer}); code != http.StatusOK {
		t.Fatalf("CONTROL: re-role to developer: %d %v", code, body)
	}
}

// G1 (files.write): a demo_user's upload token stores no file.
// CONTROL: a developer's token of the same workspace does.
func TestDemoUserCannotUpload(t *testing.T) {
	e, demo := demoEnv(t)
	visitor, dev := seat(t, e, demo, rbac.DemoUser), seat(t, e, demo, rbac.Developer)
	if code := putFile(t, e, demo, uploadToken(t, e, demo, visitor)); code != http.StatusForbidden {
		t.Fatalf("demo_user upload: %d", code)
	}
	if code := putFile(t, e, demo, uploadToken(t, e, demo, dev)); code != http.StatusCreated {
		t.Fatalf("CONTROL: developer upload: %d", code)
	}
}

// demoAllowed is every mutating human route a demo_user may call (spec 3.2):
// own messages, reactions, own topics (starter archive policy), per-user
// read marks and order, and two POST reads. A route missing from both lists
// fails TestDemoRouteWalk until someone decides it.
var demoAllowed = map[string]bool{
	"PATCH /v1/messages/{msg_id}":            true, // own message only (edit.go)
	"DELETE /v1/messages/{msg_id}":           true,
	"POST /v1/messages/{msg_id}/merge":       true,
	"PATCH /v1/messages/{msg_id}/kind":       true,
	"PUT /v1/messages/{msg_id}/reactions":    true,
	"DELETE /v1/messages/{msg_id}/reactions": true,
	"PUT /v1/messages/{msg_id}/archive":      true, // own topic: the demo workspace is starter
	"DELETE /v1/messages/{msg_id}/archive":   true,
	"DELETE /v1/messages/{msg_id}/topic":     true, // own topic only
	"PUT /v1/me/channel-order":               true,
	"PUT /v1/me/reads":                       true,
	"POST /v1/view/ids":                      true, // reads
	"POST /v1/view/previews":                 true,
	"POST /v1/perf/samples":                  true, // anonymous WUI perf ingest
}

// demoOutOfReach is every mutating route a browser session never reaches:
// box credentials, the operator's id token, and the per-process ingest.
var demoOutOfReach = map[string]bool{
	"POST /v1/pins":            true,
	"DELETE /v1/pins/{box_id}": true,
	"POST /v1/cicd-logs":       true,
}

// marketingRoute(mux, "...") registers a spec 090 route behind its gate.
var routeRe = regexp.MustCompile(`(?:HandleFunc\(|marketingRoute\(mux, )"((?:POST|PUT|PATCH|DELETE) [^"]*)"(?:\+(\w+)(?:\+"([^"]*)")?)?`)

// mutatingRoutes reads every mutating route the hub registers from its
// source, prefix constants resolved.
func mutatingRoutes(t *testing.T) []string {
	t.Helper()
	prefix := map[string]string{"eventsPrefix": "/api/v1/auth/events", "keysPrefix": "/api/v1/auth/keys"}
	files, _ := os.ReadDir(".")
	seen := map[string]bool{}
	for _, f := range files {
		n := f.Name()
		if !strings.HasSuffix(n, ".go") || strings.HasSuffix(n, "_test.go") {
			continue
		}
		src, err := os.ReadFile(n)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range routeRe.FindAllStringSubmatch(string(src), -1) {
			route := m[1]
			if m[2] != "" {
				p, ok := prefix[m[2]]
				if !ok {
					t.Fatalf("%s: unknown route prefix %s", n, m[2])
				}
				route += p + m[3]
			}
			seen[route] = true
		}
	}
	out := make([]string, 0, len(seen))
	for r := range seen {
		out = append(out, r)
	}
	sort.Strings(out)
	if len(out) < 40 {
		t.Fatalf("found only %d mutating routes: the source scan is broken", len(out))
	}
	return out
}

// FR-003: every mutating route registered on the hub refuses a demo_user
// session, unless it is allow-listed above. A new route nobody decided
// fails here, so the deny list cannot shrink silently (an allow list proves
// absence, a ban list cannot). Path values are placeholders: the refusal
// must come before any lookup of them.
func TestDemoRouteWalk(t *testing.T) {
	e, demo := demoEnv(t)
	visitor := seat(t, e, demo, rbac.DemoUser)
	fill := strings.NewReplacer("{msg_id}", "7a1c0d2e-3f4b-4c5d-8e6f-7a8b9c0d1e01", "{channel}", "general",
		"{human_id}", "HUM-1", "{box}", "box-1", "{id}", "x1", "{ref}", "ISS-1", "{file_id}",
		strings.Repeat("a", 64), "{box_id}", "box-1", "{path...}", "guide.md")
	walked := 0
	for _, route := range mutatingRoutes(t) {
		if demoAllowed[route] || demoOutOfReach[route] || strings.Contains(route, " /v1/operator/") {
			continue
		}
		method, path, _ := strings.Cut(route, " ")
		code, body := call(t, e, demo, method, fill.Replace(path), visitor, map[string]any{})
		if code != http.StatusForbidden && code != http.StatusUnauthorized {
			t.Errorf("%s: a demo_user got %d %v, want 403 (or allow-list it in demoAllowed)", route, code, body)
		}
		walked++
	}
	if walked < 25 {
		t.Fatalf("walked only %d routes", walked)
	}
	// CONTROL: a developer of the same workspace passes the new permission
	// gates (files.write is TestDemoUserCannotUpload's control), so the
	// refusals above are the role's, not the placeholders'.
	dev := seat(t, e, demo, rbac.Developer)
	for _, route := range []string{"POST /v1/issues", "POST /api/v1/auth/keys", "POST /v1/messages/{msg_id}/move",
		"POST /v1/channels/{channel}/members", "POST /api/v1/auth/events"} {
		method, path, _ := strings.Cut(route, " ")
		if code, body := call(t, e, demo, method, fill.Replace(path), dev, map[string]any{}); code == http.StatusForbidden && body["permission"] != "" {
			t.Errorf("CONTROL: %s: a developer got 403 %v", route, body)
		}
	}
}
