package store

import (
	"context"
	"crypto/rand"
	"math/big"
	"slices"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 143 T020 / T021: the Releases report over release_notes and
// estate_deploys, on both drivers.

// reportWindow is a random UTC day far from every other test's rows: both
// tables are estate-wide, so a shared Postgres sees the other tests' notes.
func reportWindow(t *testing.T) time.Time {
	t.Helper()
	n, err := rand.Int(rand.Reader, big.NewInt(300*365))
	if err != nil {
		t.Fatal(err)
	}
	return time.Date(2100, 1, 1, 0, 0, 0, 0, time.UTC).AddDate(0, 0, int(n.Int64()))
}

// seedDeploys writes deploys the way row 4's ingest will: memory directly,
// Postgres in the operator scope rdb 0202's write policy asks for.
func seedDeploys(t *testing.T, st Store, ds ...EstateDeploy) {
	t.Helper()
	switch s := st.(type) {
	case *Memory:
		memDeployMu.Lock()
		memDeploys[s] = append(memDeploys[s], ds...)
		memDeployMu.Unlock()
	case *Postgres:
		ctx := context.Background()
		err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
				return err
			}
			for _, d := range ds {
				if _, err := tx.Exec(ctx, `INSERT INTO estate_deploys (deploy_id, env, component, version, commit_sha, deployed_at, status, source)
					VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`, uuid4(), d.Env, d.Component, d.Version, d.CommitSHA, d.DeployedAt, d.Status, d.Source); err != nil {
					return err
				}
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatalf("no deploy seed for %T", st)
	}
}

// reportNote is a note of one kind and area at a time.
func reportNote(version, kind, area, subject string, at time.Time) ReleaseNote {
	n := noteOK(randSHA(), version, at)
	n.Kind, n.Area, n.Subject = kind, area, subject
	return n
}

func TestReportingReleasesDaily(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rr := st.(ReleaseReports)
			d0 := reportWindow(t)
			d1 := d0.AddDate(0, 0, 1)
			notes := []ReleaseNote{
				reportNote("v1.2.3", "feat", "wui, SPL-1", "feat(wui, SPL-1): one", d0.Add(1*time.Hour)),
				reportNote("v1.2.3", "fix", "api", "fix(api): two", d0.Add(2*time.Hour)),
				reportNote("", "fix", "csi-spl-wui", "fix(wui): three", d0.Add(23*time.Hour)),
				reportNote("v1.2.4", "docs", "doc", "docs(doc): four", d1.Add(5*time.Hour)),
				reportNote("v1.2.4", "feat", "orc", "feat(orc): outside", d1.AddDate(0, 0, 1)), // To is exclusive
			}
			if err := st.(ReleaseNotes).PutReleaseNotes(ctx, notes, d1); err != nil {
				t.Fatal(err)
			}
			f := ReleaseReportFilter{From: d0, To: d1.AddDate(0, 0, 1)}

			// With no deploy recorded (row 4 not landed) every day has an
			// empty deploys list, never nil and never an error.
			got, err := rr.ReleaseDaily(ctx, f)
			if err != nil {
				t.Fatal(err)
			}
			if got.TotalCommits != 4 || got.TotalVersions != 2 || len(got.Days) != 2 {
				t.Fatalf("daily: %+v", got)
			}
			if got.Days[0].Date != releaseDayOf(d1) || got.Days[1].Date != releaseDayOf(d0) {
				t.Fatalf("days not newest first: %s, %s", got.Days[0].Date, got.Days[1].Date)
			}
			day0 := got.Days[1]
			if day0.CommitsCount != 3 || day0.Kinds["fix"] != 2 || day0.Kinds["feat"] != 1 ||
				day0.Areas["wui"] != 2 || day0.Areas["api"] != 1 || day0.Deploys == nil || len(day0.Deploys) != 0 {
				t.Fatalf("day %s: %+v", day0.Date, day0)
			}

			seedDeploys(t, st,
				EstateDeploy{Env: "dev", Component: "hub", Version: "v1.2.3", CommitSHA: notes[1].SHA, DeployedAt: d0.Add(3 * time.Hour), Status: "success", Source: "ci"},
				EstateDeploy{Env: "prd", Component: "hub", Version: "v1.2.3", CommitSHA: notes[1].SHA, DeployedAt: d0.Add(4 * time.Hour), Status: "success", Source: "reconcile"},
				EstateDeploy{Env: "dev", Component: "wui", Version: "v1.2.4", CommitSHA: notes[3].SHA, DeployedAt: d1.AddDate(0, 0, 1), Status: "success", Source: "ci"},
			)
			got, err = rr.ReleaseDaily(ctx, f)
			if err != nil {
				t.Fatal(err)
			}
			dep := got.Days[1].Deploys
			if len(dep) != 2 || dep[0].Env != "prd" || dep[1].Env != "dev" || dep[0].Source != "reconcile" || dep[0].Version != "v1.2.3" {
				t.Fatalf("deploys of %s, want prd then dev: %+v", got.Days[1].Date, dep)
			}
			if len(got.Days[0].Deploys) != 0 {
				t.Fatalf("a deploy outside the window was joined: %+v", got.Days[0].Deploys)
			}

			// Filters: kind and area narrow the counts and the version total.
			f.Kinds, f.Areas = []string{"fix"}, []string{"wui"}
			got, err = rr.ReleaseDaily(ctx, f)
			if err != nil {
				t.Fatal(err)
			}
			if got.TotalCommits != 1 || got.TotalVersions != 0 || got.Days[len(got.Days)-1].Kinds["fix"] != 1 {
				t.Fatalf("kind+area filter: %+v", got)
			}
		})
	}
}

func TestReportingReleasesCommits(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rr := st.(ReleaseReports)
			d0 := reportWindow(t)
			a := reportNote("v3.1.0", "feat", "wui", "feat(wui): the Releases tab", d0.Add(1*time.Hour))
			b := reportNote("v3.1.1", "fix", "api", "fix(api): the daily route", d0.Add(2*time.Hour))
			b.TechHow = "Groups by the UTC day of committed_at"
			c := reportNote("", "docs", "doc", "docs(doc): a page", d0.Add(3*time.Hour))
			if err := st.(ReleaseNotes).PutReleaseNotes(ctx, []ReleaseNote{a, b, c}, d0); err != nil {
				t.Fatal(err)
			}
			f := ReleaseReportFilter{From: d0, To: d0.AddDate(0, 0, 1)}
			shas := func(f ReleaseReportFilter) ([]string, int) {
				t.Helper()
				ns, total, err := rr.ReleaseCommits(ctx, f)
				if err != nil {
					t.Fatal(err)
				}
				out := []string{}
				for _, n := range ns {
					out = append(out, n.SHA)
				}
				return out, total
			}
			if got, total := shas(f); total != 3 || !slices.Equal(got, []string{c.SHA, b.SHA, a.SHA}) {
				t.Fatalf("newest first: %v (total %d)", got, total)
			}
			for _, q := range []struct{ search, want string }{
				{"releases TAB", a.SHA}, // subject, any case
				{b.SHA[:9], b.SHA},      // sha prefix
				{"v3.1.1", b.SHA},       // version
				{"utc day of", b.SHA},   // a Tech-* trailer
				{"no such words", ""},   // nothing
			} {
				f.Search = q.search
				got, total := shas(f)
				if q.want == "" && total != 0 || q.want != "" && (total != 1 || got[0] != q.want) {
					t.Errorf("search %q: %v (total %d), want %s", q.search, got, total, q.want)
				}
			}
			f.Search, f.Limit, f.Offset = "", 1, 1
			if got, total := shas(f); total != 3 || !slices.Equal(got, []string{b.SHA}) {
				t.Fatalf("page 2 of 1: %v (total %d)", got, total)
			}
			f.Limit = ReleaseReportLimitMax + 1
			if _, _, err := rr.ReleaseCommits(ctx, f); err == nil {
				t.Fatal("limit over the max was taken")
			}
		})
	}
}

func TestReleaseArea(t *testing.T) {
	for in, want := range map[string]string{"wui, SPL-2782": "wui", "csi-spl-wui": "wui", " API ": "api", "": "", "r16-01-wui-ts": "r16-01-wui-ts"} {
		if got := ReleaseArea(in); got != want {
			t.Errorf("ReleaseArea(%q) = %q, want %q", in, got, want)
		}
	}
}
