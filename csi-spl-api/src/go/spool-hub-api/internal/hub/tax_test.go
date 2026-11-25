package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 143 taxes-tab.md S2 (SPL-6438): the Costs > Taxes routes. Real
// browser sessions (doorRig) on Postgres only, since only the Postgres
// store keeps the tax index (rdb 0326); hub-pg.tst.sh runs them under
// PRE_PUSH_TIER=full. Every value here is invented.

// taxMarker is the invented kind of the seeded document: a body that
// carries it carries a row.
const taxMarker = "kind-marker-7731"

// taxRig: fin is the tax workspace (cnf SPOOL_HUB_TAX_WORKSPACE, csitea on
// dev and prd) with one snapshot; apex is the operator workspace, which
// keeps no tax index; other is a third workspace.
type taxRig struct {
	r                *doorRig
	fin, apex, other string
}

func newTaxRig(t *testing.T) *taxRig {
	t.Helper()
	if os.Getenv("SPOOL_TEST_PG_DSN") == "" {
		t.Skip("the tax store needs Postgres (SPOOL_TEST_PG_DSN)")
	}
	x := &taxRig{fin: newTenantID("tx"), apex: newTenantID("ta"), other: newTenantID("tw")}
	x.r = newDoorRig(t, func(o *hub.Options) {
		o.OperatorTenant = x.apex
		o.TaxWorkspace = x.fin
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
	for _, id := range []string{x.fin, x.apex, x.other} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := x.r.e.st.CreateTenant(context.Background(), store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
	}
	if code, out := opCall(t, x.r.e, x.fin, http.MethodPost, "/v1/operator/tax/snapshots", "good", taxBody(time.Now())); code != http.StatusOK {
		t.Fatalf("ingest: %d %v", code, out)
	}
	return x
}

// nvs is the Netvisor rig's request helpers over this rig's hub.
func (x *taxRig) nvs() *nvsRig { return &nvsRig{r: x.r} }

// taxBody is one invented snapshot taken at now: a decision due in five
// days and a message.
func taxBody(now time.Time) map[string]any {
	day := now.UTC().Format("2006-01-02")
	return map[string]any{
		"snapshot_id": uuidV4(), "tax_year": 2026, "taken_at": now.UTC().Format(time.RFC3339),
		"documents": []map[string]any{
			{"arrival_date": day, "kind": taxMarker, "doc_type": "decision", "tax_type": "vat", "period": "2026-01",
				"due_date": now.UTC().AddDate(0, 0, 5).Format("2006-01-02"), "category": "decisions",
				"content_sha256": strings.Repeat("a", 64)},
			{"arrival_date": day, "kind": "letter", "doc_type": "msg", "tax_type": "income", "period": "2026",
				"category": "msgs", "content_sha256": strings.Repeat("b", 64)},
		},
	}
}

// TestTaxHubDoors: a developer and an admin seated in the tax workspace read
// the overview; an act-as clone, an agent seat, a time accountant, a channel
// guest, the operator service account, a box session and a cookie plus a
// token get 403 with no row; no session is 401. CONTROL: the person's own
// answer carries the marker, so each refusal is the door's.
func TestTaxHubDoors(t *testing.T) {
	x := newTaxRig(t)
	n := x.nvs()
	const path = "/v1/view/tax/overview"
	devB, dev := n.as(t, x.fin, rbac.Developer)
	adminB, _ := n.as(t, x.fin, rbac.Admin)
	for name, b := range map[string]*http.Client{"developer": devB, "admin": adminB} {
		code, body := n.nvsDo(t, b, http.MethodGet, path, "", nil)
		if code != http.StatusOK || !strings.Contains(body, taxMarker) || !strings.Contains(body, `"due_soon":true`) {
			t.Errorf("CONTROL: %s = %d %s, want 200 with the documents", name, code, body)
		}
	}
	cloneB, _ := n.as(t, x.fin, rbac.Admin)
	n.actAs(t, cloneB, dev)
	agentB, _ := n.as(t, x.fin, rbac.PureAgent)
	accB, _ := n.as(t, x.fin, rbac.TimeAccountant)
	guestB, _ := n.as(t, x.fin, rbac.ChannelGuest)
	desk := x.r.e.box(x.fin, "box-tx1", "c-101")
	x.r.e.pin(x.fin, desk)
	deskTok := x.r.e.uploadToken(x.fin, desk)
	for _, c := range []struct {
		name   string
		b      *http.Client
		bearer string
		want   int
	}{
		{"act-as clone", cloneB, "", http.StatusForbidden},
		{"agent seat", agentB, "", http.StatusForbidden},
		{"time accountant", accB, "", http.StatusForbidden},
		{"channel guest", guestB, "", http.StatusForbidden},
		{"operator service account", nil, "good", http.StatusForbidden},
		{"agent desk (box) session", nil, deskTok, http.StatusForbidden},
		{"a person's cookie plus a box token", devB, deskTok, http.StatusForbidden},
		{"no session", nil, "", http.StatusUnauthorized},
	} {
		code, body := n.nvsDo(t, c.b, http.MethodGet, path, c.bearer, nil)
		if code != c.want || strings.Contains(body, taxMarker) {
			t.Errorf("%s = %d %s, want %d and no row", c.name, code, body, c.want)
		}
	}
	if code, body := n.nvsDo(t, devB, http.MethodGet, path+"?year=26", "", nil); code != http.StatusBadRequest {
		t.Errorf("?year=26 = %d %s, want 400", code, body)
	}
	if code, body := n.nvsDo(t, devB, http.MethodGet, path+"?year=2025", "", nil); code != http.StatusOK ||
		strings.Contains(body, taxMarker) || !strings.Contains(body, `"years":[2026]`) {
		t.Errorf("?year=2025 = %d %s, want 200, no 2026 row, years [2026]", code, body)
	}
}

// TestTaxHubOtherWorkspaces: an admin of another workspace and of the
// operator workspace get an unknown route's plain 404, the same body as a
// route that does not exist; the operator ingest refuses a request that
// names another workspace (403); a hub with no tax workspace is 404.
func TestTaxHubOtherWorkspaces(t *testing.T) {
	x := newTaxRig(t)
	n := x.nvs()
	_, unknown := n.nvsDo(t, nil, http.MethodGet, "/v1/view/tax/no-such-route", "", nil)
	for _, tid := range []string{x.other, x.apex} {
		b, _ := n.as(t, tid, rbac.Admin)
		code, body := n.nvsDo(t, b, http.MethodGet, "/v1/view/tax/overview", "", nil)
		if code != http.StatusNotFound || body != unknown {
			t.Errorf("an admin of %s = %d %q, want 404 %q (an unknown route's)", tid, code, body, unknown)
		}
	}
	if code, out := opCall(t, x.r.e, x.other, http.MethodPost, "/v1/operator/tax/snapshots", "good", taxBody(time.Now())); code != http.StatusForbidden {
		t.Errorf("ingest on another workspace's host = %d %v, want 403", code, out)
	}
}

// TestTaxOperatorIngest: the ingest's auth, its refusals (a file name or
// an amount is an unknown field), the duplicate and the counts-only answer.
func TestTaxOperatorIngest(t *testing.T) {
	x := newTaxRig(t)
	const ingest = "/v1/operator/tax/snapshots"
	for _, c := range []struct {
		token string
		want  int
	}{{"", http.StatusUnauthorized}, {"forged", http.StatusUnauthorized}, {"stranger", http.StatusForbidden}} {
		if code, out := opCall(t, x.r.e, x.fin, http.MethodPost, ingest, c.token, taxBody(time.Now())); code != c.want {
			t.Errorf("token %q: %d %v, want %d", c.token, code, out, c.want)
		}
	}
	body := taxBody(time.Now())
	code, out := opCall(t, x.r.e, x.fin, http.MethodPost, ingest, "good", body)
	if code != http.StatusOK || out["documents"] != float64(2) || out["tax_year"] != float64(2026) {
		t.Fatalf("CONTROL: ingest %d %v", code, out)
	}
	for k := range out {
		if k != "snapshot_id" && k != "tax_year" && k != "documents" {
			t.Errorf("the ingest answer carries %q: counts only", k)
		}
	}
	if code, out := opCall(t, x.r.e, x.fin, http.MethodPost, ingest, "good", body); code != http.StatusConflict {
		t.Errorf("the same snapshot again = %d %v, want 409", code, out)
	}
	for name, mut := range map[string]func(map[string]any){
		"file name":    func(b map[string]any) { b["documents"].([]map[string]any)[0]["file_name"] = "x.pdf" },
		"amount":       func(b map[string]any) { b["documents"].([]map[string]any)[0]["amount"] = "1.00" },
		"bad date":     func(b map[string]any) { b["documents"].([]map[string]any)[0]["arrival_date"] = "03.11.2026" },
		"bad taken_at": func(b map[string]any) { b["taken_at"] = "yesterday" },
		"bad category": func(b map[string]any) { b["documents"].([]map[string]any)[0]["category"] = "amounts" },
		"bad sha256":   func(b map[string]any) { b["documents"].([]map[string]any)[0]["content_sha256"] = "abc" },
	} {
		b := taxBody(time.Now())
		mut(b)
		if code, out := opCall(t, x.r.e, x.fin, http.MethodPost, ingest, "good", b); code != http.StatusBadRequest {
			t.Errorf("%s: %d %v, want 400", name, code, out)
		}
	}
}

// TestTaxHubOff: with no tax workspace in cnf, both routes are 404.
func TestTaxHubOff(t *testing.T) {
	if os.Getenv("SPOOL_TEST_PG_DSN") == "" {
		t.Skip("needs Postgres (SPOOL_TEST_PG_DSN)")
	}
	n := newNvsRigBare(t) // TaxWorkspace stays ""
	b, _ := n.as(t, n.fin, rbac.Admin)
	if code, body := n.nvsDo(t, b, http.MethodGet, "/v1/view/tax/overview", "", nil); code != http.StatusNotFound {
		t.Errorf("overview with the cnf empty = %d %s, want 404", code, body)
	}
	if code, out := opCall(t, n.r.e, n.fin, http.MethodPost, "/v1/operator/tax/snapshots", "good", taxBody(time.Now())); code != http.StatusNotFound {
		t.Errorf("ingest with the cnf empty = %d %v, want 404", code, out)
	}
}
