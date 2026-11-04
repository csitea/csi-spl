package search

import "testing"

// Type.Group, StatusDoc and Query.Rank (refactor round 23 row 05): the
// response keys, the status: operator's doc and the memory store's rank.

func TestTypeGroup(t *testing.T) {
	for _, c := range []struct {
		t    Type
		want string
	}{
		{TypeBox, "boxes"},
		{TypeMessage, "messages"},
		{Type("other"), "others"},
	} {
		if got := c.t.Group(); got != c.want {
			t.Errorf("Type(%q).Group() = %q, want %q", c.t, got, c.want)
		}
	}
}

func TestStatusDoc(t *testing.T) {
	s := IssueStatuses
	t.Cleanup(func() { IssueStatuses = s })

	IssueStatuses = nil
	if got, want := StatusDoc(), opByName[OpStatus].Doc; got != want {
		t.Errorf("no workflow: StatusDoc() = %q, want the static doc %q", got, want)
	}
	IssueStatuses = []string{"open", "blocked"}
	if got, want := StatusDoc(), "issue status: open, blocked (older names such as in_progress still work)"; got != want {
		t.Errorf("workflow set: StatusDoc() = %q, want %q", got, want)
	}
}

// srQuery parses q (a trailing space keeps the last word whole) or fails;
// "" is the empty query, which Parse refuses.
func srQuery(t *testing.T, q string) *Query {
	t.Helper()
	if q == "" {
		return &Query{}
	}
	pq, err := Parse(q, now)
	if err != nil {
		t.Fatalf("Parse(%q): %v", q, err)
	}
	return pq
}

func TestQueryRank(t *testing.T) {
	for _, c := range []struct {
		name, q, body string
		want          int
	}{
		{"empty query", "", "deploy the hub", 0},
		{"no match", "deploy ", "the hub is up", 0},
		{"one match", "deploy ", "please deploy the hub", 1},
		{"each occurrence counts", "deploy ", "Deploy, then deploy again: DEPLOY", 3},
		{"two lexemes", "deploy hub ", "deploy the hub, then the hub again", 3},
		{"title: lexemes rank", "title:hub ", "the hub", 1},
		{"negated word does not rank", "deploy -hub ", "deploy the hub", 1},
		{"non-text operator does not rank", "is:task ", "task task", 0},
	} {
		if got := srQuery(t, c.q).Rank(c.body); got != c.want {
			t.Errorf("%s: Parse(%q).Rank(%q) = %d, want %d", c.name, c.q, c.body, got, c.want)
		}
	}
}
