package main

import (
	"errors"
	"flag"
	"fmt"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// cmdAgentInvitesDrop drops a retired agent id's channel seats on this box
// (spec 061 3.6, SPL-6714), over the authenticated hello like
// `spool channel-pins`, signed by the box's key and scoped to its own
// workspace and box:
//
//	agent-invites-drop --agent <id>   {agent, box, channels} as JSON
//
// channels lists the channels whose seat went to removed ([] = none). Any
// failure exits non-zero. agent-id-retire.sh runs it on every desk of the
// box (csi-spl-orc do_spl_agent_invites_drop).
func cmdAgentInvitesDrop(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("agent-invites-drop", flag.ContinueOnError)
	agent := fs.String("agent", "", "the retired agent id")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if fs.NArg() > 0 || *agent == "" {
		return fail(errors.New("usage: spool agent-invites-drop --agent <id>"))
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := action.AgentInvitesDrop(ctx, cfg, action.AgentInvitesDropArgs{Agent: *agent})
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
