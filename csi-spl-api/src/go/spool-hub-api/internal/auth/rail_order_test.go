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
	if !isPermutation(append([]string{"notes", "reporting", "monitoring"}, eleven...), RailTabs) {
		t.Errorf("RailTabs = %v, want the eleven plus monitoring, reporting and notes", RailTabs)
	}
}

// SPL-2587 (spec 143 1.1): Reporting is a rail entry. An order holding it is
// admitted, every order stored before it still is, and a set the DB check
// (rdb 0209) refuses is refused here too. Red control: on the RailTabs before
// SPL-2587 the "thirteen with reporting" row fails.
func TestIsRailOrderReporting(t *testing.T) {
	twelve := []string{"monitoring", "calendar", "boxes", "agents", "people", "events", "archive", "flow", "topics", "issues", "channels", "dm"}
	for _, c := range []struct {
		name  string
		order []string
		want  bool
	}{
		{"thirteen with reporting", append([]string{"reporting"}, twelve...), true},
		{"twelve, stored before reporting", twelve, true},
		{"eleven, stored before monitoring", twelve[1:], true},
		{"reporting without monitoring", append([]string{"reporting"}, twelve[1:]...), false},
		{"reporting twice", append([]string{"reporting", "reporting"}, twelve...), false},
		{"thirteen with an unknown", append([]string{"gauges"}, twelve...), false},
		{"thirteen with hours", append([]string{"hours"}, twelve...), false},
	} {
		if got := IsRailOrder(c.order); got != c.want {
			t.Errorf("%s: IsRailOrder = %v, want %v", c.name, got, c.want)
		}
	}
	if !isPermutation(append([]string{"notes", "reporting"}, twelve...), RailTabs) {
		t.Errorf("RailTabs = %v, want the twelve plus reporting and notes", RailTabs)
	}
}

// SPL-3223 (spec 155 B1, case C1): Notes is a rail entry. A 14-id order holding
// it is admitted, every order stored before it still is, and a set the DB
// check (rdb 0224) refuses is refused here too. Red control: on the RailTabs
// before SPL-3223 the "fourteen with notes" row fails.
func TestIsRailOrderNotes(t *testing.T) {
	thirteen := []string{"reporting", "monitoring", "calendar", "boxes", "agents", "people", "events", "archive", "flow", "topics", "issues", "channels", "dm"}
	for _, c := range []struct {
		name  string
		order []string
		want  bool
	}{
		{"fourteen with notes", append([]string{"notes"}, thirteen...), true},
		{"thirteen, stored before notes", thirteen, true},
		{"twelve, stored before reporting", thirteen[1:], true},
		{"notes without reporting", append([]string{"notes"}, thirteen[1:]...), false},
		{"notes twice", append([]string{"notes", "notes"}, thirteen...), false},
		{"fourteen with an unknown", append([]string{"gauges"}, thirteen...), false},
		{"fifteen with notes and an unknown", append([]string{"gauges", "notes"}, thirteen...), false},
	} {
		if got := IsRailOrder(c.order); got != c.want {
			t.Errorf("%s: IsRailOrder = %v, want %v", c.name, got, c.want)
		}
	}
	if RailTabs[len(RailTabs)-1] != "notes" {
		t.Errorf("RailTabs ends with %q, want notes last", RailTabs[len(RailTabs)-1])
	}
}
