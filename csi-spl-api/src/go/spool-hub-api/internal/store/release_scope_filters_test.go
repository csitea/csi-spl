package store

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// R7 W2 of SPL-5108: each test fails when its one workspace filter is removed.

func releaseScopeNote(t *testing.T, s Store, tenant, version string, at time.Time) {
	t.Helper()
	if err := s.(ReleaseNotes).PutReleaseNotes(context.Background(), tenant, relRepo, []ReleaseNote{noteOK(randSHA(), version, at)}, at); err != nil {
		t.Fatal(err)
	}
}

// Another workspace's release neither adds a Flow line (flowReleasesSQL) nor
// counts on the badge (flowEventCountsSQL). CONTROL: that workspace reads it.
func TestFlowReleasesStayInTheirWorkspace(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			a, b := newTenant(t, s), newTenant(t, s)
			base := time.Date(2093, 7, 8, 10, 0, 0, 0, time.UTC)
			now := base.Add(26 * time.Hour)
			releaseScopeNote(t, s, a, "v1.0.0", base.Add(time.Hour))
			releaseScopeNote(t, s, b, "v2.0.0", base.Add(25*time.Hour))
			for tenant, want := range map[string]string{a: "v1.0.0", b: "v2.0.0"} {
				f, err := s.(FlowFolder).FlowFoldRead(ctx, FlowQuery{Tenant: tenant, Member: "HUM-1", Limit: 30, Now: now, Kind: FlowRelease})
				if err != nil || len(f.Lines) != 1 || f.Lines[0].VersionTo != want {
					t.Fatalf("lines of %s: %+v %v, want only %s", tenant, f.Lines, err, want)
				}
				if err := s.(ReadMarks).SaveReadMarks(ctx, tenant, "HUM-1", map[string]ReadMark{FlowSeenKey: {At: base}}, base); err != nil {
					t.Fatal(err)
				}
				p, err := s.(FlowEvents).FlowRead(ctx, FlowQuery{Tenant: tenant, Member: "HUM-1", Now: now})
				if err != nil || p.Counts.Release != 1 {
					t.Fatalf("badge of %s: %d %v, want 1", tenant, p.Counts.Release, err)
				}
			}
		})
	}
}

func scopeDeploy(tenant, repo, sha, run string) EstateDeploy {
	return EstateDeploy{TenantID: tenant, RepoSlug: repo, Env: "dev", Component: "hub", Version: "v1.0.0", CommitSHA: sha,
		Status: "success", WorkflowRunID: run, DeployedBy: "ci"}
}

func scopePostgres(t *testing.T, s Store) *Postgres {
	t.Helper()
	pg, ok := s.(*Postgres)
	if !ok {
		t.Skip("estate deploys are Postgres only")
	}
	return pg
}

// The daily report joins only this workspace's deploys. CONTROL: the other
// workspace reads the row this one cannot.
func TestReleaseDailyDeploysStayInTheirWorkspace(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			pg, ctx := scopePostgres(t, s), context.Background()
			a, b := newTenant(t, s), newTenant(t, s)
			now := time.Now().UTC()
			shas := map[string]string{a: randSHA(), b: randSHA()}
			for tenant, sha := range shas {
				if _, _, err := pg.PutEstateDeploy(ctx, scopeDeploy(tenant, relRepo, sha, "")); err != nil {
					t.Fatal(err)
				}
			}
			for tenant, sha := range shas {
				daily, err := pg.ReleaseDaily(ctx, ReleaseReportFilter{Tenant: tenant, From: now.Add(-time.Hour), To: now.Add(time.Hour)})
				if err != nil {
					t.Fatal(err)
				}
				var got []string
				for _, d := range daily.Days {
					for _, dp := range d.Deploys {
						got = append(got, dp.CommitSHA)
					}
				}
				if len(got) != 1 || got[0] != sha {
					t.Fatalf("deploys of %s: %v, want only %s", tenant, got, sha)
				}
			}
		})
	}
}

// One run reporting the same deploy for another workspace or repo is a new
// row. CONTROL: the same workspace and repo again is the earlier row.
func TestEstateDeployDedupeStaysInItsRepo(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			pg, ctx := scopePostgres(t, s), context.Background()
			a, b := newTenant(t, s), newTenant(t, s)
			sha, run := randSHA(), "run-"+uuid4()
			for _, c := range []struct {
				why, tenant, repo string
				want              bool
			}{{"first", a, relRepo, true}, {"other workspace", b, relRepo, true}, {"other repo", a, otherRepo, true}, {"CONTROL again", a, relRepo, false}} {
				if _, stored, err := pg.PutEstateDeploy(ctx, scopeDeploy(c.tenant, c.repo, sha, run)); err != nil || stored != c.want {
					t.Fatalf("%s: stored %v %v, want %v", c.why, stored, err, c.want)
				}
			}
		})
	}
}

func seedPrimaryRepo(t *testing.T, pg *Postgres, tenant, repo string) {
	t.Helper()
	ctx := context.Background()
	err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO software_projects (tenant_id, project_slug, name, is_default) VALUES ($1, 'web-shop', 'Web shop', true)`, tenant); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO workspace_repos (tenant_id, repo_slug, project_slug, repo_web_url, is_primary)
			VALUES ($1, $2, 'web-shop', 'https://example.com/shop', true)`, tenant, repo)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
}

// The reconcile compares a sha with this workspace's newest deploy only.
// CONTROL: the same workspace and sha again stores nothing.
func TestFillEstateDeployStaysInItsWorkspace(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			pg, ctx := scopePostgres(t, s), context.Background()
			a, b := newTenant(t, s), newTenant(t, s)
			seedPrimaryRepo(t, pg, a, relRepo)
			seedPrimaryRepo(t, pg, b, otherRepo)
			sha := randSHA()
			for _, c := range []struct {
				why, tenant string
				want        bool
			}{{"first", a, true}, {"other workspace, same sha", b, true}, {"CONTROL again", a, false}} {
				if stored, err := pg.FillEstateDeploy(ctx, c.tenant, "dev", "hub", "v1.0.0", sha); err != nil || stored != c.want {
					t.Fatalf("%s: stored %v %v, want %v", c.why, stored, err, c.want)
				}
			}
		})
	}
}
