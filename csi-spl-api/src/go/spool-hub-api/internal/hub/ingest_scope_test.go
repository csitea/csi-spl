package hub_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 143 releases-projects.md row B-2 (SPL-5108), spec 171 Lane 2: where an
// ingest or a deploy record lands, and the workspace a reader sees.

// registerRepo registers repo for tid, as its primary when primary, the way
// the memory store's seam and rdb 0266's operator writes each allow.
func registerRepo(t *testing.T, e *env, tid, repo string, primary bool) {
	t.Helper()
	switch s := e.st.(type) {
	case *store.Memory:
		s.SeedWorkspaceRepo(tid, repo, primary)
	case *store.Postgres:
		ctx := context.Background()
		err := pgx.BeginFunc(ctx, s.Pool(), func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `INSERT INTO software_projects (tenant_id, project_slug, name, is_default)
				VALUES ($1, 'web-shop', 'Web shop', true) ON CONFLICT DO NOTHING`, tid); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `INSERT INTO workspace_repos (tenant_id, repo_slug, project_slug, repo_web_url, is_primary)
				VALUES ($1, $2, 'web-shop', 'https://example.com/repo', $3)`, tid, repo, primary)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatalf("no repo seam on %T", e.st)
	}
}

// repoOf is a per-tenant slug: a slug is unique across workspaces (rdb 0266).
func repoOf(tid, name string) string { return "csitea/" + strings.ToLower(tid) + "-" + name }

// presetTenant reserves a tenant id before the hub exists, so it can be the
// hub's operator workspace.
func presetTenant() string {
	b := make([]byte, 4)
	rand.Read(b) //nolint:errcheck
	return "t" + hex.EncodeToString(b)
}

func createTenant(t *testing.T, e *env, id string) {
	t.Helper()
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: id, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
}

// operatorInForce skips a test whose outcome depends on which workspace is the
// operator one when the shared test database flagged another (rdb 0116).
func operatorInForce(t *testing.T, e *env, want string) {
	t.Helper()
	f, ok := e.st.(store.OperatorFlag)
	if !ok {
		return
	}
	if id, err := f.OperatorTenant(context.Background()); err != nil || (id != "" && id != want) {
		t.Skipf("the test database flags %q as the operator workspace (%v)", id, err)
	}
}

func notesIn(t *testing.T, e *env, tid string) []store.ReleaseNote {
	t.Helper()
	rows, err := e.st.(store.ReleaseNotes).ListReleaseNotes(context.Background(), tid, "", 50)
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

// Every way of naming the workspace and the repo, and each refusal, which
// stores nothing.
func TestIngestScope(t *testing.T) {
	op := presetTenant()
	e, tid, _ := releaseEnv(t, func(o *hub.Options) { o.OperatorTenant = op })
	createTenant(t, e, op)
	operatorInForce(t, e, op)
	registerRepo(t, e, op, repoOf(op, "main"), true)
	other, _ := e.tenant()
	registerRepo(t, e, other, repoOf(other, "main"), true)
	registerRepo(t, e, other, repoOf(other, "second"), false)
	bare, _ := e.tenant()
	suspended, _ := e.tenant()
	registerRepo(t, e, suspended, repoOf(suspended, "main"), true)
	if err := e.st.(store.OperatorWorkspaces).SetWorkspaceState(context.Background(), suspended, true, false, time.Now()); err != nil {
		t.Fatal(err)
	}
	row := func(c string) []map[string]any {
		return []map[string]any{releaseRow(releaseSHA(c), "v7.4.1", releaseFullMsg)}
	}
	post := func(host, query string, body map[string]any) (int, map[string]any) {
		t.Helper()
		return opCall(t, e, host, http.MethodPost, "/v1/operator/release-notes"+query, "good", body)
	}
	for _, c := range []struct {
		name, host, query string
		body              map[string]any
		tenant, repo      string
	}{
		{"the host names it", tid, "", map[string]any{"notes": row("a")}, tid, ""},
		{"api host, the operator workspace", "api", "", map[string]any{"notes": row("b")}, op, repoOf(op, "main")},
		{"the body names it", "api", "", map[string]any{"notes": row("c"), "tenant": other}, other, repoOf(other, "main")},
		{"?tenant= names it", "api", "?tenant=" + other, map[string]any{"notes": row("d")}, other, repoOf(other, "main")},
		{"a named repo", "api", "", map[string]any{"notes": row("e"), "tenant": other, "repo_slug": repoOf(other, "second")}, other, repoOf(other, "second")},
	} {
		if code, out := post(c.host, c.query, c.body); code != http.StatusOK || out["stored"] != float64(1) {
			t.Fatalf("%s: %d %v", c.name, code, out)
		}
		found := false
		for _, n := range notesIn(t, e, c.tenant) {
			found = found || (n.SHA == c.body["notes"].([]map[string]any)[0]["sha"] && (c.repo == "" || n.RepoSlug == c.repo))
		}
		if !found {
			t.Errorf("%s: the row is not in %s repo %q", c.name, c.tenant, c.repo)
		}
	}
	for _, c := range []struct {
		name, host, tenant, repo, code string
		want                           int
	}{
		{"unknown workspace", "api", "tnosuch00", "", "unknown_tenant", http.StatusNotFound},
		{"suspended", "api", suspended, "", "workspace_suspended", http.StatusForbidden},
		{"no primary repo", "api", bare, "", "repo_not_registered", http.StatusConflict},
		{"another workspace's repo", "api", other, repoOf(op, "main"), "repo_not_registered", http.StatusConflict},
	} {
		body := map[string]any{"notes": row("f"), "tenant": c.tenant}
		if c.repo != "" {
			body["repo_slug"] = c.repo
		}
		code, out := post(c.host, "", body)
		if code != c.want || !strings.Contains(strings.ToLower(jsonText(out)), c.code) {
			t.Errorf("%s: %d %v, want %d %s", c.name, code, out, c.want, c.code)
		}
	}
	for _, id := range []string{bare, other} {
		for _, n := range notesIn(t, e, id) {
			if n.SHA == releaseSHA("f") {
				t.Errorf("a refused ingest stored a row in %s", id)
			}
		}
	}
}

func jsonText(m map[string]any) string {
	var sb strings.Builder
	for _, v := range m {
		if s, ok := v.(string); ok {
			sb.WriteString(s + " ")
		}
	}
	return sb.String()
}

// A hub with no operator workspace refuses an ingest and a record naming none.
func TestIngestScopeTenantRequired(t *testing.T) {
	e, _, _ := releaseEnv(t)
	if f, ok := e.st.(store.OperatorFlag); ok {
		if id, err := f.OperatorTenant(context.Background()); err != nil || id != "" {
			t.Skipf("the test database flags %q as the operator workspace (%v)", id, err)
		}
	}
	if code, out := opCall(t, e, "api", http.MethodPost, "/v1/operator/release-notes", "good", map[string]any{"notes": []any{}}); code != http.StatusBadRequest || !strings.Contains(jsonText(out), "tenant_required") {
		t.Fatalf("no workspace named: %d %v", code, out)
	}
}

// A second workspace reads none of the first's notes, and a version resolves
// before a sha, so any stored tag opens.
func TestReleaseNotesReadScopeAndTags(t *testing.T) {
	e, tid, hum := releaseEnv(t)
	other, _ := e.tenant()
	otherHum := seat(t, e, other, rbac.Developer)
	for _, r := range []map[string]any{
		releaseRow(releaseSHA("a"), "2026.11.05", releaseFullMsg),
		releaseRow(releaseSHA("b"), "abcdef1", releaseFullMsg),
		releaseRow(releaseSHA("c"), "v1.0.0-cool", releaseFullMsg),
	} {
		if code, out := ingest(t, e, tid, r); code != http.StatusOK || out["stored"] != float64(1) {
			t.Fatalf("ingest %v: %d %v", r["version"], code, out)
		}
	}
	for ref, display := range map[string]string{"2026.11.05": "2026.11.05", "abcdef1": "abcdef1", "v1.0.0-cool": "v1.0.0-cool"} {
		code, out := call(t, e, tid, http.MethodGet, "/v1/release-notes/"+ref, hum, nil)
		if code != http.StatusOK || out["version"] != ref || out["display"] != display {
			t.Errorf("GET %s: %d %v", ref, code, out)
		}
		if code, out := call(t, e, other, http.MethodGet, "/v1/release-notes/"+ref, otherHum, nil); code != http.StatusNotFound {
			t.Errorf("another workspace read %s: %d %v", ref, code, out)
		}
	}
	if note := noteOf(t, e, tid, hum, releaseSHA("a")[:7]); note["sha"] != releaseSHA("a") {
		t.Errorf("a sha still opens its note: %v", note)
	}
	code, out := call(t, e, other, http.MethodGet, "/v1/release-notes?limit=5", otherHum, nil)
	if v, _ := out["versions"].([]any); code != http.StatusOK || len(v) != 0 {
		t.Errorf("another workspace's list: %d %v", code, out)
	}
}

// The deploy record lands in the workspace it resolves, and the reconcile
// check skips, never fails, when it has none or no primary repo.
func TestDeployScopeAndReconcileSkips(t *testing.T) {
	e, tid, ed, _ := deployEnv(t)
	ctx := context.Background()
	operatorInForce(t, e, tid)
	sha := randSHA(t)
	body := map[string]any{"env": "dev", "component": "hub", "version": "3.2.5", "commit_sha": sha}
	code, out := opCall(t, e, "api", http.MethodPost, "/v1/operator/deploys", "good", body)
	if row, _ := out["deploy"].(map[string]any); code != http.StatusOK || row["tenant_id"] != tid || row["repo_slug"] != repoOf(tid, "main") {
		t.Fatalf("api host lands in the operator workspace: %d %v", code, out)
	}
	other, _ := e.tenant()
	if r, ok, err := ed.LatestEstateDeploy(ctx, other, "dev", "hub"); err != nil || ok {
		t.Fatalf("another workspace reads the deploy: %+v %v %v", r, ok, err)
	}
	if code, out := opCall(t, e, "api", http.MethodPost, "/v1/operator/deploys", "good", map[string]any{"env": "dev", "component": "hub", "version": "3.2.5", "commit_sha": sha, "tenant": other}); code != http.StatusConflict {
		t.Fatalf("no primary repo: %d %v", code, out)
	}
}

func TestDeployReconcileNoPrimaryRepo(t *testing.T) {
	op := presetTenant()
	e := rbacEnv(t, func(o *hub.Options) {
		o.Env, o.OperatorTenant, o.OperatorAudience = "dev", op, "https://api.dev.example"
	})
	createTenant(t, e, op)
	operatorInForce(t, e, op)
	if _, ok := e.st.(store.EstateDeploys); !ok {
		t.Skip("the deploy record needs Postgres (SPOOL_TEST_PG_DSN)")
	}
	r := e.srv.NewDeployReconciler()
	sha := strings.Repeat("a", 40)
	r.Probe = func(context.Context, string) (hub.DeployServed, error) {
		return hub.DeployServed{Version: "3.2.7", Commit: sha}, nil
	}
	r.Grace = 0
	ctx := context.Background()
	r.Tick(ctx)
	if res := r.Tick(ctx); res.Skipped != 2 || res.Filled != 0 || res.Errors != 0 {
		t.Fatalf("no primary repo: %+v, want Skipped 2", res)
	}
}

func TestDeployReconcileNoOperatorWorkspace(t *testing.T) {
	e, _, _, _ := deployEnvNoOperator(t)
	if f, ok := e.st.(store.OperatorFlag); ok {
		if id, err := f.OperatorTenant(context.Background()); err != nil || id != "" {
			t.Skipf("the test database flags %q as the operator workspace (%v)", id, err)
		}
	}
	r := e.srv.NewDeployReconciler()
	r.Probe = func(context.Context, string) (hub.DeployServed, error) {
		t.Fatal("no workspace to record for: the probe must not run")
		return hub.DeployServed{}, nil
	}
	if res := r.Tick(context.Background()); res.Skipped != 2 || res.Errors != 0 {
		t.Fatalf("no operator workspace: %+v, want Skipped 2", res)
	}
}
