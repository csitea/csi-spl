package hub_test

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 118 T003: GET /v1/me/realm/hours, the person's hours across every
// workspace. Memory, and Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).
// The hub clock is hoursNow (Wed 2026-10-07 12:00 UTC); the week of Mon
// 10-05 is open in every workspace.

const realmWeek = "/v1/me/realm/hours?from=2026-10-05&to=2026-10-11"

// realmSpy wraps the store the hub sees: it counts the workspaces read and
// the reads in flight, fails one workspace on demand, serves receipts (no
// store writes them before 119 T004) and marks act-as clones.
type realmSpy struct {
	store.Store
	store.Hours
	store.Realm
	store.MembershipLister

	mu          sync.Mutex
	inFlight    int
	maxInFlight int
	read        map[string]int // tenant -> HoursEntries calls
	fail        string         // a tenant whose reads fail
	receipts    []store.RealmReceipt
	clones      map[string]bool
}

func (s *realmSpy) HoursEntries(ctx context.Context, tenant, member, from, to string) ([]store.HoursEntry, error) {
	s.mu.Lock()
	s.read[tenant]++
	s.inFlight++
	s.maxInFlight = max(s.maxInFlight, s.inFlight)
	fail := s.fail == tenant
	s.mu.Unlock()
	time.Sleep(2 * time.Millisecond) // long enough for the fan-out to overlap
	defer func() { s.mu.Lock(); s.inFlight--; s.mu.Unlock() }()
	if fail {
		return nil, errors.New("planted: workspace down")
	}
	return s.Hours.HoursEntries(ctx, tenant, member, from, to)
}

func (s *realmSpy) RealmReceipts(ctx context.Context, person string) ([]store.RealmReceipt, error) {
	if s.receipts != nil {
		return s.receipts, nil
	}
	return s.Realm.RealmReceipts(ctx, person)
}

// Clone answers a live clone for a marked human (the act-as door).
func (s *realmSpy) Clone(_ context.Context, tenant, clone string) (store.Clone, error) {
	if s.clones[clone] {
		return store.Clone{CloneHum: clone, TenantID: tenant}, nil
	}
	return store.Clone{}, store.ErrNotFound
}

func (s *realmSpy) reads() map[string]int {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]int{}
	for k, v := range s.read {
		out[k] = v
	}
	return out
}

func realmEnv(t *testing.T) (*env, *realmSpy) {
	t.Helper()
	spy := &realmSpy{read: map[string]int{}, clones: map[string]bool{}}
	e := hoursEnvWith(t, func(o *hub.Options) {
		spy.Store = o.Store
		spy.Hours = o.Store.(store.Hours)
		spy.Realm = o.Store.(store.Realm)
		spy.MembershipLister = o.Store.(store.MembershipLister)
		o.Store = spy
	})
	return e, spy
}

func hoursEnvWith(t *testing.T, mut func(*hub.Options)) *env {
	t.Helper()
	return rbacEnv(t, func(o *hub.Options) { o.Now = func() time.Time { return hoursNow } }, mut)
}

// realmGet is GET path as hum (no tenant: the realm host), with extra headers.
func realmGet(t *testing.T, e *env, hum, path string, hdr map[string]string) (int, map[string]any, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, e.url("api")+path, nil)
	if hum != "" {
		req.Header.Set(memberHeader, hum)
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var raw json.RawMessage
	json.NewDecoder(resp.Body).Decode(&raw) //nolint:errcheck
	out := map[string]any{}
	json.Unmarshal(raw, &out) //nolint:errcheck
	return resp.StatusCode, out, string(raw)
}

// spanEntry is an approved entry of minutes on day with one span.
func spanEntry(day, target string, start, end time.Time) store.HoursEntry {
	return store.HoursEntry{Day: day, Target: target, Minutes: int(end.Sub(start) / time.Minute), State: store.HoursApproved,
		Spans: []store.HoursSpan{{Start: start, End: end, Src: store.HoursSpanTimer}}}
}

func putAs(t *testing.T, e *env, tid, hum string, es ...store.HoursEntry) {
	t.Helper()
	if err := hoursStore(e).PutHoursEntries(context.Background(), tid, hum, es, hum, hoursNow); err != nil {
		t.Fatalf("put %s in %s: %v", hum, tid, err)
	}
}

// person is one fresh human seated in every tid (an operator invite each).
func person(t *testing.T, e *env, tids ...string) string {
	t.Helper()
	email := freshEmail()
	hum := ""
	for _, tid := range tids {
		hum = join(t, e, email, tid)
	}
	return hum
}

func freshEmail() string {
	b := make([]byte, 5)
	rand.Read(b) //nolint:errcheck
	return hex.EncodeToString(b) + "@example.com"
}

// join seats the human of email in tid too.
func join(t *testing.T, e *env, email, tid string) string {
	t.Helper()
	h := e.st.(store.Humans)
	now := time.Now()
	if err := h.PutInvite(context.Background(), store.Invite{TenantID: tid, Email: email, Role: rbac.Developer,
		InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	hum, err := h.Admit(context.Background(), store.Identity{Provider: "google", Subject: "s-" + email, Email: email}, tid, store.AdmitPolicy{}, now)
	if err != nil {
		t.Fatalf("admit to %s: %v", tid, err)
	}
	return hum
}

func realmDay(t *testing.T, out map[string]any, day string) map[string]any {
	t.Helper()
	days, _ := out["days"].([]any)
	for _, x := range days {
		if m := x.(map[string]any); m["day"] == day {
			return m
		}
	}
	t.Fatalf("no day %s in %v", day, out)
	return nil
}

func realmWS(out map[string]any) map[string]string {
	got := map[string]string{}
	wss, _ := out["workspaces"].([]any)
	for _, x := range wss {
		m := x.(map[string]any)
		got[m["id"].(string)] = m["state"].(string)
	}
	return got
}

func mon(h, m int) time.Time { return time.Date(2026, 10, 5, h, m, 0, 0, time.UTC) }

// T-R1a through the route, T-R1c, T-RLS1: P and Q both in A and B. P's read
// joins A and B with the overlap; Q's rows never show. Each workspace's own
// GET /v1/me/hours shows only its own row and no cross-workspace field (T-R2a).
func TestRealmHoursAcrossWorkspaces(t *testing.T) {
	e, spy := realmEnv(t)
	a, _ := e.tenant()
	b, _ := e.tenant()
	p := person(t, e, a, b)
	q := person(t, e, a, b)
	putAs(t, e, a, p, spanEntry("2026-10-05", "ws", mon(9, 0), mon(12, 0)))
	putAs(t, e, b, p, spanEntry("2026-10-05", "ws", mon(10, 0), mon(13, 0)))
	putAs(t, e, a, q, spanEntry("2026-10-05", "ws", mon(14, 0), mon(18, 0)))

	code, out, raw := realmGet(t, e, p, realmWeek, nil)
	if code != http.StatusOK {
		t.Fatalf("GET as P: %d %s", code, raw)
	}
	monday := realmDay(t, out, "2026-10-05")
	if monday["reported"] != float64(360) || monday["actual"] != float64(240) || monday["overlap"] != float64(120) {
		t.Fatalf("monday: reported/actual/overlap %v/%v/%v, want 360/240/120: %v", monday["reported"], monday["actual"], monday["overlap"], monday)
	}
	ivs, _ := monday["overlap_intervals"].([]any)
	if len(ivs) != 1 {
		t.Fatalf("intervals: %v", ivs)
	}
	iv := ivs[0].(map[string]any)
	if iv["start"] != "2026-10-05T10:00:00Z" || iv["end"] != "2026-10-05T12:00:00Z" || fmt.Sprint(iv["workspaces"]) != fmt.Sprint([]any{min(a, b), max(a, b)}) {
		t.Fatalf("interval: %v", iv)
	}
	if ws := realmWS(out); ws[a] != "member" || ws[b] != "member" || len(ws) != 2 {
		t.Fatalf("workspaces: %v", ws)
	}
	if days, _ := out["days"].([]any); len(days) != 7 || out["incomplete"] != false || out["tz"] != "UTC" {
		t.Fatalf("window: %d days, incomplete %v, tz %v", len(days), out["incomplete"], out["tz"])
	}
	if tot := out["totals"].(map[string]any); tot["reported"] != float64(360) || tot["actual"] != float64(240) {
		t.Fatalf("totals: %v", tot)
	}
	// T-RLS1 control: Q's own read holds Q's 4:00 alone.
	_, qo, _ := realmGet(t, e, q, realmWeek, nil)
	if d := realmDay(t, qo, "2026-10-05"); d["reported"] != float64(240) || d["overlap"] != float64(0) {
		t.Fatalf("Q's monday: %v", d)
	}
	if r := spy.reads(); r[a] != 2 || r[b] != 2 { // P's GET and Q's
		t.Fatalf("one read per workspace per GET: %v", r)
	}
}

// T-R2a: after the realm read, A's own member route carries A's row only and
// no realm number or B id. Its control: the realm answer does carry them.
func TestRealmHoursNoLeakToWorkspace(t *testing.T) {
	e := hoursEnvWith(t, func(*hub.Options) {})
	a, _ := e.tenant()
	b, _ := e.tenant()
	p := person(t, e, a, b)
	putAs(t, e, a, p, spanEntry("2026-10-05", "ws", mon(9, 0), mon(12, 0)))
	putAs(t, e, b, p, spanEntry("2026-10-05", "ws", mon(10, 0), mon(13, 0)))
	banned := []string{b, `"actual"`, `"overlap"`, `"limits"`, `"reported"`}
	code, _, raw := realmGet(t, e, p, realmWeek, nil)
	for _, k := range banned {
		if code != http.StatusOK || !strings.Contains(raw, k) {
			t.Fatalf("control: the realm answer lacks %q: %d %s", k, code, raw)
		}
	}
	_, mine := call(t, e, a, http.MethodGet, "/v1/me/hours?period=2026-10-05", p, nil)
	body, _ := json.Marshal(mine)
	for _, k := range banned {
		if strings.Contains(string(body), k) {
			t.Fatalf("A's /v1/me/hours carries %q: %s", k, body)
		}
	}
	if row := hoursRow(t, mine, "2026-10-05", "ws"); row == nil || row["minutes"] != float64(180) {
		t.Fatalf("A's own row: %v", row)
	}
}

// T-RLS6: only the signed-in person; never a named workspace or member.
func TestRealmHoursPersonOnly(t *testing.T) {
	e, spy := realmEnv(t)
	a, _ := e.tenant()
	p := person(t, e, a)
	cases := []struct {
		name, as, path string
		hdr            map[string]string
		code           int
		errCode        string
	}{
		{"X-Spool-Tenant", p, realmWeek, map[string]string{hub.TenantHeader: a}, 400, "person_scope"},
		{"member=", p, realmWeek + "&member=" + p, nil, 400, "person_scope"},
		{"workspace=", p, realmWeek + "&workspace=" + a, nil, 400, "person_scope"},
		{"no session", "", realmWeek, nil, 401, "view_door"},
		{"box or agent token", "", realmWeek, map[string]string{"Authorization": "Bearer box-token"}, 403, "person_only"},
	}
	for _, tc := range cases {
		code, out, raw := realmGet(t, e, tc.as, tc.path, tc.hdr)
		if code != tc.code || out["error"] != tc.errCode && out["code"] != tc.errCode {
			t.Errorf("%s: %d %s, want %d %s", tc.name, code, raw, tc.code, tc.errCode)
		}
	}
	// Act-as (054): a live clone is refused, store-based.
	clone := person(t, e, a)
	spy.clones[clone] = true
	if code, _, raw := realmGet(t, e, clone, realmWeek, nil); code != http.StatusForbidden || !strings.Contains(raw, "person_only") {
		t.Fatalf("act-as clone: %d %s", code, raw)
	}
	if r := spy.reads(); len(r) != 0 {
		t.Fatalf("a refused request read workspaces: %v", r)
	}
	// Positive control: the person alone passes.
	if code, _, raw := realmGet(t, e, p, realmWeek, nil); code != http.StatusOK {
		t.Fatalf("P: %d %s", code, raw)
	}
}

func TestRealmHoursWindow(t *testing.T) {
	e, _ := realmEnv(t)
	a, _ := e.tenant()
	p := person(t, e, a)
	for _, path := range []string{
		"/v1/me/realm/hours?from=2026-10-05",
		"/v1/me/realm/hours?from=2026-10-05&to=2026-10-04",
		"/v1/me/realm/hours?from=2026-08-01&to=2026-10-02", // 63 days
		"/v1/me/realm/hours?from=05.10.2026&to=2026-10-06",
	} {
		if code, _, raw := realmGet(t, e, p, path, nil); code != http.StatusBadRequest || !strings.Contains(raw, "bad_window") {
			t.Errorf("%s: %d %s", path, code, raw)
		}
	}
	code, out, raw := realmGet(t, e, p, "/v1/me/realm/hours?from=2026-08-01&to=2026-10-01", nil)
	if days, _ := out["days"].([]any); code != http.StatusOK || len(days) != 62 {
		t.Fatalf("62 days: %d %s", code, raw)
	}
	// No window: the person's current ISO week.
	_, out, _ = realmGet(t, e, p, "/v1/me/realm/hours", nil)
	if out["from"] != "2026-10-05" || out["to"] != "2026-10-11" {
		t.Fatalf("default window: %v..%v", out["from"], out["to"])
	}
}

// T-PERF bound and T-RLS2: 20 workspaces read with at most 2 in flight, one
// read each; a 21st is 400. A workspace P is not in is never read, even
// holding rows with member_id = P.
func TestRealmHoursFanOutBound(t *testing.T) {
	e, spy := realmEnv(t)
	var tids []string
	for len(tids) < 20 {
		tid, _ := e.tenant()
		tids = append(tids, tid)
	}
	email := freshEmail()
	p := join(t, e, email, tids[0])
	for _, tid := range tids[1:] {
		join(t, e, email, tid)
	}
	for i, tid := range tids {
		putAs(t, e, tid, p, spanEntry("2026-10-05", "ws", mon(8, i), mon(8, i+1)))
	}
	c, _ := e.tenant() // not P's
	putAs(t, e, c, p, spanEntry("2026-10-05", "ws", mon(20, 0), mon(21, 0)))

	start := time.Now()
	code, out, raw := realmGet(t, e, p, realmWeek, nil)
	took := time.Since(start)
	if code != http.StatusOK {
		t.Fatalf("20 workspaces: %d %s", code, raw)
	}
	t.Logf("T-PERF local: 20 workspaces x 7 days in %v (n=1, %T)", took, spy.Store)
	reads := spy.reads()
	if len(reads) != 20 || reads[c] != 0 {
		t.Fatalf("reads %d workspaces, C %d: %v", len(reads), reads[c], reads)
	}
	if spy.maxInFlight > 2 || spy.maxInFlight < 1 {
		t.Fatalf("in flight: %d, want 1..2", spy.maxInFlight)
	}
	if d := realmDay(t, out, "2026-10-05"); d["reported"] != float64(20) || d["actual"] != float64(20) {
		t.Fatalf("monday: %v (C's hour must not count)", d)
	}
	extra, _ := e.tenant()
	if again := join(t, e, email, extra); again != p {
		t.Fatalf("one identity, two humans: %s %s", p, again)
	}
	if code, _, raw := realmGet(t, e, p, realmWeek, nil); code != http.StatusBadRequest || !strings.Contains(raw, "too_many_workspaces") {
		t.Fatalf("21 workspaces: %d %s", code, raw)
	}
}

// 5.2: a workspace that cannot be read is unavailable, its days incomplete;
// the rest is still computed. Never a silent zero.
func TestRealmHoursUnavailable(t *testing.T) {
	e, spy := realmEnv(t)
	a, _ := e.tenant()
	b, _ := e.tenant()
	p := person(t, e, a, b)
	putAs(t, e, a, p, spanEntry("2026-10-05", "ws", mon(9, 0), mon(10, 0)))
	putAs(t, e, b, p, spanEntry("2026-10-05", "ws", mon(11, 0), mon(12, 0)))
	spy.fail = b
	code, out, raw := realmGet(t, e, p, realmWeek, nil)
	if code != http.StatusOK {
		t.Fatalf("%d %s", code, raw)
	}
	if ws := realmWS(out); ws[a] != "member" || ws[b] != "unavailable" {
		t.Fatalf("workspaces: %v", ws)
	}
	monday := realmDay(t, out, "2026-10-05")
	if out["incomplete"] != true || monday["incomplete"] != true || monday["reported"] != float64(60) || fmt.Sprint(monday["unavailable"]) != fmt.Sprint([]any{b}) {
		t.Fatalf("monday: %v", monday)
	}
}

// C5, C6, T-RLS3: B's membership past access_until -> no live B read, only
// the receipt, reported and unplaced (receipts keep no times, Q5 A).
func TestRealmHoursLeftWorkspaceReceipt(t *testing.T) {
	e, spy := realmEnv(t)
	a, _ := e.tenant()
	b, _ := e.tenant()
	p := person(t, e, a, b)
	putAs(t, e, b, p, spanEntry("2026-10-06", "ws", time.Date(2026, 10, 6, 9, 0, 0, 0, time.UTC), time.Date(2026, 10, 6, 10, 0, 0, 0, time.UTC)))
	gone := time.Now().Add(-time.Hour)
	au, ok := e.st.(interface {
		SetMemberAccessUntil(ctx context.Context, tenant, humanID string, until *time.Time) error
	})
	if !ok {
		t.Skip("store has no access_until")
	}
	if err := au.SetMemberAccessUntil(context.Background(), b, p, &gone); err != nil {
		t.Fatal(err)
	}
	spy.receipts = []store.RealmReceipt{{WorkspaceID: b, WorkspaceName: "Beta", Day: "2026-10-06", Minutes: 300,
		Label: "workspace", Kind: "work", ApprovalState: store.HoursApproved, ApproverName: "FirstName LastName"}}
	code, out, raw := realmGet(t, e, p, realmWeek, nil)
	if code != http.StatusOK {
		t.Fatalf("%d %s", code, raw)
	}
	if r := spy.reads(); r[b] != 0 || r[a] != 1 {
		t.Fatalf("reads: %v (B is past access_until)", r)
	}
	if ws := realmWS(out); ws[b] != "left" || ws[a] != "member" {
		t.Fatalf("workspaces: %v", ws)
	}
	tue := realmDay(t, out, "2026-10-06")
	if tue["reported"] != float64(300) || tue["unplaced"] != float64(300) || tue["approx"] != true || tue["actual"] != float64(300) {
		t.Fatalf("tuesday: %v", tue)
	}
}

// C3, C4: the realm profile's zone buckets the spans (a span on Monday
// evening UTC is Tuesday in Helsinki); the limits in force come back for the
// WUI's warning, and no number is judged here.
func TestRealmHoursZoneAndLimits(t *testing.T) {
	e, _ := realmEnv(t)
	a, _ := e.tenant()
	p := person(t, e, a)
	putAs(t, e, a, p, spanEntry("2026-10-05", "ws", mon(22, 0), mon(23, 0)))
	rs := e.st.(store.Realm)
	ctx := context.Background()
	if err := rs.PutRealmProfile(ctx, p, store.RealmProfile{TimeZone: "Europe/Helsinki"}, hoursNow); err != nil {
		t.Fatal(err)
	}
	week, day := 2700, 480
	for _, l := range []store.RealmLimits{
		{ValidFrom: "2026-09-01", WeekLimitMinutes: &week},
		{ValidFrom: "2026-10-01", DayLimitMinutes: &day, WeekLimitMinutes: &week},
		{ValidFrom: "2026-10-08", WeekLimitMinutes: &week},
		{ValidFrom: "2026-11-01", DayLimitMinutes: &day},
	} {
		if err := rs.AppendRealmLimits(ctx, p, l, hoursNow); err != nil {
			t.Fatal(err)
		}
	}
	code, out, raw := realmGet(t, e, p, realmWeek+"&tz=America/New_York", nil)
	if code != http.StatusOK || out["tz"] != "Europe/Helsinki" || out["tz_source"] != "profile" {
		t.Fatalf("zone: %d %s", code, raw)
	}
	if d := realmDay(t, out, "2026-10-06"); d["actual"] != float64(60) {
		t.Fatalf("tuesday in Helsinki: %v", d)
	}
	if d := realmDay(t, out, "2026-10-05"); d["actual"] != float64(0) {
		t.Fatalf("monday in Helsinki: %v", d)
	}
	ls, _ := out["limits"].([]any)
	var from []string
	for _, x := range ls {
		from = append(from, x.(map[string]any)["valid_from"].(string))
	}
	if strings.Join(from, ",") != "2026-10-01,2026-10-08" {
		t.Fatalf("limits: %v", ls)
	}
}

// Reported counts today's open suggestions (6.2 step 2) as "open"; an entered
// target is not suggested twice.
func TestRealmHoursOpenSuggestion(t *testing.T) {
	e := hoursEnvWith(t, func(*hub.Options) {})
	a, _ := e.tenant()
	p := person(t, e, a)
	wed := time.Date(2026, 10, 7, 9, 0, 0, 0, time.UTC)
	var ms []store.HoursMinute
	for i := 0; i < 30; i++ {
		ms = append(ms, store.HoursMinute{At: wed.Add(time.Duration(i) * time.Minute), Target: "t:task-a", Src: store.HoursSrcTab, TZ: "UTC"})
	}
	if err := hoursStore(e).UpsertHoursMinutes(context.Background(), a, p, ms); err != nil {
		t.Fatal(err)
	}
	_, out, raw := realmGet(t, e, p, realmWeek, nil)
	d := realmDay(t, out, "2026-10-07")
	if d["reported"] != float64(30) || d["open"] != float64(30) || d["actual"] != float64(30) || d["approx"] != false {
		t.Fatalf("wednesday: %v (%s)", d, raw)
	}
	putAs(t, e, a, p, spanEntry("2026-10-07", "t:task-a", wed, wed.Add(30*time.Minute)))
	_, out, _ = realmGet(t, e, p, realmWeek, nil)
	if d := realmDay(t, out, "2026-10-07"); d["reported"] != float64(30) || d["open"] != float64(0) {
		t.Fatalf("entered: %v", d)
	}
}

// The one preflight of /v1/me/realm/hours serves this GET and 118 T004's PUT.
func TestRealmHoursPreflight(t *testing.T) {
	e, _ := realmEnv(t)
	req, _ := http.NewRequest(http.MethodOptions, e.url("api")+"/v1/me/realm/hours", nil)
	req.Header.Set("Origin", wuiOrigin)
	req.Header.Set("Access-Control-Request-Method", http.MethodPut)
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if got := resp.Header.Get("Access-Control-Allow-Methods"); resp.StatusCode != http.StatusNoContent || got != "GET, PUT" {
		t.Fatalf("preflight: %d methods %q", resp.StatusCode, got)
	}
}
