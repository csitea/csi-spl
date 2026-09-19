package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

type searchResp struct {
	Query    string   `json:"query"`
	Sort     string   `json:"sort"`
	Types    []string `json:"types"`
	Warnings []struct {
		Token  string `json:"token"`
		Pos    int    `json:"pos"`
		Detail string `json:"detail"`
	} `json:"warnings"`
	Groups map[string]struct {
		Results []map[string]any `json:"results"`
		Next    *string          `json:"next"`
	} `json:"groups"`
}

func searchGet(t *testing.T, e *env, tenant, q string, extra string, hdr ...string) (int, http.Header, searchResp, map[string]any) {
	t.Helper()
	code, h, b := viewGet(t, e, tenant, "/v1/view/search?q="+url.QueryEscape(q)+extra, hdr...)
	var r searchResp
	var raw map[string]any
	json.Unmarshal(b, &r)   //nolint:errcheck
	json.Unmarshal(b, &raw) //nolint:errcheck
	return code, h, r, raw
}

func putMsg(t *testing.T, st store.Store, tenant, task, channel, from, fromBox, to, body string, at time.Time, files string) store.Message {
	t.Helper()
	if files == "" {
		files = "[]"
	}
	m := store.Message{TenantID: tenant, MsgID: uuidV4(), TaskID: task, Channel: channel, TS: at,
		FromBox: fromBox, FromID: from, ToBox: "box-b", ToID: to, Kind: "note", Body: body,
		Files: []byte(files), Msg: []byte(`{"v":1}`), EnvSig: "sig", Env: []byte("env-" + uuidV4()),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
	if _, err := st.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
	return m
}

// US9 (contracts/search-v1.md): grouped sections, one type, cursors,
// highlights, errors with pos, the operators endpoint, the rate limit, and
// the CONTROLS: another tenant's messages / robots / users / files never
// appear, a DM stays private, SQL-shaped text is text.
func TestSearchAPI(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.SearchRatePerMin = 1000
		o.SessionID = func(r *http.Request, _ string) (string, error) { return r.Header.Get("X-Test-Human"), nil }
	})
	ctx := context.Background()
	ta, _ := e.tenant()
	tb, _ := e.tenant()
	now := time.Now().UTC().Truncate(time.Microsecond)
	pub, _, _ := ed25519.GenerateKey(nil)
	for _, tid := range []string{ta, tb} {
		if err := e.st.PutPin(ctx, tid, "box-a", pub, false, now, now); err != nil {
			t.Fatal(err)
		}
	}
	e.st.SetRoster(ctx, ta, "box-a", []string{"CLE-07", "GRK-03"}, now) //nolint:errcheck
	e.st.SetRoster(ctx, tb, "box-a", []string{"CLE-99"}, now)           //nolint:errcheck
	task, dmMine, dmOther := uuidV4(), uuidV4(), uuidV4()
	pdf := `[{"mode":"blob","kind":"file","file_id":"` + strings.Repeat("ab", 32) + `","name":"Deploy Plan.pdf","bytes":2048}]`
	m1 := putMsg(t, e.st, ta, task, "tasks", "CLE-07", "box-a", "GRK-03", "Please deploy the hub 😀 now", now.Add(-3*time.Minute), pdf)
	putMsg(t, e.st, ta, task, "tasks", "GRK-03", "box-a", "CLE-07", "deploy done", now.Add(-2*time.Minute), "")
	putMsg(t, e.st, ta, dmMine, "", "HUM-1", "box-wui", "CLE-07", "deploy key for HUM-1", now.Add(-90*time.Second), "")
	putMsg(t, e.st, ta, dmOther, "", "HUM-2", "box-wui", "CLE-07", "deploy secret of HUM-2", now.Add(-time.Minute), "")
	putMsg(t, e.st, tb, uuidV4(), "tasks", "CLE-99", "box-a", "CLE-07", "deploy in tenant B", now.Add(-30*time.Second), pdf)

	// grouped: every type the query applies to, fixed order, plural keys
	code, _, r, raw := searchGet(t, e, ta, "deploy", "")
	if code != http.StatusOK || strings.Join(r.Types, ",") != "message,thread,file,robot,user,channel,box" {
		t.Fatalf("grouped: %d %+v", code, r)
	}
	if n := len(r.Groups["messages"].Results); n != 4 {
		t.Fatalf("messages (door off: no DM filter): %d", n)
	}
	if n := len(r.Groups["files"].Results); n != 1 || r.Groups["files"].Results[0]["file_id"] != strings.Repeat("ab", 32) {
		t.Fatalf("files: %+v", r.Groups["files"])
	}
	if _, ok := raw["groups"].(map[string]any)["boxes"]; !ok || len(r.Warnings) != 0 {
		t.Fatalf("boxes group / warnings: %+v", raw)
	}
	// snippet highlights are UTF-16 offsets
	last := r.Groups["messages"].Results[3]
	sn := last["snippet"].(map[string]any)
	if last["msg_id"] != m1.MsgID || sn["text"] != "Please deploy the hub 😀 now" || fmt.Sprint(sn["highlights"]) != "[[7 13]]" ||
		last["channel"] != "tasks" || last["from"] != "CLE-07" || last["files"] != float64(1) {
		t.Fatalf("message row: %+v", last)
	}
	// CONTROL: a member reader never sees another member's DM
	_, _, r, _ = searchGet(t, e, ta, "type:message deploy", "", "X-Test-Human", "HUM-1")
	for _, m := range r.Groups["messages"].Results {
		if strings.Contains(m["snippet"].(map[string]any)["text"].(string), "HUM-2") {
			t.Fatalf("HUM-1 saw HUM-2's DM: %+v", m)
		}
	}
	if len(r.Groups["messages"].Results) != 3 {
		t.Fatalf("HUM-1 messages: %+v", r.Groups["messages"])
	}
	// CONTROL: tenant B's rows never appear under A
	for _, q := range []string{"tenant", "type:robot CLE-99", "type:file plan"} {
		_, _, r, _ := searchGet(t, e, ta, q, "")
		for g, sec := range r.Groups {
			for _, row := range sec.Results {
				if strings.Contains(fmt.Sprint(row), "CLE-99") || strings.Contains(fmt.Sprint(row), "tenant B") {
					t.Fatalf("%q: tenant B row in %s: %+v", q, g, row)
				}
			}
		}
	}
	// one type: robots with presence, sorted, highlighted
	_, _, r, _ = searchGet(t, e, ta, "type:robot box-a", "")
	if len(r.Types) != 1 || len(r.Groups["robots"].Results) != 2 || r.Groups["robots"].Results[0]["id"] != "CLE-07" {
		t.Fatalf("robots: %+v", r)
	}
	// cursors: page messages one at a time, bound to q
	_, _, p1, _ := searchGet(t, e, ta, "type:message deploy", "&limit=1")
	if p1.Groups["messages"].Next == nil {
		t.Fatalf("no next: %+v", p1)
	}
	_, _, p2, _ := searchGet(t, e, ta, "type:message deploy", "&limit=1&cursor="+*p1.Groups["messages"].Next)
	if len(p2.Groups["messages"].Results) != 1 || p2.Groups["messages"].Results[0]["msg_id"] == p1.Groups["messages"].Results[0]["msg_id"] {
		t.Fatalf("page 2: %+v", p2)
	}
	// a grouped section's cursor answers that section only
	_, _, g, _ := searchGet(t, e, ta, "deploy", "&limit=1")
	c := g.Groups["messages"].Next
	if c == nil {
		t.Fatal("grouped next")
	}
	_, _, gm, _ := searchGet(t, e, ta, "deploy", "&limit=1&cursor="+*c)
	if strings.Join(gm.Types, ",") != "message" || len(gm.Groups) != 1 {
		t.Fatalf("cursor section: %+v", gm)
	}
	if code, _, _, raw := searchGet(t, e, ta, "hub", "&cursor="+*c); code != http.StatusBadRequest || raw["error"] != "bad_cursor" {
		t.Fatalf("cursor for another q: %d %+v", code, raw)
	}
	if code, _, _, raw := searchGet(t, e, ta, "deploy", "&cursor=zz!"); code != http.StatusBadRequest || raw["error"] != "bad_cursor" {
		t.Fatalf("garbage cursor: %d %+v", code, raw)
	}
	// 400 bad_query with pos + token; unknown operators warn
	for q, pos := range map[string]float64{"deploy (hub": 7, "is:urgent": 0, "": 0, "filename:x is:online": 11} {
		code, _, _, raw := searchGet(t, e, ta, q, "")
		if code != http.StatusBadRequest || raw["error"] != "bad_query" || raw["pos"] != pos || raw["token"] == nil {
			t.Errorf("%q: %d %+v", q, code, raw)
		}
	}
	if code, _, _, raw := searchGet(t, e, ta, "deploy", "&sort=best"); code != http.StatusBadRequest || raw["error"] != "bad_query" {
		t.Fatalf("sort: %d %+v", code, raw)
	}
	_, _, r, _ = searchGet(t, e, ta, "foo:bar deploy", "")
	if len(r.Warnings) != 1 || r.Warnings[0].Token != "foo:bar" {
		t.Fatalf("warning: %+v", r.Warnings)
	}
	// CONTROL: SQL-shaped queries are text (200, nothing found, store intact)
	for _, q := range []string{`'; DROP TABLE messages; --`, `x' OR 'z'='z`} {
		code, _, r, _ := searchGet(t, e, ta, "type:message "+q, "")
		if code != http.StatusOK || len(r.Groups["messages"].Results) != 0 {
			t.Fatalf("%q: %d %+v", q, code, r)
		}
	}
	if _, _, r, _ := searchGet(t, e, ta, "type:message deploy", ""); len(r.Groups["messages"].Results) != 4 {
		t.Fatal("store intact after SQL-shaped queries")
	}
	// relevance sort answers and pages by offset
	if code, _, r, _ := searchGet(t, e, ta, "type:message deploy hub", "&sort=relevance"); code != http.StatusOK || r.Sort != "relevance" || len(r.Groups["messages"].Results) != 1 {
		t.Fatalf("relevance: %d %+v", code, r)
	}
	// read-only: 405 on POST
	req, _ := http.NewRequest(http.MethodPost, e.url(ta)+"/v1/view/search?q=x", nil)
	if resp, err := e.client.Do(req); err != nil || resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("POST: %v %v", err, resp)
	}
	// the operators endpoint is the parser's table
	code, _, b := viewGet(t, e, ta, "/v1/view/search/operators")
	var ops struct {
		Version   string                         `json:"version"`
		Types     []struct{ Type, Group string } `json:"types"`
		Operators []struct {
			Name    string   `json:"name"`
			Applies []string `json:"applies_to"`
		} `json:"operators"`
	}
	if json.Unmarshal(b, &ops) != nil || code != http.StatusOK || ops.Version != "1.0" || len(ops.Types) != 7 || len(ops.Operators) < 17 || ops.Types[6].Group != "boxes" {
		t.Fatalf("operators: %d %s", code, b)
	}
}

// The view door guards search like every /v1/view/* route, and the per-reader
// rate limit answers 429 with Retry-After.
func TestSearchDoorAndRate(t *testing.T) {
	e := newEnv(t) // token door: fails closed
	tid, _ := e.tenant()
	if code, _, _, raw := searchGet(t, e, tid, "deploy", ""); code != http.StatusUnauthorized || raw["error"] != "view_door" {
		t.Fatalf("door: %d %+v", code, raw)
	}
	e = newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.SearchRatePerMin = 2
		o.SessionID = func(r *http.Request, _ string) (string, error) { return r.Header.Get("X-Test-Human"), nil }
	})
	tid, _ = e.tenant()
	for i := 0; i < 2; i++ {
		if code, _, _, _ := searchGet(t, e, tid, "deploy", "", "X-Test-Human", "HUM-1"); code != http.StatusOK {
			t.Fatalf("search %d: %d", i, code)
		}
	}
	code, h, _, raw := searchGet(t, e, tid, "deploy", "", "X-Test-Human", "HUM-1", "Origin", wuiOrigin)
	if code != http.StatusTooManyRequests || raw["error"] != "rate_limited" || h.Get("Retry-After") == "" ||
		h.Get("Access-Control-Allow-Origin") != wuiOrigin || h.Get("Access-Control-Expose-Headers") != "Retry-After" {
		t.Fatalf("rate: %d %v %+v", code, h, raw)
	}
	if code, _, _, _ := searchGet(t, e, tid, "deploy", "", "X-Test-Human", "HUM-2"); code != http.StatusOK {
		t.Fatalf("another reader has its own budget: %d", code)
	}
	// error answers carry the view CORS headers, so the browser can read pos / token
	code, h, _, raw = searchGet(t, e, tid, "(x", "", "X-Test-Human", "HUM-3", "Origin", wuiOrigin)
	if code != http.StatusBadRequest || raw["pos"] != float64(0) || h.Get("Access-Control-Allow-Origin") != wuiOrigin {
		t.Fatalf("400 CORS: %d %v %+v", code, h, raw)
	}
}
