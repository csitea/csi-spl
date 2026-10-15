package hub

import (
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// FleetSurgeIDOf is the alert msg_id of a surge of agent on box ending at
// end, for the external tests.
func FleetSurgeIDOf(box, agent string, end time.Time) string {
	var sg fleetTokenSurge
	sg.box, sg.agent = box, agent
	sg.minutes[fleetTokenSurgeMinutes-1].Minute = end
	return fleetSurgeID(sg)
}

// spec 140 4.4.2: the newest run of 3 consecutive minutes above 60k fresh
// tokens is the surge; a gap minute or a minute at or below 60k breaks it,
// and cache reads never count.
func TestLatestFleetSurge(t *testing.T) {
	m0 := time.Date(2026, 10, 15, 10, 0, 0, 0, time.UTC)
	b := func(min int, fresh, cacheRead int64) store.FleetTokenBucket {
		return store.FleetTokenBucket{BoxTag: "sat", AgentID: "c-1", Vendor: "claude", Model: "claude-opus-5-5",
			Minute: m0.Add(time.Duration(min) * time.Minute), TokensIn: fresh, CacheRead: cacheRead, IsMetered: true}
	}
	cases := []struct {
		name string
		rs   []store.FleetTokenBucket
		end  int // -1 = no surge
	}{
		{"three above", []store.FleetTokenBucket{b(0, 64200, 0), b(1, 71500, 0), b(2, 68900, 0)}, 2},
		{"two then a drop", []store.FleetTokenBucket{b(0, 65000, 0), b(1, 65000, 0), b(2, 20000, 0)}, -1},
		{"only two", []store.FleetTokenBucket{b(0, 65000, 0), b(1, 65000, 0)}, -1},
		{"a gap minute", []store.FleetTokenBucket{b(0, 65000, 0), b(1, 65000, 0), b(3, 65000, 0)}, -1},
		{"exactly 60k is not above", []store.FleetTokenBucket{b(0, 60000, 0), b(1, 65000, 0), b(2, 65000, 0)}, -1},
		{"cache reads do not count", []store.FleetTokenBucket{b(0, 100, 900000), b(1, 100, 900000), b(2, 100, 900000)}, -1},
		{"the newest of two runs", []store.FleetTokenBucket{b(0, 61000, 0), b(1, 61000, 0), b(2, 61000, 0), b(3, 61000, 0)}, 3},
	}
	for _, c := range cases {
		sg, ok := latestFleetSurge(c.rs)
		switch {
		case c.end < 0 && ok:
			t.Errorf("%s: surge %+v, want none", c.name, sg)
		case c.end >= 0 && (!ok || !sg.minutes[2].Minute.Equal(m0.Add(time.Duration(c.end)*time.Minute))):
			t.Errorf("%s: %v %+v, want a surge ending at minute %d", c.name, ok, sg, c.end)
		}
	}
	sg, _ := latestFleetSurge(cases[0].rs)
	sg.minutes[0].CostMicros, sg.minutes[0].Priced, sg.minutes[0].Currency = 480000, true, "USD"
	body := fleetSurgeBody(sg)
	for _, want := range []string{":warning: **Fleet Token Surge Alert**", "Agent `c-1` (`claude` / `claude-opus-5-5`) on box `sat`",
		"3 consecutive minutes", "- Minute 1 (10:00Z): 64,200 fresh tokens/min", "- Minute 3 (10:02Z): 68,900", "Cumulative cost in window: USD 0.48."} {
		if !strings.Contains(body, want) {
			t.Errorf("body lacks %q:\n%s", want, body)
		}
	}
	if groupDigits(1234567) != "1,234,567" || groupDigits(999) != "999" || groupDigits(0) != "0" {
		t.Error("groupDigits")
	}
	if id := fleetSurgeID(sg); len(id) != 36 || !uuidRe.MatchString(id) || id != FleetSurgeIDOf("sat", "c-1", sg.minutes[2].Minute) {
		t.Errorf("surge id %q", id)
	}
}
