package action

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
)

// AgentInvitesDropArgs is one retire's drop of an agent id's channel seats
// (spec 061 3.6, SPL-6714): the verb behind `spool agent-invites-drop`.
type AgentInvitesDropArgs struct {
	Agent string
	Hub   *hubclient.Client // nil = hubclient.New(cfg)
}

// agentInvitesDropAnswer is the hub's answer; the pointer proves channels was sent.
type agentInvitesDropAnswer struct {
	Agent    string    `json:"agent"`
	Box      string    `json:"box"`
	Channels *[]string `json:"channels"`
}

// AgentInvitesDrop asks the hub, over a one-shot cli session signed by this
// box's key, to mark every channel seat of Agent on this box removed in the
// box's own workspace, and returns its answer {agent, box, channels}. Hub
// mode only. Any failure is an error: no hub, a refusal, or an answer that
// is not that object for this agent and box.
func AgentInvitesDrop(ctx context.Context, cfg *config.Config, in AgentInvitesDropArgs) (json.RawMessage, error) {
	if cfg.HubURL == "" {
		return nil, fmt.Errorf("agent-invites-drop needs hub mode ($SPOOL_HUB_URL is not set)")
	}
	if !agentid.IsAgent(in.Agent) {
		return nil, fmt.Errorf("--agent must be an agent id, got %q", in.Agent)
	}
	row, err := json.Marshal(map[string]string{"agent": in.Agent, "box": cfg.BoxID})
	if err != nil {
		return nil, err
	}
	hc := in.Hub
	if hc == nil {
		hc = hubclient.New(cfg)
	}
	raw, err := hc.Lane(ctx, "agent_invites_drop", "", row)
	if err != nil {
		return nil, err
	}
	var a agentInvitesDropAnswer
	if err := json.Unmarshal(raw, &a); err != nil || a.Channels == nil || a.Agent != in.Agent || a.Box != cfg.BoxID {
		return nil, fmt.Errorf("hub answer is not an invites drop of %s on %s: %s", in.Agent, cfg.BoxID, raw)
	}
	return raw, nil
}
