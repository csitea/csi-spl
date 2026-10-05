package store

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// TestReleaseNotesPinRdbChecks pins rdb 0108's CHECKs to the Go side (spec
// 065 section 4.2): a state or a limit changed on one side only turns this red.
func TestReleaseNotesPinRdbChecks(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0108_release_note.sql"))
	if err != nil {
		t.Fatal(err)
	}
	sql := string(raw)
	m := regexp.MustCompile(`state\s+text\s+NOT NULL CHECK \(state IN \((.*)\)\),`).FindStringSubmatch(sql)
	if want := "'" + strings.Join(ReleaseNoteStates, "', '") + "'"; m == nil || m[1] != want {
		t.Errorf("state: rdb %v, Go (%s)", m, want)
	}
	for _, want := range []string{
		`sha ~ '^[0-9a-f]{40}$'`,
		`kind ~ '` + releaseKindRe.String() + `'`,
		fmt.Sprintf("length(area) <= %d", ReleaseAreaMax),
		fmt.Sprintf("length(subject) BETWEEN 1 AND %d", ReleaseSubjectMax),
		`reverts ~ '^[0-9a-f]{40}$'`,
		fmt.Sprintf("length(link) <= %d", ReleaseLinkMax),
	} {
		if !strings.Contains(sql, want) {
			t.Errorf("0108 lacks CHECK %s", want)
		}
	}
	for _, c := range []string{"lay_what", "lay_how", "lay_why", "tech_what", "tech_how", "tech_why"} {
		if want := fmt.Sprintf("length(%s) <= %d", c, ReleaseTrailerMax); !strings.Contains(sql, want) {
			t.Errorf("0108 lacks CHECK %s", want)
		}
	}
	if releaseSHARe.String() != `^[0-9a-f]{40}$` {
		t.Errorf("Go sha shape drifted from 0108")
	}
}

// TestReleaseNotesPinRdbCycle pins rdb 0114 (the release key: v<X.Y.Z> in
// cycle 1, v<X.Y.Z>-c<N> after the 9.9.9 wrap) to releaseVersionRe and
// releaseKeySQL: a shape or sort key changed on one side only turns this red.
func TestReleaseNotesPinRdbCycle(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0114_release_note_cycle.sql"))
	if err != nil {
		t.Fatal(err)
	}
	sql := strings.Join(strings.Fields(string(raw)), " ")
	if want := `CHECK (version ~ '^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c([2-9]|[1-9][0-9]{1,3}))?$')`; !strings.Contains(sql, want) {
		t.Errorf("0114 lacks %s", want)
	}
	if want := `^v([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})(?:-c([2-9]|[1-9][0-9]{1,3}))?$`; releaseVersionRe.String() != want {
		t.Errorf("Go version shape drifted from 0114: %s", releaseVersionRe)
	}
	if want := "((" + strings.Join(strings.Fields(releaseKeySQL("version")), " ") + ") DESC"; !strings.Contains(sql, want) {
		t.Errorf("0114's index is not on releaseKeySQL: want %s", want)
	}
}

// TestReleaseVersionKey: the cycle sorts first, a bare tag is cycle 1, the
// display drops the cycle, and -c0 / -c1 are not keys (cycle 1 has none).
func TestReleaseVersionKey(t *testing.T) {
	for v, want := range map[string][4]int{"v9.9.9": {1, 9, 9, 9}, "v1.0.1-c2": {2, 1, 0, 1}, "v7.10.0-c12": {12, 7, 10, 0}} {
		if k, ok := releaseVersionKey(v); !ok || k != want {
			t.Errorf("releaseVersionKey(%s) = %v %v, want %v", v, k, ok, want)
		}
	}
	for _, bad := range []string{"v1.0.1-c1", "v1.0.1-c0", "v1.0.1-c02", "v1.0.1-c", "1.0.1-c2", "v1.0.1-c12345"} {
		if _, ok := releaseVersionKey(bad); ok {
			t.Errorf("releaseVersionKey(%s) accepted", bad)
		}
	}
	if d := ReleaseDisplay("v1.0.1-c2"); d != "v1.0.1" {
		t.Errorf("ReleaseDisplay(v1.0.1-c2) = %s", d)
	}
	if d := ReleaseDisplay("v7.4.1"); d != "v7.4.1" {
		t.Errorf("ReleaseDisplay(v7.4.1) = %s", d)
	}
}

func randSHA() string {
	b := make([]byte, 20)
	rand.Read(b) //nolint:errcheck
	return hex.EncodeToString(b)
}

func noteOK(sha, version string, at time.Time) ReleaseNote {
	return ReleaseNote{SHA: sha, Version: version, CommittedAt: at, Kind: "fix", Area: "wui",
		Subject: "fix(wui): the unread badge stays after a channel is read",
		LayWhat: "The red dot now disappears once you have read a channel.", LayHow: "The app tells the server.",
		LayWhy: "The dot was useless.", TechWhat: "WUI marks the channel read on open.",
		TechHow: "ChannelView calls the read route on mount.", TechWhy: "The read call was only sent on scroll.",
		State: "ok", Link: "https://example.com/commit/" + sha}
}

// put, get by sha and prefix, first version kept, version paging (numeric
// order), one version's rows: on memory and, with SPOOL_TEST_PG_DSN, Postgres.
// The table is estate-wide, so every row lives under a random major version
// and every list starts below the next one: rows another test left are out
// of range.
func TestReleaseNotes(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rs := st.(ReleaseNotes)
			mj, _ := rand.Int(rand.Reader, big.NewInt(800000))
			major := int(mj.Int64()) + 100000
			v := func(minor, patch int) string { return fmt.Sprintf("v%d.%d.%d", major, minor, patch) }
			top := fmt.Sprintf("v%d.0.0", major+1)
			t0 := time.Now().UTC().Truncate(time.Second).Add(-time.Hour)
			now := t0.Add(time.Hour)

			a, b, c, d := randSHA(), randSHA(), randSHA(), randSHA()
			ra := noteOK(a, v(9, 0), t0)
			rb := noteOK(b, v(10, 0), t0.Add(time.Minute)) // v.10 is newer than v.9
			rc := noteOK(c, v(10, 0), t0.Add(2*time.Minute))
			rc.State, rc.Reverts, rc.LayHow, rc.TechWhat = "revert", a, "", ""
			rd := ReleaseNote{SHA: d, CommittedAt: t0.Add(3 * time.Minute), Subject: "docs: a line", State: "missing"}
			for _, n := range []ReleaseNote{ra, rb, rc, rd} {
				if why := CheckReleaseNote(n); why != "" {
					t.Fatalf("CheckReleaseNote(%s): %s", n.SHA, why)
				}
			}
			if err := rs.PutReleaseNotes(ctx, []ReleaseNote{ra, rb, rc, rd}, now); err != nil {
				t.Fatal(err)
			}

			got, err := rs.ReleaseNote(ctx, a)
			if err != nil || got.Version != v(9, 0) || got.LayWhat != ra.LayWhat || got.State != "ok" ||
				!got.CommittedAt.Equal(t0) || !got.IngestedAt.Equal(now) || got.Link != ra.Link || got.Reverts != "" {
				t.Fatalf("get by sha: %+v %v", got, err)
			}
			if got, err = rs.ReleaseNote(ctx, strings.ToUpper(c[:7])); err != nil || got.SHA != c || got.Reverts != a || got.State != "revert" {
				t.Fatalf("get by prefix: %+v %v", got, err)
			}
			if got, err = rs.ReleaseNote(ctx, d); err != nil || got.Version != "" || got.State != "missing" {
				t.Fatalf("undeployed row: %+v %v", got, err)
			}
			if _, err = rs.ReleaseNote(ctx, randSHA()); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown sha: %v", err)
			}
			if _, err = rs.ReleaseNote(ctx, "abc"); err == nil {
				t.Fatal("a 3-char ref was accepted")
			}

			// newest first, versions compared as numbers; the undeployed row is not listed
			ls, err := rs.ListReleaseNotes(ctx, top, 0)
			if err != nil || len(ls) != 3 || ls[0].SHA != c || ls[1].SHA != b || ls[2].SHA != a {
				t.Fatalf("list: %+v %v", ls, err)
			}
			if ls, _ = rs.ListReleaseNotes(ctx, top, 1); len(ls) != 2 || ls[0].Version != v(10, 0) || ls[1].Version != v(10, 0) {
				t.Fatalf("one version page: %+v", ls)
			}
			if ls, _ = rs.ListReleaseNotes(ctx, v(10, 0), 1); len(ls) != 1 || ls[0].SHA != a {
				t.Fatalf("next page: %+v", ls)
			}
			if ls, _ = rs.ListReleaseNotes(ctx, v(9, 0), 5); len(ls) != 0 {
				t.Fatalf("past the oldest: %+v", ls)
			}
			if _, err = rs.ListReleaseNotes(ctx, "7.4.1", 5); err == nil {
				t.Fatal("a before without v was accepted")
			}
			if ls, err = rs.ReleaseNotesOfVersion(ctx, v(10, 0)); err != nil || len(ls) != 2 || ls[0].SHA != c {
				t.Fatalf("of version: %+v %v", ls, err)
			}

			// re-ingest: the deploy that tags d fills its version; a later
			// tag never moves a or d; a correction replaces the text
			rd.Version = v(11, 0)
			ra2 := ra
			ra2.Version, ra2.LayWhat = v(11, 0), "Corrected."
			if err = rs.PutReleaseNotes(ctx, []ReleaseNote{rd, ra2}, now.Add(time.Minute)); err != nil {
				t.Fatal(err)
			}
			rd.Version = v(12, 0)
			if err = rs.PutReleaseNotes(ctx, []ReleaseNote{rd}, now.Add(2*time.Minute)); err != nil {
				t.Fatal(err)
			}
			if got, _ = rs.ReleaseNote(ctx, d); got.Version != v(11, 0) {
				t.Fatalf("first version not kept: %+v", got)
			}
			if got, _ = rs.ReleaseNote(ctx, a); got.Version != v(9, 0) || got.LayWhat != "Corrected." || !got.IngestedAt.Equal(now.Add(time.Minute)) {
				t.Fatalf("correction: %+v", got)
			}
			if ls, _ = rs.ListReleaseNotes(ctx, top, 1); len(ls) != 1 || ls[0].SHA != d {
				t.Fatalf("tagged row listed: %+v", ls)
			}

			// one sha twice in a batch: the last row wins on both drivers
			e := randSHA()
			e1, e2 := noteOK(e, v(1, 0), t0), noteOK(e, v(1, 0), t0)
			e2.LayWhat = "second"
			if err = rs.PutReleaseNotes(ctx, []ReleaseNote{e1, e2}, now); err != nil {
				t.Fatal(err)
			}
			if got, _ = rs.ReleaseNote(ctx, e); got.LayWhat != "second" {
				t.Fatalf("duplicate in batch: %+v", got)
			}
		})
	}
}

// The rolling number (owner, t1 55b6de46): seq counts the versioned rows
// from the oldest (1) up, the list order reversed, so the newest listed row
// carries the highest; an untagged row has none and is not counted, and the
// row a later deploy tags takes the next number. Postgres shares its table
// with other tests, so there the numbers are checked relative to each other;
// a fresh memory store starts at 1.
func TestReleaseNotesSeq(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rs := st.(ReleaseNotes)
			mj, _ := rand.Int(rand.Reader, big.NewInt(800000))
			major := int(mj.Int64()) + 100000
			v := func(minor int) string { return fmt.Sprintf("v%d.%d.0", major, minor) }
			top := fmt.Sprintf("v%d.0.0", major+1)
			t0 := time.Now().UTC().Truncate(time.Second).Add(-time.Hour)

			a, b, c, d := randSHA(), randSHA(), randSHA(), randSHA()
			untagged := noteOK(d, "", t0.Add(3*time.Minute))
			batch := []ReleaseNote{noteOK(a, v(9), t0), noteOK(b, v(10), t0.Add(time.Minute)), noteOK(c, v(10), t0.Add(2*time.Minute)), untagged}
			if err := rs.PutReleaseNotes(ctx, batch, t0.Add(time.Hour)); err != nil {
				t.Fatal(err)
			}
			ls, err := rs.ListReleaseNotes(ctx, top, 2)
			if err != nil || len(ls) != 3 || ls[0].SHA != c || ls[2].SHA != a {
				t.Fatalf("list: %+v %v", ls, err)
			}
			if ls[2].Seq < 1 || ls[1].Seq != ls[2].Seq+1 || ls[0].Seq != ls[2].Seq+2 {
				t.Fatalf("seq not counted up from the oldest: %d %d %d", ls[0].Seq, ls[1].Seq, ls[2].Seq)
			}
			if name == "memory" && ls[2].Seq != 1 {
				t.Fatalf("the oldest row is %d, want 1", ls[2].Seq)
			}
			of, err := rs.ReleaseNotesOfVersion(ctx, v(10))
			if err != nil || len(of) != 2 || of[0].Seq != ls[0].Seq || of[1].Seq != ls[1].Seq {
				t.Fatalf("of version seq: %+v %v", of, err)
			}
			// the deploy that tags d gives it the next number; the others keep theirs
			untagged.Version = v(11)
			if err = rs.PutReleaseNotes(ctx, []ReleaseNote{untagged}, t0.Add(2*time.Hour)); err != nil {
				t.Fatal(err)
			}
			ls2, err := rs.ListReleaseNotes(ctx, top, 3)
			if err != nil || len(ls2) != 4 || ls2[0].SHA != d || ls2[0].Seq != ls[0].Seq+1 || ls2[3].Seq != ls[2].Seq {
				t.Fatalf("tagged row seq: %+v %v", ls2, err)
			}
		})
	}
}

// Cycle 1 vs cycle 2 of one X.Y.Z (owner t1 1c5b6d53: after 9.9.9 start over
// at 1.0.1): v<M>.0.1 and v<M>.0.1-c<N> are two versions, never merged, and
// the later cycle pages first even though its X.Y.Z reads lower than a
// cycle-1 v<M>.9.9. The cycle is random and high so rows other tests left
// (all cycle 1, or another run's cycle) stay out of the before window.
func TestReleaseNotesCycles(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rs := st.(ReleaseNotes)
			cy, _ := rand.Int(rand.Reader, big.NewInt(8000))
			cycle := int(cy.Int64()) + 1000
			mj, _ := rand.Int(rand.Reader, big.NewInt(800000))
			major := int(mj.Int64()) + 100000
			c1 := fmt.Sprintf("v%d.0.1", major)
			c1top := fmt.Sprintf("v%d.9.9", major)
			c2 := fmt.Sprintf("v%d.0.1-c%d", major, cycle)
			top := fmt.Sprintf("v%d.0.0-c%d", major, cycle+1)
			t0 := time.Now().UTC().Truncate(time.Second).Add(-time.Hour)

			a, b, c, d := randSHA(), randSHA(), randSHA(), randSHA()
			batch := []ReleaseNote{noteOK(a, c1, t0), noteOK(b, c1top, t0.Add(time.Minute)),
				noteOK(c, c2, t0.Add(2*time.Minute)), noteOK(d, c2, t0.Add(3*time.Minute))}
			for _, n := range batch {
				if why := CheckReleaseNote(n); why != "" {
					t.Fatalf("CheckReleaseNote(%s): %s", n.Version, why)
				}
			}
			if err := rs.PutReleaseNotes(ctx, batch, t0.Add(time.Hour)); err != nil {
				t.Fatal(err)
			}
			if got, err := rs.ReleaseNote(ctx, c); err != nil || got.Version != c2 || ReleaseDisplay(got.Version) != c1 {
				t.Fatalf("cycle-2 row: %+v %v", got, err)
			}
			// the cycle-2 version pages first; its rows stay apart from cycle 1's
			ls, err := rs.ListReleaseNotes(ctx, top, 1)
			if err != nil || len(ls) != 2 || ls[0].SHA != d || ls[1].SHA != c || ls[0].Version != c2 {
				t.Fatalf("cycle-2 page: %+v %v", ls, err)
			}
			// cycle 1 of this major alone: its two versions, never the cycle-2 rows
			ls, err = rs.ListReleaseNotes(ctx, fmt.Sprintf("v%d.0.0", major+1), 2)
			if err != nil || len(ls) != 2 || ls[0].SHA != b || ls[1].SHA != a {
				t.Fatalf("cycle-1 page: %+v %v", ls, err)
			}
			if ls, err = rs.ReleaseNotesOfVersion(ctx, c2); err != nil || len(ls) != 2 || ls[0].SHA != d || ls[1].SHA != c {
				t.Fatalf("of cycle-2 version: %+v %v", ls, err)
			}
			if ls, err = rs.ReleaseNotesOfVersion(ctx, c1); err != nil || len(ls) != 1 || ls[0].SHA != a {
				t.Fatalf("of cycle-1 version: %+v %v", ls, err)
			}
			if _, err = rs.ListReleaseNotes(ctx, fmt.Sprintf("v%d.0.1-c1", major), 1); err == nil {
				t.Fatal("a -c1 cursor was accepted")
			}
		})
	}
}

// The ingest refuses what 0108's CHECKs would, so a bad row is a 400.
func TestCheckReleaseNote(t *testing.T) {
	ok := noteOK(randSHA(), "v7.4.1", time.Now())
	if why := CheckReleaseNote(ok); why != "" {
		t.Fatalf("refused a good row: %s", why)
	}
	if c2 := noteOK(randSHA(), "v1.0.1-c2", time.Now()); CheckReleaseNote(c2) != "" {
		t.Fatalf("refused a cycle-2 row: %s", CheckReleaseNote(c2))
	}
	for _, bad := range []func(*ReleaseNote){
		func(n *ReleaseNote) { n.SHA = strings.ToUpper(n.SHA) },
		func(n *ReleaseNote) { n.SHA = n.SHA[:7] },
		func(n *ReleaseNote) { n.Version = "7.4.1" },
		func(n *ReleaseNote) { n.Version = "v7.4.1-c1" },
		func(n *ReleaseNote) { n.Version = "v7.4.1-c" },
		func(n *ReleaseNote) { n.CommittedAt = time.Time{} },
		func(n *ReleaseNote) { n.Kind = "Fix" },
		func(n *ReleaseNote) { n.Area = strings.Repeat("a", ReleaseAreaMax+1) },
		func(n *ReleaseNote) { n.Subject = "" },
		func(n *ReleaseNote) { n.Subject = "two\nlines" },
		func(n *ReleaseNote) { n.LayWhy = strings.Repeat("a", ReleaseTrailerMax+1) },
		func(n *ReleaseNote) { n.TechHow = "a\tb" },
		func(n *ReleaseNote) { n.State = "done" },
		func(n *ReleaseNote) { n.Reverts = randSHA() },
		func(n *ReleaseNote) { n.State, n.Reverts = "revert", "abc" },
		func(n *ReleaseNote) { n.Link = "http://example.com/x" },
		func(n *ReleaseNote) { n.Link = "https://example.com/" + strings.Repeat("a", ReleaseLinkMax) },
	} {
		n := ok
		bad(&n)
		if CheckReleaseNote(n) == "" {
			t.Fatalf("accepted %+v", n)
		}
	}
}
