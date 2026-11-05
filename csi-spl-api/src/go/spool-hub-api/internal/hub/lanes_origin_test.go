package hub_test

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Spec 153 section 3.12 (SPL-4620; owner HUM-10, t1 4e9f7153, msg 9a89d1e1):
// a lane row names the issue it came from, and a report task's relay hash
// resolves to the discussion it is the hash of, never stored as a topic.
// Memory, and Postgres under SPOOL_TEST_PG_DSN.

// hashOf is spool-fleet-relay.sh's name-to-uuid, written out so the test
// breaks when the hub's copy drifts from it.
func hashOf(name string) string {
	return uuid.NewSHA1(uuid.NameSpaceURL, []byte("spool-task:"+name)).String()
}

// C54: a put names its origin issue; the list answers it, a bad key is
// refused, and a put with none stores none. RED CONTROL (master 06c1fa804):
// the row had no such field, so SPL-4420 was lost.
func TestLanePutCarriesOriginIssue(t *testing.T) {
	r := newFleetTokensRig(t)
	row := func(id, origin string) string {
		return `{"agent_id":"` + id + `","agent_box":"` + r.opBox.id + `","state":"live","files":[],"topic":"t-1","issue_key":"SPL-4490","origin_issue":"` + origin + `"}`
	}
	if got, err := lanePut(t, r.opBox, row("c-461", "SPL-4420")); err != nil || got.OriginIssue != "SPL-4420" || got.IssueKey != "SPL-4490" {
		t.Errorf("C54 put: %+v %v, want origin SPL-4420 next to own SPL-4490", got, err)
	}
	if got, err := lanePut(t, r.opBox, row("c-462", "")); err != nil || got.OriginIssue != "" {
		t.Errorf("C54 no origin is none, never a guess: %+v %v", got, err)
	}
	if _, err := lanePut(t, r.opBox, row("c-463", "not a key")); err == nil {
		t.Error("C54b a bad origin key must be refused")
	}
}

// C55: the view links the origin issue with its status; none is absent; a key
// of another prefix goes with no status (the page shows it as text).
func TestFleetLanesOriginIssue(t *testing.T) {
	r := newFleetTokensRig(t)
	if code, out := call(t, r.e, r.op, http.MethodPost, "/v1/issues", r.admin, map[string]any{"title": "origin", "status": "wip"}); code != http.StatusCreated {
		t.Fatalf("issue: %d %v", code, out)
	}
	for id, origin := range map[string]string{"c-471": "SPL-1", "c-472": "", "c-473": "OPS-9"} {
		if _, err := lanePut(t, r.opBox, `{"agent_id":"`+id+`","agent_box":"`+r.opBox.id+`","state":"live","files":[],"topic":"t-1","issue_key":"SPL-2","origin_issue":"`+origin+`"}`); err != nil {
			t.Fatal(err)
		}
	}
	code, body := call(t, r.e, r.op, http.MethodGet, fleetLanesPath, r.admin, nil)
	if code != http.StatusOK {
		t.Fatalf("GET: %d %v", code, body)
	}
	raw, _ := json.Marshal(body["lanes"])
	var rows []struct {
		AgentID     string `json:"agent_id"`
		Workspace   string `json:"workspace"`
		OriginIssue *struct {
			Key    string `json:"key"`
			Status string `json:"status"`
		} `json:"origin_issue"`
	}
	if err := json.Unmarshal(raw, &rows); err != nil {
		t.Fatal(err)
	}
	seen := 0
	for _, l := range rows {
		if !r.ws[l.Workspace] { // another test's workspace on a shared Postgres (3.17)
			continue
		}
		switch l.AgentID {
		case "c-471":
			seen++
			if l.OriginIssue == nil || l.OriginIssue.Key != "SPL-1" || l.OriginIssue.Status == "" {
				t.Errorf("C55 own prefix: %+v, want SPL-1 with its status", l.OriginIssue)
			}
		case "c-472":
			seen++
			if l.OriginIssue != nil {
				t.Errorf("C55 no origin: %+v, want absent", l.OriginIssue)
			}
		case "c-473":
			seen++
			if l.OriginIssue == nil || l.OriginIssue.Key != "OPS-9" || l.OriginIssue.Status != "" {
				t.Errorf("C55 another prefix: %+v, want OPS-9 with no status", l.OriginIssue)
			}
		}
	}
	if seen != 3 {
		t.Fatalf("saw %d of the 3 lanes: %s", seen, raw)
	}
}

// C56: dispatch-<topic8> as 8 hex and as its relay hash both resolve to the
// full topic uuid; C56b: the hash of a name that is no topic stores nothing,
// so a lane's topic is never a relay task's hash (3.11, R7 c-287 W1). RED
// CONTROL (master 06c1fa804): C56b stored the hash as sent, and the hash of
// dispatch-<topic8> never found its topic.
func TestLanePutRelayHashResolves(t *testing.T) {
	r := newFleetTokensRig(t)
	talk := uid.New()
	lobbyTopic(t, r.e, r.op, talk, "## Lane origin\n\nthe topic")
	put := func(id, topic string) string {
		t.Helper()
		got, err := lanePut(t, r.opBox, `{"agent_id":"`+id+`","agent_box":"`+r.opBox.id+`","state":"live","files":[],"issue_key":"SPL-1","topic":"`+topic+`"}`)
		if err != nil {
			t.Fatal(err)
		}
		return got.Topic
	}
	if got := put("c-481", talk[:8]); got != talk {
		t.Errorf("C56 dispatch-<topic8>, sent as its 8 hex: %q, want %s", got, talk)
	}
	if got := put("c-482", hashOf("dispatch-"+talk[:8])); got != talk {
		t.Errorf("C56 its relay hash: %q, want %s", got, talk)
	}
	// rdb 0263: a lane with no discussion is refused, never stored without one
	if got, err := lanePut(t, r.opBox, `{"agent_id":"c-483","agent_box":"`+r.opBox.id+`","state":"live","files":[],"issue_key":"SPL-1","topic":"`+hashOf("dispatch-r47")+`"}`); err == nil || !strings.Contains(err.Error(), "names no single discussion") {
		t.Errorf("C56b the hash of a name that is no topic: stored %q (%v), want refused", got.Topic, err)
	}
	if got := put("c-484", talk); got != talk {
		t.Errorf("C56c a full topic uuid stays: %q, want %s", got, talk)
	}
}
