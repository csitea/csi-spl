package hub_test

import (
	"context"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/046 §3: CONTROL first - every role without tenant.settings /
// members.invite gets 403 naming the permission on every 046 route, a
// plain developer included.
func TestTenantSettingsForbidden(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	victim := seat(t, e, tid, rbac.Tester)
	for _, role := range []string{rbac.Developer, rbac.Tester, rbac.ProductOwner, rbac.PureAgent, rbac.BizCustomer, rbac.RegularUser} {
		as := seat(t, e, tid, role)
		for _, x := range []struct {
			method, path, perm string
			body               any
		}{
			{http.MethodGet, "/v1/tenant/settings", rbac.TenantSettings, nil},
			{http.MethodPatch, "/v1/tenant/settings", rbac.TenantSettings, map[string]any{"display_name": "x"}},
			{http.MethodGet, "/v1/tenant/channels", rbac.TenantSettings, nil},
			{http.MethodPatch, "/v1/tenant/channels/lobby", rbac.TenantSettings, map[string]any{"no_fallback": true}},
			{http.MethodDelete, "/v1/tenant/channels/lobby", rbac.TenantSettings, nil},
			{http.MethodPatch, "/v1/members/" + victim, rbac.MembersInvite, map[string]any{"disabled": true}},
		} {
			code, body := call(t, e, tid, x.method, x.path, as, x.body)
			if code != http.StatusForbidden || body["permission"] != x.perm {
				t.Fatalf("CONTROL: %s %s %s = %d %v, want 403 %s", role, x.method, x.path, code, body, x.perm)
			}
		}
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/tenant/settings", "", nil); code != http.StatusForbidden {
		t.Fatalf("CONTROL: anonymous settings read: %d", code)
	}
	// Another tenant's admin manages nothing here.
	other, _ := e.tenant()
	stranger := seat(t, e, other, rbac.Admin)
	if code, _ := call(t, e, tid, http.MethodPatch, "/v1/tenant/settings", stranger, map[string]any{"display_name": "pwn"}); code != http.StatusForbidden {
		t.Fatalf("CONTROL: another tenant's admin renamed this tenant: %d", code)
	}
}

// General + responders: admin and biz_owner read and write; bad values 400.
func TestTenantSettingsGeneral(t *testing.T) {
	var mu sync.Mutex
	var locales []string
	e := rbacEnv(t, func(o *hub.Options) {
		o.InviteMail = func(_ context.Context, _, _, locale string) (string, error) {
			mu.Lock()
			defer mu.Unlock()
			locales = append(locales, locale)
			return "sent", nil
		}
	})
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	owner := seat(t, e, tid, rbac.BizOwner)

	code, body := call(t, e, tid, http.MethodGet, "/v1/tenant/settings", admin, nil)
	if code != 200 || body["display_name"] != "" || body["default_locale"] != "" || len(body["responders"].([]any)) != 0 {
		t.Fatalf("fresh settings: %d %v", code, body)
	}
	// CLE-77819: a fresh workspace archives for everyone (the default).
	if body["topic_archive_policy"] != "everyone" {
		t.Fatalf("fresh archive policy: %v, want everyone", body["topic_archive_policy"])
	}
	code, body = call(t, e, tid, http.MethodPatch, "/v1/tenant/settings", admin,
		map[string]any{"display_name": "  Acme  ", "default_locale": "fi", "responders": []string{"CLE-01", "GRK-3", "CLE-01"}})
	if code != 200 || body["display_name"] != "Acme" || body["default_locale"] != "fi" {
		t.Fatalf("patch: %d %v", code, body)
	}
	if rs := body["responders"].([]any); len(rs) != 2 || rs[0] != "CLE-01" || rs[1] != "GRK-3" {
		t.Fatalf("responders (deduped, in order): %v", rs)
	}
	// A partial patch leaves the rest.
	code, body = call(t, e, tid, http.MethodPatch, "/v1/tenant/settings", owner, map[string]any{"default_locale": ""})
	if code != 200 || body["display_name"] != "Acme" || body["default_locale"] != "" || len(body["responders"].([]any)) != 2 {
		t.Fatalf("biz_owner partial patch: %d %v", code, body)
	}
	// CLE-77819: set the archive policy, and a partial patch leaves it.
	code, body = call(t, e, tid, http.MethodPatch, "/v1/tenant/settings", admin, map[string]any{"topic_archive_policy": "admins"})
	if code != 200 || body["topic_archive_policy"] != "admins" {
		t.Fatalf("patch archive policy: %d %v", code, body)
	}
	code, body = call(t, e, tid, http.MethodPatch, "/v1/tenant/settings", admin, map[string]any{"display_name": "Acme"})
	if code != 200 || body["topic_archive_policy"] != "admins" {
		t.Fatalf("archive policy survives a partial patch: %d %v", code, body)
	}
	call(t, e, tid, http.MethodPatch, "/v1/tenant/settings", admin, map[string]any{"topic_archive_policy": "everyone"})
	for name, bad := range map[string]map[string]any{
		"locale":    {"default_locale": "xx"},
		"name":      {"display_name": "two\nlines"},
		"policy":    {"topic_archive_policy": "nobody"},
		"responder": {"responders": []string{"HUM-4"}},
		"unknown":   {"billing": "free"},
	} {
		if code, body := call(t, e, tid, http.MethodPatch, "/v1/tenant/settings", admin, bad); code != http.StatusBadRequest {
			t.Errorf("bad %s: %d %v, want 400", name, code, body)
		}
	}
	// The default locale is the invite mail's language when the admin sent none.
	call(t, e, tid, http.MethodPatch, "/v1/tenant/settings", admin, map[string]any{"default_locale": "bg"})
	if code, body := call(t, e, tid, http.MethodPost, "/v1/members/invites", admin, map[string]string{"email": "n@example.com"}); code != 201 {
		t.Fatalf("invite: %d %v", code, body)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(locales) != 1 || locales[0] != "bg" {
		t.Fatalf("invite mail locale %v, want [bg]", locales)
	}
}

// Channels: every channel, private ones the admin is not in too; the
// no-fallback flag; archive without being the creator; defaults refused.
func TestTenantSettingsChannels(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	dev := seat(t, e, tid, rbac.Developer)
	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels", dev, map[string]string{"channel": "secret", "name": "Secret"}); code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, out)
	}
	find := func() map[string]any {
		code, body := call(t, e, tid, http.MethodGet, "/v1/tenant/channels", admin, nil)
		if code != 200 {
			t.Fatalf("list: %d %v", code, body)
		}
		for _, c := range body["channels"].([]any) {
			if m := c.(map[string]any); m["channel"] == "secret" {
				return m
			}
		}
		return nil
	}
	c := find()
	if c == nil || c["visibility"] != "members" || c["members"] != float64(1) || c["archivable"] != true || c["no_fallback"] != false {
		t.Fatalf("private channel row (admin not a member): %v", c)
	}
	if code, body := call(t, e, tid, http.MethodPatch, "/v1/tenant/channels/secret", admin, map[string]any{"no_fallback": true}); code != 200 {
		t.Fatalf("no_fallback: %d %v", code, body)
	}
	if c := find(); c["no_fallback"] != true {
		t.Fatalf("no_fallback not stored: %v", c)
	}
	if code, body := call(t, e, tid, http.MethodDelete, "/v1/tenant/channels/lobby", admin, nil); code != http.StatusConflict || body["error"] != "channel_public" {
		t.Fatalf("archive lobby: %d %v, want 409", code, body)
	}
	if code, _ := call(t, e, tid, http.MethodDelete, "/v1/tenant/channels/nope", admin, nil); code != http.StatusNotFound {
		t.Fatalf("archive unknown: %d", code)
	}
	if code, body := call(t, e, tid, http.MethodDelete, "/v1/tenant/channels/secret", admin, nil); code != http.StatusNoContent {
		t.Fatalf("archive: %d %v", code, body)
	}
	if c := find(); c != nil {
		t.Fatalf("archived channel still listed: %v", c)
	}
}

// Members: suspend / restore (per tenant), name and locale for a
// single-tenant account only, the last-admin guard, last seen.
func TestTenantSettingsMemberPatch(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	owner := seat(t, e, tid, rbac.BizOwner)
	dev := seat(t, e, tid, rbac.Developer)
	h := e.st.(store.Humans)

	if code, body := call(t, e, tid, http.MethodPatch, "/v1/members/"+dev, admin,
		map[string]any{"display_name": "Dev One", "locale": "sv"}); code != http.StatusNoContent {
		t.Fatalf("name+locale: %d %v", code, body)
	}
	if n, _ := h.DisplayName(context.Background(), dev); n != "Dev One" {
		t.Fatalf("name %q", n)
	}
	if l, _ := h.PreferredLocale(context.Background(), dev); l != "sv" {
		t.Fatalf("locale %q", l)
	}
	// Suspend: the member reads nothing here at once, and is listed suspended.
	if code, body := call(t, e, tid, http.MethodPatch, "/v1/members/"+dev, admin, map[string]any{"disabled": true}); code != http.StatusNoContent {
		t.Fatalf("suspend: %d %v", code, body)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/me", dev, nil); code != http.StatusForbidden {
		t.Fatalf("suspended member still reads: %d", code)
	}
	_, body := call(t, e, tid, http.MethodGet, "/v1/members", owner, nil)
	var row map[string]any
	for _, m := range body["members"].([]any) {
		if mm := m.(map[string]any); mm["human_id"] == dev {
			row = mm
		}
	}
	if row == nil || row["suspended"] != true || row["disabled"] != false {
		t.Fatalf("suspended row: %v", row)
	}
	if _, ok := row["last_seen"]; !ok {
		t.Fatalf("last_seen missing: %v", row)
	}
	// Restore (a suspended member is still found).
	if code, body := call(t, e, tid, http.MethodPatch, "/v1/members/"+dev, owner, map[string]any{"disabled": false}); code != http.StatusNoContent {
		t.Fatalf("restore: %d %v", code, body)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/me", dev, nil); code != http.StatusOK {
		t.Fatalf("restored member cannot read: %d", code)
	}
	// Not yourself; not the last admin; an admin never reaches a biz_owner.
	if code, body := call(t, e, tid, http.MethodPatch, "/v1/members/"+admin, admin, map[string]any{"disabled": true}); code != http.StatusConflict || body["error"] != "self" {
		t.Fatalf("self suspend: %d %v", code, body)
	}
	if code, body := call(t, e, tid, http.MethodPatch, "/v1/members/"+owner, admin, map[string]any{"disabled": true}); code != http.StatusForbidden {
		t.Fatalf("admin suspends biz_owner: %d %v", code, body)
	}
	// With the biz_owner holding members.invite, suspending the only admin leaves one.
	if code, body := call(t, e, tid, http.MethodPatch, "/v1/members/"+admin, owner, map[string]any{"disabled": true}); code != http.StatusNoContent {
		t.Fatalf("owner suspends the admin: %d %v", code, body)
	}
	if code, body := call(t, e, tid, http.MethodPatch, "/v1/members/"+admin, owner, map[string]any{"disabled": false}); code != http.StatusNoContent {
		t.Fatalf("owner restores the admin: %d %v", code, body)
	}
	// A person in another tenant too owns their profile.
	other, _ := e.tenant()
	email := "shared-" + tid + "@example.com"
	var shared string
	for _, tn := range []string{other, tid} {
		now := time.Now()
		if err := h.PutInvite(context.Background(), store.Invite{TenantID: tn, Email: email, Role: rbac.Developer,
			InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
			t.Fatal(err)
		}
		hum, err := h.Admit(context.Background(), store.Identity{Provider: "google", Subject: "s-" + email, Email: email}, tn, store.AdmitPolicy{}, now)
		if err != nil {
			t.Fatal(err)
		}
		shared = hum
	}
	if code, body := call(t, e, tid, http.MethodPatch, "/v1/members/"+shared, admin, map[string]any{"display_name": "Renamed"}); code != http.StatusConflict || body["error"] != "shared_account" {
		t.Fatalf("shared account rename: %d %v, want 409 shared_account", code, body)
	}
	if code, body := call(t, e, tid, http.MethodPatch, "/v1/members/"+shared, admin, map[string]any{"disabled": true}); code != http.StatusNoContent {
		t.Fatalf("shared account suspend here: %d %v", code, body)
	}
	if code, _ := call(t, e, other, http.MethodGet, "/v1/view/me", shared, nil); code != http.StatusOK {
		t.Fatalf("suspension leaked into the other tenant: %d", code)
	}
	for name, bad := range map[string]map[string]any{
		"empty":  {},
		"name":   {"display_name": " "},
		"locale": {"locale": "xx"},
	} {
		if code, body := call(t, e, tid, http.MethodPatch, "/v1/members/"+dev, admin, bad); code != http.StatusBadRequest {
			t.Errorf("bad %s: %d %v, want 400", name, code, body)
		}
	}
}
