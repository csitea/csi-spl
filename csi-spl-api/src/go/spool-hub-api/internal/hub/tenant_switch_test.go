package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/026 §6: POST /api/v1/auth/tenant switches a member of two tenants
// between them without a new sign-in, refuses a tenant the human is not a
// member of, and the tenant switched into last is where a later session with
// no bound tenant lands (instead of 409 tenant_required).
func TestWorkspaceSwitch(t *testing.T) {
	r := newDoorRig(t)
	a, _ := r.e.tenant()
	b, _ := r.e.tenant()
	c, _ := r.e.tenant()
	// Its own person: the Postgres run shares humans across tests, and a
	// stamped last_active_at would end another test's unbound 409.
	sub := "switcher-" + a
	r.fake.Set(fakeidp.Person{Subject: sub, Email: sub + "@example.com", EmailVerified: true, Name: "FirstName LastName"}, false)
	hs := r.e.st.(store.Humans)
	for _, tn := range []string{a, b} {
		if _, err := hs.Admit(context.Background(), store.Identity{Provider: "google", Subject: sub, Email: sub + "@example.com"},
			tn, store.AdmitPolicy{BootstrapOwner: true}, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	aOther := ownedByInvite(t, r.e, a, "other-in-a-"+a)
	bOther := ownedByInvite(t, r.e, b, "other-in-b-"+b)
	ownedBy(t, r.e, c, "owner-of-c-"+c)

	switchTo := func(tenant string, h http.Header) (int, string) {
		t.Helper()
		if h == nil {
			h = http.Header{"Content-Type": {"application/json"}}
		}
		body, _ := json.Marshal(map[string]string{"tenant": tenant})
		return r.req(t, http.MethodPost, "login", "/api/v1/auth/tenant", h, strings.NewReader(string(body)))
	}
	roster := func() (int, string) {
		t.Helper()
		return r.req(t, http.MethodGet, apiLabel, "/v1/view/roster", nil, nil)
	}

	// CONTROL: no session, no switch.
	if code, body := switchTo(a, nil); code != http.StatusUnauthorized {
		t.Fatalf("anonymous switch: %d %s", code, body)
	}
	if landed := r.signIn(t, ""); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in: %s", landed)
	}
	if code, body := roster(); code != http.StatusConflict || errToken([]byte(body)) != "tenant_required" {
		t.Fatalf("unbound, never switched: %d %s", code, body)
	}

	// CONTROLS: not a member, a bad id, not JSON: refused, and nothing bound.
	if code, body := switchTo(c, nil); code != http.StatusForbidden || errToken([]byte(body)) != "not_member" {
		t.Fatalf("switch to a non-member tenant: %d %s", code, body)
	}
	if code, body := switchTo("Not A Tenant", nil); code != http.StatusBadRequest || errToken([]byte(body)) != "bad_tenant" {
		t.Fatalf("switch to a bad id: %d %s", code, body)
	}
	if code, body := switchTo(b, http.Header{"Content-Type": {"text/plain"}}); code != http.StatusUnsupportedMediaType {
		t.Fatalf("switch without JSON: %d %s", code, body)
	}
	if code, body := roster(); code != http.StatusConflict {
		t.Fatalf("a refused switch bound a tenant: %d %s", code, body)
	}

	// Switch to B: the api host serves B, and the answer is the new session.
	code, body := switchTo(b, nil)
	var sv sessionView
	if code != http.StatusOK || json.Unmarshal([]byte(body), &sv) != nil || sv.Tenant != b ||
		sv.ActiveTenant == nil || *sv.ActiveTenant != b {
		t.Fatalf("switch to B: %d %s", code, body)
	}
	if code, body := roster(); code != http.StatusOK || !strings.Contains(body, bOther) || strings.Contains(body, aOther) {
		t.Fatalf("api host after switch to B: %d %s", code, body)
	}
	// Idempotent, then back to A.
	if code, body := switchTo(b, nil); code != http.StatusOK {
		t.Fatalf("switch to B again: %d %s", code, body)
	}
	if code, body := switchTo(a, nil); code != http.StatusOK {
		t.Fatalf("switch to A: %d %s", code, body)
	}
	if code, body := roster(); code != http.StatusOK || !strings.Contains(body, aOther) || strings.Contains(body, bOther) {
		t.Fatalf("api host after switch to A: %d %s", code, body)
	}

	// Last used: a new sign-in with no tenant lands in A (switched into last).
	if landed := r.signIn(t, ""); strings.Contains(landed, "auth_error") {
		t.Fatalf("second sign-in: %s", landed)
	}
	sv = r.sessionView(t)
	if sv.Tenant != "" || sv.ActiveTenant == nil || *sv.ActiveTenant != a {
		t.Fatalf("unbound session after switches: %+v, want active %s", sv, a)
	}
	if code, body := roster(); code != http.StatusOK || !strings.Contains(body, aOther) {
		t.Fatalf("unbound api host after switches: %d %s", code, body)
	}
}
