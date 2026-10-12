package hub_test

import (
	"net/http"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Owner, t1 c9beaa77 (msg 25e9d4bc): /search?q=type:msg SPAWN REQUEST
// listed the fleet's relayed agent-to-agent mail. The hub hides it unless
// the query asks (is:relay, from:, to:, topic:); a human's DM stays.
func TestSearchHidesAgentRelay(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.SearchRatePerMin = 1000
		o.Authorizer = rbac.Fixed(rbac.Developer)
		o.SessionID = func(r *http.Request, _ string) (string, error) { return r.Header.Get("X-Test-Human"), nil }
	})
	ta, _ := e.tenant()
	now := time.Now().UTC().Truncate(time.Microsecond)
	relay := putMsg(t, e.st, ta, uuidV4(), "", "c-001", "box-a", "c-001", "from_agent: c-001@box-a\nSPAWN REQUEST one lane", now.Add(-2*time.Minute), "")
	human := putMsg(t, e.st, ta, uuidV4(), "", "HUM-10", "box-wui", "c-001", "SPAWN REQUEST please", now.Add(-time.Minute), "")
	msgs := func(q string, hdr ...string) []string {
		t.Helper()
		code, _, r, _ := searchGet(t, e, ta, q, "", hdr...)
		if code != http.StatusOK {
			t.Fatalf("%q: %d", q, code)
		}
		var ids []string
		for _, m := range r.Groups["messages"].Results {
			ids = append(ids, m["msg_id"].(string))
		}
		return ids
	}
	for q, want := range map[string][]string{
		"type:msg SPAWN REQUEST":   {human.MsgID},
		"SPAWN REQUEST":            {human.MsgID},
		"is:relay SPAWN REQUEST":   {relay.MsgID},
		"from:c-001 SPAWN REQUEST": {relay.MsgID},
		"to:c-001 SPAWN REQUEST":   {human.MsgID, relay.MsgID},
	} {
		if got := msgs(q); !slices.Equal(got, want) {
			t.Errorf("%q: %v, want %v", q, got, want)
		}
	}
	// a member reader: the same rule over the read door
	if got := msgs("SPAWN REQUEST", "X-Test-Human", "HUM-10"); !slices.Equal(got, []string{human.MsgID}) {
		t.Errorf("HUM-10: %v", got)
	}
	// the topics section: the relay-only topic is not listed
	_, _, r, _ := searchGet(t, e, ta, "type:topic SPAWN", "")
	for _, th := range r.Groups["topics"].Results {
		if th["task_id"] == relay.TaskID {
			t.Errorf("relay topic listed: %+v", th)
		}
	}
}
