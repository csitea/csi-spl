package hub_test

import (
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// Spec 154 section 12 (SPL-5431): every member of a workspace reads every
// other member's name and address, from that workspace only; a token, an
// agent and an act-as clone are refused. Memory, and Postgres under
// SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full). Fixtures: example.com only.

func memberCardPath(id string) string { return "/v1/view/members/" + id + "/card" }

// C30: P1 (owner of W1) and Q (a developer in W1, never an admin) read each
// other's card with the address; Q's session needs no members.invite.
func TestMemberCardSameWorkspace(t *testing.T) {
	c := newContactsRig(t, onAll)
	q, qHum := c.other(t, "developer")
	code, raw, out := c.do(t, c.b1, http.MethodGet, memberCardPath(qHum), nil, nil)
	if code != http.StatusOK || out["human_id"] != qHum || !strings.HasSuffix(asString(out["email"]), "@example.com") {
		t.Fatalf("P1 reads Q's card = %d %s, want 200 with Q's email", code, raw)
	}
	code, raw, out = c.do(t, q, http.MethodGet, memberCardPath(c.p1), nil, nil)
	if code != http.StatusOK || out["email"] != c.email || out["display_name"] == nil {
		t.Fatalf("Q (developer) reads P1's card = %d %s, want 200 email %s", code, raw, c.email)
	}
	if code, _, out := c.do(t, q, http.MethodGet, memberCardPath(qHum), nil, nil); code != http.StatusOK || out["human_id"] != qHum {
		t.Errorf("Q reads own card = %d %v, want 200", code, out)
	}
}

// C31: the session's workspace decides. P1 is in W1 and W2, Q only in W1:
// P1's W2 session asking for Q is 404, and so is a person of another
// workspace (R, a fresh workspace of their own) asking for Q or P1. The
// twin is TestMemberCardSameWorkspace (P1's W1 session reads Q: 200).
func TestMemberCardOtherWorkspaceIs404(t *testing.T) {
	c := newContactsRig(t, onAll)
	_, qHum := c.other(t, "developer")
	r, _ := c.other(t, "")
	cases := []struct {
		name string
		b    *http.Client
		id   string
	}{{"P1 in W2 -> Q (W1 only)", c.b2, qHum}, {"R -> Q", r, qHum}, {"R -> P1", r, c.p1}, {"P1 -> unknown", c.b1, "HUM-999999999"}}
	for _, k := range cases {
		code, raw, out := c.do(t, k.b, http.MethodGet, memberCardPath(k.id), nil, nil)
		if code != http.StatusNotFound || realmToken(out) != "not_found" || strings.Contains(string(raw), "@") {
			t.Errorf("%s = %d %s, want 404 not_found and no address", k.name, code, raw)
		}
	}
}

// C32: a Bearer token (an agent or a box) and an act-as clone session are 403
// person_only and never see an address; the twin is the same browser
// without the token, 200.
func TestMemberCardPersonOnly(t *testing.T) {
	c := newContactsRig(t, onAll)
	_, qHum := c.other(t, "developer")
	if code, _, _ := c.do(t, c.b1, http.MethodGet, memberCardPath(qHum), nil, nil); code != http.StatusOK {
		t.Fatalf("twin: P1's own session = %d, want 200", code)
	}
	code, raw, out := c.do(t, c.b1, http.MethodGet, memberCardPath(qHum), nil, map[string]string{"Authorization": "Bearer box-agent-token"})
	if code != http.StatusForbidden || realmToken(out) != "person_only" || strings.Contains(string(raw), "@") {
		t.Errorf("Bearer = %d %s, want 403 person_only", code, raw)
	}
	c.cs.setClone(c.p1)
	code, raw, out = c.do(t, c.b1, http.MethodGet, memberCardPath(qHum), nil, nil)
	if code != http.StatusForbidden || realmToken(out) != "person_only" || strings.Contains(string(raw), "@") {
		t.Errorf("act-as clone = %d %s, want 403 person_only", code, raw)
	}
}

// C33: the address is never logged and the answer is never cached.
func TestMemberCardNoStoreNoLog(t *testing.T) {
	c := newContactsRig(t, onAll)
	q, _ := c.other(t, "developer")
	req, _ := http.NewRequest(http.MethodGet, "http://api"+domain+memberCardPath(c.p1), nil)
	req.Header.Set("Origin", wuiOrigin)
	resp, err := q.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || resp.Header.Get("Cache-Control") != "no-store" {
		t.Errorf("= %d Cache-Control %q, want 200 no-store", resp.StatusCode, resp.Header.Get("Cache-Control"))
	}
	if strings.Contains(realmLogs(c.logs), c.email) {
		t.Errorf("the hub log carries the member's address")
	}
}

// C34 (section 12.4, owner HUM-10 t1 028ac340): in a name-only workspace
// (t1 in every deployed hub, W1 here) a member reads another member's name
// and never the address; the twin is the same person in W2, not name-only,
// who reads the address. The card has no phone key in any workspace.
func TestMemberCardNameOnlyWorkspace(t *testing.T) {
	c := newContactsRig(t, onAll, func(o *hub.Options, w1, _ string) { o.MemberCardNameOnlyWorkspaces = []string{w1} })
	q, qHum := c.other(t, "developer")
	for _, k := range []struct {
		name string
		b    *http.Client
		id   string
	}{{"P1 -> Q in W1", c.b1, qHum}, {"Q -> P1 in W1", q, c.p1}, {"P1 -> self in W1", c.b1, c.p1}} {
		code, raw, out := c.do(t, k.b, http.MethodGet, memberCardPath(k.id), nil, nil)
		if code != http.StatusOK || out["human_id"] != k.id || out["display_name"] == nil || out["email"] != nil || strings.Contains(string(raw), "@") {
			t.Errorf("%s = %d %s, want 200 with the name and no address", k.name, code, raw)
		}
		if _, has := out["phone"]; has {
			t.Errorf("%s carries a phone key: %s", k.name, raw)
		}
	}
	code, raw, out := c.do(t, c.b2, http.MethodGet, memberCardPath(c.p1), nil, nil)
	if code != http.StatusOK || out["email"] != c.email {
		t.Errorf("twin: P1 in W2 (not name-only) = %d %s, want 200 email %s", code, raw, c.email)
	}
	if _, has := out["phone"]; has {
		t.Errorf("W2 card carries a phone key: %s", raw)
	}
}

func asString(v any) string {
	s, _ := v.(string)
	return s
}
