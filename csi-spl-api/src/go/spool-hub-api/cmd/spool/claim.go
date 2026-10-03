package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// cmdClaim is `spool claim` (spec 068 4.1): a peer seat locks, keeps, gives
// back and closes messages - the primitive do_spl_peer_poll builds on.
// Exactly one of --poll, --renew, --release <msg>, --done <msg>. Prints the
// hub's answer {seat, msgs, dead}.
func cmdClaim(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("claim", flag.ContinueOnError)
	poll := fs.Bool("poll", false, "lock up to --max free peer messages for the seat")
	renew := fs.Bool("renew", false, "extend the seat's locks; lists what it holds")
	release := fs.String("release", "", "give this message (its msg id) back now; needs --reason")
	done := fs.String("done", "", "close this message (its msg id); --how says how")
	as := fs.String("as", "", "the seat, <ID> or <ID>@<box> (a bare id is this box's)")
	max := fs.Int("max", 0, "poll: the most messages to lock (default 3)")
	ttl := fs.Int("ttl", 0, "poll|renew: the lock in seconds, 10..600 (default 120)")
	how := fs.String("how", "", "done: answered (default), handed:<lane> or no-reply:<reason>")
	reason := fs.String("reason", "", "release: why (harness-refused:<step>, send-failed, ...)")
	gen := fs.Int64("gen", 0, "release|done: the fence the poll returned; refused if it moved")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "claim: unexpected argument %q (one of --poll, --renew, --release <msg>, --done <msg>)\n", fs.Arg(0))
		return 1
	}
	var ops []string
	in := action.ClaimArgs{Max: *max, TTLS: *ttl, How: *how, Reason: *reason, Gen: *gen}
	if *poll {
		ops, in.Op = append(ops, "poll"), "poll"
	}
	if *renew {
		ops, in.Op = append(ops, "renew"), "renew"
	}
	if *release != "" {
		ops, in.Op, in.MsgID = append(ops, "release"), "release", *release
	}
	if *done != "" {
		ops, in.Op, in.MsgID = append(ops, "done"), "done", *done
	}
	if len(ops) != 1 {
		fmt.Fprintln(os.Stderr, "claim: exactly one of --poll, --renew, --release <msg>, --done <msg>")
		return 1
	}
	if err := edgeIDs(cfg, map[string]*string{"as": as}); err != nil {
		return fail(err)
	}
	in.Seat = *as
	ctx, stop := interruptible()
	defer stop()
	out, err := action.Claim(ctx, cfg, in)
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
