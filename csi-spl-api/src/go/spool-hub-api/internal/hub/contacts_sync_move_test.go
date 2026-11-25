package hub_test

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 154 2.2 step 6 (SPL-6454, owner HUM-10 t1 85bdf803 msg deec5dc3):
// the Contacts switch in W2 while P1's binding is on in W1 reads state
// "elsewhere" with W1's display name, and POST /sync/move moves the binding
// to W2 in one call: 200 state "here", W1 now reads "elsewhere" with W2's
// name, and P1's contact list is unchanged. Without a Google connection in
// W2 the move is 409 gcal_not_connected and W1 keeps the binding. Red
// control on the parent (origin/master before SPL-6454): the GET carries no
// state and the move route answers 404, so this test fails there.
func TestContactsSyncMove(t *testing.T) {
	c := newContactsRig(t, onAll)
	ctx := context.Background()
	w1Name := "Workspace One"
	if err := c.r.e.st.(store.TenantSettings).SetTenantConfig(ctx, c.w1, store.TenantConfigPatch{DisplayName: &w1Name}); err != nil {
		t.Fatal(err)
	}
	c.create(t, c.b1, map[string]any{"first_name": "FirstName", "last_name": "LastName", "email": "first.last@example.com"})
	c.connect(t, c.w1, "p1.google@example.com")
	if code, _, out := c.do(t, c.b1, http.MethodPut, contactsBase+"/sync", map[string]any{"enabled": true}, nil); code != http.StatusNoContent {
		t.Fatalf("PUT sync on in W1 = %d %v, want 204", code, out)
	}
	state := func(b *http.Client, label string) map[string]any {
		t.Helper()
		code, raw, out := c.do(t, b, http.MethodGet, contactsBase+"/sync", nil, nil)
		if code != http.StatusOK {
			t.Fatalf("%s: GET sync = %d %s, want 200", label, code, raw)
		}
		return out
	}
	if got := state(c.b2, "W2 while on in W1"); got["state"] != "elsewhere" || got["workspace"] != w1Name || got["elsewhere"] != true {
		t.Errorf("W2 while on in W1: %v, want state elsewhere, workspace %q", got, w1Name)
	}
	if got := state(c.b1, "W1, on here"); got["state"] != "here" || got["enabled"] != true || got["workspace"] != nil {
		t.Errorf("W1, on here: %v, want state here, enabled, no workspace", got)
	}

	if code, _, out := c.do(t, c.b2, http.MethodPost, contactsBase+"/sync/move", nil, nil); code != http.StatusConflict || realmToken(out) != "gcal_not_connected" {
		t.Errorf("move to W2 with no Google connection there = %d %v, want 409 gcal_not_connected", code, out)
	}
	if b, err := c.r.e.st.(store.ContactsSyncs).ContactsSyncOf(ctx, c.p1); err != nil || b.Tenant != c.w1 || !b.Enabled {
		t.Errorf("P1's binding after the refused move = %+v %v, want W1's, on", b, err)
	}

	c.connect(t, c.w2, "p1.google@example.com")
	code, raw, out := c.do(t, c.b2, http.MethodPost, contactsBase+"/sync/move", nil, nil)
	if code != http.StatusOK || out["state"] != "here" || out["enabled"] != true {
		t.Fatalf("move to W2 = %d %s, want 200 state here, enabled", code, raw)
	}
	if b, err := c.r.e.st.(store.ContactsSyncs).ContactsSyncOf(ctx, c.p1); err != nil || b.Tenant != c.w2 || !b.Enabled {
		t.Errorf("P1's binding after the move = %+v %v, want W2's, on", b, err)
	}
	if got := state(c.b1, "W1 after the move"); got["state"] != "elsewhere" || got["workspace"] != c.w2 {
		t.Errorf("W1 after the move: %v, want state elsewhere, workspace %q (W2 has no display name: its id)", got, c.w2)
	}
	_, _, list := c.do(t, c.b1, http.MethodGet, contactsBase, nil, nil)
	if got := contactsOf(t, list); len(got) != 1 {
		t.Errorf("P1's contacts after the move: %d, want the 1 kept", len(got))
	}
	if code, _, out := c.do(t, c.b2, http.MethodPost, contactsBase+"/sync/move", nil, nil); code != http.StatusOK || out["state"] != "here" {
		t.Errorf("move again where the binding is = %d %v, want 200 here", code, out)
	}

	req, _ := http.NewRequest(http.MethodOptions, "http://api"+domain+contactsBase+"/sync/move", nil)
	req.Header.Set("Origin", wuiOrigin)
	req.Header.Set("Access-Control-Request-Method", "POST")
	resp, err := c.b1.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if m := resp.Header.Get("Access-Control-Allow-Methods"); !strings.Contains(m, "POST") {
		t.Errorf("OPTIONS sync/move Allow-Methods = %q, want POST", m)
	}
}
