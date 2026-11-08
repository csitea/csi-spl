package main

import (
	"flag"
	"fmt"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// cmdLane lists the fleet-wide lane map or, with --agent, writes that agent's
// row (CLE-77920): the primitive do_spl_lane_map / do_spl_lane_put build on.
// Prints the hub's answer {fleet, lanes}. --archived lists the live rows
// whose topic is archived, --box's only (SPL-3983), or with --topic only that
// topic's stamp (SPL-4955), and writes nothing. A list given --state lists
// that state's rows only (SPL-4630); without it, every row.
func cmdLane(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("lane", flag.ContinueOnError)
	fleet := fs.String("fleet", "", "the fleet (a lowercase slug)")
	agent := fs.String("agent", "", "write: the agent id whose row this is (omit to list)")
	agentBox := fs.String("box", "", "write: its box, the desk box id of the machine it runs on (<id>@<box>)")
	repo := fs.String("repo", "", "write: the repo it works in")
	branch := fs.String("branch", "", "write: its branch")
	scope := fs.String("scope", "", "write: its scope, one line")
	files := fs.String("files", "", "write: the paths it owns, comma-separated")
	topic := fs.String("topic", "", "write: its topic (task id); with --archived: the topic to read (full or 8-hex id)")
	issue := fs.String("issue", "", "write: its issue key, e.g. SPL-12")
	origin := fs.String("origin-issue", "", "write: the issue it came from, e.g. SPL-12")
	state := fs.String("state", "live", "write: live or done; list: only the rows in that state (default every row)")
	archived := fs.Bool("archived", false, "list the live rows whose topic is archived (with --box: that box's only)")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if *state != "done" || !agentid.Retired(*agent) { // a retired id may only close its row (SPL-4962)
		if err := edgeIDs(cfg, map[string]*string{"agent": agent}); err != nil {
			return fail(err)
		}
	}
	listState := ""
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "state" && *agent == "" {
			listState = *state
		}
	})
	var fl []string
	for _, p := range strings.Split(*files, ",") {
		if p = strings.TrimSpace(p); p != "" {
			fl = append(fl, p)
		}
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := action.Lane(ctx, cfg, action.LaneArgs{Fleet: *fleet, Agent: *agent, Box: *agentBox, Repo: *repo,
		Branch: *branch, Scope: *scope, Files: fl, Topic: *topic, Issue: *issue, OriginIssue: *origin, State: *state, Archived: *archived, ListState: listState})
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
