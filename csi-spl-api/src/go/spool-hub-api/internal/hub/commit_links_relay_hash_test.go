package hub

import (
	"strconv"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-5126: a version-5 uuid is the hash a relay makes of a task name, never a
// discussion. The answer says so in relay_hash_only; Discussions still counts
// it, so a check that does not read the new field behaves as before.
func TestCommitLinksRelayHashOnly(t *testing.T) {
	const (
		hash  = "11111111-2222-5333-8444-555555555555"
		topic = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
	)
	def := store.IssueDiscussionDefault("t1")
	link := func(ids ...string) []store.IssueDiscussion {
		out := []store.IssueDiscussion{}
		for _, id := range ids {
			out = append(out, store.IssueDiscussion{TaskID: id})
		}
		return out
	}
	cases := []struct {
		name  string
		links []store.IssueDiscussion
		n     int
		only  bool
	}{
		{"hash alone", link(hash), 1, true},
		{"default and hash", link(def, hash), 1, true},
		{"real alone", link(topic), 1, false}, // CONTROL: a version-4 topic
		{"hash and real", link(hash, topic), 2, false},
		{"default only", link(def), 0, false}, // default_only says it, not this
	}
	for k, c := range cases {
		key := "SPL-" + strconv.Itoa(k+1)
		got := commitLinks("t1", []string{key}, map[int][]store.IssueDiscussion{k + 1: c.links})[0]
		if got.Discussions != c.n || got.RelayHashOnly != c.only {
			t.Errorf("%s: discussions %d relay_hash_only %v, want %d %v", c.name, got.Discussions, got.RelayHashOnly, c.n, c.only)
		}
	}
	if got := commitLinks("t1", []string{"SPL-9"}, nil)[0]; got.Found || got.RelayHashOnly {
		t.Errorf("no issue: %+v", got)
	}
}
