package main

import (
	"flag"
	"fmt"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// cmdMove moves a topic by its task id to another channel as an agent of
// this box: the box twin of the WUI's "Move to channel". Prints the hub's
// answer {kind, msg_id, task_id, channel, from_channel, moved, moved_by, ...}.
func cmdMove(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("move", flag.ContinueOnError)
	task := fs.String("task", "", "the topic's task id (the ?topic= of the WUI URL)")
	ch := fs.String("channel", "", "the target channel id")
	as := fs.String("as", "", "the acting agent (one this box announced)")
	actingFor := fs.String("acting-for", "", "the HUM-* this agent acts for: a box operator who is a workspace owner or admin")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := action.Move(ctx, cfg, action.MoveArgs{TaskID: *task, Channel: *ch, As: *as, ActingFor: *actingFor})
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
