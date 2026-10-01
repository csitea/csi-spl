package hub_test

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// fixtureAt is the base time of a fixture that the hub reads back through
// retention (messages, topics, files): an hour before the test clock, on a
// whole minute so a pinned RFC 3339 rendering stays exact. Never stamp such a
// fixture at a calendar date: the hub's own clock keeps moving, so the 30-day
// retention expired TestSearchEntityRows and TestSearchPagingWalksEverySection
// on 2026-10-01T10:02Z, thirty days after their fixed 2026-09-01 stamps
// (CLE-77858).
func fixtureAt() time.Time {
	return time.Now().UTC().Truncate(time.Minute).Add(-time.Hour)
}

// fixedDate is a time.Date call with a literal year.
var fixedDate = regexp.MustCompile(`time\.Date\(\s*\d{4}\s*,`)

// retentionWrite names the helpers that store a row the hub later reads
// through retention.
var retentionWrite = regexp.MustCompile(`\b(putMsg|InsertMessage)\(`)

// TestNoFixedDateInRetentionFixtures is the guard for fixtureAt: a hub test
// file that writes a retention-bearing row may not also build a time from a
// literal year, unless the line says why with a `clock-pinned:` comment (a
// test that injects the same fixed clock into every reader). It is a
// per-file heuristic, cheap on purpose: the failure it prevents went red on
// every sha at once, a month after it was written.
func TestNoFixedDateInRetentionFixtures(t *testing.T) {
	files, err := filepath.Glob("*_test.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range files {
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if !retentionWrite.Match(src) {
			continue
		}
		for i, line := range strings.Split(string(src), "\n") {
			if fixedDate.MatchString(line) && !strings.Contains(line, "clock-pinned:") {
				t.Errorf("%s:%d: a fixed date next to a retention write expires with the calendar; use fixtureAt(): %s",
					f, i+1, strings.TrimSpace(line))
			}
		}
	}
}
