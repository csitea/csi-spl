package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// askOps is every `spool ask` op, for the usage line.
const askOps = "list put ack done decline raise escalate release dead queue enqueue lock-next renew reopen pool"

// cmdAsk is `spool ask <op>` (CLE-77929): record, work or list the fleet's
// asks to the orchestrator - the primitive do_spl_asks_* build on - and the
// OD pool's jobs, role od (spec 134 3.4: enqueue, lock-next, renew, release,
// done, decline, reopen, pool, list --role od --free). Prints the hub's
// answer {fleet, created, asks[, dead][, pool]}.
func cmdAsk(cfg *config.Config, args []string) int {
	op := "list"
	if len(args) > 0 && len(args[0]) > 0 && args[0][0] != '-' {
		op, args = args[0], args[1:]
	}
	fs := flag.NewFlagSet("ask", flag.ContinueOnError)
	fleet := fs.String("fleet", "", "the fleet (a lowercase slug)")
	id := fs.String("id", "", "the ask id: the msg_id of the message that raised it")
	role := fs.String("role", "", "put: the recipient role (default orch); list: only that role")
	kind := fs.String("kind", "", "put: blocker, task or escalation; enqueue: route_post, spawn, lane_verify or box_op")
	from := fs.String("from", "", "put|enqueue: the sender, <ID> or <ID>@<box>")
	topic := fs.String("topic", "", "put|enqueue: the topic (task id)")
	summary := fs.String("summary", "", "put|enqueue: one line, up to 500 bytes")
	deadline := fs.String("deadline", "", "put|enqueue: when it is due, RFC 3339 (optional)")
	by := fs.String("by", "", "ack|done|decline|raise|escalate|release|dead|queue|renew|reopen|pool --set: the acting agent, <ID>@<box>")
	reason := fs.String("reason", "", "done|decline|dead: why (a decline and a dead-letter need one)")
	placement := fs.String("placement", "", "queue: what the placer launches, <vendor>:<slug> (optional)")
	all := fs.Bool("all", false, "list: also the closed asks of the last week")
	// role od (spec 134, rdb 0183)
	gen := fs.Int64("gen", 0, "renew|done|decline|release of an od job: the gen lock-next gave the holder")
	refuse := fs.String("refuse", "", "release of an od job: the harness that refuses it joins not_by (claude, grok, vibe)")
	free := fs.Bool("free", false, "list --role od: only the jobs a seat could lock now")
	seat := fs.String("seat", "", "lock-next: the locking seat, <ID>@<box>")
	vendor := fs.String("vendor", "", "lock-next: the seat's vendor (claude, grok)")
	harness := fs.String("harness", "", "lock-next: the seat's harness for not_by (default the vendor)")
	caps := fs.String("caps", "", "lock-next: the seat's caps, comma-separated (prd); the hub adds its box")
	issue := fs.String("issue", "", "enqueue: the issue key, SPL-n")
	dedupe := fs.String("dedupe", "", "enqueue: one open job per kind and this key")
	vendorAllow := fs.String("vendor-allow", "", "enqueue: only this vendor's seats lock it (claude, grok)")
	needs := fs.String("needs", "", "enqueue: box:<box> or prd")
	lease := fs.Int("lease", 0, "enqueue: the lease in seconds, 15..86400 (default 120)")
	needsOwner := fs.Bool("needs-owner", false, "enqueue: the job waits for a human (needs_owner), never locked")
	set := fs.Bool("set", false, "pool: write the fields given below (with --by)")
	claudeN := fs.Int("claude-n", 0, "pool --set: the Claude seat target")
	grokN := fs.Int("grok-n", 0, "pool --set: the Grok seat target")
	minBoxes := fs.Int("min-boxes", 0, "pool --set: the boxes the seats spread over")
	vendorOut := fs.String("vendor-out", "", "pool --set: the vendor that is out (claude, grok, or empty)")
	outUntil := fs.String("out-until", "", "pool --set: until when, RFC 3339 (empty clears it)")
	kinds := fs.String("kinds", "", "pool --set: the job kinds the seats lock, comma-separated (empty: none)")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "ask: unexpected argument %q (ops: %s)\n", fs.Arg(0), askOps)
		return 1
	}
	if err := edgeIDs(cfg, map[string]*string{"from": from, "by": by, "seat": seat}); err != nil {
		return fail(err)
	}
	pool := map[string]any{}
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "claude-n":
			pool["claude_n"] = *claudeN
		case "grok-n":
			pool["grok_n"] = *grokN
		case "min-boxes":
			pool["min_boxes"] = *minBoxes
		case "vendor-out":
			pool["vendor_out"] = *vendorOut
		case "out-until":
			pool["out_until"] = *outUntil
		case "kinds":
			pool["kinds"] = splitList(*kinds)
		}
	})
	ctx, stop := interruptible()
	defer stop()
	out, err := action.Ask(ctx, cfg, action.AskArgs{Fleet: *fleet, Op: op, AskID: *id, Role: *role, Kind: *kind, From: *from,
		Topic: *topic, Summary: *summary, Deadline: *deadline, By: *by, Reason: *reason, Place: *placement, All: *all,
		Gen: *gen, Refuse: *refuse, Free: *free, Seat: *seat, Vendor: *vendor, Harness: *harness, Caps: splitList(*caps),
		IssueKey: *issue, DedupeKey: *dedupe, VendorAllow: *vendorAllow, Needs: *needs, LeaseS: *lease, NeedsOwner: *needsOwner,
		PoolSet: *set, Pool: pool})
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}

// splitList is a comma-separated flag as a list ("" = empty, never nil).
func splitList(s string) []string {
	out := []string{}
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
