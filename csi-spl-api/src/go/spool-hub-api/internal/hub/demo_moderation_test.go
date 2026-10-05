package hub_test

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"testing"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/077 T016 part A: report + hide in the demo workspace.

const reportGlyph = "🚩"

// modRig is one demo workspace with a poster, a moderator (admin) and four
// visitors, and a lobby thread: topic t1 (opener open, reply reply) and
// topic t2 (opener head). markA is in reply's body, markB in head's.
type modRig struct {
	e                    *env
	demo, admin, dev     string
	v                    [4]string
	t1, t2               string
	open, reply, head    string
	markA, markB         string
	devSock, visitorSock *websocket.Conn
	adminSock            *websocket.Conn
}

func newModRig(t *testing.T) *modRig {
	t.Helper()
	e, demo := quotaEnv(t)
	b := make([]byte, 4)
	rand.Read(b) //nolint:errcheck
	m := &modRig{e: e, demo: demo, admin: seat(t, e, demo, rbac.Admin), dev: seat(t, e, demo, rbac.Developer),
		t1: uuidV4(), t2: uuidV4(), open: uuidV4(), reply: uuidV4(), head: uuidV4(),
		markA: "hidea" + hex.EncodeToString(b), markB: "hideb" + hex.EncodeToString(b)}
	for i := range m.v {
		m.v[i] = seat(t, e, demo, rbac.DemoUser)
	}
	m.devSock = dialMember(t, e, demo, "", m.dev)
	m.post(t, m.open, m.t1, "opening line", 1)
	m.post(t, m.reply, m.t1, "a reply "+m.markA, 0)
	m.post(t, m.head, m.t2, m.markB+" subject line", 1)
	m.visitorSock, m.adminSock = follow(t, e, demo, m.v[0]), follow(t, e, demo, m.admin)
	return m
}

// post sends body as dev into the lobby channel.
func (m *modRig) post(t *testing.T, id, task, body string, isParent int) {
	t.Helper()
	wsjson.Write(context.Background(), m.devSock, map[string]any{"type": "send", "msg_id": id, "task_id": task, //nolint:errcheck
		"kind": "note", "body": body, "is_parent": isParent, "channel": store.ChannelLobby})
	if f := readType(t, m.devSock, "ack"); f["type"] != "ack" {
		t.Fatalf("post %s: %v", body, f)
	}
}

// follow dials member's WUI socket subscribed to everything.
func follow(t *testing.T, e *env, tid, member string) *websocket.Conn {
	t.Helper()
	c := dialMember(t, e, tid, "", member)
	wsjson.Write(context.Background(), c, map[string]any{"type": "subscribe", "all": true}) //nolint:errcheck
	readType(t, c, "subscribed")
	return c
}

// raw is one request as member: the code and the body.
func raw(t *testing.T, e *env, tid, method, path, as, body string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(method, e.url(tid)+path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if as != "" {
		req.Header.Set(memberHeader, as)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func report(t *testing.T, e *env, tid, msgID, as string) int {
	t.Helper()
	code, _ := call(t, e, tid, http.MethodPut, "/v1/messages/"+msgID+"/reactions", as, map[string]string{"emoji": reportGlyph})
	return code
}

// topicHas reads topic task as as: whether msgID is on the page, and marked.
func topicHas(t *testing.T, m *modRig, task, msgID, as string) (code int, has, hidden bool) {
	t.Helper()
	code, body := raw(t, m.e, m.demo, http.MethodGet, "/v1/view/topics/"+task, as, "")
	var page struct {
		Messages []struct {
			Env    json.RawMessage `json:"env"`
			Hidden bool            `json:"hidden"`
		} `json:"messages"`
	}
	json.Unmarshal([]byte(body), &page) //nolint:errcheck
	for _, v := range page.Messages {
		if strings.Contains(string(v.Env), msgID) {
			return code, true, v.Hidden
		}
	}
	return code, false, false
}

// TestDemoReportHide (memory, and Postgres under SPOOL_TEST_PG_DSN): one
// reporter counts once; the third distinct reporter hides the message; the
// visitors' sockets drop it and the moderator's mark it; a moderator hides
// and unhides; an unhide sticks against later reports; a demo_user cannot
// hide; a real workspace has no report glyph and no hide.
func TestDemoReportHide(t *testing.T) {
	m := newModRig(t)
	e, demo, v := m.e, m.demo, m.v
	for i := 0; i < 3; i++ { // the same reporter, three times: one report
		if code := report(t, e, demo, m.reply, v[0]); code != http.StatusOK {
			t.Fatalf("report %d by v0: %d", i, code)
		}
	}
	report(t, e, demo, m.reply, v[1])
	if _, has, _ := topicHas(t, m, m.t1, m.reply, v[2]); !has {
		t.Fatal("two distinct reporters (one of them three times) hid the message: want it visible until the third")
	}
	if code := report(t, e, demo, m.reply, v[2]); code != http.StatusOK {
		t.Fatalf("the third report: %d", code)
	}
	if f := readType(t, m.visitorSock, "message_deleted"); f["msg_id"] != m.reply {
		t.Errorf("visitor socket after the auto-hide: %v, want message_deleted %s", f, m.reply)
	}
	if f := readType(t, m.adminSock, "message_hidden"); f["msg_id"] != m.reply || f["hidden"] != true {
		t.Errorf("moderator socket after the auto-hide: %v", f)
	}
	for _, who := range []string{v[0], v[3], m.dev} {
		if code, has, _ := topicHas(t, m, m.t1, m.reply, who); code != http.StatusOK || has {
			t.Errorf("%s reads the auto-hidden reply: %d %v", who, code, has)
		}
	}
	if _, has, hidden := topicHas(t, m, m.t1, m.reply, m.admin); !has || !hidden {
		t.Errorf("the moderator's read of the hidden reply: has %v hidden %v, want both", has, hidden)
	}
	// Gone from the message routes too: a visitor's reaction is a 404.
	if code := report(t, e, demo, m.reply, v[3]); code != http.StatusNotFound {
		t.Errorf("a report on a hidden message: %d, want 404", code)
	}

	// A moderator hides the head of t2; a demo_user may not.
	if code, _ := call(t, e, demo, http.MethodPut, "/v1/messages/"+m.head+"/hidden", v[0], nil); code != http.StatusForbidden {
		t.Errorf("a demo_user's hide: %d, want 403", code)
	}
	if code, body := call(t, e, demo, http.MethodPut, "/v1/messages/"+m.head+"/hidden", m.admin, nil); code != http.StatusOK || body["hidden"] != true {
		t.Fatalf("the moderator's hide: %d %v", code, body)
	}
	if code, _, _ := topicHas(t, m, m.t2, m.head, v[0]); code != http.StatusNotFound {
		t.Errorf("a topic whose only message is hidden: %d, want 404", code)
	}
	if _, body := raw(t, e, demo, http.MethodGet, "/v1/view/topics", v[0], ""); strings.Contains(body, m.t2) || !strings.Contains(body, m.t1) {
		t.Errorf("visitor's topic list: want t1 and not t2: %s", body)
	}
	if _, body := raw(t, e, demo, http.MethodGet, "/v1/view/topics", m.admin, ""); !strings.Contains(body, m.t2) {
		t.Errorf("moderator's topic list lost t2: %s", body)
	}

	// Unhide: back for everyone, and the reports already counted (and new
	// ones) do not hide it again.
	if code, body := call(t, e, demo, http.MethodDelete, "/v1/messages/"+m.reply+"/hidden", m.admin, nil); code != http.StatusOK || body["hidden"] != false {
		t.Fatalf("the moderator's unhide: %d %v", code, body)
	}
	report(t, e, demo, m.reply, v[3])
	if _, has, hidden := topicHas(t, m, m.t1, m.reply, v[0]); !has || hidden {
		t.Errorf("after the unhide and a 4th report the visitor reads: has %v hidden %v", has, hidden)
	}
	realWorkspaceUnaffected(t, e)
}

// realWorkspaceUnaffected: outside the demo workspace the report glyph is
// not a reaction and nobody hides anything; the plain emoji still works.
func realWorkspaceUnaffected(t *testing.T, e *env) {
	t.Helper()
	tid, _ := e.tenant()
	admin, dev := seat(t, e, tid, rbac.Admin), seat(t, e, tid, rbac.Developer)
	c := dialMember(t, e, tid, "", dev)
	id := uuidV4()
	wsjson.Write(context.Background(), c, map[string]any{"type": "send", "msg_id": id, "task_id": uuidV4(), //nolint:errcheck
		"kind": "note", "body": "real", "is_parent": 1, "channel": store.ChannelLobby})
	readType(t, c, "ack")
	if code := report(t, e, tid, id, dev); code != http.StatusBadRequest {
		t.Errorf("the report glyph in a real workspace: %d, want 400", code)
	}
	if code, _ := call(t, e, tid, http.MethodPut, "/v1/messages/"+id+"/hidden", admin, nil); code != http.StatusNotFound {
		t.Errorf("a hide in a real workspace: %d, want 404", code)
	}
	if code, _ := call(t, e, tid, http.MethodPut, "/v1/messages/"+id+"/reactions", dev, map[string]string{"emoji": "👍"}); code != http.StatusOK {
		t.Errorf("CONTROL: a plain emoji in a real workspace: %d", code)
	}
}

// hubReadRoutes is readRoutes (demo_exfil_test.go) without the auth
// handler's: this rig signs members in by header, not by session.
func hubReadRoutes(t *testing.T) []string {
	var out []string
	for _, r := range readRoutes(t) {
		if !strings.Contains(r, "/api/v1/auth/") {
			out = append(out, r)
		}
	}
	return out
}

var echoRe = regexp.MustCompile(`"query":"[^"]*"`)

// modWalk runs every hub read route as as, each path value naming the two
// hidden messages and their topics, the query searching the markers: the
// routes whose answer carried a marker (route -> why).
func (m *modRig) modWalk(t *testing.T, as string) map[string]string {
	t.Helper()
	b := exfilB{crossB: crossB{marker: m.markA, msgID: m.reply, taskID: m.t1}, chanMsg: m.head, chanTask: m.t2}
	reqs := b.requests(hubReadRoutes(t))
	for _, q := range []string{m.markA, m.markB} {
		for _, path := range []string{"/v1/view/search?q=", "/v1/view/search?sort=relevance&q="} {
			reqs = append(reqs, exfilReq{route: "GET /v1/view/search", method: http.MethodGet, path: path + url.QueryEscape(q)})
		}
	}
	reqs = append(reqs, exfilReq{route: "GET /v1/view/topics", method: http.MethodGet, path: "/v1/view/topics?per_topic=10"},
		exfilReq{route: "GET /v1/view/topics", method: http.MethodGet, path: "/v1/view/topics?channel=" + store.ChannelLobby + "&per_topic=10"})
	got := map[string]string{}
	for _, rq := range reqs {
		code, body := raw(t, m.e, m.demo, rq.method, rq.path, as, rq.body)
		body = echoRe.ReplaceAllString(body, "<echo>")
		for _, mk := range []string{m.markA, m.markB} {
			if strings.Contains(body, mk) && got[rq.route] == "" {
				got[rq.route] = rq.method + " " + rq.path + ": " + http.StatusText(code) + " carries " + mk + ": " + body
			}
		}
	}
	return got
}

// TestDemoHiddenGoneFromEveryRead: with the reply auto-hidden and the head
// hidden by the moderator, a visitor walks every read route the hub
// registers (read from its source) and no answer carries either message's
// text. CONTROL: the moderator's same walk reads both through the topic,
// the topic list (per_topic), search, previews and flow-free core routes.
func TestDemoHiddenGoneFromEveryRead(t *testing.T) {
	m := newModRig(t)
	for _, who := range []string{m.v[0], m.v[1], m.v[2]} {
		report(t, m.e, m.demo, m.reply, who)
	}
	if code, _ := call(t, m.e, m.demo, http.MethodPut, "/v1/messages/"+m.head+"/hidden", m.admin, nil); code != http.StatusOK {
		t.Fatalf("hide head: %d", code)
	}
	for route, why := range m.modWalk(t, m.v[3]) {
		t.Errorf("%s: a demo_user read a hidden message: %s", route, why)
	}
	got := m.modWalk(t, m.admin)
	for _, route := range []string{"GET /v1/view/topics/{task_id}", "GET /v1/view/topics", "GET /v1/view/search",
		"POST /v1/view/previews"} {
		if got[route] == "" {
			t.Errorf("CONTROL: the moderator read no hidden text through %s: the plant or the walk is broken", route)
		}
	}
}
