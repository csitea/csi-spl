package hub_test

import (
	"context"
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-4187: GET /v1/tenant/costs/cloud, one estate GCP project's month per
// day and service (the Cloud section's third level). The rows are
// costReadEnv's: on Postgres the real store reads them, on the memory store
// costReadStub answers from the same rows.

func (c *costReadStub) CostCloudDays(_ context.Context, q store.CostCloudDaysQuery) ([]store.CostCloudDay, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := []store.CostCloudDay{}
	for _, r := range c.rows {
		if r.tenant == "" && r.pov == q.Project {
			out = append(out, store.CostCloudDay{Day: "2011-03-04", Kind: "cloud_run", USDMicros: r.usd, EURMicros: r.usd})
		}
	}
	return out, nil
}

// estatePov is the project of the estate row, read from the admin's month.
func estatePov(t *testing.T, e *env, op, admin string) string {
	t.Helper()
	_, body := call(t, e, op, http.MethodGet, costPath, admin, nil)
	for pov, estate := range povs(body) {
		if estate {
			return pov
		}
	}
	t.Fatalf("no estate row in %v", body)
	return ""
}

// TestCostCloudDays: the operator workspace's admin reads the estate
// project's days; every other role there and every member of another
// workspace reads 403 (a workspace's own project included), and so does a
// request with no member session (a box or agent credential carries none:
// the same hum == "" refusal in membersActor); no project or a bad month is
// 400. CONTROL: the admin's answer holds the day, so each 403
// is the rule, not an empty month.
func TestCostCloudDays(t *testing.T) {
	e, op, other, who, whoOther, _ := costReadEnv(t)
	pov := estatePov(t, e, op, who[rbac.Admin])
	path := "/v1/tenant/costs/cloud?month=2011-03&project=" + url.QueryEscape(pov)
	code, body := call(t, e, op, http.MethodGet, path, who[rbac.Admin], nil)
	days, _ := body["days"].([]any)
	if code != http.StatusOK || body["project"] != pov || len(days) != 1 {
		t.Fatalf("CONTROL: the operator admin: %d %v", code, body)
	}
	if d := days[0].(map[string]any); d["day"] != "2011-03-04" || d["kind"] != "cloud_run" || d["usd_micros"] != float64(5_000_000) {
		t.Errorf("day %v, want 2011-03-04 cloud_run 5.00 USD", d)
	}
	for _, c := range []struct{ tid, hum, path string }{
		{op, who[rbac.BizOwner], path}, {op, who[rbac.RegularUser], path}, {op, who[rbac.Developer], path}, {op, "", path},
		{other, whoOther[rbac.Admin], path}, {other, whoOther[rbac.BizOwner], "/v1/tenant/costs/cloud?month=2011-03&project=other-own"},
	} {
		if code, body := call(t, e, c.tid, http.MethodGet, c.path, c.hum, nil); code != http.StatusForbidden {
			t.Errorf("%s in %s: %d %v, want 403", c.hum, c.tid, code, body)
		}
	}
	for _, p := range []string{"/v1/tenant/costs/cloud?month=2011-03", "/v1/tenant/costs/cloud?month=march&project=x"} {
		if code, body := call(t, e, op, http.MethodGet, p, who[rbac.Admin], nil); code != http.StatusBadRequest {
			t.Errorf("%s: %d %v, want 400", p, code, body)
		}
	}
}

// TestCostCloudDaysActAsClone (c-504 W1): a live act-as clone of the
// operator admin holds the admin's roles, yet reads 403 on the cloud days
// and the workspace answer of the month read, never the estate's. CONTROL:
// the admin itself reads 200 and the estate scope, so the refusal is the
// clone's.
func TestCostCloudDaysActAsClone(t *testing.T) {
	e, op, _, who, _, _ := costReadEnv(t)
	cs, ok := e.st.(dmCloneStore)
	if !ok {
		t.Skip("act-as clone store needs Postgres (SPOOL_TEST_PG_DSN)")
	}
	admin := who[rbac.Admin]
	pov := estatePov(t, e, op, admin)
	path := "/v1/tenant/costs/cloud?month=2011-03&project=" + url.QueryEscape(pov)
	now := time.Now().UTC().Truncate(time.Microsecond)
	cl, err := cs.StartClone(context.Background(), store.CloneStart{TenantID: op, TargetHum: admin, AdminName: "Admin",
		CreatedBy: admin, ExpiresAt: now.Add(time.Hour)}, now)
	if err != nil {
		t.Fatal(err)
	}
	if code, body := call(t, e, op, http.MethodGet, path, admin, nil); code != http.StatusOK {
		t.Fatalf("CONTROL: the operator admin: %d %v", code, body)
	}
	if _, body := call(t, e, op, http.MethodGet, costPath, admin, nil); body["scope"] != "estate" {
		t.Fatalf("CONTROL: the operator admin's month scope %v, want estate", body["scope"])
	}
	if code, body := call(t, e, op, http.MethodGet, path, cl.CloneHum, nil); code != http.StatusForbidden {
		t.Errorf("the clone of the operator admin: %d %v, want 403", code, body)
	}
	code, body := call(t, e, op, http.MethodGet, costPath, cl.CloneHum, nil)
	if code != http.StatusOK || body["scope"] != "workspace" {
		t.Errorf("the clone's month: %d scope %v, want 200 workspace", code, body["scope"])
	}
	for pov, estate := range povs(body) {
		if estate {
			t.Errorf("the clone's month holds the estate row %s", pov)
		}
	}
}
