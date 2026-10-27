package hub_test

// Spec 025 section 11 (SPL-3686): the channel owner adds a person who has
// not joined the workspace yet, by address. Owner HUM-10, t1 b602f8b4 msg
// 4a3ec33a. Red on origin/master before SPL-3686: POST {"email"} answered
// 400 bad_json (the body knew only human_id), and a typed HUM id of a person
// who is not a member answers 404 not_a_member.

import (
	"context"
	"net/http"
	"net/url"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

type chInviteHub struct {
	e   *env
	tid string
}

func (c chInviteHub) members(t *testing.T, ch, as string) (humans, invited []string) {
	t.Helper()
	code, out := call(t, c.e, c.tid, http.MethodGet, "/v1/channels/"+ch+"/members", as, nil)
	if code != http.StatusOK {
		t.Fatalf("GET members: %d %v", code, out)
	}
	for _, v := range out["members"].([]any) {
		humans = append(humans, v.(string))
	}
	inv, ok := out["invited"].([]any)
	if !ok {
		t.Fatalf("members answer carries no invited list: %v", out)
	}
	for _, v := range inv {
		invited = append(invited, v.(string))
	}
	return humans, invited
}

func (c chInviteHub) admit(t *testing.T, email string) string {
	t.Helper()
	hum, err := c.e.st.(store.Humans).Admit(context.Background(), store.Identity{Provider: "google", Subject: "s-" + email,
		Email: email}, c.tid, store.AdmitPolicy{}, time.Now())
	if err != nil {
		t.Fatalf("admit %s: %v", email, err)
	}
	return hum
}

// TestChannelAddInvitedPerson: an address with no invite gets one (the
// owner holds members.invite) and a pending row; the members list shows it
// as invited; accepting the invite puts the person in the channel.
func TestChannelAddInvitedPerson(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	c := chInviteHub{e, tid}
	owner := seat(t, e, tid, "biz_owner")
	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels", owner,
		map[string]string{"channel": "launch", "name": "Launch"}); code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, out)
	}
	code, out := call(t, e, tid, http.MethodPost, "/v1/channels/launch/members", owner, map[string]string{"email": "New@Example.com"})
	if code != http.StatusCreated || out["pending"] != true || out["invite"] != "created" || out["email"] != "new@example.com" {
		t.Fatalf("add by address: %d %v, want 201 pending invite=created", code, out)
	}
	if hs, inv := c.members(t, "launch", owner); !slices.Equal(inv, []string{"new@example.com"}) || len(hs) != 1 {
		t.Fatalf("before accept: members %v invited %v", hs, inv)
	}
	hum := c.admit(t, "new@example.com")
	hs, inv := c.members(t, "launch", owner)
	if !slices.Contains(hs, hum) || len(inv) != 0 {
		t.Fatalf("after accept: members %v invited %v, want %s in and nobody invited", hs, inv, hum)
	}
	// The new member reads the channel's members, so they passed the read door.
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/channels/launch/members", hum, nil); code != http.StatusOK {
		t.Fatalf("new member GET members: %d, want 200", code)
	}
	// The address of a member is the plain add.
	other := seat(t, e, tid, "developer")
	email := memberEmail(t, e, tid, other)
	code, out = call(t, e, tid, http.MethodPost, "/v1/channels/launch/members", owner, map[string]string{"email": email})
	if code != http.StatusCreated || out["human_id"] != other {
		t.Fatalf("add a member by address: %d %v, want 201 human_id %s", code, out, other)
	}
	// CONTROL: a HUM id that is no member is still refused.
	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels/launch/members", owner,
		map[string]string{"human_id": "HUM-999999"}); code != http.StatusNotFound || out["error"] != "not_a_member" {
		t.Fatalf("unknown HUM: %d %v, want 404 not_a_member", code, out)
	}
	if code, _ := call(t, e, tid, http.MethodPost, "/v1/channels/launch/members", owner,
		map[string]string{"human_id": other, "email": email}); code != http.StatusBadRequest {
		t.Fatalf("both fields: %d, want 400", code)
	}
}

// TestChannelAddInvitedPermissions: a developer channel owner (no
// members.invite) may add the address of an OPEN invite, but cannot mint a
// new invite; a non-owner may not add at all; a revoked invite takes its
// pending row with it; the owner may undo a pending add, a member without
// channels.manage may not (the rule for removing someone else).
func TestChannelAddInvitedPermissions(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	c := chInviteHub{e, tid}
	admin := seat(t, e, tid, "biz_owner")
	dev := seat(t, e, tid, "developer")
	peer := seat(t, e, tid, "tester") // in the channel, no channels.manage
	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels", dev,
		map[string]string{"channel": "ops", "name": "Ops"}); code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels/ops/members", dev, map[string]string{"human_id": peer}); code != http.StatusCreated {
		t.Fatalf("add peer: %d %v", code, out)
	}
	code, out := call(t, e, tid, http.MethodPost, "/v1/channels/ops/members", dev, map[string]string{"email": "stranger@example.com"})
	if code != http.StatusForbidden || out["permission"] != "members.invite" {
		t.Fatalf("no invite, no members.invite: %d %v, want 403 members.invite", code, out)
	}
	for _, addr := range []string{"open@example.com", "gone@example.com", "undo@example.com"} {
		if code, out := call(t, e, tid, http.MethodPost, "/v1/members/invites", admin,
			map[string]any{"email": addr, "no_mail": true}); code != http.StatusCreated {
			t.Fatalf("invite %s: %d %v", addr, code, out)
		}
		code, out := call(t, e, tid, http.MethodPost, "/v1/channels/ops/members", dev, map[string]string{"email": addr})
		if code != http.StatusCreated || out["invite"] != "existing" {
			t.Fatalf("add open invite %s: %d %v, want 201 invite=existing", addr, code, out)
		}
	}
	if code, _ := call(t, e, tid, http.MethodPost, "/v1/channels/ops/members", peer, map[string]string{"email": "open@example.com"}); code != http.StatusForbidden {
		t.Fatalf("non-owner add: %d, want 403", code)
	}
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/members/invites?email="+url.QueryEscape("gone@example.com"), admin, nil); code != http.StatusNoContent {
		t.Fatalf("revoke: %d %v", code, out)
	}
	if code, _ := call(t, e, tid, http.MethodDelete, "/v1/channels/ops/members/undo@example.com", peer, nil); code != http.StatusForbidden {
		t.Fatalf("non-owner undo: %d, want 403", code)
	}
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/channels/ops/members/undo@example.com", dev, nil); code != http.StatusNoContent {
		t.Fatalf("owner undo: %d %v", code, out)
	}
	if _, inv := c.members(t, "ops", dev); !slices.Equal(inv, []string{"open@example.com"}) {
		t.Fatalf("invited %v, want only open@example.com", inv)
	}
	for addr, want := range map[string]bool{"open@example.com": true, "gone@example.com": false, "undo@example.com": false} {
		if addr == "gone@example.com" { // revoked: no sign-in admits it any more
			continue
		}
		hum := c.admit(t, addr)
		if hs, _ := c.members(t, "ops", dev); slices.Contains(hs, hum) != want {
			t.Fatalf("%s (%s) in #ops = %v, want %v", addr, hum, !want, want)
		}
	}
}

// memberEmail is the address the directory holds for hum.
func memberEmail(t *testing.T, e *env, tid, hum string) string {
	t.Helper()
	ms, err := e.st.(store.MemberDirectory).ListMembers(context.Background(), tid)
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range ms {
		if m.HumanID == hum && m.Email != "" {
			return m.Email
		}
	}
	t.Fatalf("%s has no address in the directory", hum)
	return ""
}
