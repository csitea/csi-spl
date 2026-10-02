package main

import (
	"flag"
	"fmt"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// cmdLane lists the fleet-wide lane map or, with --agent, writes that agent's
// row (CLE-77920): the primitive do_spl_lane_map / do_spl_lane_put build on.
// Prints the hub's answer {fleet, lanes}.
func cmdLane(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("lane", flag.ContinueOnError)
	fleet := fs.String("fleet", "", "the fleet (a lowercase slug)")
	agent := fs.String("agent", "", "write: the agent id whose row this is (omit to list)")
	agentBox := fs.String("box", "", "write: its box, the desk box id of the machine it runs on (<id>@<box>)")
	repo := fs.String("repo", "", "write: the repo it works in")
	branch := fs.String("branch", "", "write: its branch")
	scope := fs.String("scope", "", "write: its scope, one line")
	files := fs.String("files", "", "write: the paths it owns, comma-separated")
	topic := fs.String("topic", "", "write: its topic (task id)")
	state := fs.String("state", "live", "write: live or done")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if err := edgeIDs(cfg, map[string]*string{"agent": agent}); err != nil {
		return fail(err)
	}
	var fl []string
	for _, p := range strings.Split(*files, ",") {
		if p = strings.TrimSpace(p); p != "" {
			fl = append(fl, p)
		}
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := action.Lane(ctx, cfg, action.LaneArgs{Fleet: *fleet, Agent: *agent, Box: *agentBox, Repo: *repo,
		Branch: *branch, Scope: *scope, Files: fl, Topic: *topic, State: *state})
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
