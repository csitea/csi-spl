package store

import (
	"context"
	"crypto/rand"
	"fmt"
	"maps"
	"math/big"
	"strings"
	"testing"
	"time"
)

// P5-08 (perf round 5): ListReleaseNotes numbers only its page, and its seq
// still equals releaseNumberedSQL's row_number() over every versioned row,
// on Postgres, for the first page, a cursor inside the range and pages of
// one and many versions, with two rows of one version sharing committed_at
// (the sha tie-break). The table is shared with concurrent tests, so a
// comparison counts only when the oracle read the same rows before and after
// the list.
func TestReleaseNotesPageSeqOracle(t *testing.T) {
	var pg *Postgres
	for _, s := range drivers(t) {
		if p, ok := s.(*Postgres); ok {
			pg = p
		}
	}
	if pg == nil {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	ctx := context.Background()
	mj, _ := rand.Int(rand.Reader, big.NewInt(800000))
	major := int(mj.Int64()) + 100000
	v := func(minor int) string { return fmt.Sprintf("v%d.%d.0", major, minor) }
	top := fmt.Sprintf("v%d.0.0", major+1)
	t0 := time.Now().UTC().Truncate(time.Second).Add(-time.Hour)
	var batch []ReleaseNote
	for minor := 1; minor <= 5; minor++ {
		for j := range 3 {
			batch = append(batch, noteOK(randSHA(), v(minor), t0.Add(time.Duration(minor*10+j)*time.Minute)))
		}
	}
	batch[7].CommittedAt = batch[8].CommittedAt // a tie inside v(3)
	// TestReleaseNotes lists 30 versions below its own random major: rows
	// left here under a lower major would land on its page.
	shas := make([]string, len(batch))
	for i, n := range batch {
		shas[i] = n.SHA
	}
	t.Cleanup(func() {
		if _, err := pg.pool.Exec(context.Background(), `DELETE FROM release_notes WHERE sha = ANY($1)`, shas); err != nil {
			t.Errorf("cleanup: %v", err)
		}
	})
	if err := pg.PutReleaseNotes(ctx, batch, t0.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	oracle := func(versions []string) map[string]int {
		t.Helper()
		rows, err := pg.pool.Query(ctx, `SELECT sha, seq FROM (`+releaseNumberedSQL()+`) n WHERE version = ANY($1)`, versions)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		out := map[string]int{}
		for rows.Next() {
			var sha string
			var seq int
			if err := rows.Scan(&sha, &seq); err != nil {
				t.Fatal(err)
			}
			out[sha] = seq
		}
		return out
	}
	for _, c := range []struct {
		before   string
		versions int
		want     int // rows of this test's own versions on the page
	}{{top, 2, 6}, {top, 5, 15}, {v(4), 1, 3}, {v(4), 2, 6}, {v(2), 1, 3}} {
		ok := false
		for try := 0; try < 5 && !ok; try++ {
			ls, err := pg.ListReleaseNotes(ctx, c.before, c.versions)
			if err != nil {
				t.Fatal(err)
			}
			got, seen, own := map[string]int{}, map[string]bool{}, 0
			var vs []string
			for _, n := range ls {
				got[n.SHA] = n.Seq
				if !seen[n.Version] {
					seen[n.Version] = true
					vs = append(vs, n.Version)
				}
				if strings.HasPrefix(n.Version, fmt.Sprintf("v%d.", major)) {
					own++
				}
			}
			if own != c.want || len(vs) != c.versions {
				t.Fatalf("before %s, %d versions: %d own rows over %v", c.before, c.versions, own, vs)
			}
			o1 := oracle(vs)
			ls2, _ := pg.ListReleaseNotes(ctx, c.before, c.versions)
			if o2 := oracle(vs); !maps.Equal(o1, o2) || len(ls2) != len(ls) {
				continue // another test wrote release notes meanwhile
			}
			if !maps.Equal(got, o1) {
				t.Fatalf("before %s, %d versions: page seq %v, whole-table seq %v", c.before, c.versions, got, o1)
			}
			ok = true
		}
		if !ok {
			t.Fatalf("before %s: the table kept changing", c.before)
		}
	}
}
