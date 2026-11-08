package store

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Spec 143 releases-projects.md row B-2 (SPL-5108): release notes are read and
// written per workspace and repo, under any tag a repo uses.

const otherRepo = "csitea/other-repo"

// A workspace reads only its own notes. CONTROL: the other workspace reads the
// row this one cannot.
func TestReleaseNotesScopedByWorkspace(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			rn := s.(ReleaseNotes)
			a, b := newTenant(t, s), newTenant(t, s)
			now := time.Now().UTC().Truncate(time.Microsecond)
			sa, sb := randSHA(), randSHA()
			if err := rn.PutReleaseNotes(ctx, a, relRepo, []ReleaseNote{noteOK(sa, "v1.0.0", now)}, now); err != nil {
				t.Fatal(err)
			}
			if err := rn.PutReleaseNotes(ctx, b, otherRepo, []ReleaseNote{noteOK(sb, "v1.0.0", now)}, now); err != nil {
				t.Fatal(err)
			}
			list, err := rn.ListReleaseNotes(ctx, a, "", 10)
			if err != nil || len(list) != 1 || list[0].SHA != sa || list[0].TenantID != a || list[0].RepoSlug != relRepo || list[0].Seq != 1 {
				t.Fatalf("A's list: %+v %v", list, err)
			}
			if _, err := rn.ReleaseNote(ctx, a, sb); !errors.Is(err, ErrNotFound) {
				t.Fatalf("A read B's sha: %v", err)
			}
			if n, err := rn.ReleaseNote(ctx, b, sb); err != nil || n.RepoSlug != otherRepo {
				t.Fatalf("CONTROL, B reads its own: %+v %v", n, err)
			}
			rows, err := rn.ReleaseNotesOfVersion(ctx, a, "v1.0.0")
			if err != nil || len(rows) != 1 || rows[0].SHA != sa {
				t.Fatalf("A's version: %+v %v", rows, err)
			}
			if err := rn.PutReleaseNotes(ctx, "", relRepo, nil, now); !errors.Is(err, ErrNoTenant) {
				t.Fatalf("no tenant: %v", err)
			}
			if err := rn.PutReleaseNotes(ctx, a, "", nil, now); err == nil {
				t.Fatal("no repo was accepted")
			}
			rr := s.(ReleaseReports)
			f := ReleaseReportFilter{Tenant: a, From: now.Add(-time.Hour), To: now.Add(time.Hour)}
			if got, total, err := rr.ReleaseCommits(ctx, f); err != nil || total != 1 || got[0].SHA != sa {
				t.Fatalf("A's report: %+v %d %v", got, total, err)
			}
			if daily, err := rr.ReleaseDaily(ctx, f); err != nil || daily.TotalCommits != 1 {
				t.Fatalf("A's daily: %+v %v", daily, err)
			}
			if err := CheckReleaseReportFilter(ReleaseReportFilter{From: now, To: now.Add(time.Hour)}); !errors.Is(err, ErrNoTenant) {
				t.Fatalf("a report naming no workspace: %v", err)
			}
		})
	}
}

// Any stored tag lists and pages: csi-spl's keyed versions newest first, then
// the other tags by their newest row, the seq still counting from the oldest.
func TestReleaseNotesAnyTag(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			rn := s.(ReleaseNotes)
			tid := newTenant(t, s)
			t0 := time.Now().UTC().Truncate(time.Microsecond).Add(-time.Hour)
			put := func(at time.Time, n ...ReleaseNote) {
				t.Helper()
				if err := rn.PutReleaseNotes(ctx, tid, relRepo, n, at); err != nil {
					t.Fatal(err)
				}
			}
			put(t0, noteOK(randSHA(), "v0.4.2-beta.1", t0))
			older, newer := noteOK(randSHA(), "2026.11.05", t0), noteOK(randSHA(), "2026.11.05", t0.Add(time.Minute))
			put(t0.Add(time.Minute), older, newer)
			put(t0.Add(2*time.Minute), noteOK(randSHA(), "v1.2.", t0))
			put(t0, noteOK(randSHA(), "v2.0.0", t0))

			want := []struct {
				version string
				seqs    []int
			}{{"v2.0.0", []int{5}}, {"v1.2.", []int{4}}, {"2026.11.05", []int{3, 2}}, {"v0.4.2-beta.1", []int{1}}}
			before := ""
			for _, w := range want {
				page, err := rn.ListReleaseNotes(ctx, tid, before, 1)
				if err != nil {
					t.Fatalf("page after %q: %v", before, err)
				}
				if len(page) != len(w.seqs) {
					t.Fatalf("page after %q: %+v, want %v", before, page, w)
				}
				for i, n := range page {
					if n.Version != w.version || n.Seq != w.seqs[i] {
						t.Errorf("page after %q row %d: %s seq %d, want %v", before, i, n.Version, n.Seq, w)
					}
				}
				rows, err := rn.ReleaseNotesOfVersion(ctx, tid, w.version)
				if err != nil || len(rows) != len(w.seqs) || rows[0].Seq != w.seqs[0] {
					t.Errorf("version %s: %+v %v", w.version, rows, err)
				}
				before = w.version
			}
			if page, err := rn.ListReleaseNotes(ctx, tid, before, 1); err != nil || len(page) != 0 {
				t.Fatalf("past the oldest: %+v %v", page, err)
			}
			if page, err := rn.ListReleaseNotes(ctx, tid, "2026.11.05", 10); err != nil || len(page) != 1 || page[0].Version != "v0.4.2-beta.1" {
				t.Fatalf("a tag cursor: %+v %v", page, err)
			}
			if page, err := rn.ListReleaseNotes(ctx, tid, "v2.0.0", 2); err != nil || len(page) != 3 || page[0].Version != "v1.2." || page[1].Version != "2026.11.05" {
				t.Fatalf("a keyed cursor reaches the tags: %+v %v", page, err)
			}
			if _, err := rn.ListReleaseNotes(ctx, tid, "-bad", 1); err == nil {
				t.Fatal("a bad cursor was accepted")
			}
		})
	}
}

// ReleaseDisplay drops only a real cycle, so another repo's tag stays whole.
func TestReleaseDisplayKeepsOtherTags(t *testing.T) {
	for in, want := range map[string]string{"v1.0.1-c2": "v1.0.1", "v1.0.0": "v1.0.0", "v1.0.0-cool": "v1.0.0-cool",
		"v1.0.0-c1": "v1.0.0-c1", "2026.11.05": "2026.11.05"} {
		if got := ReleaseDisplay(in); got != want {
			t.Errorf("ReleaseDisplay(%q) = %q, want %q", in, got, want)
		}
	}
}

// Row B-2's test on the memory store, whose key is already three columns.
func TestReleaseNotesSameSHATwoReposMemory(t *testing.T) {
	ctx := context.Background()
	m := NewMemory()
	now := time.Now().UTC()
	sha := randSHA()
	for _, repo := range []string{relRepo, otherRepo} {
		if err := m.PutReleaseNotes(ctx, relTenant, repo, []ReleaseNote{noteOK(sha, "v1.0.0", now)}, now); err != nil {
			t.Fatal(err)
		}
	}
	rows, err := m.ReleaseNotesOfVersion(ctx, relTenant, "v1.0.0")
	if err != nil || len(rows) != 2 || rows[0].RepoSlug == rows[1].RepoSlug {
		t.Fatalf("one sha in two repos: %+v %v", rows, err)
	}
	if _, err := m.ReleaseNote(ctx, relTenant, sha); !errors.Is(err, ErrAmbiguousRef) {
		t.Fatalf("a sha in two repos must not pick one: %v", err)
	}
}

// throwawayReleaseNotes is a Postgres store whose release_notes is a copy of
// the live columns and CHECKs in a schema of its own, primary key on key.
func throwawayReleaseNotes(t *testing.T, pg *Postgres, key string) *Postgres {
	t.Helper()
	ctx := context.Background()
	schema := "b2_" + randSHA()[:12]
	stmt := func(q string) {
		t.Helper()
		if _, err := pg.pool.Exec(ctx, q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	stmt(`CREATE SCHEMA ` + schema)
	t.Cleanup(func() { pg.pool.Exec(context.Background(), `DROP SCHEMA `+schema+` CASCADE`) }) //nolint:errcheck
	stmt(`CREATE TABLE ` + schema + `.release_notes (LIKE public.release_notes INCLUDING DEFAULTS INCLUDING CONSTRAINTS)`)
	stmt(`ALTER TABLE ` + schema + `.release_notes ADD PRIMARY KEY (` + key + `)`)
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	sep := " "
	if strings.Contains(dsn, "://") {
		sep = "?"
		if strings.Contains(dsn, "?") {
			sep = "&"
		}
	}
	eq := "search_path=" + schema + ",public"
	if sep == " " {
		eq = "search_path='" + schema + ",public'"
	}
	out, err := OpenPostgres(ctx, dsn+sep+eq)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(out.Close)
	return out
}

// Row B-2's test: one sha in two repos of a workspace keeps two rows. It runs
// on row B-3's primary key in a throwaway schema, because the live table keeps
// release_notes_pkey (sha) until B-3, whose lane re-proves it on the real key.
// RED CONTROL: on spec 171's two-column key the same two writes read one row.
func TestReleaseNotesSameSHATwoReposPostgres(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	sha := randSHA()
	three := throwawayReleaseNotes(t, pg, "tenant_id, repo_slug, sha")
	for _, repo := range []string{relRepo, otherRepo, relRepo} {
		if err := three.PutReleaseNotes(ctx, relTenant, repo, []ReleaseNote{noteOK(sha, "v1.0.0", now)}, now); err != nil {
			t.Fatal(err)
		}
	}
	var n int
	if err := three.pool.QueryRow(ctx, `SELECT count(*) FROM release_notes WHERE sha = $1`, sha).Scan(&n); err != nil || n != 2 {
		t.Fatalf("three-column key: %d rows, want 2 (%v)", n, err)
	}
	two := throwawayReleaseNotes(t, pg, "tenant_id, sha")
	for _, repo := range []string{relRepo, otherRepo} {
		if _, err := two.pool.Exec(ctx, `INSERT INTO release_notes (tenant_id, repo_slug, sha, committed_at, subject, state)
			VALUES ($1, $2, $3, now(), 's', 'ok') ON CONFLICT (tenant_id, sha) DO UPDATE SET repo_slug = EXCLUDED.repo_slug`, relTenant, repo, sha); err != nil {
			t.Fatal(err)
		}
	}
	if err := two.pool.QueryRow(ctx, `SELECT count(*) FROM release_notes WHERE sha = $1`, sha).Scan(&n); err != nil || n != 1 {
		t.Fatalf("RED CONTROL: the two-column key: %d rows, want 1 (%v)", n, err)
	}
}

// Until row B-3 the live primary key is sha alone, so a second repo's row is
// refused and no registration may reach it. B-3's swap turns this red on purpose.
func TestReleaseNotesLivePkeyStillSHA(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	sha := randSHA()
	t.Cleanup(func() { pg.pool.Exec(context.Background(), `DELETE FROM release_notes WHERE sha = $1`, sha) }) //nolint:errcheck
	if err := pg.PutReleaseNotes(ctx, relTenant, relRepo, []ReleaseNote{noteOK(sha, "", now)}, now); err != nil {
		t.Fatal(err)
	}
	err := pg.PutReleaseNotes(ctx, relTenant, otherRepo, []ReleaseNote{noteOK(sha, "", now)}, now)
	var pe *pgconn.PgError
	if !errors.As(err, &pe) || pe.ConstraintName != "release_notes_pkey" {
		t.Fatalf("a second repo on the live key: %v", err)
	}
}

// The new list walks rdb 0270's index; a seq scan costs it about 100x (R7).
func TestReleaseListPlanUsesGuardedIndex(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tx, err := pg.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `SET LOCAL enable_seqscan = off`); err != nil {
		t.Fatal(err)
	}
	vk := releaseKeySQL("version")
	rows, err := tx.Query(ctx, `EXPLAIN SELECT DISTINCT `+vk+` AS k FROM release_notes
		WHERE tenant_id = 't1' AND version IS NOT NULL AND `+vk+` IS NOT NULL ORDER BY k DESC NULLS LAST LIMIT 10`)
	if err != nil {
		t.Fatal(err)
	}
	plan, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(strings.Join(plan, "\n"), "release_notes_release_key") {
		t.Errorf("the list no longer reads release_notes_release_key:\n%s", strings.Join(plan, "\n"))
	}
}

// WorkspaceRepo answers a registered repo or the primary, nothing else.
func TestWorkspaceRepoMemory(t *testing.T) {
	ctx := context.Background()
	m := NewMemory()
	if _, err := m.WorkspaceRepo(ctx, "a", ""); !errors.Is(err, ErrRepoNotRegistered) {
		t.Fatalf("no primary: %v", err)
	}
	m.SeedWorkspaceRepo("a", relRepo, true)
	m.SeedWorkspaceRepo("a", otherRepo, false)
	if got, err := m.WorkspaceRepo(ctx, "a", ""); err != nil || got != relRepo {
		t.Fatalf("primary: %q %v", got, err)
	}
	if got, err := m.WorkspaceRepo(ctx, "a", otherRepo); err != nil || got != otherRepo {
		t.Fatalf("named: %q %v", got, err)
	}
	if _, err := m.WorkspaceRepo(ctx, "a", "csitea/nope"); !errors.Is(err, ErrRepoNotRegistered) {
		t.Fatalf("unregistered: %v", err)
	}
	if _, err := m.WorkspaceRepo(ctx, "b", relRepo); !errors.Is(err, ErrRepoNotRegistered) {
		t.Fatalf("another workspace's repo: %v", err)
	}
}
