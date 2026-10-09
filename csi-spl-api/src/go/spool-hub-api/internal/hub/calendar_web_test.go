package hub_test

import (
	"encoding/json"
	"net/http"
	"slices"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// rdb 0158: GET /v1/public/calendar/events, the signed-out calendar. A member
// sets audience web on create and on edit; a request with no session reads
// that workspace's web events with the internet-safe fields only; the
// workspace's public, internal and private events and another workspace's
// web event are not answered (the store's control, calendar_web_test.go,
// proves the leak check fails without its filter). The workspace comes from
// the page Origin or the tenant Host, never from a parameter. Memory, and
// Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

const webCalQuery = "/v1/public/calendar/events?start=2026-10-05T00:00:00Z&end=2026-10-12T00:00:00Z"

// webCalGet is a signed-out GET of path on host with origin ("" = none): the
// status, the events and the error token.
func webCalGet(t *testing.T, e *env, host, origin, path string) (int, []map[string]any, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, "http://"+host+path, nil)
	if origin != "" {
		req.Header.Set("Origin", origin)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var raw map[string]json.RawMessage
	json.NewDecoder(resp.Body).Decode(&raw) //nolint:errcheck
	var evs []map[string]any
	json.Unmarshal(raw["events"], &evs) //nolint:errcheck
	var token string
	json.Unmarshal(raw["error"], &token) //nolint:errcheck
	return resp.StatusCode, evs, token
}

func webCalTitles(evs []map[string]any) string {
	var ts []string
	for _, e := range evs {
		ts = append(ts, e["title"].(string))
	}
	slices.Sort(ts)
	return strings.Join(ts, ",")
}

func TestCalendarWebSignedOut(t *testing.T) {
	e := rbacEnv(t, func(o *hub.Options) { o.OriginTenant = hub.NewOriginTenant("{tenant}"+domain, "") })
	a, _ := e.tenant()
	b, _ := e.tenant()
	devA, devB := seat(t, e, a, rbac.Developer), seat(t, e, b, rbac.Developer)
	for _, aud := range []string{"workspace", "internal", "private"} {
		calCreate(t, e, a, devA, calBody("a-"+aud, map[string]any{"audience": aud, "mentions": []string{devA}}))
	}
	calCreate(t, e, a, devA, calBody("a-web", map[string]any{"audience": "web", "description": "open day",
		"mentions": []string{devA}}))
	// web on edit: b's event starts workspace and is moved to web.
	ev := calCreate(t, e, b, devB, calBody("b-web", nil))
	if code, out := call(t, e, b, http.MethodPatch, "/v1/calendar/events/"+ev["id"].(string), devB,
		map[string]any{"audience": "web"}); code != http.StatusOK {
		t.Fatalf("patch to web: %d %v", code, out)
	}

	// (a) + (b) + (c) on the tenant Host, no session.
	code, evs, _ := webCalGet(t, e, a+domain, "", webCalQuery)
	if code != http.StatusOK || webCalTitles(evs) != "a-web" {
		t.Fatalf("signed-out read of %s = %d %q, want only a-web (n=%d)", a, code, webCalTitles(evs), len(evs))
	}
	var keys []string
	for k := range evs[0] {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	if got := strings.Join(keys, ","); got != "all_day,description,ends_at,starts_at,title" {
		t.Fatalf("signed-out event fields = %s, want only the internet-safe five", got)
	}
	if evs[0]["description"] != "open day" || evs[0]["starts_at"] != "2026-10-06T09:00:00Z" {
		t.Fatalf("signed-out event = %v", evs[0])
	}

	// The page Origin picks the workspace on a host that names none.
	code, evs, _ = webCalGet(t, e, "api"+domain, "https://"+b+domain, webCalQuery)
	if code != http.StatusOK || webCalTitles(evs) != "b-web" {
		t.Fatalf("Origin %s read = %d %q, want only b-web", b, code, webCalTitles(evs))
	}

	for name, tc := range map[string]struct {
		host, path string
		code       int
		token      string
	}{
		"no workspace on the host": {"api" + domain, webCalQuery, http.StatusNotFound, "unknown_tenant"},
		"unknown workspace":        {"tnone0000" + domain, webCalQuery, http.StatusNotFound, "unknown_tenant"},
		"no range":                 {a + domain, "/v1/public/calendar/events", http.StatusBadRequest, ""},
	} {
		if code, _, eb := webCalGet(t, e, tc.host, "", tc.path); code != tc.code || (tc.token != "" && eb != tc.token) {
			t.Errorf("%s: %d %v, want %d %s", name, code, eb, tc.code, tc.token)
		}
	}
}

// The per-address window: the read after calendarWebPerMin (60) is 429.
func TestCalendarWebRateLimited(t *testing.T) {
	e := rbacEnv(t)
	a, _ := e.tenant()
	for i := 0; i < 60; i++ {
		if code, _, _ := webCalGet(t, e, a+domain, "", webCalQuery); code != http.StatusOK {
			t.Fatalf("read %d = %d, want 200", i+1, code)
		}
	}
	if code, _, eb := webCalGet(t, e, a+domain, "", webCalQuery); code != http.StatusTooManyRequests {
		t.Fatalf("read 61 = %d %v, want 429", code, eb)
	}
}
