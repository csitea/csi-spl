package hub_test

import (
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// POST /v1/members/invites and PUT /v1/members/{id}/role take
// application/json only. A text/plain body is a cross-site "simple" form post
// (no preflight) and it can carry valid JSON; nothing but SameSite=Lax stood
// in its way. CONTROL: the same body as application/json invites.
func TestMembersBodiesAreJSONOnly(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	post := func(ct string) int {
		t.Helper()
		body := `{"email":"x-` + tid + `@example.com","role":"tester"}`
		req, _ := http.NewRequest(http.MethodPost, e.url(tid)+"/v1/members/invites", strings.NewReader(body))
		req.Header.Set("Content-Type", ct)
		req.Header.Set(memberHeader, admin)
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	for _, ct := range []string{"text/plain", "application/x-www-form-urlencoded", ""} {
		if code := post(ct); code != http.StatusUnsupportedMediaType {
			t.Fatalf("invite as %q: %d, want 415", ct, code)
		}
	}
	if code := post("application/json; charset=utf-8"); code != http.StatusCreated {
		t.Fatalf("CONTROL: a JSON invite: %d, want 201", code)
	}
}
