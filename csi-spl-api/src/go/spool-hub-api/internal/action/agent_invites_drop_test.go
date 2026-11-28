package action

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 061 3.6 (SPL-6714): AgentInvitesDrop sends one agent_invites_drop
// lane frame {agent, box} and accepts only that agent's and box's answer.

// invitesHub answers every lane frame with answer.
func invitesHub(t *testing.T, answer string) *opHub {
	t.Helper()
	return newOpHub(t, func(f wire.Frame) wire.Frame {
		if f.Type != wire.TLane {
			return wire.Frame{Type: wire.TError, Error: "unexpected_frame"}
		}
		return wire.Frame{Type: wire.TLane, MsgID: f.MsgID, Lane: json.RawMessage(answer)}
	})
}

// TestAgentInvitesDropSent: the frame carries the op and {agent, box}, and
// the hub's answer comes back as is.
func TestAgentInvitesDropSent(t *testing.T) {
	want := `{"agent":"c-007","box":"box-a","channels":["ops"]}`
	h := invitesHub(t, want)
	cfg := opCfg(t, h.url)
	out, err := AgentInvitesDrop(context.Background(), cfg, AgentInvitesDropArgs{Agent: "c-007"})
	if err != nil || string(out) != want {
		t.Fatalf("got %s, %v; want %s", out, err, want)
	}
	fs := h.of(wire.TLane)
	if len(fs) != 1 || fs[0].LaneOp != "agent_invites_drop" || fs[0].Fleet != "" {
		t.Fatalf("frames %+v", fs)
	}
	var row map[string]string
	if err := json.Unmarshal(fs[0].Lane, &row); err != nil || row["agent"] != "c-007" || row["box"] != "box-a" || len(row) != 2 {
		t.Fatalf("row %s, %v", fs[0].Lane, err)
	}
}

// TestAgentInvitesDropRefused: no hub mode or a non-agent id never dials.
func TestAgentInvitesDropRefused(t *testing.T) {
	h := invitesHub(t, `{}`)
	cfg := opCfg(t, h.url)
	if out, err := AgentInvitesDrop(context.Background(), cfg, AgentInvitesDropArgs{Agent: "not an id"}); err == nil || !strings.Contains(err.Error(), "--agent must be an agent id") || out != nil {
		t.Fatalf("bad id: got %s, %v", out, err)
	}
	cfg.HubURL = ""
	if out, err := AgentInvitesDrop(context.Background(), cfg, AgentInvitesDropArgs{Agent: "c-007"}); err == nil || !strings.Contains(err.Error(), "needs hub mode") || out != nil {
		t.Fatalf("no hub: got %s, %v", out, err)
	}
	if n := len(h.of("")); n != 0 {
		t.Errorf("the hub received %d frames for refused requests", n)
	}
}

// TestAgentInvitesDropBadAnswer: an answer for another agent or box, or one
// without channels, or a hub error, is an error.
func TestAgentInvitesDropBadAnswer(t *testing.T) {
	for name, answer := range map[string]string{
		"no channels":   `{"agent":"c-007","box":"box-a"}`,
		"other agent":   `{"agent":"c-008","box":"box-a","channels":[]}`,
		"other box":     `{"agent":"c-007","box":"box-b","channels":[]}`,
		"not an object": `[1]`,
	} {
		t.Run(name, func(t *testing.T) {
			h := invitesHub(t, answer)
			cfg := opCfg(t, h.url)
			if out, err := AgentInvitesDrop(context.Background(), cfg, AgentInvitesDropArgs{Agent: "c-007"}); err == nil || !strings.Contains(err.Error(), "is not an invites drop of c-007 on box-a") || out != nil {
				t.Fatalf("got %s, %v", out, err)
			}
		})
	}
	h := newOpHub(t, func(f wire.Frame) wire.Frame {
		return wire.Frame{Type: wire.TError, MsgID: f.MsgID, Error: "forbidden"}
	})
	cfg := opCfg(t, h.url)
	if out, err := AgentInvitesDrop(context.Background(), cfg, AgentInvitesDropArgs{Agent: "c-007"}); err == nil || out != nil {
		t.Fatalf("hub error: got %s, %v", out, err)
	}
}
