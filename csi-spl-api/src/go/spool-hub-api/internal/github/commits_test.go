package github_test

import (
	"context"
	"fmt"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/github/githubtest"
)

// TestCommitsNewestFirstAcrossPages: the list walks the branch newest first,
// across GitHub's 100-per-page pages, and stops at n.
func TestCommitsNewestFirstAcrossPages(t *testing.T) {
	gh := githubtest.New(t, map[string]string{doc: "# one\n"})
	c := newClient(t, gh, nil, nil)
	var last string
	for i := 0; i < 130; i++ {
		last = gh.Push(doc, fmt.Sprintf("# v%d\n", i), fmt.Sprintf("docs: v%d", i))
	}
	got, err := c.Commits(context.Background(), 500)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 131 {
		t.Fatalf("commits = %d, want 131 (130 pushes + root)", len(got))
	}
	if got[0].SHA != last || got[0].Message != "docs: v129" || got[130].Message != "root" {
		t.Fatalf("order: first %s %q, last %q", got[0].SHA, got[0].Message, got[130].Message)
	}
	if got[0].Author.Name != githubtest.BotName {
		t.Fatalf("author = %+v", got[0].Author)
	}
	few, err := c.Commits(context.Background(), 3)
	if err != nil || len(few) != 3 || few[0].SHA != last {
		t.Fatalf("n=3: %d %v", len(few), err)
	}
}
