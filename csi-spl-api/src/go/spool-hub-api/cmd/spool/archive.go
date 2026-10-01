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

// cmdArchive archives a topic by its task id as an agent of this box
// (CLE-77869): the box twin of the WUI's Archive. --unarchive restores it.
// Prints the hub's answer {msg_id, task_id, archived, archived_at, archived_by}.
func cmdArchive(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("archive", flag.ContinueOnError)
	task := fs.String("task", "", "the topic's task id (the ?topic= of the WUI URL)")
	as := fs.String("as", "", "the acting agent (one this box announced)")
	un := fs.Bool("unarchive", false, "restore an archived topic")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	out, err := action.Archive(ctx, cfg, action.ArchiveArgs{TaskID: *task, As: *as, Unarchive: *un})
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
