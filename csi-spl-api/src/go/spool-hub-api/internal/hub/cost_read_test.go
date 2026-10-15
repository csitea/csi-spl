package hub_test

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/jackc/pgx/v5"
)

// Spec 123 lane 4b: GET /v1/tenant/costs, the month report of the
// Monitoring Costs tab. On Postgres (hub-pg.tst.sh) the real store reads
// seeded rows under RLS; on the memory store a stand-in answers what the
// Postgres store would, from the same rows, so the role and scope rules are
// proved on both.

const costPath = "/v1/tenant/costs?month=2011-03"

type costSeedRow struct {
	tenant string // "" = estate
	pov    string
	usd    int64
}

// costReadStub is the memory store's stand-in: it answers seeded rows by the
// scope the hub asked for, as RLS would, and records each query.
type costReadStub struct {
	*store.Memory
	mu   sync.Mutex
	rows []costSeedRow
	asks []store.CostMonthQuery
}

func (c *costReadStub) CostMonthRead(_ context.Context, q store.CostMonthQuery) (store.CostMonth, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.asks = append(c.asks, q)
	out := store.CostMonth{Parts: []store.CostPart{}, Coverage: []store.CostSourceDays{}}
	for _, r := range c.rows {
		if r.tenant == q.Tenant || (r.tenant == "" && q.Estate) {
			out.Parts = append(out.Parts, store.CostPart{Estate: r.tenant == "", Source: "gcp", ProjectOrVendor: r.pov,
				Kind: "cloud_run", Origin: "billing_export", USDMicros: r.usd, EURMicros: r.usd, Days: 1})
		}
	}
	return out, nil
}

// costReadEnv is operatorEnv's shape (an operator workspace and one other,
// one member per role in each) with the rows seeded: one estate row, one of
// the operator workspace and one of the other, all in 2011-03.
func costReadEnv(t *testing.T) (e *env, op, other string, who, whoOther map[string]string, stub *costReadStub) {
	t.Helper()
	op, other = newTenantID("op"), newTenantID("ot")
	e = rbacEnv(t, func(o *hub.Options) {
		o.OperatorTenant = op
		if m, ok := o.Store.(*store.Memory); ok {
			stub = &costReadStub{Memory: m}
			o.Store = stub
		}
	})
	ctx := context.Background()
	who, whoOther = map[string]string{}, map[string]string{}
	for _, id := range []string{op, other} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := e.st.CreateTenant(ctx, store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
	}
	for _, r := range rbac.RoleIDs {
		who[r], whoOther[r] = seat(t, e, op, r), seat(t, e, other, r)
	}
	rows := []costSeedRow{{"", newTenantID("csi-spl-"), 5_000_000}, {op, "op-own", 1_000_000}, {other, "other-own", 2_000_000}}
	if stub != nil {
		stub.rows = rows
		return
	}
	pg := e.st.(*store.Postgres)
	err := pgx.BeginFunc(ctx, pg.Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
			return err
		}
		// estate rows are shared by every test on the database: this month is ours
		if _, err := tx.Exec(ctx, `DELETE FROM cost_lines WHERE day >= '2011-03-01' AND day < '2011-04-01' AND tenant_id IS NULL`); err != nil {
			return err
		}
		for _, r := range rows {
			var tid any
			if r.tenant != "" {
				tid = r.tenant
			}
			if _, err := tx.Exec(ctx, `INSERT INTO cost_lines (day, source, project_or_vendor, tenant_id, kind, units,
				amount_micros, currency, usd_micros, eur_micros, fx_rate_day, origin, run_id)
				VALUES ('2011-03-04', 'gcp', $1, $2, 'cloud_run', 0, $3, 'USD', $3, $3, '2011-03-04', 'billing_export', 'run-1')`,
				r.pov, tid, r.usd); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return
}

// povs is project_or_vendor -> estate of each part of an answer.
func povs(body map[string]any) map[string]bool {
	m := map[string]bool{}
	parts, _ := body["parts"].([]any)
	for _, p := range parts {
		row := p.(map[string]any)
		m[row["project_or_vendor"].(string)] = row["estate"].(bool)
	}
	return m
}

// TestCostReadRoles (spec 123 section 8 "WUI Security"): costs.read is
// biz_owner's and admin's; every other role is 403 naming costs.read, in the
// operator workspace and elsewhere, and a request with no member session is
// refused. CONTROL: biz_owner and admin of both workspaces read 200, so each
// 403 is the permission's, not a broken route.
func TestCostReadRoles(t *testing.T) {
	e, op, other, who, whoOther, _ := costReadEnv(t)
	for _, ws := range []struct {
		tid string
		hum map[string]string
	}{{op, who}, {other, whoOther}} {
		for _, role := range rbac.RoleIDs {
			code, body := call(t, e, ws.tid, http.MethodGet, costPath, ws.hum[role], nil)
			want := http.StatusForbidden
			if role == rbac.BizOwner || role == rbac.Admin {
				want = http.StatusOK
			}
			if code != want || (want == http.StatusForbidden && body["permission"] != rbac.CostsRead) {
				t.Errorf("%s in %s: %d %v, want %d", role, ws.tid, code, body, want)
			}
		}
	}
	if code, _ := call(t, e, other, http.MethodGet, costPath, "", nil); code != http.StatusUnauthorized && code != http.StatusForbidden {
		t.Errorf("no session: %d, want 401 or 403", code)
	}
}

// TestCostReadEstateScope (spec 123 section 8 "Estate scope", Q-1 = A): the
// operator workspace's biz_owner reads the estate row beside its own; the
// other workspace's biz_owner and admin read their own row only, never the
// estate nor the operator workspace's. CONTROL: the estate row is there and
// readable (the operator's answer holds it), so the other's 0 is the scope.
func TestCostReadEstateScope(t *testing.T) {
	e, op, other, who, whoOther, stub := costReadEnv(t)
	code, body := call(t, e, op, http.MethodGet, costPath, who[rbac.BizOwner], nil)
	got := povs(body)
	if code != http.StatusOK || body["scope"] != "estate" || len(got) != 2 || got["op-own"] {
		t.Fatalf("CONTROL: the operator workspace: %d %v", code, body)
	}
	estate := 0
	for _, isEstate := range got {
		if isEstate {
			estate++
		}
	}
	if estate != 1 {
		t.Fatalf("CONTROL: the operator workspace reads %d estate rows, want 1: %v", estate, body)
	}
	if tot := body["total"].(map[string]any); tot["usd_micros"] != float64(6_000_000) {
		t.Errorf("operator total %v, want 6.00 USD", tot)
	}
	for _, hum := range []string{whoOther[rbac.BizOwner], whoOther[rbac.Admin]} {
		code, body := call(t, e, other, http.MethodGet, costPath, hum, nil)
		got := povs(body)
		if code != http.StatusOK || body["scope"] != "workspace" || len(got) != 1 || got["other-own"] {
			t.Errorf("the other workspace reads %d %v, want its own row only", code, body)
		}
		if _, has := got["other-own"]; !has {
			t.Errorf("the other workspace misses its own row: %v", body)
		}
	}
	if stub != nil {
		for _, q := range stub.asks {
			if q.Estate != (q.Tenant == op) {
				t.Errorf("the hub asked %+v: estate is the operator workspace's only", q)
			}
		}
	}
}

// TestCostReadMonth: a bad or future month is 400; no month is the current
// UTC month so far, N = the days that ended; a past month has ended.
func TestCostReadMonth(t *testing.T) {
	now := time.Now().UTC()
	e, op, _, who, _, _ := costReadEnv(t)
	for _, m := range []string{"2011-3", "march", now.AddDate(0, 1, 0).Format("2006-01")} {
		if code, body := call(t, e, op, http.MethodGet, "/v1/tenant/costs?month="+m, who[rbac.Admin], nil); code != http.StatusBadRequest {
			t.Errorf("month=%s: %d %v, want 400", m, code, body)
		}
	}
	code, body := call(t, e, op, http.MethodGet, "/v1/tenant/costs", who[rbac.Admin], nil)
	if code != http.StatusOK || body["month"] != now.Format("2006-01") || body["status"] != "so_far" || body["days_ended"] != float64(now.Day()-1) {
		t.Errorf("no month: %d %v", code, body)
	}
	code, body = call(t, e, op, http.MethodGet, costPath, who[rbac.Admin], nil)
	if code != http.StatusOK || body["status"] != "ended" || body["from"] != "2011-03-01" || body["to"] != "2011-03-31" || body["days"] != float64(31) {
		t.Errorf("2011-03: %d %v", code, body)
	}
}
