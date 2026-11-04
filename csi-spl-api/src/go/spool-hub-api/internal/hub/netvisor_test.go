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

// nvsRoutes are the Netvisor routes of a browser session; want is the
// owner's status; view marks a view route, which every person seated in the
// Netvisor workspace reads (C7 as rewritten, SPL-4792); the others are the
// owner's alone.
var nvsRoutes = []struct {
	method, path string
	body         any
	want         int
	view         bool
}{
	{http.MethodGet, "/v1/view/netvisor/forecast", nil, http.StatusOK, true},
	{http.MethodGet, "/v1/view/netvisor/card-costs", nil, http.StatusOK, true},
	{http.MethodPost, "/v1/netvisor/refresh", nil, http.StatusAccepted, false},
	{http.MethodGet, "/v1/netvisor/settings", nil, http.StatusOK, false},
	{http.MethodPut, "/v1/netvisor/settings", map[string]any{"env": "test", "bank_account": "1910",
		"vat_accounts": []string{"2939"}, "tax_accounts": []string{"2930"}, "vendor_exclusions": []string{"vendor-y"}}, http.StatusOK, false},
}

// nvsRig: fin is the Netvisor workspace (cnf SPOOL_HUB_NETVISOR_WORKSPACE,
// csitea on dev and prd) with the owner (a developer, so an admin may act
// as them: the act-as ceiling) and one snapshot; apex is the hub's operator
// workspace (t1 on dev), which keeps no Netvisor data; other is a third
// workspace.
type nvsRig struct {
	r                *doorRig
	fin, apex, other string
	owner            string
	email            string // the owner's sign-in email
	ownerB           *http.Client
}

func newNvsRig(t *testing.T) *nvsRig {
	t.Helper()
	n := newNvsRigBare(t)
	n.email = freshEmail()
	n.owner = join(t, n.r.e, n.email, n.fin) // a developer
	n.ownerB = n.signIn(t, n.email, n.fin)
	if code, out := opCall(t, n.r.e, n.fin, http.MethodPut, "/v1/operator/netvisor/owner", "good", map[string]any{"human_id": n.owner}); code != http.StatusOK {
		t.Fatalf("set owner: %d %v", code, out)
	}
	if code, out := opCall(t, n.r.e, n.fin, http.MethodPost, "/v1/operator/netvisor/snapshots", "good", nvsBody(time.Now())); code != http.StatusOK {
		t.Fatalf("ingest: %d %v", code, out)
	}
	return n
}

// newNvsRigBare is the rig's three workspaces and the hub, with no
// Netvisor owner yet.
func newNvsRigBare(t *testing.T) *nvsRig {
	t.Helper()
	if os.Getenv("SPOOL_TEST_PG_DSN") == "" {
		t.Skip("the Netvisor store needs Postgres (SPOOL_TEST_PG_DSN)")
	}
	n := &nvsRig{fin: newTenantID("nv"), apex: newTenantID("na"), other: newTenantID("nw")}
	n.r = newDoorRig(t, func(o *hub.Options) {
		o.OperatorTenant = n.apex
		o.NetvisorWorkspace = n.fin
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
	for _, id := range []string{n.fin, n.apex, n.other} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := n.r.e.st.CreateTenant(context.Background(), store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
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

// TestNetvisorHubRBAC is C-NVS-5 under C7 as rewritten (SPL-4792; owner
// msg cfa78746): the owner gets 2xx on every route and reads the figures; a
// developer and an admin seated in the workspace who are not the owner read
// the figures on the view routes (reader_is_owner false) and get 403 with no
// figure or account on the owner routes; an act-as clone of the owner, an
// agent seat, the operator service account, a box session and an agent's
// desk get 403 everywhere with no figure; no session is 401. CONTROL: the
// owner's own answers carry the marker, so each refusal is the door's, not
// an empty store.
func TestNetvisorHubRBAC(t *testing.T) {
	n := newNvsRig(t)
	for _, rt := range nvsRoutes {
		code, body := n.nvsDo(t, n.ownerB, rt.method, rt.path, "", rt.body)
		if code != rt.want {
			t.Errorf("CONTROL: owner %s %s = %d %s, want %d", rt.method, rt.path, code, body, rt.want)
		}
		if rt.view && (!strings.Contains(body, nvsMarker) || !strings.Contains(body, `"reader_is_owner":true`)) {
			t.Errorf("CONTROL: owner %s %s carries no figure or no reader_is_owner true: %s", rt.method, rt.path, body)
		}
	}
	adminB, admin := n.as(t, n.fin, rbac.Admin)
	devB, dev := n.as(t, n.fin, rbac.Developer)
	cloneB, _ := n.as(t, n.fin, rbac.Admin)
	n.actAs(t, cloneB, n.owner)
	agentB, _ := n.as(t, n.fin, rbac.PureAgent)
	desk := n.r.e.box(n.fin, "box-nv1", "c-101")
	n.r.e.pin(n.fin, desk)
	deskTok := n.r.e.uploadToken(n.fin, desk)
	for name, b := range map[string]*http.Client{"a developer " + dev: devB, "an admin " + admin: adminB} {
		for _, rt := range nvsRoutes {
			code, body := n.nvsDo(t, b, rt.method, rt.path, "", rt.body)
			switch {
			case rt.view && (code != http.StatusOK || !strings.Contains(body, nvsMarker) || !strings.Contains(body, `"reader_is_owner":false`)):
				t.Errorf("member %s: %s %s = %d %s, want 200, the figures and reader_is_owner false", name, rt.method, rt.path, code, body)
			case !rt.view && (code != http.StatusForbidden || strings.Contains(body, "1910") || strings.Contains(body, nvsMarker)):
				t.Errorf("member %s: owner route %s %s = %d %s, want 403 and no account or figure", name, rt.method, rt.path, code, body)
			case strings.HasSuffix(rt.path, "/card-costs") && !strings.Contains(body, `"vendor_exclusions":["vendor-y"]`):
				t.Errorf("member %s: card costs carry not the owner's vendor exclusions (put above): %s", name, body)
			}
		}
	}
	callers := []struct {
		name   string
		b      *http.Client
		bearer string
		want   int
	}{
		{"act-as clone of the owner", cloneB, "", http.StatusForbidden},
		{"agent seat", agentB, "", http.StatusForbidden},
		{"operator service account", nil, "good", http.StatusForbidden},
		{"agent desk (box) session", nil, deskTok, http.StatusForbidden},
		{"the owner's cookie plus a box token", n.ownerB, deskTok, http.StatusForbidden},
		{"no session", nil, "", http.StatusUnauthorized},
	}
	for _, c := range callers {
		for _, rt := range nvsRoutes {
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
		for _, rt := range nvsRoutes {
			code, body := n.nvsDo(t, b, rt.method, rt.path, "", rt.body)
			if code != http.StatusNotFound || strings.Contains(body, nvsMarker) {
				t.Errorf("%s: %s %s = %d %s, want 404 and no figure", name, rt.method, rt.path, code, body)
			}
		}
	}
	for _, path := range []string{"/v1/operator/netvisor/refresh"} {
		req, _ := http.NewRequest(http.MethodGet, n.r.e.url(n.fin)+path, nil)
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
		if code, out := opCall(t, n.r.e, n.fin, http.MethodPost, ingest, c.token, nvsBody(time.Now())); code != c.want {
			t.Errorf("token %q: %d %v, want %d", c.token, code, out, c.want)
		}
	}
	code, out := opCall(t, n.r.e, n.fin, http.MethodPost, ingest, "good", nvsBody(time.Now()))
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
		"unknown field": func(b map[string]any) { b["tenant_id"] = n.fin },
		"bad category":  func(b map[string]any) { b["items"].([]map[string]any)[0]["category"] = "salary" },
	} {
		b := nvsBody(time.Now())
		mut(b)
		if code, out := opCall(t, n.r.e, n.fin, http.MethodPost, ingest, "good", b); code != http.StatusBadRequest {
			t.Errorf("%s: %d %v, want 400", name, code, out)
		}
	}
	prd := nvsBody(time.Now())
	prd["env"] = "prd"
	if code, out := opCall(t, n.r.e, n.fin, http.MethodPost, ingest, "good", prd); code != http.StatusConflict || out["error"] != "env_mismatch" {
		t.Errorf("prd snapshot under test settings: %d %v, want 409 env_mismatch", code, out)
	}
	_, outsider := n.as(t, n.other, rbac.Admin)
	if code, out := opCall(t, n.r.e, n.fin, http.MethodPut, "/v1/operator/netvisor/owner", "good", map[string]any{"human_id": outsider}); code != http.StatusConflict {
		t.Errorf("owner from another workspace: %d %v, want 409", code, out)
	}
	nvsRefreshFlow(t, n)
}

// nvsRefreshFlow: none open; the owner presses (202), the poller sees it,
// a second press keeps the first time, a snapshot fetched after it clears it.
func nvsRefreshFlow(t *testing.T, n *nvsRig) {
	t.Helper()
	poll := func() any {
		code, out := opCall(t, n.r.e, n.fin, http.MethodGet, "/v1/operator/netvisor/refresh", "good", nil)
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
	if code, out := opCall(t, n.r.e, n.fin, http.MethodPost, "/v1/operator/netvisor/snapshots", "good", nvsBody(time.Now().Add(time.Second))); code != http.StatusOK {
		t.Fatalf("answering ingest: %d %v", code, out)
	}
	if at := poll(); at != nil {
		t.Errorf("the snapshot did not clear the request: %v", at)
	}
}

// nvsOpRefresh is GET /v1/operator/netvisor/refresh as the operator service
// account on host's workspace, naming named in X-Spool-Tenant ("" = none).
func nvsOpRefresh(t *testing.T, n *nvsRig, host, named string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, n.r.e.url(host)+"/v1/operator/netvisor/refresh", nil)
	req.Header.Set("Authorization", "Bearer good")
	if named != "" {
		req.Header.Set(hub.TenantHeader, named)
	}
	resp, err := n.r.e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(raw)
}

// TestNetvisorFinanceWorkspaceOnly (B5 fix, SPL-4742): the operator routes
// serve the Netvisor workspace (csitea) only: 409 no_owner before the owner
// is named, then 200; the operator workspace (t1, the apex) and a third
// workspace get 403 netvisor_workspace_only, by Host or by X-Spool-Tenant,
// and write nothing. The owner seated in the operator workspace gets 404 on
// the owner routes there. RED CONTROL: point netvisorOperator back at
// operatorTenant and the Netvisor workspace's 409 / 200 turn 403.
func TestNetvisorFinanceWorkspaceOnly(t *testing.T) {
	n := newNvsRigBare(t)
	if code, body := nvsOpRefresh(t, n, n.fin, n.fin); code != http.StatusConflict || !strings.Contains(body, "no_owner") {
		t.Fatalf("Netvisor workspace, no owner yet = %d %s, want 409 no_owner", code, body)
	}
	if code, out := opCall(t, n.r.e, n.fin, http.MethodPost, "/v1/operator/netvisor/snapshots", "good", nvsBody(time.Now())); code != http.StatusConflict || out["error"] != "no_owner" {
		t.Fatalf("ingest before the owner = %d %v, want 409 no_owner", code, out)
	}
	n.email = freshEmail()
	n.owner = join(t, n.r.e, n.email, n.fin)
	for _, tid := range []string{n.apex, n.other} {
		if code, out := opCall(t, n.r.e, tid, http.MethodPut, "/v1/operator/netvisor/owner", "good", map[string]any{"human_id": n.owner}); code != http.StatusForbidden || out["error"] != "netvisor_workspace_only" {
			t.Errorf("set owner on %s's host = %d %v, want 403 netvisor_workspace_only", tid, code, out)
		}
	}
	if code, out := opCall(t, n.r.e, n.fin, http.MethodPut, "/v1/operator/netvisor/owner", "good", map[string]any{"human_id": n.owner}); code != http.StatusOK || out["workspace"] != n.fin {
		t.Fatalf("set owner on the Netvisor workspace = %d %v", code, out)
	}
	if code, body := nvsOpRefresh(t, n, n.fin, ""); code != http.StatusOK {
		t.Errorf("Netvisor workspace poll = %d %s, want 200", code, body)
	}
	for _, c := range []struct{ host, named string }{{n.apex, ""}, {n.other, ""}, {n.fin, n.apex}, {n.fin, n.other}} {
		if code, body := nvsOpRefresh(t, n, c.host, c.named); code != http.StatusForbidden || !strings.Contains(body, "netvisor_workspace_only") {
			t.Errorf("poll host %s naming %q = %d %s, want 403", c.host, c.named, code, body)
		}
	}
	for _, tid := range []string{n.apex, n.other} {
		if code, out := opCall(t, n.r.e, tid, http.MethodPost, "/v1/operator/netvisor/snapshots", "good", nvsBody(time.Now())); code != http.StatusForbidden {
			t.Errorf("ingest on %s's host = %d %v, want 403", tid, code, out)
		}
	}
	if hum := join(t, n.r.e, n.email, n.apex); hum != n.owner {
		t.Fatalf("join apex seated %s, want the owner %s", hum, n.owner)
	}
	atApex := n.signIn(t, n.email, n.apex)
	for _, rt := range nvsRoutes {
		if code, body := n.nvsDo(t, atApex, rt.method, rt.path, "", rt.body); code != http.StatusNotFound {
			t.Errorf("the owner in the operator workspace: %s %s = %d %s, want 404", rt.method, rt.path, code, body)
		}
	}
}

// TestNetvisorCardLineNoAccount (B5 fix, SPL-4742, rdb 0258): a card line
// with no account_number (a credit-card e-invoice line) ingests, and the
// owner reads it back with account_number ""; a non-digit account is 400.
func TestNetvisorCardLineNoAccount(t *testing.T) {
	n := newNvsRig(t)
	b := nvsBody(time.Now().Add(time.Second))
	month := b["card_lines"].([]map[string]any)[0]["month"]
	b["card_lines"] = append(b["card_lines"].([]map[string]any),
		map[string]any{"line_no": 1, "month": month, "route": "credit_einvoice", "vendor": "vendor-z", "amount": "7.00"})
	if code, out := opCall(t, n.r.e, n.fin, http.MethodPost, "/v1/operator/netvisor/snapshots", "good", b); code != http.StatusOK || out["card_lines"] != float64(2) {
		t.Fatalf("ingest of a line without an account = %d %v, want 200 and 2 lines", code, out)
	}
	code, body := n.nvsDo(t, n.ownerB, http.MethodGet, "/v1/view/netvisor/card-costs", "", nil)
	var got struct {
		Lines []struct {
			Route         string `json:"route"`
			AccountNumber string `json:"account_number"`
			Amount        string `json:"amount"`
		} `json:"lines"`
	}
	if err := json.Unmarshal([]byte(body), &got); code != http.StatusOK || err != nil || len(got.Lines) != 2 {
		t.Fatalf("card-costs = %d %s (%v), want 2 lines", code, body, err)
	}
	if l := got.Lines[1]; l.Route != "credit_einvoice" || l.AccountNumber != "" || l.Amount != "7.00" {
		t.Errorf("the line without an account read back as %+v", l)
	}
	if got.Lines[0].AccountNumber != "4000" {
		t.Errorf("the line with an account read back as %+v", got.Lines[0])
	}
	bad := nvsBody(time.Now().Add(2 * time.Second))
	bad["card_lines"].([]map[string]any)[0]["account_number"] = "40x0"
	if code, out := opCall(t, n.r.e, n.fin, http.MethodPost, "/v1/operator/netvisor/snapshots", "good", bad); code != http.StatusBadRequest {
		t.Errorf("ingest of account 40x0 = %d %v, want 400", code, out)
	}
}
