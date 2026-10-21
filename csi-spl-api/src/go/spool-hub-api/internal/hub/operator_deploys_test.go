package hub_test

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 143 T025 + T027 (SPL-2788): POST /v1/operator/deploys and the
// 2-minute reconcile check. On Postgres (hub-pg.tst.sh) the real store
// writes rdb 0202 estate_deploys; on the memory store deployRecorder stands
// in, since only the Postgres store keeps the deploy record.

type deployRecorder struct {
	*store.Memory
	mu   sync.Mutex
	rows []store.EstateDeploy
	n    int
}

func (d *deployRecorder) add(r store.EstateDeploy, now time.Time) store.EstateDeploy {
	d.n++
	r.DeployID, r.DeployedAt = hex.EncodeToString([]byte{byte(d.n)}), now.Add(time.Duration(d.n)*time.Microsecond)
	d.rows = append(d.rows, r)
	return r
}

func (d *deployRecorder) PutEstateDeploy(_ context.Context, r store.EstateDeploy) (store.EstateDeploy, bool, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, x := range d.rows {
		if r.WorkflowRunID != "" && x.Source == "ci" && x.Env == r.Env && x.Component == r.Component &&
			x.CommitSHA == r.CommitSHA && x.Status == r.Status && x.WorkflowRunID == r.WorkflowRunID {
			return x, false, nil
		}
	}
	r.Source = "ci"
	return d.add(r, time.Now()), true, nil
}

func (d *deployRecorder) latest(env, component string) (store.EstateDeploy, bool) {
	var best store.EstateDeploy
	ok := false
	for _, x := range d.rows {
		if x.Env == env && x.Component == component && x.Status == "success" && (!ok || x.DeployedAt.After(best.DeployedAt)) {
			best, ok = x, true
		}
	}
	return best, ok
}

func (d *deployRecorder) LatestEstateDeploy(_ context.Context, env, component string) (store.EstateDeploy, bool, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	r, ok := d.latest(env, component)
	return r, ok, nil
}

func (d *deployRecorder) FillEstateDeploy(_ context.Context, env, component, version, sha string) (bool, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if r, ok := d.latest(env, component); ok && r.CommitSHA == sha {
		return false, nil
	}
	d.add(store.EstateDeploy{Env: env, Component: component, Version: version, CommitSHA: sha, Status: "success",
		Source: "reconcile", WorkflowRunID: store.EstateDeployReconcileRun, DeployedBy: store.EstateDeployReconcileBy}, time.Now())
	return true, nil
}

type deployClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *deployClock) Now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.now }
func (c *deployClock) add(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

// deployEnv: ed is the deploy record the hub writes (the recorder on the
// memory store, the Postgres store itself under SPOOL_TEST_PG_DSN).
func deployEnv(t *testing.T) (*env, string, store.EstateDeploys, *deployClock) {
	t.Helper()
	clk := &deployClock{now: time.Now()}
	var ed store.EstateDeploys
	e := rbacEnv(t, func(o *hub.Options) {
		if m, ok := o.Store.(*store.Memory); ok {
			o.Store = &deployRecorder{Memory: m}
		}
		ed, _ = o.Store.(store.EstateDeploys)
		o.Env = "dev"
		o.Now = clk.Now
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
	tid, _ := e.tenant()
	return e, tid, ed, clk
}

func randSHA(t *testing.T) string {
	t.Helper()
	b := make([]byte, 20)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(b)
}

// TestOperatorDeploysIngest (T025 GATE): the env's operator SA reports a
// deploy and the row is stored (source ci, plain version written v-form);
// the same run's re-post returns that row, stored=false. RED CONTROL: no
// token is 401, a stranger's token 403, another env's record or a short
// sha 400, and none of them writes a row.
func TestOperatorDeploysIngest(t *testing.T) {
	e, tid, ed, _ := deployEnv(t)
	sha := randSHA(t)
	body := map[string]any{"env": "dev", "component": "hub", "version": "3.2.5", "commit_sha": sha, "workflow_run_id": "185623910"}
	for _, c := range []struct {
		name, token string
		body        map[string]any
		want        int
	}{
		{"no token", "", body, http.StatusUnauthorized},
		{"bad token", "forged", body, http.StatusUnauthorized},
		{"stranger", "stranger", body, http.StatusForbidden},
		{"other env", "good", map[string]any{"env": "prd", "component": "hub", "version": "3.2.5", "commit_sha": sha}, http.StatusBadRequest},
		{"short sha", "good", map[string]any{"env": "dev", "component": "hub", "version": "3.2.5", "commit_sha": sha[:7]}, http.StatusBadRequest},
		{"unknown field", "good", map[string]any{"env": "dev", "component": "hub", "version": "3.2.5", "commit_sha": sha, "x": 1}, http.StatusBadRequest},
	} {
		if code, out := opCall(t, e, tid, http.MethodPost, "/v1/operator/deploys", c.token, c.body); code != c.want {
			t.Errorf("RED CONTROL %s: %d %v, want %d", c.name, code, out, c.want)
		}
	}
	if r, ok, _ := ed.LatestEstateDeploy(context.Background(), "dev", "hub"); ok && r.CommitSHA == sha {
		t.Fatalf("a refused request wrote a row: %+v", r)
	}
	code, out := opCall(t, e, tid, http.MethodPost, "/v1/operator/deploys", "good", body)
	row, _ := out["deploy"].(map[string]any)
	if code != http.StatusOK || out["stored"] != true || row["commit_sha"] != sha || row["version"] != "v3.2.5" ||
		row["source"] != "ci" || row["status"] != "success" || row["deployed_by"] != operatorSA {
		t.Fatalf("GATE: the operator's report: %d %v", code, out)
	}
	r, ok, err := ed.LatestEstateDeploy(context.Background(), "dev", "hub")
	if err != nil || !ok || r.CommitSHA != sha || r.DeployID != row["deploy_id"] {
		t.Fatalf("GATE: the stored row: %+v %v %v", r, ok, err)
	}
	code, again := opCall(t, e, tid, http.MethodPost, "/v1/operator/deploys", "good", body)
	if row2, _ := again["deploy"].(map[string]any); code != http.StatusOK || again["stored"] != false || row2["deploy_id"] != row["deploy_id"] {
		t.Fatalf("the same run's re-post: %d %v, want stored=false and deploy_id %v", code, again, row["deploy_id"])
	}
}

// TestDeployReconcileProbe (T027 GATE): what the env serves and a ci row
// already names is matched and nothing is written; a served sha no row
// names is pending first and, once it stayed unrecorded for the grace,
// filled in once as deployed_by hub-reconcile, workflow_run_id reconcile.
// RED CONTROL: the ci row is never overwritten (its re-post still returns
// it), a second tick writes nothing more, and a probe failure fills nothing.
func TestDeployReconcileProbe(t *testing.T) {
	e, tid, ed, clk := deployEnv(t)
	ctx := context.Background()
	shaCI, shaMissed := randSHA(t), randSHA(t)
	ciBody := map[string]any{"env": "dev", "component": "hub", "version": "v3.2.5", "commit_sha": shaCI, "workflow_run_id": "7"}
	code, out := opCall(t, e, tid, http.MethodPost, "/v1/operator/deploys", "good", ciBody)
	ciRow, _ := out["deploy"].(map[string]any)
	if code != http.StatusOK {
		t.Fatalf("CONTROL: the ci report: %d %v", code, out)
	}
	served := map[string]hub.DeployServed{
		"https://api.dev.example/version": {Version: "3.2.5", Commit: shaCI},
		"https://hub.test/build.json":     {Version: "3.2.6", Commit: shaMissed},
	}
	var probeErr error
	r := e.srv.NewDeployReconciler()
	if r == nil {
		t.Fatal("no reconciler on a dev hub with a deploy store")
	}
	r.Probe = func(_ context.Context, url string) (hub.DeployServed, error) {
		if probeErr != nil {
			return hub.DeployServed{}, probeErr
		}
		s, ok := served[url]
		if !ok {
			t.Errorf("probed an unexpected url %q", url)
		}
		return s, nil
	}
	wuiLatest := func() (store.EstateDeploy, bool) {
		w, ok, err := ed.LatestEstateDeploy(ctx, "dev", "wui")
		if err != nil {
			t.Fatal(err)
		}
		return w, ok && w.CommitSHA == shaMissed
	}

	if res := r.Tick(ctx); res.Matched != 1 || res.Pending != 1 || res.Filled != 0 {
		t.Fatalf("first tick: %+v, want hub matched, wui pending", res)
	}
	clk.add(2 * time.Minute)
	if res := r.Tick(ctx); res.Pending != 1 || res.Filled != 0 {
		t.Fatalf("RED CONTROL: a tick inside the grace: %+v, want wui still pending", res)
	}
	if _, filled := wuiLatest(); filled {
		t.Fatal("RED CONTROL: filled in before the grace")
	}
	probeErr = errors.New("network down")
	clk.add(3 * time.Minute)
	if res := r.Tick(ctx); res.Errors != 2 || res.Filled != 0 {
		t.Fatalf("RED CONTROL: a failed probe: %+v, want 2 errors and nothing filled", res)
	}
	probeErr = nil
	if res := r.Tick(ctx); res.Filled != 1 || res.Matched != 1 {
		t.Fatalf("GATE: the tick after the grace: %+v, want the wui deploy filled", res)
	}
	w, filled := wuiLatest()
	if !filled || w.Source != "reconcile" || w.DeployedBy != "hub-reconcile" || w.WorkflowRunID != "reconcile" ||
		w.Version != "v3.2.6" || w.Status != "success" {
		t.Fatalf("GATE: the filled-in row: %+v", w)
	}
	clk.add(2 * time.Minute)
	if res := r.Tick(ctx); res.Filled != 0 || res.Matched != 2 {
		t.Fatalf("RED CONTROL: a second tick: %+v, want both matched and nothing written", res)
	}
	if h, ok, _ := ed.LatestEstateDeploy(ctx, "dev", "hub"); !ok || h.DeployID != ciRow["deploy_id"] || h.Source != "ci" {
		t.Fatalf("RED CONTROL: the ci row was overwritten: %+v", h)
	}
	if code, again := opCall(t, e, tid, http.MethodPost, "/v1/operator/deploys", "good", ciBody); code != http.StatusOK ||
		again["stored"] != false || again["deploy"].(map[string]any)["deploy_id"] != ciRow["deploy_id"] {
		t.Fatalf("RED CONTROL: the ci row is gone: %d %v", code, again)
	}
}

// TestDeployReconcileOff: a hub that records no env (lde) or whose store
// keeps no record runs no check. CONTROL: a dev hub does (the test above).
func TestDeployReconcileOff(t *testing.T) {
	if srv := newEnv(t, func(o *hub.Options) { o.Env = "lde" }).srv; srv.NewDeployReconciler() != nil {
		t.Error("an lde hub runs the reconcile check")
	}
	if srv := newEnv(t, func(o *hub.Options) { o.Env = "dev"; o.Store = store.NewMemory() }).srv; srv.NewDeployReconciler() != nil {
		t.Error("a store without the deploy record runs the reconcile check")
	}
}
