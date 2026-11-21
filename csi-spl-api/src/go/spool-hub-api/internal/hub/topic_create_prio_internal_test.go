package hub

import "testing"

// SPL-6145 (spec 150 section 3.3.1): the trailing prio token of a new
// topic's first post. RED CONTROL: on origin/master createPrioSuffix does
// not exist and this file does not build; make the regexp's leading
// (^|\s) optional and the "xprio:1" case goes red.
func TestCreatePrioSuffix(t *testing.T) {
	cases := []struct {
		in, body string
		prio     int
	}{
		{"fix the login prio:1", "fix the login", 1},
		{"fix the login prio:01", "fix the login", 1},
		{"fix the login prio:2", "fix the login", 2},
		{"fix the login prio:02", "fix the login", 2},
		{"fix the login prio:3", "fix the login", 3},
		{"fix the login prio-04", "fix the login", 4},
		{"fix the login prio-4", "fix the login", 4},
		{"fix the login prio 5", "fix the login", 5},
		{"fix the login prio 05", "fix the login", 5},
		{"fix the login PRIO:01", "fix the login", 1},
		{"fix the login Prio-2", "fix the login", 2},
		{"fix the login prio:1  \n", "fix the login", 1},
		{"line one\nline two\nprio:2", "line one\nline two", 2},
		{"a list:\n- x\n\nprio 4", "a list:\n- x", 4},
		// rejects: plain text, the default stays
		{"fix the login prio:6", "", 0},
		{"fix the login prio:0", "", 0},
		{"fix the login prio:00", "", 0},
		{"fix the login prio:005", "", 0},
		{"fix the login prio:10", "", 0},
		{"fix the login prio:", "", 0},
		{"fix the login prio: 2", "", 0},
		{"prio:1 fix the login", "", 0},
		{"fix prio:1 the login", "", 0},
		{"fix the login xprio:1", "", 0},
		{"fix the login (prio:1)", "", 0},
		{"fix the login prio:1.", "", 0},
		{"fix the login prio_1", "", 0},
		{"fix the login priority:1", "", 0},
		{"prio:1", "", 0},
		{"  prio-2 ", "", 0},
		{"a reply quotes:\n> prio:1", "", 0},
		{"see `prio:1`", "", 0},
		{"see:\n```\nprio:1\n```", "", 0},
		{"see:\n```\nprio:1", "", 0},
	}
	for _, c := range cases {
		body, prio := createPrioSuffix(c.in)
		want := c.body
		if c.prio == 0 {
			want = c.in
		}
		if prio != c.prio || body != want {
			t.Errorf("createPrioSuffix(%q) = (%q, %d), want (%q, %d)", c.in, body, prio, want, c.prio)
		}
	}
}
