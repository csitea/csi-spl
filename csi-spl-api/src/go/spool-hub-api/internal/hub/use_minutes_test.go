package hub_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"math/big"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Hours of use (SPL-5709, rdb 0289, spec 143 usage-hours.md). Memory, and
// Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full). Each rig runs its
// clock on a random day of 2031, so on the shared Postgres the hub total of
// that day holds this rig's rows only.

type useRig struct {
	e     *env
	op    string
	clock atomic.Int64 // unix seconds
	day   string
}

func newUseRig(t *testing.T) *useRig {
	t.Helper()
	r := &useRig{op: newTenantID("op")}
	n, _ := rand.Int(rand.Reader, big.NewInt(360))
	start := time.Date(2031, 1, 1, 10, 0, 30, 0, time.UTC).AddDate(0, 0, int(n.Int64()))
	r.clock.Store(start.Unix())
	r.day = start.Format("2006-01-02")
	r.e = rbacEnv(t, func(o *hub.Options) {
		o.OperatorTenant = r.op
		o.Now = func() time.Time { return time.Unix(r.clock.Load(), 0).UTC() }
	})
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := r.e.st.CreateTenant(context.Background(), store.Tenant{ID: r.op, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	return r
}

func (r *useRig) tick(d time.Duration) { r.clock.Add(int64(d / time.Second)) }

// beat is one heartbeat of hum in tid; it answers counted.
func (r *useRig) beat(t *testing.T, tid, hum string) bool {
	t.Helper()
	code, out := call(t, r.e, tid, http.MethodPost, "/v1/me/use-minute", hum, nil)
	if code != http.StatusOK {
		t.Fatalf("POST use-minute as %s in %s: %d %v", hum, tid, code, out)
	}
	return out["counted"] == true
}

// useRow is hum's row of a GET /v1/reporting/use answer, nil when none.
func useRow(out map[string]any, hum string) map[string]any {
	ms, _ := out["members"].([]any)
	for _, x := range ms {
		if m := x.(map[string]any); m["human_id"] == hum {
			return m
		}
	}
	return nil
}

func (r *useRig) report(t *testing.T, tid, as, query string) map[string]any {
	t.Helper()
	code, out := call(t, r.e, tid, http.MethodGet, "/v1/reporting/use?from="+r.day+"&to="+r.day+query, as, nil)
	if code != http.StatusOK {
		t.Fatalf("GET reporting/use%s as %s: %d %v", query, as, code, out)
	}
	return out
}

// A second tab does not double-count: the same person's heartbeats inside
// one minute count once in the workspace and once in the hub; the next
// minute counts again. The same minute in a second workspace counts there
// too, but the hub total holds it once.
// RED CONTROL (run 2026-11-16, memory and Postgres): RecordUseMinute
// without the last_minute guard (the upsert's WHERE, countUseRow's check)
// fails here with "tab 2, minute 1: counted twice", and TestUseHubTotal
// with "hub total: ... minutes:3 ..., want 2 minutes".
func TestUseMinuteSecondTabCountsOnce(t *testing.T) {
	r := newUseRig(t)
	ws1, _ := r.e.tenant()
	ws2, _ := r.e.tenant()
	email := newTenantID("u") + "@example.com"
	p := costSeatAs(t, r.e, ws1, email, rbac.Developer)
	if p2 := costSeatAs(t, r.e, ws2, email, rbac.Developer); p2 != p {
		t.Fatalf("one person, two ids: %s %s", p, p2)
	}
	owner := seat(t, r.e, ws1, rbac.BizOwner)
	if !r.beat(t, ws1, p) {
		t.Fatal("tab 1, minute 1: not counted")
	}
	r.tick(10 * time.Second)
	if r.beat(t, ws1, p) {
		t.Fatal("tab 2, minute 1: counted twice")
	}
	if !r.beat(t, ws2, p) {
		t.Fatal("ws2, minute 1: not counted in ws2")
	}
	r.tick(time.Minute)
	if !r.beat(t, ws1, p) || r.beat(t, ws1, p) {
		t.Fatal("minute 2: want one count of two tabs")
	}
	row := useRow(r.report(t, ws1, owner, ""), p)
	if row == nil || row["minutes_here"] != 2.0 || row["minutes_hub"] != 2.0 {
		t.Fatalf("ws1 row: %v, want here 2, hub 2 (minute 1 in ws1 and ws2 counts once)", row)
	}
	if row := useRow(r.report(t, ws2, p, "&human_id="+p), p); row == nil || row["minutes_here"] != 1.0 || row["minutes_hub"] != 2.0 {
		t.Fatalf("ws2 own row: %v, want here 1, hub 2", row)
	}
}

// A member reading others' hours is refused: a developer asking for the
// whole workspace or for another member is 403 reporting.use; their own
// row is theirs. CONTROL: the biz owner and an admin read every member.
// RED CONTROL (run 2026-11-16, memory): useReportCaller with the
// a.HasAny(useReaders...) check made always true fails here with
// "developer reads \"\": 200 ..., want 403 reporting.use".
func TestUseReportMemberSeesOnlyOwn(t *testing.T) {
	r := newUseRig(t)
	ws, _ := r.e.tenant()
	dev, other := seat(t, r.e, ws, rbac.Developer), seat(t, r.e, ws, rbac.Developer)
	owner, admin := seat(t, r.e, ws, rbac.BizOwner), seat(t, r.e, ws, rbac.Admin)
	r.beat(t, ws, other)
	for _, q := range []string{"", "&human_id=" + other} {
		code, out := call(t, r.e, ws, http.MethodGet, "/v1/reporting/use?from="+r.day+"&to="+r.day+q, dev, nil)
		if code != http.StatusForbidden || out["permission"] != "reporting.use" {
			t.Errorf("developer reads %q: %d %v, want 403 reporting.use", q, code, out)
		}
	}
	own := r.report(t, ws, dev, "&human_id="+dev)
	if ms, _ := own["members"].([]any); len(ms) != 1 || useRow(own, dev) == nil {
		t.Fatalf("own read: %v, want the caller's row only", own["members"])
	}
	for _, as := range []string{owner, admin} {
		out := r.report(t, ws, as, "")
		if row := useRow(out, other); row == nil || row["minutes_here"] != 1.0 {
			t.Errorf("%s reads %v, want other's row with 1 minute", as, out["members"])
		}
		if useRow(out, dev) == nil {
			t.Errorf("%s: dev's row missing (a member with no minutes reads 0)", as)
		}
	}
	if code, _ := call(t, r.e, ws, http.MethodGet, "/v1/reporting/use", "", nil); code < 400 {
		t.Errorf("anonymous read: %d", code)
	}
}

// The hub total is the operator workspace's admins': another workspace's
// admin and the operator workspace's developer are 403. It counts each
// person and minute once and lists the workspaces. A bad range is 400.
func TestUseHubTotal(t *testing.T) {
	r := newUseRig(t)
	ws, _ := r.e.tenant()
	opAdmin, opDev := seat(t, r.e, r.op, rbac.Admin), seat(t, r.e, r.op, rbac.Developer)
	wsAdmin := seat(t, r.e, ws, rbac.Admin)
	email := newTenantID("u") + "@example.com"
	p := costSeatAs(t, r.e, ws, email, rbac.Developer)
	costSeatAs(t, r.e, r.op, email, rbac.Developer)
	r.beat(t, ws, p)
	r.beat(t, r.op, p)
	r.beat(t, ws, wsAdmin)
	path := "/v1/operator/use?from=" + r.day + "&to=" + r.day
	for _, as := range [][2]string{{ws, wsAdmin}, {r.op, opDev}} {
		if code, _ := call(t, r.e, as[0], http.MethodGet, path, as[1], nil); code != http.StatusForbidden {
			t.Errorf("%s in %s reads the hub total: %d", as[1], as[0], code)
		}
	}
	code, out := call(t, r.e, r.op, http.MethodGet, path, opAdmin, nil)
	if code != http.StatusOK || out["minutes"] != 2.0 || out["people"] != 2.0 {
		t.Fatalf("hub total: %d %v, want 2 minutes, 2 people", code, out)
	}
	wsRows, _ := out["workspaces"].([]any)
	if len(wsRows) != 2 {
		t.Fatalf("workspaces: %v, want ws and op", wsRows)
	}
	if code, _ := call(t, r.e, r.op, http.MethodGet, "/v1/operator/use?from=2031-02-02&to=2031-02-01", opAdmin, nil); code != http.StatusBadRequest {
		t.Errorf("from after to: %d", code)
	}
	if code, _ := call(t, r.e, r.op, http.MethodGet, "/v1/operator/use?from=2029-01-01&to=2031-01-01", opAdmin, nil); code != http.StatusBadRequest {
		t.Errorf("a two-year range: %d", code)
	}
}
