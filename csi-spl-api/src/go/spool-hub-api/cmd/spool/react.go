package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// cmdReact adds an emoji reaction as an agent of this box (CLE-77895): the
// box twin of the WUI's reaction chip. The target is --msg, or the topic's
// opening message; --remove takes it off; --list only reads.
// Prints the hub's answer {msg_id, task_id, reactions}.
func cmdReact(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("react", flag.ContinueOnError)
	task := fs.String("task", "", "the topic's task id (the ?topic= of the WUI URL)")
	m := fs.String("msg", "", "the message to react to (default: the topic's opening message)")
	emoji := fs.String("emoji", "", "one picker glyph or status mark, e.g. ⏸️ (on hold)")
	as := fs.String("as", "", "the acting agent (one this box announced)")
	rm := fs.Bool("remove", false, "remove the reaction instead")
	list := fs.Bool("list", false, "only print the target's reactions (read-only, no --emoji)")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	out, err := action.React(ctx, cfg, action.ReactArgs{TaskID: *task, MsgID: *m, Emoji: *emoji, As: *as, Remove: *rm, List: *list})
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
