package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
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

// TestLaneRetiredIDDoneOnly (SPL-4962): past the spec 061 deadline `spool lane`
// sends a done write on a retired id as written; live stays refused before
// anything is sent (CONTROL).
func TestLaneRetiredIDDoneOnly(t *testing.T) {
	old := agentid.Now
	t.Cleanup(func() { agentid.Now = old })
	agentid.Now = func() time.Time { return agentid.LegacyUntil.Add(time.Second) }
	h := newScriptHub(t, laneAnswer(map[string]string{"put": `{"fleet":"main","lanes":[]}`}), nil)
	cfg := hubCfg(t, h.URL)
	base := []string{"--fleet", "main", "--agent", "CLE-100006", "--box", "box-a", "--topic", "unknown", "--issue", "unknown"}

	rc, _, errOut := capture(t, "", func() int { return cmdLane(cfg, append(append([]string{}, base...), "--state", "live")) })
	if rc != 1 || !strings.Contains(errOut, "CLE-100006 is retired as an id") || len(h.Frames()) != 0 {
		t.Fatalf("live: rc %d %q, %d frames, want rc 1 refused locally", rc, errOut, len(h.Frames()))
	}
	rc, _, errOut = capture(t, "", func() int { return cmdLane(cfg, append(append([]string{}, base...), "--state", "done")) })
	if rc != 0 {
		t.Fatalf("done: rc %d %q", rc, errOut)
	}
	fr := h.Frames()
	var row map[string]any
	if err := json.Unmarshal(fr[len(fr)-1].Lane, &row); err != nil {
		t.Fatal(err)
	}
	if row["agent_id"] != "CLE-100006" || row["state"] != "done" {
		t.Errorf("done row %v, want CLE-100006 done", row)
	}
}

// TestLaneListState (SPL-4630): `spool lane --fleet main --state live` lists
// with the lane {"state":"live"}, which the hub filters on; a list with no
// --state sends no lane object, so it reads every row (CONTROL: the write's
// default state live does not leak into the list).
func TestLaneListState(t *testing.T) {
	h := newScriptHub(t, laneAnswer(map[string]string{"list": `{"fleet":"main","lanes":[]}`}), nil)
	cfg := hubCfg(t, h.URL)
	for _, c := range []struct {
		name string
		args []string
		want string
	}{
		{"--state live", []string{"--fleet", "main", "--state", "live"}, `{"state":"live"}`},
		{"--state done", []string{"--fleet", "main", "--state", "done"}, `{"state":"done"}`},
		{"control: no --state", []string{"--fleet", "main"}, ""},
	} {
		rc, _, errOut := capture(t, "", func() int { return cmdLane(cfg, c.args) })
		if rc != 0 {
			t.Fatalf("%s: rc %d err %q", c.name, rc, errOut)
		}
		fr := h.Frames()
		if last := fr[len(fr)-1]; last.LaneOp != "list" || string(last.Lane) != c.want {
			t.Errorf("%s: op %s lane %s, want list %s", c.name, last.LaneOp, last.Lane, c.want)
		}
	}
}
