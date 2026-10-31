package hub_test

import (
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-4421 (spec 153 3.10, Monitoring -> Topics): each lane row of GET
// /v1/operator/fleet-lanes and GET /v1/view/lanes names its topic's channel,
// from the same DiscussionStates read as the title and behind the same door:
// set where the title is, "" where the title is withheld (another
// workspace's topic, no topic), on a live lane and on a queued ask's row
// alike. RED CONTROL (master): the field is absent, every channel decodes "",
// and the set cases fail.
func TestLanesTopicChannel(t *testing.T) {
	r := newWSLanesRig(t)
	now := time.Now()
	box := r.opBox.id
	laneAt(t, r.fleetTokensRig, "c-601", box, r.t1, "", now.Add(-1*time.Minute))        // w1 #lobby
	laneAt(t, r.fleetTokensRig, "c-602", box, r.privTopic, "", now.Add(-2*time.Minute)) // w1 #b6-private
	laneAt(t, r.fleetTokensRig, "c-603", box, r.opTopic, "", now.Add(-3*time.Minute))   // operator #lobby
	laneAt(t, r.fleetTokensRig, "c-604", box, "", "", now.Add(-4*time.Minute))          // no topic
	queueAsk(t, r, r.opTopic, "QUEUE op lane", "claude:c002-op-lane", 20*time.Minute)   // queued, operator #lobby
	queueAsk(t, r, r.t1, "QUEUE w1 lane", "claude:c002-w1-lane", 10*time.Minute)        // queued, w1 #lobby

	type want struct{ title, channel string }
	check := func(view string, v lanesView, wants map[string]want) {
		t.Helper()
		seen := map[string]bool{}
		for _, l := range v.Lanes {
			key := l.AgentID
			if l.State == "queued" {
				key = l.Scope
			}
			w, ok := wants[key]
			if !ok {
				continue
			}
			seen[key] = true
			if l.TopicTitle != w.title || l.TopicChannel != w.channel {
				t.Errorf("%s %s: title %q channel %q, want %q %q", view, key, l.TopicTitle, l.TopicChannel, w.title, w.channel)
			}
		}
		for id := range wants {
			if !seen[id] {
				t.Errorf("%s: lane %s absent from %v", view, id, laneKeys(v))
			}
		}
	}

	// The workspace view, as the admin who may open the private channel.
	v, _ := wsLanes(t, r, r.w1, r.privMember, 200)
	check("w1 view", v, map[string]want{
		"c-601":         {"W1 build", store.ChannelLobby},
		"c-602":         {"the private channel post", "b6-private"},
		"QUEUE w1 lane": {"W1 build", store.ChannelLobby},
	})
	// The operator view: its own topic titled with its channel; another
	// workspace's topic and no topic: neither title nor channel.
	check("operator view", getLanes(t, r.fleetTokensRig), map[string]want{
		"c-603":         {"Operator only", store.ChannelLobby},
		"QUEUE op lane": {"Operator only", store.ChannelLobby},
		"c-601":         {"", ""},
		"c-602":         {"", ""},
		"c-604":         {"", ""},
		"QUEUE w1 lane": {"", ""},
	})
}
