package auth

import "testing"

// SPL-1990 (owner HUM-10, t1 dbf2f39b): Monitoring is a rail entry. An order
// holding it is admitted, every order stored before it still is, and a set
// the DB check (rdb 0198) refuses is refused here too. Red control: on the
// RailTabs before SPL-1990 the "twelve with monitoring" row fails.
func TestIsRailOrderMonitoring(t *testing.T) {
	eleven := []string{"calendar", "boxes", "agents", "people", "events", "archive", "flow", "topics", "issues", "channels", "dm"}
	for _, c := range []struct {
		name  string
		order []string
		want  bool
	}{
		{"twelve with monitoring", append([]string{"monitoring"}, eleven...), true},
		{"eleven, stored before monitoring", eleven, true},
		{"ten, stored before calendar", eleven[1:], true},
		{"the legacy six", []string{"events", "flow", "topics", "issues", "channels", "dm"}, true},
		{"monitoring without calendar", append([]string{"monitoring"}, eleven[1:]...), false},
		{"monitoring twice", append([]string{"monitoring", "monitoring"}, eleven...), false},
		{"twelve with hours", append([]string{"hours"}, eleven...), false},
		{"twelve with an unknown", append([]string{"gauges"}, eleven...), false},
	} {
		if got := IsRailOrder(c.order); got != c.want {
			t.Errorf("%s: IsRailOrder = %v, want %v", c.name, got, c.want)
		}
	}
	if RailTabs[len(RailTabs)-1] != "monitoring" {
		t.Errorf("RailTabs ends with %q, want monitoring last", RailTabs[len(RailTabs)-1])
	}
}
