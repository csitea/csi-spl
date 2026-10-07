package hub_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// resetRig is rbacEnv with native sign-in on a recording mailbox, the
// session cut-offs in the env's own store.
type resetRig struct {
	*env
	box   *mail.Recorder
	creds *auth.MemoryCredStore
	n     int
}

func newResetRig(t *testing.T, extra ...string) *resetRig {
	t.Helper()
	r := &resetRig{box: &mail.Recorder{}, creds: auth.NewMemoryCredStore()}
	r.env = rbacEnv(t, func(o *hub.Options) {
		cfg, err := auth.LoadFrom("lde", map[string]string{
			"SPOOL_HUB_AUTH_SESSION_KEY":   strings.Repeat("k", 32),
			"SPOOL_HUB_AUTH_APP_URL":       "http://app.example.test",
			"SPOOL_HUB_AUTH_COOKIE_SECURE": "false",
		})
		if err != nil {
			t.Fatal(err)
		}
		vars := map[string]string{"SPOOL_HUB_AUTH_NATIVE_ENABLED": "true",
			"SPOOL_HUB_AUTH_NATIVE_ARGON2_MEMORY_KIB": "64", "SPOOL_HUB_AUTH_NATIVE_ARGON2_ITERATIONS": "1"}
		for i := 0; i+1 < len(extra); i += 2 {
			vars[extra[i]] = extra[i+1]
		}
		nc, err := auth.LoadNativeFrom("lde", vars)
		if err != nil {
			t.Fatal(err)
		}
		a := auth.New(cfg, zerolog.Nop(), auth.Options{Revocations: o.Store.(auth.SessionRevoker)})
		if err := a.EnableNative(nc, auth.NativeDeps{Store: r.creds, Sender: r.box, Delivers: true}); err != nil {
			t.Fatal(err)
		}
		o.Auth = a
	})
	return r
}

// seatNative admits a password member of tid with role and stores its
// verified credential; it answers the human and the address.
func (r *resetRig) seatNative(t *testing.T, tid, role string) (string, string) {
	t.Helper()
	r.n++
	email := "native" + strconv.Itoa(r.n) + "-" + tid + "@example.com"
	ctx, now := context.Background(), time.Now()
	h := r.st.(store.Humans)
	if err := h.PutInvite(ctx, store.Invite{TenantID: tid, Email: email, Role: role, InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	pw, err := h.Admit(ctx, store.Identity{Provider: auth.ProviderPassword, Subject: email, Email: email}, tid, store.AdmitPolicy{}, now)
	if err != nil {
		t.Fatal(err)
	}
	hash, _ := auth.HashPassword("old-password-123", auth.Argon2Params{MemoryKiB: 64, Iterations: 1})
	if _, err := r.creds.CreateCredential(ctx, auth.Credential{Subject: email, PasswordHash: hash, EmailVerifiedAt: &now}, now); err != nil {
		t.Fatal(err)
	}
	return pw, email
}

func (r *resetRig) resetMails(to string) int {
	n := 0
	for _, m := range r.box.Messages() {
		if m.Template == mail.TemplatePasswordReset && m.To == to {
			n++
		}
	}
	return n
}

// t1 ea0af569: the admin reset route. Admin OK (mail, sessions cut off, audit
// row on Postgres); CONTROLS: a non-admin 403, a member of another workspace
// 404, an IdP-only member 409 naming the provider, a second reset inside the
// mail floor 429, the admin's own account 409. GET /v1/members says who has
// a password.
func TestMemberPasswordReset(t *testing.T) {
	r := newResetRig(t)
	tid, _ := r.tenant()
	other, _ := r.tenant()
	admin := seat(t, r.env, tid, rbac.Admin)
	dev := seat(t, r.env, tid, rbac.Developer)
	member, email := r.seatNative(t, tid, rbac.Developer)
	google := seat(t, r.env, tid, rbac.Developer)
	stranger, strangerEmail := r.seatNative(t, other, rbac.Developer)
	path := func(h string) string { return "/v1/members/" + h + "/password-reset" }

	if code, body := call(t, r.env, tid, http.MethodPost, path(member), dev, map[string]any{}); code != http.StatusForbidden {
		t.Fatalf("CONTROL non-admin: %d %v", code, body)
	}
	if code, body := call(t, r.env, tid, http.MethodPost, path(stranger), admin, map[string]any{}); code != http.StatusNotFound || body["error"] != "not_found" {
		t.Fatalf("CONTROL another workspace's member: %d %v", code, body)
	}
	if code, body := call(t, r.env, tid, http.MethodPost, path(google), admin, map[string]any{}); code != http.StatusConflict ||
		body["error"] != "no_password" || !strings.Contains(body["detail"].(string), "signs in with google") {
		t.Fatalf("CONTROL IdP-only member: %d %v", code, body)
	}
	if code, body := call(t, r.env, tid, http.MethodPost, path(admin), admin, map[string]any{}); code != http.StatusConflict || body["error"] != "self" {
		t.Fatalf("CONTROL own account: %d %v", code, body)
	}
	if n := r.resetMails(email) + r.resetMails(strangerEmail); n != 0 {
		t.Fatalf("a refused reset mailed %d links", n)
	}

	code, body := call(t, r.env, tid, http.MethodPost, path(member), admin, map[string]any{})
	if code != http.StatusOK || body["email"] != email || body["signed_out"] != true || body["debug_token"] != nil {
		t.Fatalf("admin reset: %d %v", code, body)
	}
	if r.resetMails(email) != 1 {
		t.Fatalf("reset mails to the member: %d", r.resetMails(email))
	}
	cut, err := r.st.(auth.SessionRevoker).SessionRevocations(context.Background(), time.Now().Add(-time.Hour))
	if err != nil || cut[member].IsZero() {
		t.Fatalf("the member's sessions were not cut off: %v %v", cut, err)
	}
	if !cut[dev].IsZero() || !cut[admin].IsZero() {
		t.Fatalf("CONTROL: someone else's sessions were cut off: %v", cut)
	}
	if code, body := call(t, r.env, tid, http.MethodPost, path(member), admin, map[string]any{"sign_out": true}); code != http.StatusTooManyRequests || body["error"] != "rate_limited" {
		t.Fatalf("second reset inside the floor: %d %v", code, body)
	}

	if _, pg := r.st.(*store.Postgres); pg {
		req, _ := http.NewRequest(http.MethodGet, r.url(tid)+"/v1/members/"+member+"/activity", nil)
		req.Header.Set(memberHeader, admin)
		res, err := r.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		raw, _ := io.ReadAll(res.Body)
		res.Body.Close()
		if res.StatusCode != http.StatusOK || !strings.Contains(string(raw), `"kind":"password_reset","detail":"signed_out","by":"`+admin+`"`) {
			t.Fatalf("audit row: %d %s", res.StatusCode, raw)
		}
	}

	code, body = call(t, r.env, tid, http.MethodGet, "/v1/members", admin, nil)
	if code != http.StatusOK {
		t.Fatalf("members: %d %v", code, body)
	}
	got := map[string]string{}
	for _, m := range body["members"].([]any) {
		row := m.(map[string]any)
		got[row["human_id"].(string)] = toJSON(row["sign_in"])
	}
	if got[member] != `["password"]` || got[google] != `["google"]` {
		t.Fatalf("sign_in per member: %v", got)
	}
}

func toJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// Owner HUM-10 (msgs 2ca618b9, 9a5e31e5): the admin never sees the new
// password or the reset token - not in the response, not even on a hub whose
// debug tokens are on (lde/dev, where password/forgot DOES answer the token).
// CONTROL: the same rig's forgot route answers its token, so the rig really
// runs with debug tokens on and the absence below is not vacuous.
func TestMemberPasswordResetAnswersNoTokenOrPassword(t *testing.T) {
	r := newResetRig(t, "SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS", "true")
	tid, _ := r.tenant()
	admin := seat(t, r.env, tid, rbac.Admin)
	member, email := r.seatNative(t, tid, rbac.Developer)
	req, _ := http.NewRequest(http.MethodPost, r.url(tid)+"/v1/members/"+member+"/password-reset", strings.NewReader(`{}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(memberHeader, admin)
	res, err := r.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("reset: %d %s", res.StatusCode, raw)
	}
	var link string
	for _, m := range r.box.Messages() {
		if m.Template == mail.TemplatePasswordReset && m.To == email {
			for _, line := range strings.Split(m.TextBody, "\n") {
				if i := strings.Index(line, "token="); i >= 0 {
					link = line[i+len("token="):]
				}
			}
		}
	}
	if len(link) != 64 {
		t.Fatalf("no reset link mailed to the member: %q", link)
	}
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatal(err)
	}
	for k := range body {
		if k != "human_id" && k != "email" && k != "signed_out" {
			t.Fatalf("the admin's answer carries %q: %s", k, raw)
		}
	}
	if strings.Contains(string(raw), link) || strings.Contains(strings.ToLower(string(raw)), "token") ||
		strings.Contains(strings.ToLower(string(raw)), "password") {
		t.Fatalf("the admin's answer leaks the token or a password: %s", raw)
	}
	// CONTROL: debug tokens are really on in this rig
	_, other := r.seatNative(t, tid, rbac.Developer)
	fr, _ := http.NewRequest(http.MethodPost, r.url(tid)+"/api/v1/auth/password/forgot", strings.NewReader(`{"email":"`+other+`"}`))
	fr.Header.Set("Content-Type", "application/json")
	fres, err := r.client.Do(fr)
	if err != nil {
		t.Fatal(err)
	}
	fraw, _ := io.ReadAll(fres.Body)
	fres.Body.Close()
	if fres.StatusCode != http.StatusOK || !strings.Contains(string(fraw), "debug_token") {
		t.Fatalf("CONTROL: the rig's forgot route should answer its debug token: %d %s", fres.StatusCode, fraw)
	}
}
