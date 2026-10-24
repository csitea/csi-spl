package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// TestLanePutCarriesIssue: `spool lane --issue SPL-1` puts a row carrying
// issue_key (spec 153 3.4); without the flag the key is "" (CONTROL), and a
// key the hub would refuse is refused before anything is sent.
func TestLanePutCarriesIssue(t *testing.T) {
	h := newScriptHub(t, laneAnswer(map[string]string{"put": `{"fleet":"main","lanes":[]}`}), nil)
	cfg := hubCfg(t, h.URL)
	base := []string{"--fleet", "main", "--agent", "c-001", "--box", "box-a", "--topic", "5e7b15c9"}
	for _, c := range []struct {
		name string
		args []string
		want string
	}{
		{"with --issue", append(append([]string{}, base...), "--issue", "SPL-1"), "SPL-1"},
		{"control: no --issue", base, ""},
	} {
		rc, _, errOut := capture(t, "", func() int { return cmdLane(cfg, c.args) })
		if rc != 0 {
			t.Fatalf("%s: rc %d err %q", c.name, rc, errOut)
		}
		fr := h.Frames()
		last := fr[len(fr)-1]
		var row map[string]any
		if err := json.Unmarshal(last.Lane, &row); err != nil {
			t.Fatalf("%s: row %s (%v)", c.name, last.Lane, err)
		}
		if got, ok := row["issue_key"]; !ok || got != c.want || last.LaneOp != "put" {
			t.Errorf("%s: op %s issue_key %v (present %v), want %q", c.name, last.LaneOp, got, ok, c.want)
		}
	}
	n := len(h.Frames())
	bad := append(append([]string{}, base...), "--issue", "spl 1")
	rc, _, errOut := capture(t, "", func() int { return cmdLane(cfg, bad) })
	if rc != 1 || !strings.Contains(errOut, "issue_key must be an issue key") || len(h.Frames()) != n {
		t.Errorf("bad key: rc %d %q, %d frames sent, want rc 1 refused locally", rc, errOut, len(h.Frames())-n)
	}
}
