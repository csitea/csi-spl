package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// cmdAsk is `spool ask <op>` (CLE-77929): record, work or list the fleet's
// asks to the orchestrator - the primitive do_spl_asks_* build on. Prints
// the hub's answer {fleet, created, asks}.
func cmdAsk(cfg *config.Config, args []string) int {
	op := "list"
	if len(args) > 0 && len(args[0]) > 0 && args[0][0] != '-' {
		op, args = args[0], args[1:]
	}
	fs := flag.NewFlagSet("ask", flag.ContinueOnError)
	fleet := fs.String("fleet", "", "the fleet (a lowercase slug)")
	id := fs.String("id", "", "the ask id: the msg_id of the message that raised it")
	role := fs.String("role", "", "put: the recipient role (default orch); list: only that role")
	kind := fs.String("kind", "", "put: blocker, task or escalation")
	from := fs.String("from", "", "put: the sender, <ID> or <ID>@<box>")
	topic := fs.String("topic", "", "put: the topic (task id)")
	summary := fs.String("summary", "", "put: one line, up to 500 bytes")
	deadline := fs.String("deadline", "", "put: when it is due, RFC 3339 (optional)")
	by := fs.String("by", "", "ack|done|decline|raise|escalate: the acting agent, <ID>@<box>")
	reason := fs.String("reason", "", "done|decline: why (a decline needs one)")
	all := fs.Bool("all", false, "list: also the closed asks of the last week")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "ask: unexpected argument %q (ops: list put ack done decline raise escalate)\n", fs.Arg(0))
		return 1
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := action.Ask(ctx, cfg, action.AskArgs{Fleet: *fleet, Op: op, AskID: *id, Role: *role, Kind: *kind, From: *from,
		Topic: *topic, Summary: *summary, Deadline: *deadline, By: *by, Reason: *reason, All: *all})
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
