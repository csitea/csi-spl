package search

import (
	"testing"
	"time"
)

// Owner, t1 c9beaa77: agent-to-agent mail is out of a search unless the query
// asks for it (Query.Relay): is:relay, or a positive from:, to: or topic:.
func TestQueryRelay(t *testing.T) {
	now := time.Date(2026, 10, 12, 0, 0, 0, 0, time.UTC)
	for q, want := range map[string]bool{
		"type:msg SPAWN REQUEST": false,
		"SPAWN REQUEST":          false,
		"is:task deploy":         false,
		"is:relay":               true,
		"is:relay SPAWN":         true,
		"-is:relay SPAWN":        false,
		"from:c-001 SPAWN":       true,
		"to:c-001":               true,
		"-from:c-001 SPAWN":      false,
		"deploy OR from:c-001":   true,
		"topic:6f1c2a0e-5b7d-4c1e-9a8b-2d3e4f5a6b7c": true,
	} {
		p, err := Parse(q, now)
		if err != nil {
			t.Fatalf("%q: %v", q, err)
		}
		if p.Relay != want {
			t.Errorf("%q: Relay %v, want %v", q, p.Relay, want)
		}
	}
	p, _ := Parse("is:relay", now)
	if len(p.Types) != 1 || p.Types[0] != TypeMessage {
		t.Fatalf("is:relay types: %v", p.Types)
	}
}

func TestRelayMsg(t *testing.T) {
	for _, c := range []struct {
		m    Msg
		want bool
	}{
		{Msg{FromID: "c-001", ToID: "c-001"}, true},
		{Msg{FromID: "c-002", ToID: "c-522"}, true},
		{Msg{FromID: "HUM-10", ToID: "c-001"}, false},
		{Msg{FromID: "c-001", ToID: "HUM-10"}, false},
		{Msg{FromID: "GST-1", ToID: "c-001"}, false},
		{Msg{FromID: "c-001", ToID: "ALL-0"}, false},
		{Msg{Channel: "tasks", FromID: "c-001", ToID: "c-002"}, false},
	} {
		if got := Relay(c.m); got != c.want {
			t.Errorf("%+v: %v, want %v", c.m, got, c.want)
		}
	}
}
