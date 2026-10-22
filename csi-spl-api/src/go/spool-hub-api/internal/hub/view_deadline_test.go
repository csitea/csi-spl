package hub

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// TestViewDeadline (SPL-2866): a /v1/view/* request runs under a context
// deadline of ViewTimeout + viewDeadlineGrace and a statement budget of
// ViewTimeout; a 5xx it answers past the limit reads 503 view_timeout, one it
// answers inside the limit is kept. CONTROLS: OPTIONS, a non-view path and a
// zero ViewTimeout get neither deadline nor budget.
func TestViewDeadline(t *testing.T) {
	const limit = 80 * time.Millisecond
	type seen struct {
		deadline bool
		left     time.Duration
		budget   time.Duration
	}
	var got seen
	var wait time.Duration
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		dl, ok := r.Context().Deadline()
		got = seen{deadline: ok, left: time.Until(dl), budget: store.StatementTimeout(r.Context())}
		if wait > 0 {
			select {
			case <-time.After(wait):
			case <-r.Context().Done():
			}
		}
		writeErr(w, http.StatusInternalServerError, "internal", "channels unavailable")
	})
	serve := func(timeout time.Duration, method, path string) *httptest.ResponseRecorder {
		s := &Server{o: Options{ViewTimeout: timeout}}
		rec := httptest.NewRecorder()
		s.viewDeadline(h).ServeHTTP(rec, httptest.NewRequest(method, path, nil))
		return rec
	}
	token := func(rec *httptest.ResponseRecorder) string {
		var b struct{ Error string }
		json.Unmarshal(rec.Body.Bytes(), &b) //nolint:errcheck
		return b.Error
	}

	rec := serve(limit, http.MethodGet, "/v1/view/channels")
	if !got.deadline || got.left > limit+viewDeadlineGrace || got.left < limit || got.budget != limit {
		t.Fatalf("view: deadline %v in %s, budget %s; want %s + %s and %s", got.deadline, got.left, got.budget, limit, viewDeadlineGrace, limit)
	}
	if rec.Code != http.StatusInternalServerError || token(rec) != "internal" {
		t.Fatalf("a 500 inside the limit must stay itself: %d %s", rec.Code, rec.Body)
	}

	wait = 2 * limit
	start := time.Now()
	rec = serve(limit, http.MethodGet, "/v1/view/channels")
	if rec.Code != http.StatusServiceUnavailable || token(rec) != viewTimeoutToken {
		t.Fatalf("a 500 past the limit: %d %s, want 503 %s", rec.Code, rec.Body, viewTimeoutToken)
	}
	if took := time.Since(start); took > limit+viewDeadlineGrace {
		t.Fatalf("answered after %s", took)
	}

	wait = 0
	for _, c := range []struct {
		name          string
		timeout       time.Duration
		method, route string
	}{
		{"OPTIONS", limit, http.MethodOptions, "/v1/view/channels"},
		{"not a view", limit, http.MethodGet, "/v1/me/reads"},
		{"no limit", 0, http.MethodGet, "/v1/view/channels"},
	} {
		got = seen{}
		serve(c.timeout, c.method, c.route)
		if got.deadline || got.budget != 0 {
			t.Errorf("CONTROL %s: deadline %v, budget %s; want neither", c.name, got.deadline, got.budget)
		}
	}
}
