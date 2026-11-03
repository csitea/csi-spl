package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 125 B5 (SPL-4732), case C-NVS-5: the Netvisor routes. Real browser
// sessions (doorRig: fake IdP, session cookies, act-as) on Postgres only,
// since only the Postgres store keeps Netvisor data (B4, rdb 0255, 0257);
// hub-pg.tst.sh runs them under PRE_PUSH_TIER=full. Every figure, account
// number and id here is invented (C2).

// nvsMarker is the invented amount of the seeded snapshot: a body that
// carries it carries a figure.
const nvsMarker = "4321.09"

// nvsOwnerRoutes are the owner's routes; want is the owner's status.
var nvsOwnerRoutes = []struct {
	method, path string
	body         any
	want         int
}{
	{http.MethodGet, "/v1/view/netvisor/forecast", nil, http.StatusOK},
	{http.MethodGet, "/v1/view/netvisor/card-costs", nil, http.StatusOK},
	{http.MethodPost, "/v1/netvisor/refresh", nil, http.StatusAccepted},
	{http.MethodGet, "/v1/netvisor/settings", nil, http.StatusOK},
	{http.MethodPut, "/v1/netvisor/settings", map[string]any{"env": "test", "bank_account": "1910",
		"vat_accounts": []string{"2939"}, "tax_accounts": []string{"2930"}, "vendor_exclusions": []string{"vendor-y"}}, http.StatusOK},
}

// nvsRig: op is the operator workspace with the owner (a developer, so an
// admin may act as them: the act-as ceiling) and one snapshot; other is
// another workspace.
type nvsRig struct {
	r         *doorRig
	op, other string
	owner     string
	email     string // the owner's sign-in email
	ownerB    *http.Client
}

func newNvsRig(t *testing.T) *nvsRig {
	t.Helper()
	if os.Getenv("SPOOL_TEST_PG_DSN") == "" {
		t.Skip("the Netvisor store needs Postgres (SPOOL_TEST_PG_DSN)")
	}
	n := &nvsRig{op: newTenantID("nv"), other: newTenantID("nw")}
	n.r = newDoorRig(t, func(o *hub.Options) {
		o.OperatorTenant = n.op
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = "https://api.dev.example"
		o.OperatorVerify = func(_ context.Context, token, _ string) (string, error) {
			switch token {
			case "good":
				return operatorSA, nil
			case "stranger":
				return "someone@example.com", nil
			}
			return "", errors.New("token rejected")
		}
	})
	for _, id := range []string{n.op, n.other} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := n.r.e.st.CreateTenant(context.Background(), store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
	}
	n.email = freshEmail()
	n.owner = join(t, n.r.e, n.email, n.op) // a developer
	n.ownerB = n.signIn(t, n.email, n.op)
	if code, out := opCall(t, n.r.e, n.op, http.MethodPut, "/v1/operator/netvisor/owner", "good", map[string]any{"human_id": n.owner}); code != http.StatusOK {
		t.Fatalf("set owner: %d %v", code, out)
	}
	if code, out := opCall(t, n.r.e, n.op, http.MethodPost, "/v1/operator/netvisor/snapshots", "good", nvsBody(time.Now())); code != http.StatusOK {
		t.Fatalf("ingest: %d %v", code, out)
	}
	return n
}

// as is a browser of a fresh person seated in tid with role.
func (n *nvsRig) as(t *testing.T, tid, role string) (*http.Client, string) {
	t.Helper()
	return (&notesRig{r: n.r}).browserAs(t, tid, role)
}

// signIn is a new browser of the person of email, signed in to tid.
func (n *nvsRig) signIn(t *testing.T, email, tid string) *http.Client {
	t.Helper()
	n.r.fake.Set(fakeidp.Person{Subject: "s-" + email, Email: email, EmailVerified: true, Name: "FirstName LastName"}, false)
	return (&contactsRig{r: n.r}).signedIn(t, tid)
}

// nvsBody is one invented snapshot fetched at now: two forecast items, one
// card line.
func nvsBody(now time.Time) map[string]any {
	day := now.UTC().Format("2006-01-02")
	first := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	return map[string]any{
		"snapshot_id": uuidV4(), "as_of": day, "month_end": first.AddDate(0, 1, -1).Format("2006-01-02"),
		"newest_bank_voucher_date": day, "fetched_at": now.UTC().Format(time.RFC3339),
		"items": []map[string]any{
			{"item_no": 0, "category": "bank_balance", "sign": 1, "amount": nvsMarker, "label": "bank"},
			{"item_no": 1, "category": "payable", "sign": -1, "amount": "10.00", "due_date": day, "approved": true, "label": "bill"},
		},
		"card_lines": []map[string]any{
			{"line_no": 0, "month": first.Format("2006-01-02"), "route": "debit_ledger", "vendor": "vendor-x",
				"account_number": "4000", "amount": nvsMarker},
		},
	}
}

// nvsDo sends one request from browser b (nil = no session) on the api
// host; bearer "" sends no Authorization header.
func (n *nvsRig) nvsDo(t *testing.T, b *http.Client, method, path, bearer string, body any) (int, string) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		rd = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, "http://api"+domain+path, rd)
	req.Header.Set("Origin", wuiOrigin)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	if b == nil {
		b = &http.Client{Transport: n.r.browser.Transport}
	}
	resp, err := b.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(raw)
}

// actAs turns browser b (an admin of op) into an act-as clone of target.
func (n *nvsRig) actAs(t *testing.T, b *http.Client, target string) {
	t.Helper()
	raw, _ := json.Marshal(map[string]string{"human_id": target})
	req, _ := http.NewRequest(http.MethodPost, "http://"+loginHost+"/api/v1/auth/act-as", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", wuiOrigin)
	resp, err := b.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "clone_hum") {
		t.Fatalf("act-as %s: %d %s", target, resp.StatusCode, body)
	}
}

// TestNetvisorHubRBAC is C-NVS-5: the owner gets 2xx on every owner route
// and reads the figures; another admin of the workspace, an act-as clone of
// the owner, the operator service account, a box session, an agent seat
// and an agent's desk (a box carrying an agent) all get 403 with no figure;
// no session is 401. CONTROL: the owner's own answers carry the marker, so
// each refusal is the door's, not an empty store.
func TestNetvisorHubRBAC(t *testing.T) {
	n := newNvsRig(t)
	for _, rt := range nvsOwnerRoutes {
		code, body := n.nvsDo(t, n.ownerB, rt.method, rt.path, "", rt.body)
		if code != rt.want {
			t.Errorf("CONTROL: owner %s %s = %d %s, want %d", rt.method, rt.path, code, body, rt.want)
		}
		if strings.Contains(rt.path, "/view/") && !strings.Contains(body, nvsMarker) {
			t.Errorf("CONTROL: owner %s %s carries no figure: %s", rt.method, rt.path, body)
		}
	}
	adminB, admin := n.as(t, n.op, rbac.Admin)
	cloneB, _ := n.as(t, n.op, rbac.Admin)
	n.actAs(t, cloneB, n.owner)
	agentB, _ := n.as(t, n.op, rbac.PureAgent)
	desk := n.r.e.box(n.op, "box-nv1", "c-101")
	n.r.e.pin(n.op, desk)
	deskTok := n.r.e.uploadToken(n.op, desk)
	callers := []struct {
		name   string
		b      *http.Client
		bearer string
		want   int
	}{
		{"another admin " + admin, adminB, "", http.StatusForbidden},
		{"act-as clone of the owner", cloneB, "", http.StatusForbidden},
		{"agent seat", agentB, "", http.StatusForbidden},
		{"operator service account", nil, "good", http.StatusForbidden},
		{"agent desk (box) session", nil, deskTok, http.StatusForbidden},
		{"the owner's cookie plus a box token", n.ownerB, deskTok, http.StatusForbidden},
		{"no session", nil, "", http.StatusUnauthorized},
	}
	for _, c := range callers {
		for _, rt := range nvsOwnerRoutes {
			code, body := n.nvsDo(t, c.b, rt.method, rt.path, c.bearer, rt.body)
			if code != c.want {
				t.Errorf("%s: %s %s = %d %s, want %d", c.name, rt.method, rt.path, code, body, c.want)
			}
			if strings.Contains(body, nvsMarker) || strings.Contains(body, "1910") {
				t.Errorf("%s: %s %s leaked a figure: %s", c.name, rt.method, rt.path, body)
			}
		}
	}
}

// TestNetvisorCrossTenant: a person of another workspace, and the owner
// themself signed in to another workspace, get 404 on every owner route;
// the operator routes refuse a request that names another workspace (403).
// CONTROL: the owner in op still reads the figures afterwards.
func TestNetvisorCrossTenant(t *testing.T) {
	n := newNvsRig(t)
	strangerB, _ := n.as(t, n.other, rbac.Admin)
	if hum := join(t, n.r.e, n.email, n.other); hum != n.owner {
		t.Fatalf("join other seated %s, want the owner %s", hum, n.owner)
	}
	ownerElsewhere := n.signIn(t, n.email, n.other)
	for name, b := range map[string]*http.Client{"an admin of another workspace": strangerB, "the owner in another workspace": ownerElsewhere} {
		for _, rt := range nvsOwnerRoutes {
			code, body := n.nvsDo(t, b, rt.method, rt.path, "", rt.body)
			if code != http.StatusNotFound || strings.Contains(body, nvsMarker) {
				t.Errorf("%s: %s %s = %d %s, want 404 and no figure", name, rt.method, rt.path, code, body)
			}
		}
	}
	for _, path := range []string{"/v1/operator/netvisor/refresh"} {
		req, _ := http.NewRequest(http.MethodGet, n.r.e.url(n.op)+path, nil)
		req.Header.Set("Authorization", "Bearer good")
		req.Header.Set(hub.TenantHeader, n.other)
		resp, err := n.r.e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusForbidden {
			t.Errorf("operator %s naming %s = %d, want 403", path, n.other, resp.StatusCode)
		}
	}
	if code, out := opCall(t, n.r.e, n.other, http.MethodPost, "/v1/operator/netvisor/snapshots", "good", nvsBody(time.Now())); code != http.StatusForbidden {
		t.Errorf("ingest on another workspace's host = %d %v, want 403", code, out)
	}
	if code, body := n.nvsDo(t, n.ownerB, http.MethodGet, "/v1/view/netvisor/forecast", "", nil); code != http.StatusOK || !strings.Contains(body, nvsMarker) {
		t.Fatalf("CONTROL: the owner in op = %d %s", code, body)
	}
}

// TestNetvisorOperatorIngest: the operator routes' auth, the owner move, the
// ingest's refusals and counts-only answer, and the refresh request from
// the owner's press to the snapshot that answers it.
func TestNetvisorOperatorIngest(t *testing.T) {
	n := newNvsRig(t)
	ingest := "/v1/operator/netvisor/snapshots"
	for _, c := range []struct {
		token string
		want  int
	}{{"", http.StatusUnauthorized}, {"forged", http.StatusUnauthorized}, {"stranger", http.StatusForbidden}} {
		if code, out := opCall(t, n.r.e, n.op, http.MethodPost, ingest, c.token, nvsBody(time.Now())); code != c.want {
			t.Errorf("token %q: %d %v, want %d", c.token, code, out, c.want)
		}
	}
	code, out := opCall(t, n.r.e, n.op, http.MethodPost, ingest, "good", nvsBody(time.Now()))
	if code != http.StatusOK || out["items"] != float64(2) || out["card_lines"] != float64(1) || out["env"] != "test" {
		t.Fatalf("CONTROL: ingest %d %v", code, out)
	}
	for k := range out {
		if k != "snapshot_id" && k != "env" && k != "items" && k != "card_lines" {
			t.Errorf("the ingest answer carries %q: counts only", k)
		}
	}
	for name, mut := range map[string]func(map[string]any){
		"bad date":      func(b map[string]any) { b["as_of"] = "03.11.2026" },
		"float amount":  func(b map[string]any) { b["items"].([]map[string]any)[0]["amount"] = "1.234" },
		"unknown field": func(b map[string]any) { b["tenant_id"] = n.op },
		"bad category":  func(b map[string]any) { b["items"].([]map[string]any)[0]["category"] = "salary" },
	} {
		b := nvsBody(time.Now())
		mut(b)
		if code, out := opCall(t, n.r.e, n.op, http.MethodPost, ingest, "good", b); code != http.StatusBadRequest {
			t.Errorf("%s: %d %v, want 400", name, code, out)
		}
	}
	prd := nvsBody(time.Now())
	prd["env"] = "prd"
	if code, out := opCall(t, n.r.e, n.op, http.MethodPost, ingest, "good", prd); code != http.StatusConflict || out["error"] != "env_mismatch" {
		t.Errorf("prd snapshot under test settings: %d %v, want 409 env_mismatch", code, out)
	}
	_, outsider := n.as(t, n.other, rbac.Admin)
	if code, out := opCall(t, n.r.e, n.op, http.MethodPut, "/v1/operator/netvisor/owner", "good", map[string]any{"human_id": outsider}); code != http.StatusConflict {
		t.Errorf("owner from another workspace: %d %v, want 409", code, out)
	}
	nvsRefreshFlow(t, n)
}

// nvsRefreshFlow: none open; the owner presses (202), the poller sees it,
// a second press keeps the first time, a snapshot fetched after it clears it.
func nvsRefreshFlow(t *testing.T, n *nvsRig) {
	t.Helper()
	poll := func() any {
		code, out := opCall(t, n.r.e, n.op, http.MethodGet, "/v1/operator/netvisor/refresh", "good", nil)
		if code != http.StatusOK {
			t.Fatalf("poll: %d %v", code, out)
		}
		return out["refresh_requested_at"]
	}
	if at := poll(); at != nil {
		t.Fatalf("a request is open before any press: %v", at)
	}
	_, first := n.nvsDo(t, n.ownerB, http.MethodPost, "/v1/netvisor/refresh", "", nil)
	at := poll()
	if at == nil || !strings.Contains(first, at.(string)) {
		t.Fatalf("after the press the poller reads %v (press answered %s)", at, first)
	}
	if _, again := n.nvsDo(t, n.ownerB, http.MethodPost, "/v1/netvisor/refresh", "", nil); !strings.Contains(again, at.(string)) {
		t.Errorf("a second press moved the request: %s, want %v", again, at)
	}
	if code, out := opCall(t, n.r.e, n.op, http.MethodPost, "/v1/operator/netvisor/snapshots", "good", nvsBody(time.Now().Add(time.Second))); code != http.StatusOK {
		t.Fatalf("answering ingest: %d %v", code, out)
	}
	if at := poll(); at != nil {
		t.Errorf("the snapshot did not clear the request: %v", at)
	}
}
