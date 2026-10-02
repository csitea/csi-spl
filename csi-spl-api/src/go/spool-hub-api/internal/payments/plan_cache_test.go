package payments

import (
	"net/http/httptest"
	"testing"
)

// perf round 4 G11: the plan is the same bytes for every visitor, so the
// hosting edge and the browser may keep it 5 minutes; a checkout answer
// (buyer-specific) stays no-store. CONTROL: the 404 of an unknown checkout.
func TestPlanCacheHeaders(t *testing.T) {
	cfg := mustLoad(t, "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true", "SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000"})
	r := newRig(t, cfg)

	w := httptest.NewRecorder()
	r.h.ServeHTTP(w, httptest.NewRequest("GET", "/api/v1/checkout/plan", nil))
	if w.Code != 200 || w.Header().Get("Cache-Control") != "public, max-age=300" {
		t.Fatalf("plan: %d Cache-Control %q, want 200 public, max-age=300", w.Code, w.Header().Get("Cache-Control"))
	}
	if ct := w.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("plan Content-Type %q", ct)
	}

	w = httptest.NewRecorder()
	r.h.ServeHTTP(w, httptest.NewRequest("POST", "/api/v1/checkout", nil))
	if cc := w.Header().Get("Cache-Control"); cc == "public, max-age=300" {
		t.Fatalf("CONTROL: a checkout answer is cacheable: %q", cc)
	}
}
