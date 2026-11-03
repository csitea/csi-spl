package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// SPL-4725: a create that names no priority inherits the highest priority SET
// on its linked discussions, else its class label's (bug and alert 1,
// refactor 2), else 5; a named priority always wins (issue_prio_default.go).
// Red control: set issueClassPriority["bug"] to 5 and C1 fails.
func TestIssuePriorityDefault(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	for _, l := range []string{"bug", "refactor", "alert", "feature"} {
		if code, out := call(t, e, tid, http.MethodPost, "/v1/issue-labels", dev, map[string]string{"name": l}); code != http.StatusCreated {
			t.Fatalf("label %s: %d %v", l, code, out)
		}
	}
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "epic", "kind": "epic"}); code != http.StatusCreated {
		t.Fatalf("epic: %d %v", code, out)
	}
	topic := func(prio int) string {
		task := uid.New()
		lobbyTopic(t, e, tid, task, "## talk")
		if prio > 0 {
			if _, err := e.st.(store.TopicPriorityStore).SetTopicPriority(context.Background(), tid, task, prio, "HUM-1", time.Now()); err != nil {
				t.Fatal(err)
			}
		}
		return task
	}
	unset, set1, set3, set4 := topic(0), topic(1), topic(3), topic(4)
	cases := []struct {
		name   string
		labels []string
		disc   []string
		prio   any
		want   float64
	}{
		{"C1 bug, unset discussion", []string{"bug"}, []string{unset}, nil, 1},
		{"C1 refactor", []string{"refactor"}, []string{unset}, nil, 2},
		{"C1 alert", []string{"alert"}, []string{unset}, nil, 1},
		{"C1 bug + refactor: the highest", []string{"refactor", "bug"}, []string{unset}, nil, 1},
		{"C1 feature: today's default", []string{"feature"}, []string{unset}, nil, 5},
		{"C1 no class", nil, []string{unset}, nil, 5},
		{"C2 a set discussion beats the class", []string{"bug"}, []string{set4}, nil, 4},
		{"C2 a set 3 counts as set", []string{"refactor"}, []string{set3}, nil, 3},
		{"C2 several discussions: the highest set", nil, []string{unset, set4, set3}, nil, 3},
		{"C2 several, one set 1", []string{"refactor"}, []string{set4, set1}, nil, 1},
		{"C3 an explicit priority wins", []string{"bug"}, []string{set1}, 5, 5},
		{"C3 an explicit priority wins over a class", []string{"refactor"}, []string{unset}, 4, 4},
	}
	for _, c := range cases {
		b := map[string]any{"title": c.name, "epic": "SPL-1", "discussions": c.disc}
		if c.labels != nil {
			b["labels"] = c.labels
		}
		if c.prio != nil {
			b["priority"] = c.prio
		}
		code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, b)
		if code != http.StatusCreated {
			t.Fatalf("%s: %d %v", c.name, code, out)
		}
		if got := issueOf(t, out)["priority"]; got != c.want {
			t.Errorf("%s: priority %v, want %v", c.name, got, c.want)
		}
	}
}
