package hub_test

import (
	"context"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Sign-in emails (owner HUM-10, t1 f265541a, msgs cca0746d + 39420f52): an
// admin of the workspace, or the member themselves, adds an address as
// PENDING; one public-provider sign-in that proves it, started from the
// member's own session (a link, LinkTo), turns it ACTIVE; a cold one or a
// native password sign-in never does. Memory, and Postgres under
// SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).
func TestSignInEmailRoutes(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	other, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	dev := seat(t, e, tid, rbac.Developer)
	x, xid := seatIdent(t, e, tid, rbac.Developer)
	stranger, strangerID := seatIdent(t, e, other, rbac.Developer)
	path := "/v1/members/" + x + "/emails"
	h := e.st.(store.Humans)
	ctx, now := context.Background(), time.Now()
	gmail := randHex(5) + "@example.org"

	if code, body := call(t, e, tid, http.MethodPost, path, dev, map[string]any{"email": gmail}); code != http.StatusForbidden {
		t.Fatalf("CONTROL non-admin adds for another member: %d %v", code, body)
	}
	// Security: an admin of this workspace cannot reach a human who is no
	// member of it, and the answer does not say the human exists.
	code, body := call(t, e, tid, http.MethodPost, "/v1/members/"+stranger+"/emails", admin, map[string]any{"email": gmail})
	if code != http.StatusNotFound || body["error"] != "not_found" {
		t.Fatalf("admin adds to another workspace's member: %d %v", code, body)
	}
	if code, body := call(t, e, tid, http.MethodPost, path, admin, map[string]any{"email": "not an address"}); code != http.StatusBadRequest {
		t.Fatalf("bad address: %d %v", code, body)
	}

	code, body = call(t, e, tid, http.MethodPost, path, admin, map[string]any{"email": strings.ToUpper(gmail)})
	if code != http.StatusOK || body["state"] != store.EmailPending || body["email"] != gmail ||
		body["reason"] != "pending_until_provider_sign_in" {
		t.Fatalf("admin adds: %d %v", code, body)
	}
	// 409 on another human's active address, with no hint of whose it is.
	code, body = call(t, e, tid, http.MethodPost, path, admin, map[string]any{"email": strangerID.Email})
	if code != http.StatusConflict || body["error"] != "email_taken" || strings.Contains(toJSON(body), stranger) {
		t.Fatalf("another human's address: %d %v", code, body)
	}

	// The member reads their own list; another non-admin member does not.
	code, body = call(t, e, tid, http.MethodGet, path, x, nil)
	if code != http.StatusOK || !strings.Contains(toJSON(body["emails"]), `"email":"`+gmail+`","main":false,"providers":[],"state":"pending"`) {
		t.Fatalf("own list: %d %v", code, body)
	}
	if code, body := call(t, e, tid, http.MethodGet, path, dev, nil); code != http.StatusForbidden {
		t.Fatalf("CONTROL another member reads the list: %d %v", code, body)
	}
	if code, body := call(t, e, tid, http.MethodGet, "/v1/members/"+stranger+"/emails", admin, nil); code != http.StatusNotFound {
		t.Fatalf("CONTROL admin reads a non-member's list: %d %v", code, body)
	}

	// A Google link sign-in that proves the pending address lands on x.
	if got, err := h.Admit(ctx, store.Identity{Provider: "google", Subject: "g-" + gmail, Email: gmail, LinkTo: x}, "", store.AdmitPolicy{}, now); err != nil || got != x {
		t.Fatalf("google sign-in of the pending address: %q %v, want %q", got, err, x)
	}
	code, body = call(t, e, tid, http.MethodGet, path, admin, nil)
	if code != http.StatusOK || !strings.Contains(toJSON(body["emails"]), `"email":"`+gmail+`","main":false,"providers":["google"],"state":"active"`) ||
		!strings.Contains(toJSON(body["emails"]), `"email":"`+xid.Email+`","main":true`) {
		t.Fatalf("admin list after the sign-in: %d %v", code, body)
	}

	// The member adds one by themselves (msg 39420f52); a native password
	// sign-in with it does NOT reach the account, a provider sign-in does.
	own := randHex(5) + "@example.net"
	code, body = call(t, e, tid, http.MethodPost, path, x, map[string]any{"email": own})
	if code != http.StatusOK || body["state"] != store.EmailPending || body["reason"] != "pending_until_provider_sign_in" {
		t.Fatalf("self add: %d %v", code, body)
	}
	pw, err := h.Admit(ctx, store.Identity{Provider: auth.ProviderPassword, Subject: own, Email: own, LinkTo: x}, "", store.AdmitPolicy{}, now)
	if err != nil || pw == x {
		t.Fatalf("a password sign-in with a self-added address reached the account: %q %v", pw, err)
	}
	own2 := randHex(5) + "@example.net"
	if code, body := call(t, e, tid, http.MethodPost, path, x, map[string]any{"email": own2}); code != http.StatusOK {
		t.Fatalf("self add 2: %d %v", code, body)
	}
	if got, err := h.Admit(ctx, store.Identity{Provider: "linkedin", Subject: "l-" + own2, Email: own2, LinkTo: x}, "", store.AdmitPolicy{}, now); err != nil || got != x {
		t.Fatalf("CONTROL provider sign-in of a self-added address: %q %v, want %q", got, err, x)
	}
	code, body = call(t, e, tid, http.MethodPost, path, x, map[string]any{"email": own2})
	if code != http.StatusOK || body["state"] != store.EmailActive || body["reason"] != "already_active" {
		t.Fatalf("re-add an active address: %d %v", code, body)
	}

	del := func(as, addr string) (int, map[string]any) {
		return call(t, e, tid, http.MethodDelete, path+"?email="+url.QueryEscape(addr), as, nil)
	}
	if code, body := del(dev, gmail); code != http.StatusForbidden {
		t.Fatalf("CONTROL non-admin removes another member's address: %d %v", code, body)
	}
	if code, body := del(admin, xid.Email); code != http.StatusConflict || body["error"] != "main_email" {
		t.Fatalf("remove the main address: %d %v", code, body)
	}
	if code, body := del(admin, gmail); code != http.StatusNoContent {
		t.Fatalf("admin removes an extra address: %d %v", code, body)
	}
	if code, body := del(x, own2); code != http.StatusNoContent {
		t.Fatalf("the member removes their own extra address: %d %v", code, body)
	}
	if code, body := del(admin, gmail); code != http.StatusNotFound {
		t.Fatalf("remove twice: %d %v", code, body)
	}
}
