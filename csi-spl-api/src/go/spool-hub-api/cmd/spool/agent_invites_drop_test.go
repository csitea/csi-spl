package main

import (
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
)

const agentInvitesDropReply = `{"agent":"c-873","box":"box-a","channels":["lobby","ops"]}`

// TestAgentInvitesDropCLI (SPL-6714): `spool agent-invites-drop --agent <id>`
// sends agent_invites_drop {agent, box: this box} and prints the hub's answer
// as is, exit 0. The CONTROL: when the hub does not answer, refuses, or
// answers for another agent or box, it exits non-zero and prints nothing, so
// the retire never reads a failure as dropped.
func TestAgentInvitesDropCLI(t *testing.T) {
	h := newScriptHub(t, laneAnswer(map[string]string{"agent_invites_drop": agentInvitesDropReply}), nil)
	rc, out, errOut := capture(t, "", func() int {
		return cmdAgentInvitesDrop(hubCfg(t, h.URL), []string{"--agent", "c-873"})
	})
	if rc != 0 || out != agentInvitesDropReply+"\n" {
		t.Fatalf("agent-invites-drop: rc %d %q err %q, want 0 %q", rc, out, errOut, agentInvitesDropReply)
	}
	fr := h.Frames()
	if len(fr) != 1 || fr[0].LaneOp != "agent_invites_drop" || string(fr[0].Lane) != `{"agent":"c-873","box":"box-a"}` {
		t.Fatalf("frames = %d %+v, want one agent_invites_drop {agent: c-873, box: box-a}", len(fr), fr)
	}

	gone := httptest.NewServer(nil)
	gone.Close() // CONTROL: the hub does not answer
	refuse := newScriptHub(t, laneAnswer(nil), nil)
	other := newScriptHub(t, laneAnswer(map[string]string{"agent_invites_drop": `{"agent":"c-873","box":"box-b","channels":[]}`}), nil)
	partial := newScriptHub(t, laneAnswer(map[string]string{"agent_invites_drop": `{"agent":"c-873","box":"box-a"}`}), nil)
	for _, c := range []struct {
		name string
		url  string
		args []string
		want string
	}{
		{"hub does not answer", gone.URL, []string{"--agent", "c-873"}, ""},
		{"hub refuses", refuse.URL, []string{"--agent", "c-873"}, "bad_lane_op"},
		{"answer for another box", other.URL, []string{"--agent", "c-873"}, "not an invites drop"},
		{"answer without channels", partial.URL, []string{"--agent", "c-873"}, "not an invites drop"},
		{"local mode", "", []string{"--agent", "c-873"}, "needs hub mode"},
		{"no agent", refuse.URL, nil, "usage: spool agent-invites-drop"},
		{"extra argument", refuse.URL, []string{"--agent", "c-873", "x"}, "usage: spool agent-invites-drop"},
		{"not an agent id", refuse.URL, []string{"--agent", "HUM-1"}, "must be an agent id"},
	} {
		cfg := testkit.NewConfig(t)
		if c.url != "" {
			cfg = hubCfg(t, c.url)
		}
		rc, out, errOut := capture(t, "", func() int { return cmdAgentInvitesDrop(cfg, c.args) })
		if rc == 0 || out != "" || !strings.Contains(errOut, c.want) {
			t.Errorf("%s: rc %d out %q err %q, want non-zero naming %q", c.name, rc, out, errOut, c.want)
		}
	}
	if n := len(refuse.Frames()); n != 1 {
		t.Errorf("refusing hub read %d frames, want 1 (usage errors are refused before dialling)", n)
	}
}
