package hub_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// mktIDs are fresh workspace ids, known before the hub starts so the
// allow-list can name them (unique per run: the Postgres store is shared).
func mktIDs(n int) []string {
	out := make([]string, n)
	for i := range out {
		b := make([]byte, 4)
		rand.Read(b) //nolint:errcheck
		out[i] = "m" + hex.EncodeToString(b)
	}
	return out
}

func mktEnv(t *testing.T, allow []string, ids ...string) *env {
	t.Helper()
	e := rbacEnv(t, func(o *hub.Options) { o.MarketingWorkspaces = allow })
	for _, id := range ids {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
	}
	return e
}

// spec 090 §15: the effective switch is (allow-listed) AND (the admin's flag).
// Runs on the memory store, and on Postgres when SPOOL_TEST_PG_DSN is set.
func TestMarketingSwitch(t *testing.T) {
	ids := mktIDs(2)
	listed, unlisted := ids[0], ids[1]
	e := mktEnv(t, []string{listed}, listed, unlisted)
	admin, dev := seat(t, e, listed, rbac.Admin), seat(t, e, listed, rbac.Developer)

	// CONTROL: outside the allow-list the toggle is refused (404) even for
	// its admin, and the probe is 404.
	out := seat(t, e, unlisted, rbac.Admin)
	if code, _ := call(t, e, unlisted, http.MethodPatch, "/v1/marketing/settings", out, map[string]any{"enabled": true}); code != http.StatusNotFound {
		t.Fatalf("CONTROL: unlisted admin toggled marketing: %d, want 404", code)
	}
	for _, p := range []string{"/v1/marketing/settings", "/v1/marketing"} {
		if code, _ := call(t, e, unlisted, http.MethodGet, p, out, nil); code != http.StatusNotFound {
			t.Fatalf("CONTROL: unlisted GET %s: %d, want 404", p, code)
		}
	}
	// A non-admin of a listed workspace may not read or flip the switch.
	if code, body := call(t, e, listed, http.MethodPatch, "/v1/marketing/settings", dev, map[string]any{"enabled": false}); code != http.StatusForbidden || body["permission"] != rbac.TenantSettings {
		t.Fatalf("CONTROL: developer toggled marketing: %d %v, want 403 %s", code, body, rbac.TenantSettings)
	}
	if code, _ := call(t, e, listed, http.MethodGet, "/v1/marketing/settings", dev, nil); code != http.StatusForbidden {
		t.Fatalf("CONTROL: developer read the switch: %d, want 403", code)
	}
	// CONTROL: allow-listed starts OFF (owner 5cd2e544): the probe is 404
	// until the admin turns it on.
	if code, body := call(t, e, listed, http.MethodGet, "/v1/marketing/settings", admin, nil); code != 200 || body["enabled"] != false {
		t.Fatalf("CONTROL: fresh listed switch: %d %v, want 200 enabled=false", code, body)
	}
	if code, _ := call(t, e, listed, http.MethodGet, "/v1/marketing", dev, nil); code != http.StatusNotFound {
		t.Fatalf("CONTROL: fresh listed probe: %d, want 404 (off by default)", code)
	}
	if code, body := call(t, e, listed, http.MethodPatch, "/v1/marketing/settings", admin, map[string]any{"enabled": true}); code != 200 || body["enabled"] != true {
		t.Fatalf("turn on: %d %v", code, body)
	}
	if code, _ := call(t, e, listed, http.MethodGet, "/v1/marketing", dev, nil); code != 200 {
		t.Fatalf("listed + on probe: %d, want 200", code)
	}
	// CONTROL: the admin turns it off, and every marketing route is 404 again;
	// the switch itself stays reachable, so the admin can turn it back on.
	if code, body := call(t, e, listed, http.MethodPatch, "/v1/marketing/settings", admin, map[string]any{"enabled": false}); code != 200 || body["enabled"] != false {
		t.Fatalf("turn off: %d %v", code, body)
	}
	if code, _ := call(t, e, listed, http.MethodGet, "/v1/marketing", dev, nil); code != http.StatusNotFound {
		t.Fatalf("CONTROL: flag off but the probe answered %d, want 404", code)
	}
	if code, _ := call(t, e, listed, http.MethodPatch, "/v1/marketing/settings", admin, map[string]any{}); code != http.StatusBadRequest {
		t.Fatalf("PATCH without enabled: %d, want 400", code)
	}
}

// "all" admits every workspace but the demo one; an empty allow-list admits none.
func TestMarketingSwitchAllowListAll(t *testing.T) {
	ids := mktIDs(2)
	e := mktEnv(t, []string{"all"}, ids[0])
	admin := seat(t, e, ids[0], rbac.Admin)
	if code, body := call(t, e, ids[0], http.MethodPatch, "/v1/marketing/settings", admin, map[string]any{"enabled": true}); code != 200 || body["enabled"] != true {
		t.Fatalf("all: %d %v, want 200 enabled", code, body)
	}
	if code, _ := call(t, e, ids[0], http.MethodGet, "/v1/marketing", admin, nil); code != 200 {
		t.Fatalf("all + on probe: %d, want 200", code)
	}
	ids = mktIDs(1)
	e = mktEnv(t, nil, ids...)
	admin = seat(t, e, ids[0], rbac.Admin)
	if code, _ := call(t, e, ids[0], http.MethodPatch, "/v1/marketing/settings", admin, map[string]any{"enabled": true}); code != http.StatusNotFound {
		t.Fatalf("CONTROL: empty allow-list toggle: %d, want 404", code)
	}
	if code, _ := call(t, e, ids[0], http.MethodGet, "/v1/marketing", admin, nil); code != http.StatusNotFound {
		t.Fatalf("CONTROL: empty allow-list probe: %d, want 404", code)
	}
}

// CONTROL: the open demo workspace (specs/077) never gets marketing, even
// under "all" and even for its admin.
func TestMarketingSwitchNeverInDemo(t *testing.T) {
	e, demo := demoEnv(t, func(o *hub.Options) { o.MarketingWorkspaces = []string{"all"} })
	admin := seat(t, e, demo, rbac.Admin)
	for _, x := range []struct{ method, path string }{
		{http.MethodPatch, "/v1/marketing/settings"}, {http.MethodGet, "/v1/marketing/settings"}, {http.MethodGet, "/v1/marketing"},
	} {
		if code, _ := call(t, e, demo, x.method, x.path, admin, map[string]any{"enabled": true}); code != http.StatusForbidden {
			t.Fatalf("CONTROL: demo %s %s: %d, want 403", x.method, x.path, code)
		}
	}
}
