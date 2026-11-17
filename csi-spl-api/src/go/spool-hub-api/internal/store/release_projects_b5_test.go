package store

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 143 releases-projects.md row B-5 (SPL-5772), the store half: the repo
// flags the hub reads (IsPrimary, NotesPublic), the repo parameter on the
// three release note reads, the Flow's primary-only release fold and the
// operator's project write.

// b5Seed registers repo under project of tenant on either driver, with its
// primary and notes_public flags; the memory store also learns the primary
// for WorkspaceRepo.
func b5Seed(t *testing.T, st Store, tenant, project, repo string, primary, public bool) {
	t.Helper()
	switch s := st.(type) {
	case *Memory:
		s.SeedProjectRepo(tenant, project, "Name "+project, true, ReleaseProjectRepo{Slug: repo, NotesPublic: public}, primary)
		s.SeedWorkspaceRepo(tenant, repo, primary)
	case *Postgres:
		ctx := context.Background()
		err := s.asOperator(ctx, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `INSERT INTO software_projects (tenant_id, project_slug, name, is_default)
				VALUES ($1, $2, 'Name ' || $2, true) ON CONFLICT DO NOTHING`, tenant, project); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `INSERT INTO workspace_repos (tenant_id, repo_slug, project_slug, repo_web_url, is_primary, notes_public)
				VALUES ($1, $2, $3, 'https://example.com/' || $2, $4, $5)`, tenant, repo, project, primary, public)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatalf("no project seed for %T", st)
	}
}

// The projects answer carries each repo's primary and notes_public flags.
func TestReleaseProjectsRepoFlags(t *testing.T) {
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tenant, pub, priv := newTenant(t, st), b4Repo(), b4Repo()
			b5Seed(t, st, tenant, "web-shop", pub, true, true)
			b5Seed(t, st, tenant, "web-shop", priv, false, false)
			got, err := st.(ReleaseReports).ReleaseProjects(context.Background(), tenant)
			if err != nil || len(got) != 1 || len(got[0].Repos) != 2 {
				t.Fatalf("projects: %+v %v", got, err)
			}
			if r := got[0].Repos[0]; r.Slug != pub || !r.IsPrimary || !r.NotesPublic {
				t.Fatalf("primary repo: %+v, want primary and public", r)
			}
			if r := got[0].Repos[1]; r.Slug != priv || r.IsPrimary || r.NotesPublic {
				t.Fatalf("second repo: %+v, want neither flag", r)
			}
		})
	}
}

// Each read keeps the rows of its repo: the same sha and the same version in
// two repos of one workspace stay apart, and the seq counts that repo only.
// CONTROL: repo "" reads both, so the sha is ambiguous.
func TestReleaseNotesRepoParam(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rn := st.(ReleaseNotes)
			tenant, a, b := newTenant(t, st), b4Repo(), b4Repo()
			at := time.Date(2094, 3, 4, 10, 0, 0, 0, time.UTC)
			shared := randSHA()
			b4Put(t, st, tenant, a, noteOK(shared, "v1.0.0", at), noteOK(randSHA(), "v1.1.0", at.Add(time.Hour)))
			nb := noteOK(shared, "v1.0.0", at)
			nb.Subject = "fix(api): the b repo's own text"
			b4Put(t, st, tenant, b, nb)
			if _, err := rn.ReleaseNote(ctx, tenant, "", shared); !errors.Is(err, ErrAmbiguousRef) {
				t.Fatalf("every repo: %v, want ErrAmbiguousRef", err)
			}
			if n, err := rn.ReleaseNote(ctx, tenant, b, shared[:9]); err != nil || n.RepoSlug != b || n.Subject != nb.Subject {
				t.Fatalf("repo b's note: %+v %v", n, err)
			}
			if _, err := rn.ReleaseNote(ctx, tenant, b4Repo(), shared); !errors.Is(err, ErrNotFound) {
				t.Fatalf("a repo with no rows: %v, want ErrNotFound", err)
			}
			list, err := rn.ListReleaseNotes(ctx, tenant, a, "", 10)
			if err != nil || len(list) != 2 || slices.ContainsFunc(list, func(n ReleaseNote) bool { return n.RepoSlug != a }) {
				t.Fatalf("repo a's list: %+v %v", list, err)
			}
			if list[0].Version != "v1.1.0" || list[0].Seq != 2 || list[1].Seq != 1 {
				t.Fatalf("repo a's order and seq: %s/%d %s/%d", list[0].Version, list[0].Seq, list[1].Version, list[1].Seq)
			}
			if all, err := rn.ListReleaseNotes(ctx, tenant, "", "", 10); err != nil || len(all) != 3 {
				t.Fatalf("every repo's list: %d rows %v, want 3", len(all), err)
			}
			of, err := rn.ReleaseNotesOfVersion(ctx, tenant, b, "v1.0.0")
			if err != nil || len(of) != 1 || of[0].RepoSlug != b || of[0].Seq != 1 {
				t.Fatalf("repo b's v1.0.0: %+v %v", of, err)
			}
			if of, err := rn.ReleaseNotesOfVersion(ctx, tenant, "", "v1.0.0"); err != nil || len(of) != 2 {
				t.Fatalf("every repo's v1.0.0: %d rows %v, want 2", len(of), err)
			}
		})
	}
}

// The Flow folds the primary repo's releases only, lines and badge. CONTROL:
// a workspace with no primary repo still folds every row (as before B-5).
func TestFlowReleasesPrimaryRepoOnly(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tenant, prim, side := newTenant(t, st), b4Repo(), b4Repo()
			b5Seed(t, st, tenant, "web-shop", prim, true, true)
			b5Seed(t, st, tenant, "web-shop", side, false, true)
			base := time.Date(2094, 5, 6, 10, 0, 0, 0, time.UTC)
			now := base.Add(50 * time.Hour)
			b4Put(t, st, tenant, prim, noteOK(randSHA(), "v1.0.0", base.Add(time.Hour)))
			b4Put(t, st, tenant, side, noteOK(randSHA(), "v9.0.0", base.Add(26*time.Hour)))
			f, err := st.(FlowFolder).FlowFoldRead(ctx, FlowQuery{Tenant: tenant, Member: "HUM-1", Limit: 30, Now: now, Kind: FlowRelease})
			if err != nil || len(f.Lines) != 1 || f.Lines[0].VersionTo != "v1.0.0" {
				t.Fatalf("lines: %+v %v, want only the primary repo's v1.0.0", f.Lines, err)
			}
			if err := st.(ReadMarks).SaveReadMarks(ctx, tenant, "HUM-1", map[string]ReadMark{FlowSeenKey: {At: base}}, base); err != nil {
				t.Fatal(err)
			}
			if p, err := st.(FlowEvents).FlowRead(ctx, FlowQuery{Tenant: tenant, Member: "HUM-1", Now: now}); err != nil || p.Counts.Release != 1 {
				t.Fatalf("badge: %d %v, want 1 (the side repo's day is not counted)", p.Counts.Release, err)
			}
			bare := newTenant(t, st)
			b4Put(t, st, bare, b4Repo(), noteOK(randSHA(), "v1.0.0", base.Add(time.Hour)))
			b4Put(t, st, bare, b4Repo(), noteOK(randSHA(), "v9.0.0", base.Add(26*time.Hour)))
			if f, err := st.(FlowFolder).FlowFoldRead(ctx, FlowQuery{Tenant: bare, Member: "HUM-1", Limit: 30, Now: now, Kind: FlowRelease}); err != nil || len(f.Lines) != 2 {
				t.Fatalf("no primary: %+v %v, want both lines", f.Lines, err)
			}
		})
	}
}

// The operator's project write: the first project is the default whatever
// the flag says, a false never moves the default away, a true takes it, a
// re-put renames. A bad slug or name is refused before the write.
func TestPutSoftwareProject(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			sp := st.(SoftwareProjects)
			tenant := newTenant(t, st)
			for _, c := range []struct {
				slug, name string
				flag, want bool
			}{
				{"web-shop", "Web shop", false, true},
				{"blog", "Blog", false, false},
				{"web-shop", "Web shop", false, true},
				{"blog", "The blog", true, true},
			} {
				if def, err := sp.PutSoftwareProject(ctx, tenant, c.slug, c.name, c.flag); err != nil || def != c.want {
					t.Fatalf("put %s default=%v: %v %v, want default %v", c.slug, c.flag, def, err, c.want)
				}
			}
			b5Seed(t, st, tenant, "web-shop", b4Repo(), true, false)
			b5Seed(t, st, tenant, "blog", b4Repo(), false, false)
			got, err := st.(ReleaseReports).ReleaseProjects(ctx, tenant)
			if err != nil || len(got) != 2 || got[0].Slug != "blog" || got[0].Name != "The blog" || !got[0].IsDefault || got[1].IsDefault {
				t.Fatalf("projects after the puts: %+v %v, want blog the one default", got, err)
			}
			for _, bad := range [][2]string{{"Web", "x"}, {"-x", "x"}, {"ok", ""}, {"ok", "two\nlines"}} {
				if _, err := sp.PutSoftwareProject(ctx, tenant, bad[0], bad[1], false); err == nil {
					t.Fatalf("put %q %q: accepted", bad[0], bad[1])
				}
			}
			if _, err := sp.PutSoftwareProject(ctx, "", "ok", "x", false); !errors.Is(err, ErrNoTenant) {
				t.Fatalf("no tenant: %v", err)
			}
		})
	}
}
