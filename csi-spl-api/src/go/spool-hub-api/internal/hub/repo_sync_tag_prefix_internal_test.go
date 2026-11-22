package hub

import (
	"context"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
)

// tagsOnly is a RepoSyncReader that answers only its tags and releases.
type tagsOnly struct {
	RepoSyncReader
	tags []github.RepoTag
	rels []github.RepoRelease
}

func (r tagsOnly) Tags(context.Context) ([]github.RepoTag, error)         { return r.tags, nil }
func (r tagsOnly) Releases(context.Context) ([]github.RepoRelease, error) { return r.rels, nil }

// A repo whose tags carry a path prefix (shop-wui/vX.Y.Z,
// SPL-6277): the glob shop-wui/v* matches them and each version is the
// tag after its last /, since a stored version holds no / (rdb 0267).
// RED CONTROL: store tg.Name whole and the versions read app/v1.0.0.
func TestRepoVersionTagsPathPrefix(t *testing.T) {
	rd := tagsOnly{
		tags: []github.RepoTag{
			{Name: "app/v1.1.0", SHA: "b"}, {Name: "app/v1.0.0", SHA: "a"}, {Name: "app/v1.0.1", SHA: "a"},
			{Name: "other/v9.0.0", SHA: "c"}, {Name: "v8.0.0", SHA: "d"}, {Name: "rel/2026.11.05", SHA: "e"},
		},
		rels: []github.RepoRelease{{TagName: "rel/2026.11.05"}},
	}
	got, err := repoVersionTags(context.Background(), rd, "app/v*", nil)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"a": "v1.0.0", "b": "v1.1.0", "e": "2026.11.05"}
	if len(got) != len(want) {
		t.Fatalf("versions %v, want %v", got, want)
	}
	for sha, v := range want {
		if got[sha] != v {
			t.Errorf("%s -> %q, want %q (all: %v)", sha, got[sha], v, got)
		}
	}
}
