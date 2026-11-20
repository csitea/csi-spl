package github_test

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
	"github.com/csitea/csi-spl/spool-hub-api/internal/github/githubtest"
)

// Spec 143 releases-projects.md row B-6b (SPL-5808): the per-repo reader.

func fixtureCommits(n int) []githubtest.FakeCommit {
	out := make([]githubtest.FakeCommit, n)
	for i := range out {
		out[i] = githubtest.FakeCommit{SHA: fmt.Sprintf("%040x", i+1), Message: fmt.Sprintf("feat: c%d", i+1),
			At: time.Date(2026, 11, 19, 0, i%60, 0, 0, time.UTC), Files: []string{"a/x", "b/y", "b/z", "root"}}
	}
	return out
}

func TestRepoReaderCommitsSincePagesAndStops(t *testing.T) {
	fake := githubtest.NewRepos(t)
	fake.Put("org/r", &githubtest.FakeRepo{Installation: "9", Commits: fixtureCommits(250)})
	app, err := github.NewRepoApp(github.RepoAppConfig{API: fake.URL, AppID: "1", Key: fake.KeyPEM})
	if err != nil {
		t.Fatal(err)
	}
	rd, err := app.Reader("org", "r", "9")
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	all, found, err := rd.CommitsSince(ctx, "main", "", 2000)
	if err != nil || found || len(all) != 250 || all[0].SHA != fmt.Sprintf("%040x", 250) {
		t.Fatalf("first walk: %d found=%v %v, want 250 newest first", len(all), found, err)
	}
	since := fmt.Sprintf("%040x", 120)
	got, found, err := rd.CommitsSince(ctx, "main", since, 2000)
	if err != nil || !found || len(got) != 130 {
		t.Fatalf("since c120: %d found=%v %v, want 130 and found", len(got), found, err)
	}
	if capped, _, _ := rd.CommitsSince(ctx, "main", "", 150); len(capped) != 150 {
		t.Fatalf("max 150: %d", len(capped))
	}
	if top, err := rd.CommitTopFolder(ctx, all[0].SHA); err != nil || top != "b" {
		t.Fatalf("top folder: %q %v, want b (two of three nested files)", top, err)
	}
	if _, err := app.Reader("org", "r", ""); err != nil {
		t.Fatal(err)
	}
	pub, _ := app.Reader("org", "r", "")
	var ae *github.APIError
	if _, _, err := pub.CommitsSince(ctx, "main", "", 1); !errors.As(err, &ae) || ae.Status != 404 {
		t.Fatalf("a private repo read with no credential: %v, want 404", err)
	}
}

func TestRepoReaderTagsReleasesAndNoKey(t *testing.T) {
	fake := githubtest.NewRepos(t)
	fake.Put("org/p", &githubtest.FakeRepo{Public: true, Commits: fixtureCommits(2),
		Releases: []githubtest.FakeRelease{{Tag: "r1", Published: time.Unix(1, 0)}, {Tag: "r2", Draft: true}}})
	fake.Tag("org/p", "v1.0.0", fmt.Sprintf("%040x", 1))
	nokey, _ := github.NewRepoApp(github.RepoAppConfig{API: fake.URL})
	if _, err := nokey.Reader("org", "p", "9"); !errors.Is(err, github.ErrNoAppKey) {
		t.Fatalf("installation read with no key: %v", err)
	}
	if _, err := nokey.Reader("org", "a/b", ""); err == nil {
		t.Fatal("a slash in the repo name was accepted")
	}
	if _, err := github.NewRepoApp(github.RepoAppConfig{}); err == nil {
		t.Fatal("no API base was accepted")
	}
	rd, _ := nokey.Reader("org", "p", "")
	ctx := context.Background()
	tags, err := rd.Tags(ctx)
	if err != nil || len(tags) != 1 || tags[0].Name != "v1.0.0" {
		t.Fatalf("tags: %+v %v", tags, err)
	}
	rels, err := rd.Releases(ctx)
	if err != nil || len(rels) != 2 || rels[0].TagName != "r1" || !rels[1].Draft {
		t.Fatalf("releases: %+v %v", rels, err)
	}
}

// R7 W1 of SPL-5808 (SPL-6006): the tag list reads past 1000 tags, and a
// repo with more than 5000 is an error, never a silent cut. RED CONTROL:
// tagPages = 10 (part 1's cap) reads 1000 of the 1001 and fails here.
func TestRepoReaderTagsPastAThousand(t *testing.T) {
	fake := githubtest.NewRepos(t)
	fake.Put("org/many", &githubtest.FakeRepo{Public: true, Commits: fixtureCommits(1)})
	fake.Put("org/toomany", &githubtest.FakeRepo{Public: true, Commits: fixtureCommits(1)})
	for i := range 1001 {
		fake.Tag("org/many", fmt.Sprintf("t%05d", i), fmt.Sprintf("%040x", 1))
	}
	for i := range 5001 {
		fake.Tag("org/toomany", fmt.Sprintf("t%05d", i), fmt.Sprintf("%040x", 1))
	}
	app, _ := github.NewRepoApp(github.RepoAppConfig{API: fake.URL})
	ctx := context.Background()
	rd, _ := app.Reader("org", "many", "")
	if tags, err := rd.Tags(ctx); err != nil || len(tags) != 1001 || tags[1000].Name != "t01000" {
		t.Fatalf("1001 tags: read %d, %v; want all 1001", len(tags), err)
	}
	rd, _ = app.Reader("org", "toomany", "")
	if tags, err := rd.Tags(ctx); !errors.Is(err, github.ErrTooManyTags) {
		t.Fatalf("5001 tags: read %d, %v; want ErrTooManyTags", len(tags), err)
	}
}
