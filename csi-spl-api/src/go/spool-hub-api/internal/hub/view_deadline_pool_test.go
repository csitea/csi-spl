package hub_test

import (
	"context"
	"io"
	"net/http"
	"net/http/cookiejar"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// TestViewDeadlineFreesPoolForSignIn (Postgres, SPL-2866, the prd incident of
// 2026-10-22): on a pool of 2, two GET /v1/view/channels whose statement
// cannot finish (a lock held outside the hub stands in for the slow view
// query) hold both connections. Today (ViewTimeout 0, the CONTROL) a fresh
// sign-in then waits for a connection past its 4 s client limit, while
// Postgres has free connections: the starvation is the hub's own pool. With
// a 1 s ViewTimeout both views answer 503 view_timeout near 1 s, their
// connections come back, and the sign-in lands. Logs each wait (n = 1 per
// case).
//
//	SPOOL_TEST_PG_DSN=... go test ./internal/hub -run TestViewDeadlineFreesPoolForSignIn -v
func TestViewDeadlineFreesPoolForSignIn(t *testing.T) {
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	for _, c := range []struct {
		name    string
		limit   time.Duration
		starved bool
	}{
		{"CONTROL no limit", 0, true},
		{"limit 1s", time.Second, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv("SPOOL_TEST_PG_DSN", dsn+"&pool_max_conns=2")
			viewsHoldPool(t, dsn, c.limit, c.starved)
		})
	}
}

func viewsHoldPool(t *testing.T, dsn string, limit time.Duration, starved bool) {
	const signInLimit = 4 * time.Second
	r := newDoorRig(t, func(o *hub.Options) { o.ViewTimeout = limit })
	tenant, _ := r.e.tenant()
	if landed := r.signIn(t, tenant); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in landed on %s", landed)
	}
	// Warm both pool connections: pgx prepares a statement it has not seen
	// on a connection BEFORE the batch's scope statement runs, so a cold
	// parse waits on the lock under the role's own statement_timeout and only
	// the context deadline ends it; warm, the wait is the read's, under the
	// budget, as a slow prd read is.
	var warm sync.WaitGroup
	for range 2 {
		warm.Add(1)
		go func() {
			defer warm.Done()
			r.get(t, tenant, "/v1/view/channels")
		}()
	}
	warm.Wait()
	ctx := context.Background()
	lock, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close(ctx) //nolint:errcheck
	tx, err := lock.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	released := false
	release := func() {
		if !released {
			released = true
			tx.Rollback(ctx) //nolint:errcheck
		}
	}
	defer release()
	if _, err := tx.Exec(ctx, `LOCK TABLE messages IN ACCESS EXCLUSIVE MODE`); err != nil {
		t.Fatal(err)
	}

	type answer struct {
		code int
		body string
		took time.Duration
	}
	answers := make([]answer, 2)
	var wg sync.WaitGroup
	start := time.Now()
	for i := range answers {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			req, _ := http.NewRequest(http.MethodGet, r.e.url(tenant)+"/v1/view/channels", nil)
			req.Header.Set("Origin", wuiOrigin)
			resp, err := r.browser.Do(req)
			if err != nil {
				answers[i] = answer{body: err.Error(), took: time.Since(start)}
				return
			}
			b, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			answers[i] = answer{resp.StatusCode, string(b), time.Since(start)}
		}(i)
	}
	waitLockWaiters(t, tx, 2)

	jar, _ := cookiejar.New(nil)
	fresh := &http.Client{Jar: jar, Transport: r.browser.Transport, Timeout: signInLimit}
	signStart := time.Now()
	resp, err := fresh.Get("http://" + loginHost + "/api/v1/auth/google/start?redirect=/t&tenant=" + tenant)
	signTook := time.Since(signStart)
	if err == nil {
		resp.Body.Close()
	}
	t.Logf("limit %s: sign-in took %s (err %v)", limit, signTook.Round(time.Millisecond), err)
	release()
	wg.Wait()
	for i, a := range answers {
		t.Logf("view %d: %d after %s %s", i, a.code, a.took.Round(time.Millisecond), strings.TrimSpace(a.body))
	}

	if starved {
		if err == nil {
			t.Fatalf("CONTROL: the sign-in landed in %s while two views held the pool: the rig does not starve it", signTook)
		}
		return
	}
	if err != nil || strings.Contains(resp.Request.URL.String(), "auth_error") {
		t.Fatalf("sign-in starved behind the views: %v after %s", err, signTook)
	}
	for i, a := range answers {
		if a.code != http.StatusServiceUnavailable || errToken([]byte(a.body)) != "view_timeout" || a.took > limit+2*time.Second {
			t.Errorf("view %d: %d after %s %s; want 503 view_timeout near %s", i, a.code, a.took, a.body, limit)
		}
	}
}

// waitLockWaiters waits until n backends wait on a lock (the views' reads
// queued behind tx's LOCK), so both pool connections are held.
func waitLockWaiters(t *testing.T, tx pgx.Tx, n int) {
	t.Helper()
	ctx := context.Background()
	for end := time.Now().Add(10 * time.Second); time.Now().Before(end); time.Sleep(20 * time.Millisecond) {
		var got int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM pg_stat_activity
			WHERE datname = current_database() AND wait_event_type = 'Lock'`).Scan(&got); err != nil {
			t.Fatal(err)
		}
		if got >= n {
			return
		}
	}
	t.Fatalf("the views never queued behind the lock (want %d waiters)", n)
}
