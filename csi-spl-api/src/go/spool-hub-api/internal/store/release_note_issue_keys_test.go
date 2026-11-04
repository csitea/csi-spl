package store

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

// SPL-4789, rdb 0261: a release note names the issue keys its message cites.

func TestReleaseIssueKeys(t *testing.T) {
	msg := "feat(wui, SPL-12): links (SPL-12, SPL-7)\n\nCloses: SPL-30\nRefs: SPL-7, HUM-10, UTF-8\n" +
		"not keys: xSPL-1 SPL-2a SPL-0 SPL-01 ABC-SPL-3 SPL-\nend SPL-44."
	if got, want := ReleaseIssueKeys("SPL", msg), []string{"SPL-12", "SPL-7", "SPL-30", "SPL-44"}; !reflect.DeepEqual(got, want) {
		t.Errorf("keys %v, want %v", got, want)
	}
	if got := ReleaseIssueKeys("", msg); got == nil || len(got) != 0 {
		t.Errorf("no prefix: %v", got)
	}
	if got := ReleaseIssueKeys("DVN", msg); len(got) != 0 {
		t.Errorf("another prefix: %v", got)
	}
	var many strings.Builder
	for i := 1; i <= 30; i++ {
		many.WriteString(" SPL-" + strconv.Itoa(i))
	}
	if got := ReleaseIssueKeys("SPL", many.String()); len(got) != ReleaseIssueKeysMax || got[19] != "SPL-20" {
		t.Errorf("cap: %d %v", len(got), got)
	}
	n := noteOK(randSHA(), "", time.Now())
	n.IssueKeys = []string{"SPL-1", "spl-2"}
	if CheckReleaseNote(n) == "" {
		t.Error("a lowercase key passed CheckReleaseNote")
	}
}

// TestReleaseNotesPinRdbIssueKeys pins rdb 0261's CHECK to the Go limits.
func TestReleaseNotesPinRdbIssueKeys(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0261_release_note_issue_keys.sql"))
	if err != nil {
		t.Fatal(err)
	}
	sql := strings.Join(strings.Fields(string(raw)), " ")
	shape := strings.TrimSuffix(strings.TrimPrefix(releaseIssueKeyRe.String(), "^"), "$")
	for _, want := range []string{
		"cardinality(issue_keys) <= " + strconv.Itoa(ReleaseIssueKeysMax),
		"'^(" + shape + "(,|$))*$'",
	} {
		if !strings.Contains(sql, want) {
			t.Errorf("0261 lacks %s", want)
		}
	}
}

// The keys round-trip on both drivers; a row re-sent with no issue tenant
// keeps them, one re-sent with a tenant replaces them.
func TestReleaseNotesIssueKeys(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rs := st.(ReleaseNotes)
			now := time.Now().UTC().Truncate(time.Second)
			sha := randSHA()
			n := noteOK(sha, "", now)
			n.IssueTenant, n.IssueKeys = "t1", []string{"SPL-5", "SPL-9"}
			if err := rs.PutReleaseNotes(ctx, []ReleaseNote{n}, now); err != nil {
				t.Fatal(err)
			}
			read := func() ReleaseNote {
				t.Helper()
				got, err := rs.ReleaseNote(ctx, sha)
				if err != nil {
					t.Fatal(err)
				}
				return got
			}
			if got := read(); got.IssueTenant != "t1" || !reflect.DeepEqual(got.IssueKeys, []string{"SPL-5", "SPL-9"}) {
				t.Fatalf("stored %q %v", got.IssueTenant, got.IssueKeys)
			}
			plain := noteOK(sha, "", now)
			if err := rs.PutReleaseNotes(ctx, []ReleaseNote{plain}, now); err != nil {
				t.Fatal(err)
			}
			if got := read(); got.IssueTenant != "t1" || len(got.IssueKeys) != 2 {
				t.Fatalf("a re-send with no tenant dropped the keys: %q %v", got.IssueTenant, got.IssueKeys)
			}
			plain.IssueTenant, plain.IssueKeys = "t1", nil
			if err := rs.PutReleaseNotes(ctx, []ReleaseNote{plain}, now); err != nil {
				t.Fatal(err)
			}
			if got := read(); got.IssueKeys == nil || len(got.IssueKeys) != 0 {
				t.Fatalf("a re-send with the tenant and no keys: %v", got.IssueKeys)
			}
		})
	}
}
