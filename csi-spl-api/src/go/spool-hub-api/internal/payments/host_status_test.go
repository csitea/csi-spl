package payments

import (
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/022 FR-004: a paid checkout reports its tenant host and whether the
// reconcile has provisioned it yet; the WUI shows "being prepared" on pending.
func TestCheckoutHostStatus(t *testing.T) {
	cfg := mustLoad(t, "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true"})
	r := newRig(t, cfg)
	code, co := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "acme", "email": "buyer@example.com"})
	if code != 201 {
		t.Fatalf("checkout %d %v", code, co)
	}
	id, tok := co["checkout_id"].(string), co["claim_token"].(string)
	_, s := r.do(t, "GET", "/api/v1/checkout/"+id, nil)
	if s["tenant_host"] != "acme.dev.example.test" || s["host_status"] != nil {
		t.Fatalf("pending checkout: want tenant_host and no host_status, got %v", s)
	}
	if code, f := r.do(t, "POST", "/api/v1/checkout/fake-pay", map[string]string{"checkout_id": id}); code != 200 {
		t.Fatalf("fake-pay %d %v", code, f)
	}
	if _, s := r.do(t, "GET", "/api/v1/checkout/"+id, nil); s["host_status"] != store.HostPending {
		t.Fatalf("paid, host not provisioned: want pending, got %v", s)
	}
	// a failed attempt is retried by the next reconcile: the buyer still sees pending
	if err := r.st.SetTenantHost(t.Context(), "acme", store.HostFailed, "cert", time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, s := r.do(t, "GET", "/api/v1/checkout/"+id, nil); s["host_status"] != store.HostPending {
		t.Fatalf("failed host: want pending to the buyer, got %v", s)
	}
	code, cl := r.do(t, "POST", "/api/v1/checkout/claim", map[string]string{"checkout_id": id, "claim_token": tok})
	if code != 200 || cl["host_status"] != store.HostPending || cl["tenant_host"] != "acme.dev.example.test" {
		t.Fatalf("claim: want host_status pending, got %d %v", code, cl)
	}
	// CONTROL: the reconcile marks it ready, and the same read flips
	if err := r.st.SetTenantHost(t.Context(), "acme", store.HostReady, "", time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, s := r.do(t, "GET", "/api/v1/checkout/"+id, nil); s["host_status"] != store.HostReady {
		t.Fatalf("ready host: got %v", s)
	}
}
