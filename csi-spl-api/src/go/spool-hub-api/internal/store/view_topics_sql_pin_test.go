package store

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

var updateTopicsSQL = flag.Bool("update-topics-sql", false, "rewrite testdata/view_topics_sql.golden")

// TestViewTopicsSQLGolden pins viewTopicsSQL byte for byte - the statement
// and its argument list, whose $n numbering depends on the order the
// builder asks for arguments - for every filter alone and in combination.
// Recorded before viewTopicsSQL was split into named builder steps
// (SPL-1029 round 2); the Postgres suites prove the SQL, this proves it did
// not move.
func TestViewTopicsSQLGolden(t *testing.T) {
	now := time.Date(2026, 9, 28, 12, 0, 0, 0, time.UTC)
	base := TopicQuery{Limit: 30, Now: now}
	with := func(f func(q *TopicQuery)) TopicQuery { q := base; f(&q); return q }
	cases := []struct {
		name string
		q    TopicQuery
	}{
		{"plain", base},
		{"channel", with(func(q *TopicQuery) { q.Channel = "lobby" })},
		{"dm", with(func(q *TopicQuery) { q.DM = true })},
		{"before", with(func(q *TopicQuery) {
			q.BeforeAt, q.BeforeTask = now.Add(-time.Hour), "11111111-2222-4333-8444-555555555555"
		})},
		{"agent", with(func(q *TopicQuery) { q.Agent = "CLE-07" })},
		{"agent+box", with(func(q *TopicQuery) { q.Agent, q.AgentBox = "CLE-07", "box-a" })},
		{"viewer", with(func(q *TopicQuery) { q.Viewer = "HUM-1" })},
		{"reader", with(func(q *TopicQuery) { q.Reader, q.ReaderChannels = "HUM-1", []string{"ops"} })},
		{"roots", with(func(q *TopicQuery) { q.Roots = true })},
		{"noissues", with(func(q *TopicQuery) { q.NoIssues = true })},
		{"parent", with(func(q *TopicQuery) { q.Parent = "11111111-2222-4333-8444-555555555555" })},
		{"lobby", with(func(q *TopicQuery) { q.Lobby = "22222222-2222-4333-8444-555555555555" })},
		{"everything", with(func(q *TopicQuery) {
			q.Channel, q.DM, q.BeforeAt, q.BeforeTask = "ops", true, now.Add(-time.Hour), "11111111-2222-4333-8444-555555555555"
			q.Agent, q.AgentBox, q.Viewer, q.Reader, q.ReaderChannels = "CLE-07", "box-a", "HUM-2", "HUM-1", []string{"ops", "dev"}
			q.Roots, q.NoIssues, q.Parent, q.Lobby = true, true, "33333333-2222-4333-8444-555555555555", "22222222-2222-4333-8444-555555555555"
		})},
	}
	var b strings.Builder
	for _, c := range cases {
		sql, args := viewTopicsSQL("t1", c.q)
		fmt.Fprintf(&b, "## %s\n%s\n-- args %q\n", c.name, sql, fmt.Sprint(args...))
	}
	const path = "testdata/view_topics_sql.golden"
	if *updateTopicsSQL {
		if err := os.MkdirAll("testdata", 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if b.String() != string(want) {
		got, exp := strings.Split(b.String(), "\n"), strings.Split(string(want), "\n")
		for i := 0; i < len(got) && i < len(exp); i++ {
			if got[i] != exp[i] {
				t.Fatalf("viewTopicsSQL differs from %s at line %d:\n got %s\nwant %s", path, i+1, got[i], exp[i])
			}
		}
		t.Fatalf("viewTopicsSQL differs from %s in length", path)
	}
}
