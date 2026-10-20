package main

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
)

// cmdCaps is the box's read of its workspace's agent caps (spec 147 6.2,
// SPL-2675), over the authenticated hello like `spool box-stats`:
//
//	caps                  {workspace_id, caps, live, can_edit} as JSON
//	caps check <agent>    exit 0 when the workspace admits one more agent
//	                      of <agent>'s vendor, 3 (one line why) when it is
//	                      at its cap: do_spl_desk_up's courtesy pre-check
//	                      (spec 147 5.2). The hub's SetRoster gate is the
//	                      authority; this only fails fast.
func cmdCaps(cfg *config.Config, args []string) int {
	if cfg.HubURL == "" {
		return fail(errors.New("agent caps need hub mode ($SPOOL_HUB_URL is not set)"))
	}
	switch {
	case len(args) == 0:
		raw, err := readCaps(cfg)
		if err != nil {
			return fail(err)
		}
		fmt.Println(string(raw))
		return 0
	case args[0] == "check" && len(args) == 2:
		return capsCheck(cfg, args[1])
	}
	return fail(errors.New("usage: spool caps | spool caps check <agent-id>"))
}

func readCaps(cfg *config.Config) ([]byte, error) {
	ctx, stop := interruptible()
	defer stop()
	return hubclient.New(cfg).Lane(ctx, "agent_caps_get", "", nil)
}

// capsAnswer is the part of the agent_caps_get reply a check reads.
type capsAnswer struct {
	WorkspaceID string          `json:"workspace_id"`
	Caps        map[string]*int `json:"caps"`
	Live        map[string]int  `json:"live"`
}

// capsVerdict is the check's decision: "" = admitted, else the refusal.
func capsVerdict(a capsAnswer, agent string) string {
	kind := agentid.Kind(agent)
	c := a.Caps[kind]
	if c == nil || a.Live[kind] < *c {
		return ""
	}
	return fmt.Sprintf("agent %s (%s) exceeds workspace %s cap of %d (currently %d live); seating refused",
		agent, kind, a.WorkspaceID, *c, a.Live[kind])
}

func capsCheck(cfg *config.Config, agent string) int {
	if agentid.Kind(agent) == "" {
		return fail(fmt.Errorf("caps check: %q is not an agent id", agent))
	}
	raw, err := readCaps(cfg)
	if err != nil {
		return fail(err)
	}
	var a capsAnswer
	if err := json.Unmarshal(raw, &a); err != nil {
		return fail(fmt.Errorf("caps check: the hub's answer is not caps JSON: %w", err))
	}
	if why := capsVerdict(a, agent); why != "" {
		fmt.Println(why)
		return 3
	}
	kind := agentid.Kind(agent)
	if c := a.Caps[kind]; c != nil {
		fmt.Printf("ok %s (%s): %d of %d live in %s\n", agent, kind, a.Live[kind], *c, a.WorkspaceID)
	} else {
		fmt.Printf("ok %s (%s): uncapped in %s\n", agent, kind, a.WorkspaceID)
	}
	return 0
}
