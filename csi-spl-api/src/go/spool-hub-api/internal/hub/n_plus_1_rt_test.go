package hub_test

// perf round 4 G2 (kill N+1 query loops): Postgres round trips of the two
// routes that read once per item, counted by the TCP proxy of
// onsend_bench_test.go. GET /v1/tenant/channels read members + no_fallback per
// channel; GET /v1/view/locate/{id} probed one member tenant per round trip.
// Both must stay flat as the item count grows.
//
//	SPOOL_TEST_PG_DSN=... go test ./internal/hub -run TestNPlus1RoundTrips -v
//
// Skipped without SPOOL_TEST_PG_DSN (the memory store has no wire).

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// proxiedPG points SPOOL_TEST_PG_DSN at a counting proxy for this test.
func proxiedPG(t *testing.T) *pgProxy {
	t.Helper()
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatal(err)
	}
	if u.Host == "" { // a unix-socket DSN (host=...): nothing to proxy
		t.Skip("SPOOL_TEST_PG_DSN has no tcp host")
	}
	p := newPGProxy(t, u.Host)
	u.Host = p.ln.Addr().String()
	t.Setenv("SPOOL_TEST_PG_DSN", u.String())
	return p
}

// rtSample runs fn n times and returns the sorted round-trip counts.
func rtSample(p *pgProxy, n int, fn func()) []int64 {
	out := make([]int64, 0, n)
	for i := 0; i < n; i++ {
		time.Sleep(20 * time.Millisecond) // let background writes settle
		before := p.packets.Load()
		fn()
		time.Sleep(20 * time.Millisecond)
		out = append(out, p.packets.Load()-before)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

func TestNPlus1RoundTripsTenantChannels(t *testing.T) {
	p := proxiedPG(t)
	e := rbacEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	dev := seat(t, e, tid, rbac.Developer)
	list := func() int {
		code, body := call(t, e, tid, http.MethodGet, "/v1/tenant/channels", admin, nil)
		if code != http.StatusOK {
			t.Fatalf("list: %d %v", code, body)
		}
		return len(body["channels"].([]any))
	}
	const n = 5
	created := 0
	var rts [][]int64
	for _, want := range []int{3, 13} {
		for ; created < want; created++ {
			ch := fmt.Sprintf("np%02d", created)
			if code, out := call(t, e, tid, http.MethodPost, "/v1/channels", dev, map[string]string{"channel": ch, "name": ch}); code != http.StatusCreated {
				t.Fatalf("create %s: %d %v", ch, code, out)
			}
		}
		list() // warm the statement cache
		var rows int
		rt := rtSample(p, n, func() { rows = list() })
		rts = append(rts, rt)
		t.Logf("GET /v1/tenant/channels created=%d listed=%d RT(n=%d)=%v median=%d", want, rows, n, rt, rt[n/2])
	}
	// The read must not grow with the channel count: 10 more channels may
	// cost at most one round trip more (a background write in a sample).
	if rts[1][0] > rts[0][0]+1 {
		t.Fatalf("GET /v1/tenant/channels grows per channel: min %d at 3 created, %d at 13", rts[0][0], rts[1][0])
	}
}

func TestNPlus1RoundTripsLocate(t *testing.T) {
	p := proxiedPG(t)
	r := newDoorRig(t)
	first, _ := r.e.tenant()
	sub := "np1-" + first
	r.fake.Set(fakeidp.Person{Subject: sub, Email: sub + "@example.com", EmailVerified: true, Name: "FirstName LastName"}, false)
	hs := r.e.st.(store.Humans)
	admit := func(tn string) {
		if _, err := hs.Admit(context.Background(), store.Identity{Provider: "google", Subject: sub, Email: sub + "@example.com"},
			tn, store.AdmitPolicy{BootstrapOwner: true}, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	admit(first)
	if landed := r.signIn(t, first); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in: %s", landed)
	}
	const n = 5
	tenants := 1
	var rts [][]int64
	for _, k := range []int{1, 8} {
		for ; tenants < k; tenants++ {
			tn, _ := r.e.tenant()
			admit(tn)
		}
		unknown := uuidV4() // the worst case: every member tenant is searched
		locate := func() {
			if code, body := r.req(t, http.MethodGet, apiLabel, "/v1/view/locate/"+unknown, nil, nil); code != http.StatusNotFound {
				t.Fatalf("locate unknown: %d %s", code, body)
			}
		}
		locate()
		rt := rtSample(p, n, locate)
		rts = append(rts, rt)
		t.Logf("GET /v1/view/locate tenants=%d RT(n=%d)=%v median=%d", k, n, rt, rt[n/2])
	}
	if rts[1][0] > rts[0][0]+1 {
		t.Fatalf("locate grows per tenant: min %d at 1 tenant, %d at 8", rts[0][0], rts[1][0])
	}
}

// HUM-10: POST /v1/view/ids resolves every id of a body in one statement, so
// 50 ids cost what 1 costs.
func TestNPlus1RoundTripsViewIDs(t *testing.T) {
	p := proxiedPG(t)
	r := newPrivacyRig(t)
	const n = 5
	var rts [][]int64
	for _, k := range []int{1, 50} {
		ids := []string{r.priv, r.dm, r.public, r.public[:8]}
		for len(ids) < k {
			ids = append(ids, uuidV4())
		}
		ids = ids[:k]
		ask := func() {
			if code, _ := viewIDs(t, r, "HUM-1", ids...); code != http.StatusOK {
				t.Fatalf("view ids: %d", code)
			}
		}
		ask()
		rt := rtSample(p, n, ask)
		rts = append(rts, rt)
		t.Logf("POST /v1/view/ids ids=%d RT(n=%d)=%v median=%d", k, n, rt, rt[n/2])
	}
	if rts[1][0] > rts[0][0]+1 {
		t.Fatalf("view ids grows per id: min %d at 1 id, %d at 50", rts[0][0], rts[1][0])
	}
}
