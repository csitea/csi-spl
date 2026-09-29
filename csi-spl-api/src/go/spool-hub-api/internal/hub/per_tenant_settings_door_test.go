package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// CLE-35099 (spec 023 addendum, rdb 0078): the control the owner asked for —
// a personal setting changed in one tenant does NOT move another. A member of
// two tenants sets a different theme in each through the real HTTP door; each
// tenant's GET /session answers its OWN value, and a change in one never
// changes the other. This is the per-tenant overlay + dual-write + the
// memberships-carried override, end to end.
func TestPerTenantSettingsIsolation(t *testing.T) {
	r := newDoorRig(t)
	a, _ := r.e.tenant()
	b, _ := r.e.tenant()
	hs := r.e.st.(store.Humans)
	alice := store.Identity{Provider: "google", Subject: "alice-sub", Email: "alice@example.com"}
	for _, tn := range []string{a, b} {
		if _, err := hs.Admit(context.Background(), alice, tn, store.AdmitPolicy{BootstrapOwner: true}, time.Now()); err != nil {
			t.Fatal(err)
		}
	}

	putTheme := func(theme string) {
		t.Helper()
		code, body := r.req(t, http.MethodPut, loginHost, "/api/v1/auth/preferences",
			http.Header{"Content-Type": {"application/json"}}, strings.NewReader(`{"preferred_theme":"`+theme+`"}`))
		if code != http.StatusOK {
			t.Fatalf("PUT preferences theme=%s: %d %s", theme, code, body)
		}
	}
	theme := func() string {
		t.Helper()
		resp, err := r.browser.Get("http://" + loginHost + "/api/v1/auth/session")
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var s struct {
			PreferredTheme *string `json:"preferred_theme"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&s); err != nil {
			t.Fatal(err)
		}
		if s.PreferredTheme == nil {
			return ""
		}
		return *s.PreferredTheme
	}

	// Bound to A: set the theme dark; A's session answers dark.
	if landed := r.signIn(t, a); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in A: %s", landed)
	}
	putTheme("dark")
	if got := theme(); got != "dark" {
		t.Fatalf("A after set dark: %q", got)
	}

	// Bound to B: set the theme light; B's session answers light.
	if landed := r.signIn(t, b); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in B: %s", landed)
	}
	putTheme("light")
	if got := theme(); got != "light" {
		t.Fatalf("B after set light: %q", got)
	}

	// Back to A: STILL dark — B's change did not move A (the isolation control).
	if landed := r.signIn(t, a); strings.Contains(landed, "auth_error") {
		t.Fatalf("re-sign-in A: %s", landed)
	}
	if got := theme(); got != "dark" {
		t.Fatalf("A after B changed to light: %q, want dark (per-tenant isolation broken)", got)
	}

	// And B is still light.
	if landed := r.signIn(t, b); strings.Contains(landed, "auth_error") {
		t.Fatalf("re-sign-in B: %s", landed)
	}
	if got := theme(); got != "light" {
		t.Fatalf("B after re-checking A: %q, want light", got)
	}
}
