package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// cmdTopicPDF is `spool topic-pdf` (spec 183 7.1.2, row P3): the PDF of a
// topic this box's operator reads, rendered by the hub, written to a file on
// this machine. Prints one JSON line {task_id, path, bytes, rows, pictures,
// sha256}. Exit 0 written; 1 usage; 3 the hub's 404; 4 operator_ambiguous or
// typed_by_not_bound; 5 too_large, render_unavailable or render_timeout. A
// failed export writes no file.
func cmdTopicPDF(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("topic-pdf", flag.ContinueOnError)
	task := fs.String("task", "", "the topic: its uuid or a WUI link (/t/<uuid>, /m/<id>, a page with ?topic=<uuid>)")
	out := fs.String("out", "", "the file to write, replaced when it exists (default $SPOOL_ROOT/<agent id>/exports/<the hub's name>)")
	typedBy := fs.String("typed-by", "", "HUM-<n>: export as this operator of the box; needed only when several are bound")
	timeout := fs.Duration("timeout", action.TopicPDFTimeout, "how long to wait for the PDF, a cold start of the renderer included")
	desks := fs.String("desks", os.Getenv("SPOOL_DESKS"), "this box's hub desk dir (<state>/<env>/desk), tried in a link's order; empty = this hub-mode spool is the one desk")
	deskBox := fs.String("desk-box", cfg.DeskBox, "with --desks: the desk box (default $SPOOL_DESK_BOX)")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if *task == "" || fs.NArg() > 0 {
		fmt.Fprintln(os.Stderr, "spool: topic-pdf --task <uuid|WUI link> [--out <path>] [--typed-by HUM-<n>] [--timeout 120s] [--desks <dir> [--desk-box <box>]]")
		return 1
	}
	if *timeout <= 0 {
		fmt.Fprintln(os.Stderr, "spool: topic-pdf: --timeout must be above 0")
		return 1
	}
	ctx, stop := interruptible()
	defer stop()
	res, err := action.TopicPDF(ctx, action.Desks{Dir: *desks, Box: *deskBox, Base: cfg}, action.TopicPDFArgs{
		Task: *task, Out: *out, TypedBy: *typedBy, Timeout: *timeout,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "spool: topic-pdf: "+err.Error())
		return action.TopicPDFExitCode(err)
	}
	fmt.Println(action.JSON(res))
	return 0
}
