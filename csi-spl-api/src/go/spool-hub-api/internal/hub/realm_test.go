package hub_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The personal realm routes (spec 119 T003, 9 C2): the session's own person,
// never one named by the request.

// realmLogs is everything the hub logged so far (lockedBuf: server_5xx_log_test.go).
func realmLogs(l *lockedBuf) string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// realmDo sends one realm request as the rig's browser, answering the status
// and the decoded body.
func realmDo(t *testing.T, r *doorRig, method, path string, body any, hdr map[string]string) (int, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, "http://api"+domain+path, rd)
	req.Header.Set("Origin", wuiOrigin)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := r.browser.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	return resp.StatusCode, out
}

func realmToken(out map[string]any) string {
	if e, ok := out["error"].(string); ok {
		return e
	}
	if e, ok := out["error"].(map[string]any); ok {
		s, _ := e["code"].(string)
		return s
	}
	s, _ := out["code"].(string)
	return s
}

// realmRig is a door rig whose hub logs into buf, with alice signed in to a
// fresh workspace.
func realmRig(t *testing.T, mut ...func(*hub.Options)) (*doorRig, *lockedBuf, string) {
	t.Helper()
	buf := &lockedBuf{}
	r := newDoorRig(t, append([]func(*hub.Options){func(o *hub.Options) { o.Log = zerolog.New(buf) }}, mut...)...)
	tid, _ := r.e.tenant()
	if landed := r.signIn(t, tid); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in landed on %s", landed)
	}
	return r, buf, tid
}

// TestRealmSettingsAndProfile: the person reads and writes their own
// profile and limits; a past valid_from and an out-of-range limit are 400;
// and no log line carries a realm value (T-K2: limit, zone, prefs).
func TestRealmSettingsAndProfile(t *testing.T) {
	r, buf, _ := realmRig(t)

	code, out := realmDo(t, r, http.MethodGet, "/v1/me/realm/profile", nil, nil)
	if code != http.StatusOK || out["comm_prefs"] == nil {
		t.Fatalf("GET profile before = %d %v", code, out)
	}
	prof := map[string]any{"time_zone": "Pacific/Chatham", "locale": "fi", "comm_prefs": map[string]any{"digest": "realm-prefs-sentinel"}}
	if code, out = realmDo(t, r, http.MethodPut, "/v1/me/realm/profile", prof, nil); code != http.StatusOK || out["time_zone"] != "Pacific/Chatham" {
		t.Fatalf("PUT profile = %d %v", code, out)
	}
	if code, out = realmDo(t, r, http.MethodGet, "/v1/me/realm/profile", nil, nil); code != http.StatusOK || out["locale"] != "fi" {
		t.Fatalf("GET profile = %d %v", code, out)
	}
	if code, out = realmDo(t, r, http.MethodPut, "/v1/me/realm/profile", map[string]any{"time_zone": "Mars/Base"}, nil); code != http.StatusBadRequest {
		t.Fatalf("PUT bad zone = %d %v, want 400", code, out)
	}

	code, out = realmDo(t, r, http.MethodPut, "/v1/me/realm/settings", map[string]any{"day_limit_minutes": 437, "week_limit_minutes": 2213}, nil)
	if code != http.StatusOK {
		t.Fatalf("PUT settings = %d %v", code, out)
	}
	lim, _ := out["limits"].(map[string]any)
	if lim == nil || lim["day_limit_minutes"] != float64(437) || lim["week_limit_minutes"] != float64(2213) {
		t.Fatalf("limits in force = %v", out)
	}
	if out["warning"] != nil {
		t.Fatalf("the settings answer carries a warning: %v", out)
	}
	if code, out = realmDo(t, r, http.MethodGet, "/v1/me/realm/settings", nil, nil); code != http.StatusOK || len(out["history"].([]any)) < 1 {
		t.Fatalf("GET settings = %d %v", code, out)
	}
	if code, out = realmDo(t, r, http.MethodPut, "/v1/me/realm/settings", map[string]any{"day_limit_minutes": 30}, nil); code != http.StatusBadRequest {
		t.Fatalf("PUT day limit 30 = %d %v, want 400", code, out)
	}
	if code, out = realmDo(t, r, http.MethodPut, "/v1/me/realm/settings", map[string]any{"valid_from": "2001-01-01", "day_limit_minutes": 480}, nil); code != http.StatusBadRequest {
		t.Fatalf("PUT past valid_from = %d %v, want 400", code, out)
	}

	// T-K2: no log line holds the zone, the prefs or a limit value.
	logs := realmLogs(buf)
	for _, banned := range []string{"Pacific/Chatham", "realm-prefs-sentinel", "Mars/Base"} {
		if strings.Contains(logs, banned) {
			t.Errorf("a log line carries the realm value %q", banned)
		}
	}
	for _, line := range strings.Split(strings.TrimSpace(logs), "\n") {
		var ev map[string]any
		if json.Unmarshal([]byte(line), &ev) != nil {
			continue
		}
		for k, v := range ev {
			if v == float64(437) || v == float64(2213) || v == "437" || v == "2213" {
				t.Errorf("log field %s carries a limit: %s", k, line)
			}
		}
	}
	if !strings.Contains(logs, "/v1/me/realm/settings") {
		t.Errorf("CONTROL: the capture saw no realm request line: %q", logs)
	}
}

// TestRealmRefusals (T-N7 route half, T-N8): no session 401; a box token 403
// person_only; X-Spool-Tenant and member= 400; a person id in a body 400, in
// a query ignored; a path naming a person 404.
func TestRealmRefusals(t *testing.T) {
	r := newDoorRig(t)
	if code, out := realmDo(t, r, http.MethodGet, "/v1/me/realm/settings", nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("anonymous = %d %v, want 401", code, out)
	}
	tid, _ := r.e.tenant()
	if landed := r.signIn(t, tid); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in landed on %s", landed)
	}
	me := r.session(t).HumanID
	mine, _ := r.e.st.(store.Realm).RealmProfileOf(context.Background(), me)

	// Someone else in the same workspace, an admin, with a profile of their own.
	other := seat(t, r.e, tid, "admin")
	if err := r.e.st.(store.Realm).PutRealmProfile(context.Background(), other,
		store.RealmProfile{TimeZone: "Asia/Kathmandu"}, time.Now()); err != nil {
		t.Fatal(err)
	}

	for _, p := range []string{"/v1/me/realm/settings", "/v1/me/realm/profile", "/v1/me/realm/receipts"} {
		if code, out := realmDo(t, r, http.MethodGet, p, nil, map[string]string{"Authorization": "Bearer box-upload-token"}); code != http.StatusForbidden || realmToken(out) != "person_only" {
			t.Errorf("box token GET %s = %d %v, want 403 person_only", p, code, out)
		}
		if code, out := realmDo(t, r, http.MethodGet, p, nil, map[string]string{hub.TenantHeader: tid}); code != http.StatusBadRequest {
			t.Errorf("X-Spool-Tenant GET %s = %d %v, want 400", p, code, out)
		}
		if code, out := realmDo(t, r, http.MethodGet, p+"?member="+other, nil, nil); code != http.StatusBadRequest {
			t.Errorf("member= GET %s = %d %v, want 400", p, code, out)
		}
		if code, out := realmDo(t, r, http.MethodGet, p, nil, nil); code != http.StatusOK {
			t.Errorf("CONTROL: own GET %s = %d %v, want 200", p, code, out)
		}
	}
	if code, out := realmDo(t, r, http.MethodDelete, "/v1/me/realm/receipts/"+tid, nil, map[string]string{hub.TenantHeader: tid}); code != http.StatusBadRequest {
		t.Errorf("X-Spool-Tenant DELETE = %d %v, want 400", code, out)
	}

	// A person id in a query is ignored: the session's own profile answers.
	if code, out := realmDo(t, r, http.MethodGet, "/v1/me/realm/profile?person="+other+"&human_id="+other, nil, nil); code != http.StatusOK || out["time_zone"] == "Asia/Kathmandu" {
		t.Errorf("?person=other = %d %v: read another person's realm", code, out)
	}
	// In a body it is 400, and nothing is written.
	if code, out := realmDo(t, r, http.MethodPut, "/v1/me/realm/profile", map[string]any{"person_id": other, "time_zone": "Europe/Oslo"}, nil); code != http.StatusBadRequest {
		t.Errorf("body person_id = %d %v, want 400", code, out)
	}
	if p, _ := r.e.st.(store.Realm).RealmProfileOf(context.Background(), other); p.TimeZone != "Asia/Kathmandu" {
		t.Errorf("the other person's profile changed: %+v", p)
	}
	// No route names a person: P's realm under another id is 404.
	if code, _ := realmDo(t, r, http.MethodGet, "/v1/me/realm/profile/"+other, nil, nil); code != http.StatusNotFound {
		t.Errorf("GET /v1/me/realm/profile/<id> = %d, want 404", code)
	}
	if p, _ := r.e.st.(store.Realm).RealmProfileOf(context.Background(), me); p.TimeZone != mine.TimeZone {
		t.Errorf("the signed-in person's profile changed: %+v", p)
	}
}

// receiptStore is the memory store with receipts seeded: the copy that writes
// them is T004's.
type receiptStore struct {
	*store.Memory
	mu   sync.Mutex
	rows map[string][]store.RealmReceipt
}

func (s *receiptStore) RealmReceipts(_ context.Context, person string) ([]store.RealmReceipt, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]store.RealmReceipt(nil), s.rows[person]...), nil
}

func (s *receiptStore) DeleteRealmReceipts(_ context.Context, person, ws string) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	keep, n := s.rows[person][:0], 0
	for _, rc := range s.rows[person] {
		if rc.WorkspaceID == ws {
			n++
			continue
		}
		keep = append(keep, rc)
	}
	s.rows[person] = keep
	return n, nil
}

// TestRealmReceipts: GET lists the person's own receipts only; DELETE erases
// one workspace's, leaves the other's and another person's; no receipt value
// reaches a log line beyond the DELETE path.
func TestRealmReceipts(t *testing.T) {
	rs := &receiptStore{rows: map[string][]store.RealmReceipt{}}
	r, buf, _ := realmRig(t, func(o *hub.Options) {
		m, ok := o.Store.(*store.Memory)
		if !ok {
			t.Skip("seeded receipts ride the memory store; the Postgres receipt reads are T002's store tests")
		}
		rs.Memory = m
		o.Store = rs
	})
	me := r.session(t).HumanID
	now := time.Now().UTC()
	rc := func(ws, day string) store.RealmReceipt {
		return store.RealmReceipt{WorkspaceID: ws, WorkspaceName: "Left " + ws, Day: day, Minutes: 451,
			Label: "t:receipt-label-sentinel", Kind: "work", PeriodStart: day, PeriodEnd: day,
			ApprovalState: "approved", ApproverName: "FirstName LastName", DecidedAt: &now, CopiedAt: now}
	}
	rs.rows[me] = []store.RealmReceipt{rc("wsleft1", "2026-09-01"), rc("wsleft1", "2026-09-02"), rc("wsleft2", "2026-09-01")}
	rs.rows["HUM-999999"] = []store.RealmReceipt{rc("wsleft1", "2026-09-01")}

	code, out := realmDo(t, r, http.MethodGet, "/v1/me/realm/receipts", nil, nil)
	if got, _ := out["receipts"].([]any); code != http.StatusOK || len(got) != 3 {
		t.Fatalf("GET receipts = %d %v, want 3", code, out)
	}
	if code, out = realmDo(t, r, http.MethodDelete, "/v1/me/realm/receipts/wsleft1", nil, nil); code != http.StatusOK || out["deleted"] != float64(2) {
		t.Fatalf("DELETE wsleft1 = %d %v, want deleted 2", code, out)
	}
	if code, out = realmDo(t, r, http.MethodGet, "/v1/me/realm/receipts", nil, nil); len(out["receipts"].([]any)) != 1 {
		t.Fatalf("after delete = %d %v, want wsleft2's 1", code, out)
	}
	if len(rs.rows["HUM-999999"]) != 1 {
		t.Fatal("another person's receipt of the same workspace was deleted")
	}
	if code, out = realmDo(t, r, http.MethodDelete, "/v1/me/realm/receipts/wsleft1", nil, nil); code != http.StatusOK || out["deleted"] != float64(0) {
		t.Fatalf("second DELETE = %d %v, want deleted 0", code, out)
	}
	if logs := realmLogs(buf); strings.Contains(logs, "receipt-label-sentinel") || strings.Contains(logs, "FirstName LastName") {
		t.Error("a log line carries a receipt value")
	}
}
