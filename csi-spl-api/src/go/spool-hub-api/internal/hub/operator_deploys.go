package hub

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The deploy record (spec 143 section 2.3.2, T025 + T027, SPL-2788). Owner
// HUM-10 poll 3 = C (msg a8bfcdd0): the deploy step reports each deploy, plus
// a hub check every 2 minutes fills in a missed one, marked as filled in.
//
//	POST /v1/operator/deploys   {env, component, version, commit_sha, status?,
//	                             workflow_run_id?, deployed_by?} -> the row
//
// Operator auth only (operatorAuth: the env's project SA id token), as every
// /v1/operator write; the workflows call it through do_spl_deploy_record.
// Each hub records its OWN env: its operator allow-list holds only that env's
// SA, and the reconcile check reads that env's served endpoints.

const (
	// deployReconcileEvery is how often the check reads what the env serves.
	deployReconcileEvery = 2 * time.Minute
	// deployReconcileGrace is how long a served sha stays unrecorded before
	// the check fills it in: the deploy step reports after the roll and its
	// verify, so a fresh deploy is not "missed" while that step still runs.
	deployReconcileGrace = 4 * time.Minute
	deployProbeTimeout   = 10 * time.Second
	deployProbeBodyMax   = 64 << 10
	operatorDeployMax    = 4 << 10
)

type operatorDeployBody struct {
	Env           string `json:"env"`
	Component     string `json:"component"`
	Version       string `json:"version"`
	CommitSHA     string `json:"commit_sha"`
	Status        string `json:"status"`
	WorkflowRunID string `json:"workflow_run_id"`
	DeployedBy    string `json:"deployed_by"`
}

func (s *Server) routeOperatorDeploys(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/operator/deploys", s.handleOperatorDeploy)
}

// ownDeployEnv is the env this hub records, "" on lde or an unset env.
func (s *Server) ownDeployEnv() string {
	if slices.Contains(store.EstateDeployEnvs, s.o.Env) {
		return s.o.Env
	}
	return ""
}

// deployVersion writes a served or reported version as rdb 0202 keeps it:
// /version and build.json show it plain (3.2.5), the row carries v3.2.5.
func deployVersion(v string) string {
	v = strings.TrimSpace(v)
	if v != "" && !strings.HasPrefix(v, "v") {
		return "v" + v
	}
	return v
}

func (s *Server) handleOperatorDeploy(w http.ResponseWriter, r *http.Request) {
	by, ok := s.operatorAuth(w, r)
	if !ok {
		return
	}
	ed, ok := s.o.Store.(store.EstateDeploys)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "deploys_off", "this hub's store keeps no deploy record")
		return
	}
	var body operatorDeployBody
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, operatorDeployMax))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {env, component, version, commit_sha, status?, workflow_run_id?, deployed_by?}: "+err.Error())
		return
	}
	d := store.EstateDeploy{Env: strings.TrimSpace(body.Env), Component: strings.TrimSpace(body.Component),
		Version: deployVersion(body.Version), CommitSHA: strings.TrimSpace(body.CommitSHA),
		Status: strings.TrimSpace(body.Status), WorkflowRunID: strings.TrimSpace(body.WorkflowRunID),
		DeployedBy: strings.TrimSpace(body.DeployedBy)}
	if d.Status == "" {
		d.Status = "success"
	}
	if d.DeployedBy == "" {
		d.DeployedBy = by
	}
	if own := s.ownDeployEnv(); own != "" && d.Env != own {
		writeErr(w, http.StatusBadRequest, "wrong_env", "this hub records "+own+" deploys only")
		return
	}
	if why := store.CheckEstateDeploy(d); why != "" {
		writeErr(w, http.StatusBadRequest, "bad_deploy", why)
		return
	}
	row, stored, err := ed.PutEstateDeploy(r.Context(), d)
	if err != nil {
		s.o.Log.Error().Err(err).Str("env", d.Env).Str("component", d.Component).Msg("deploy.record_failed")
		writeErr(w, http.StatusServiceUnavailable, "internal", "deploy not recorded")
		return
	}
	s.o.Log.Info().Str("env", row.Env).Str("component", row.Component).Str("version", row.Version).
		Str("sha", row.CommitSHA).Str("status", row.Status).Bool("stored", stored).Msg("deploy.recorded")
	writeJSON(w, http.StatusOK, map[string]any{"deploy": row, "stored": stored})
}

// DeployServed is what one probe read: the version and commit an env serves.
type DeployServed struct {
	Version string
	Commit  string
}

// DeployProbe reads one served endpoint (the hub's /version, the WUI's
// build.json).
type DeployProbe func(ctx context.Context, url string) (DeployServed, error)

// DeployReconcileResult counts one pass of the check.
type DeployReconcileResult struct {
	Matched, Pending, Filled, Skipped, Errors int
}

type deployProbeTarget struct{ component, url string }

type deploySeen struct {
	sha   string
	since time.Time
}

// DeployReconciler is the 2-minute check. One per hub process; every
// instance runs one, and the store's lock writes a missed deploy once.
type DeployReconciler struct {
	s     *Server
	Probe DeployProbe
	Grace time.Duration
	seen  map[string]deploySeen
}

// NewDeployReconciler builds the check with the HTTP probe and the default
// grace; nil when this hub records no env or its store keeps no record.
func (s *Server) NewDeployReconciler() *DeployReconciler {
	if s.ownDeployEnv() == "" {
		return nil
	}
	if _, ok := s.o.Store.(store.EstateDeploys); !ok {
		return nil
	}
	c := &http.Client{Timeout: deployProbeTimeout}
	return &DeployReconciler{s: s, Grace: deployReconcileGrace, seen: map[string]deploySeen{},
		Probe: func(ctx context.Context, url string) (DeployServed, error) { return probeDeploy(ctx, c, url) }}
}

// deployProbeTargets are this env's served endpoints, from config only (no
// literal host): the hub at its operator audience (cnf {api_fqdn}, the
// public URL Cloud Run routes to the serving revision, so an old instance
// still draining reads the new version), the WUI at the tenant host
// pattern's apex (cnf env.dns.fqdn).
func (s *Server) deployProbeTargets() []deployProbeTarget {
	var ts []deployProbeTarget
	if a := strings.TrimRight(strings.TrimSpace(s.o.OperatorAudience), "/"); strings.HasPrefix(a, "https://") {
		ts = append(ts, deployProbeTarget{"hub", a + "/version"})
	}
	if apex, ok := strings.CutPrefix(s.o.TenantHostPattern, "{tenant}."); ok && apex != "" {
		ts = append(ts, deployProbeTarget{"wui", "https://" + apex + "/build.json"})
	}
	return ts
}

func probeDeploy(ctx context.Context, c *http.Client, url string) (DeployServed, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return DeployServed{}, err
	}
	req.Header.Set("Cache-Control", "no-cache")
	resp, err := c.Do(req)
	if err != nil {
		return DeployServed{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return DeployServed{}, fmt.Errorf("%s answered HTTP %d", url, resp.StatusCode)
	}
	var v struct {
		Version   string `json:"version"`
		Commit    string `json:"commit"`
		CommitSHA string `json:"commit_sha"`
		SHA       string `json:"sha"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, deployProbeBodyMax)).Decode(&v); err != nil {
		return DeployServed{}, fmt.Errorf("%s: %w", url, err)
	}
	sha := v.Commit
	for _, alt := range []string{v.CommitSHA, v.SHA} {
		if sha == "" {
			sha = alt
		}
	}
	return DeployServed{Version: v.Version, Commit: sha}, nil
}

// Tick is one pass: per target, read what is served; a sha the newest
// successful row already names is matched; an unrecorded one is pending
// until it has stayed unrecorded for Grace, then filled in as a reconcile
// row. A row the workflow wrote is never touched.
func (r *DeployReconciler) Tick(ctx context.Context) DeployReconcileResult {
	var res DeployReconcileResult
	env := r.s.ownDeployEnv()
	ed, ok := r.s.o.Store.(store.EstateDeploys)
	if env == "" || !ok {
		return res
	}
	now := r.s.o.Now()
	for _, t := range r.s.deployProbeTargets() {
		r.tickOne(ctx, ed, env, t, now, &res)
	}
	return res
}

func (r *DeployReconciler) tickOne(ctx context.Context, ed store.EstateDeploys, env string, t deployProbeTarget, now time.Time, res *DeployReconcileResult) {
	log := r.s.o.Log.With().Str("env", env).Str("component", t.component).Logger()
	served, err := r.Probe(ctx, t.url)
	if err != nil {
		res.Errors++
		log.Warn().Err(err).Msg("deploy.reconcile_probe_failed")
		return
	}
	served.Version = deployVersion(served.Version)
	d := store.EstateDeploy{Env: env, Component: t.component, Version: served.Version, CommitSHA: served.Commit, Status: "success"}
	if why := store.CheckEstateDeploy(d); why != "" {
		res.Skipped++
		log.Warn().Str("version", served.Version).Str("sha", served.Commit).Str("why", why).Msg("deploy.reconcile_unreadable")
		return
	}
	latest, ok, err := ed.LatestEstateDeploy(ctx, env, t.component)
	if err != nil {
		res.Errors++
		log.Error().Err(err).Msg("deploy.reconcile_read_failed")
		return
	}
	if ok && latest.CommitSHA == served.Commit {
		delete(r.seen, t.component)
		res.Matched++
		return
	}
	p, seen := r.seen[t.component]
	if !seen || p.sha != served.Commit {
		r.seen[t.component] = deploySeen{sha: served.Commit, since: now}
		res.Pending++
		return
	}
	if now.Sub(p.since) < r.Grace {
		res.Pending++
		return
	}
	stored, err := ed.FillEstateDeploy(ctx, env, t.component, served.Version, served.Commit)
	if err != nil {
		res.Errors++
		log.Error().Err(err).Msg("deploy.reconcile_fill_failed")
		return
	}
	delete(r.seen, t.component)
	if stored {
		res.Filled++
		log.Warn().Str("version", served.Version).Str("sha", served.Commit).Msg("deploy.reconcile_filled")
		return
	}
	res.Matched++
}

// RunDeployReconcile runs the check every deployReconcileEvery until ctx
// ends; it returns at once on a hub that records no env.
func (s *Server) RunDeployReconcile(ctx context.Context) {
	r := s.NewDeployReconciler()
	if r == nil {
		return
	}
	t := time.NewTicker(deployReconcileEvery)
	defer t.Stop()
	for {
		r.Tick(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}
