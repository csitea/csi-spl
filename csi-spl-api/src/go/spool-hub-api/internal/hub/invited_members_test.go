package hub_test

// Spec 025 section 13 (SPL-5706, owner HUM-10, t1 028ac340): an open
// workspace invite IS an inactive member. GET /v1/view/members/invited lists
// it to the workspace's members (no address in a name-only workspace, for
// anyone: spec 154 section 12.6, SPL-5830), the channel add takes its invite id, the add grants
// nothing before sign-in and everything after, a revoke and an expiry drop it.
// Memory, and Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).
// Fixtures: example.com only.

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

const invitedPath = "/v1/view/members/invited"

// putInvite stores an invite of tid to email that expires at exp.
func putInvite(t *testing.T, st store.Store, tid, email string, exp time.Time) {
	t.Helper()
	if err := st.(store.Humans).PutInvite(context.Background(), store.Invite{TenantID: tid, Email: email,
		Role: store.RoleDefault, InvitedBy: store.AdmittedOperator, ExpiresAt: exp}, time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
}

// invitedRows is the caller's GET /v1/view/members/invited.
func invitedRows(t *testing.T, c *contactsRig, b *http.Client) (int, string, []map[string]any) {
	t.Helper()
	code, raw, out := c.do(t, b, http.MethodGet, invitedPath, nil, nil)
	var rows []map[string]any
	if list, ok := out["invited"].([]any); ok {
		for _, v := range list {
			rows = append(rows, v.(map[string]any))
		}
	}
	return code, string(raw), rows
}

// I1: every member reads the open invites of the session's workspace as
// inactive members: a developer (no members.invite) included; an expired
// invite is no member; another workspace's person never sees them; a Bearer
// token is person_only.
func TestInvitedMembersListed(t *testing.T) {
	c := newContactsRig(t, onAll)
	putInvite(t, c.r.e.st, c.w1, "open@example.com", time.Now().Add(time.Hour))
	putInvite(t, c.r.e.st, c.w1, "lapsed@example.com", time.Now().Add(-time.Minute))
	q, _ := c.other(t, "developer")
	code, raw, rows := invitedRows(t, c, q)
	if code != http.StatusOK || len(rows) != 1 || rows[0]["label"] != "open@example.com" || rows[0]["masked"] != false ||
		!strings.HasPrefix(asString(rows[0]["id"]), "INV-") || rows[0]["expires_at"] == nil {
		t.Fatalf("developer = %d %s, want 200 with open@ only, unmasked, an INV- id", code, raw)
	}
	if strings.Contains(raw, "lapsed@") {
		t.Errorf("an expired invite is listed: %s", raw)
	}
	r, _ := c.other(t, "")
	if code, raw, _ := invitedRows(t, c, r); code != http.StatusOK || strings.Contains(raw, "open@") {
		t.Errorf("another workspace's person = %d %s, want 200 without W1's invitee", code, raw)
	}
	code, rawB, out := c.do(t, q, http.MethodGet, invitedPath, nil, map[string]string{"Authorization": "Bearer box-agent-token"})
	if code != http.StatusForbidden || realmToken(out) != "person_only" || strings.Contains(string(rawB), "@") {
		t.Errorf("Bearer = %d %s, want 403 person_only", code, rawB)
	}
}

// I2 (spec 154 section 12.6, SPL-5830; owner HUM-10 msg 10b28abb): in a
// name-only workspace an invitee carries no address and no domain for anyone:
// a member, an admin (members.invite) and the admin who invited them each read
// label "" and masked true, the id kept. The twin is W2, not name-only, where
// the same invitee shows whole to a member.
func TestInvitedMembersHiddenNameOnly(t *testing.T) {
	c := newContactsRig(t, onAll, func(o *hub.Options, w1, _ string) { o.MemberCardNameOnlyWorkspaces = []string{w1} })
	inviter, inviterID := c.other(t, "admin")
	if err := c.r.e.st.(store.Humans).PutInvite(context.Background(), store.Invite{TenantID: c.w1, Email: "open@example.com",
		Role: store.RoleDefault, InvitedBy: inviterID, OrderedBy: inviterID, ExpiresAt: time.Now().Add(time.Hour)}, time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	putInvite(t, c.r.e.st, c.w2, "open@example.com", time.Now().Add(time.Hour))
	q, _ := c.other(t, "developer")
	adm, _ := c.other(t, "admin")
	for who, b := range map[string]*http.Client{"member": q, "admin": adm, "inviter": inviter} {
		code, raw, rows := invitedRows(t, c, b)
		if code != http.StatusOK || len(rows) != 1 || rows[0]["label"] != "" || rows[0]["masked"] != true ||
			!strings.HasPrefix(asString(rows[0]["id"]), "INV-") || strings.Contains(raw, "@") || strings.Contains(raw, "example.com") {
			t.Errorf("%s in name-only W1 = %d %s, want one row, label \"\", masked, no address or domain", who, code, raw)
		}
	}
	if code, raw, rows := invitedRows(t, c, c.b2); code != http.StatusOK || len(rows) != 1 || rows[0]["label"] != "open@example.com" {
		t.Errorf("twin: P1 in W2 = %d %s, want the address", code, raw)
	}
}

// chInvitees is the channel members answer's invitees rows.
func chInvitees(t *testing.T, e *env, tid, ch, as string) []map[string]any {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, "/v1/channels/"+ch+"/members", as, nil)
	if code != http.StatusOK {
		t.Fatalf("GET members: %d %v", code, out)
	}
	var rows []map[string]any
	for _, v := range out["invitees"].([]any) {
		rows = append(rows, v.(map[string]any))
	}
	return rows
}

// I3: the channel owner adds an inactive member by its invite id. Before
// sign-in the person (a member of another workspace, so a real HUM-*) reads
// and posts nothing in the channel's workspace; after the sign-in that
// accepts the invite they are in the channel. The undo works on the id; an
// unknown id adds nothing; a revoked invite leaves no row.
func TestChannelAddInactiveMember(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	other, _ := e.tenant()
	c := chInviteHub{e, tid}
	owner := seat(t, e, tid, "biz_owner")
	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels", owner,
		map[string]string{"channel": "plan", "name": "Plan"}); code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, out)
	}
	putInvite(t, e.st, tid, "late@example.com", time.Now().Add(time.Hour))
	putInvite(t, e.st, other, "late@example.com", time.Now().Add(time.Hour))
	elsewhere := chInviteHub{e, other}.admit(t, "late@example.com") // a HUM-*, active in OTHER only
	id := hub.InviteIDForTest(tid, "late@example.com")
	code, out := call(t, e, tid, http.MethodPost, "/v1/channels/plan/members", owner, map[string]string{"invite_id": id})
	if code != http.StatusCreated || out["pending"] != true || out["invite"] != "existing" ||
		out["invite_id"] != id || out["email"] != "late@example.com" || out["masked"] != false {
		t.Fatalf("add by invite id: %d %v, want 201 pending existing, the address shown", code, out)
	}
	if rows := chInvitees(t, e, tid, "plan", owner); len(rows) != 1 || rows[0]["id"] != id || rows[0]["label"] != "late@example.com" {
		t.Fatalf("invitees %v, want the one row %s", rows, id)
	}
	// Inactive: no read, no post in tid before the sign-in.
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/channels/plan/members", elsewhere, nil); code == http.StatusOK {
		t.Fatalf("inactive member read #plan: %d, want refused", code)
	}
	if code, _ := call(t, e, tid, http.MethodPost, "/v1/channels/plan/members", elsewhere, map[string]string{"human_id": elsewhere}); code < 400 {
		t.Fatalf("inactive member wrote in #plan: %d, want refused", code)
	}
	if hs, _ := c.members(t, "plan", owner); slices.Contains(hs, elsewhere) {
		t.Fatalf("inactive member is in #plan before the sign-in: %v", hs)
	}
	// Activation: the sign-in to tid accepts the invite and moves the row.
	if hum := c.admit(t, "late@example.com"); hum != elsewhere {
		t.Fatalf("sign-in seated %s, want %s", hum, elsewhere)
	}
	if hs, inv := c.members(t, "plan", owner); !slices.Contains(hs, elsewhere) || len(inv) != 0 {
		t.Fatalf("after the sign-in: members %v invited %v, want %s in", hs, inv, elsewhere)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/channels/plan/members", elsewhere, nil); code != http.StatusOK {
		t.Fatalf("active member GET #plan: %d, want 200", code)
	}
	// CONTROL: an unknown or malformed id adds nothing.
	for _, bad := range []string{"INV-0000000000000000", "INV-zz", "late@example.com"} {
		code, out := call(t, e, tid, http.MethodPost, "/v1/channels/plan/members", owner, map[string]string{"invite_id": bad})
		if code != http.StatusNotFound || out["error"] != "no_open_invite" {
			t.Errorf("invite_id %q: %d %v, want 404 no_open_invite", bad, code, out)
		}
	}
	// N2: another workspace's invite id is no invite here.
	putInvite(t, e.st, other, "far@example.com", time.Now().Add(time.Hour))
	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels/plan/members", owner,
		map[string]string{"invite_id": hub.InviteIDForTest(other, "far@example.com")}); code != http.StatusNotFound || out["error"] != "no_open_invite" {
		t.Errorf("foreign workspace id: %d %v, want 404 no_open_invite", code, out)
	}
	// N2: a member outside the private channel adds nobody by id.
	putInvite(t, e.st, tid, "side@example.com", time.Now().Add(time.Hour))
	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels/plan/members", seat(t, e, tid, "developer"),
		map[string]string{"invite_id": hub.InviteIDForTest(tid, "side@example.com")}); code != http.StatusNotFound || out["error"] != "unknown_channel" {
		t.Errorf("non-member add by id: %d %v, want 404 unknown_channel", code, out)
	}
	if code, _ := call(t, e, tid, http.MethodPost, "/v1/channels/plan/members", owner,
		map[string]string{"invite_id": id, "email": "late@example.com"}); code != http.StatusBadRequest {
		t.Errorf("two fields: %d, want 400", code)
	}
	// Undo by id, then revoke: neither leaves a row.
	putInvite(t, e.st, tid, "undo@example.com", time.Now().Add(time.Hour))
	putInvite(t, e.st, tid, "gone@example.com", time.Now().Add(time.Hour))
	for _, addr := range []string{"undo@example.com", "gone@example.com"} {
		if code, out := call(t, e, tid, http.MethodPost, "/v1/channels/plan/members", owner,
			map[string]string{"invite_id": hub.InviteIDForTest(tid, addr)}); code != http.StatusCreated {
			t.Fatalf("add %s: %d %v", addr, code, out)
		}
	}
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/channels/plan/members/"+hub.InviteIDForTest(tid, "undo@example.com"), owner, nil); code != http.StatusNoContent {
		t.Fatalf("undo by id: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/members/invites?email="+url.QueryEscape("gone@example.com"), seat(t, e, tid, "admin"), nil); code != http.StatusNoContent {
		t.Fatalf("revoke: %d %v", code, out)
	}
	if rows := chInvitees(t, e, tid, "plan", owner); len(rows) != 0 {
		t.Fatalf("invitees after undo and revoke: %v, want none", rows)
	}
}

// I4 (spec 154 section 12.6, SPL-5830): in a name-only workspace the channel
// list carries no address and no domain for the member who added the
// invitee nor for an admin; the id stays, so the undo still works; the plain
// invited list is "" the same way. The twin is a workspace that is not
// name-only, where the same add shows the address.
func TestChannelInviteesHiddenNameOnly(t *testing.T) {
	b := make([]byte, 4)
	rand.Read(b) //nolint:errcheck
	tid := "t" + hex.EncodeToString(b)
	e := rbacEnv(t, func(o *hub.Options) { o.MemberCardNameOnlyWorkspaces = []string{tid} })
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: tid, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	dev := seat(t, e, tid, "developer")
	adm := seat(t, e, tid, "admin")
	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels", dev,
		map[string]string{"channel": "quiet", "name": "Quiet"}); code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels/quiet/members", dev, map[string]string{"human_id": adm}); code != http.StatusCreated {
		t.Fatalf("add admin: %d %v", code, out)
	}
	putInvite(t, e.st, tid, "open@example.com", time.Now().Add(time.Hour))
	id := hub.InviteIDForTest(tid, "open@example.com")
	// R7 W1: the 201 answer carries no more than the picker showed: nothing.
	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels/quiet/members", dev, map[string]string{"invite_id": id}); code != http.StatusCreated ||
		out["email"] != "" || out["masked"] != true || out["invite_id"] != id || strings.Contains(fmt.Sprint(out), "example.com") {
		t.Fatalf("add by id: %d %v, want 201 with an empty label only", code, out)
	}
	for who, as := range map[string]string{"adder": dev, "admin": adm} {
		code, out := call(t, e, tid, http.MethodGet, "/v1/channels/quiet/members", as, nil)
		rows := chInvitees(t, e, tid, "quiet", as)
		if code != http.StatusOK || len(rows) != 1 || rows[0]["label"] != "" || rows[0]["masked"] != true || rows[0]["id"] != id ||
			strings.Contains(fmt.Sprint(out), "example.com") {
			t.Fatalf("%s sees %v, want one row, label \"\", id %s, no domain", who, out, id)
		}
		if inv, _ := out["invited"].([]any); len(inv) != 1 || inv[0] != "" {
			t.Fatalf("%s invited %v, want [\"\"]", who, out["invited"])
		}
	}
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/channels/quiet/members/"+id, dev, nil); code != http.StatusNoContent {
		t.Fatalf("undo by id: %d %v", code, out)
	}
	// Twin: a workspace that is not name-only shows the adder the address.
	other, _ := e.tenant()
	odev := seat(t, e, other, "developer")
	if code, out := call(t, e, other, http.MethodPost, "/v1/channels", odev,
		map[string]string{"channel": "loud", "name": "Loud"}); code != http.StatusCreated {
		t.Fatalf("create twin: %d %v", code, out)
	}
	putInvite(t, e.st, other, "open@example.com", time.Now().Add(time.Hour))
	if code, out := call(t, e, other, http.MethodPost, "/v1/channels/loud/members", odev,
		map[string]string{"invite_id": hub.InviteIDForTest(other, "open@example.com")}); code != http.StatusCreated || out["email"] != "open@example.com" {
		t.Fatalf("twin add: %d %v, want the address", code, out)
	}
}
