package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// cmdClaim is `spool claim` (spec 068 4.1): a peer seat locks, keeps, gives
// back, closes, fences and adopts messages - the primitive do_spl_peer_poll
// (L3) builds on, in the call shape of its header. Exactly one of --poll,
// --renew, --release, --done, --check, --adopt.
//
// stdout: --poll and --renew print a JSON array, one object per message (the
// v:1 fields plus msg_id and responsible_gen; a row the poll closed dead
// carries "dead": true); the others, and --full, print the hub's answer
// {seat, msgs, dead, held, adopted}. Exit: 0 done; --check 1 = the seat lost
// the message; any other failure 2 for --check (so 1 always means "lost"),
// else the usual spool exit code.
func cmdClaim(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("claim", flag.ContinueOnError)
	poll := fs.Bool("poll", false, "lock up to --max free peer messages for the seat")
	renew := fs.Bool("renew", false, "extend the seat's locks; lists what it holds")
	check := fs.Bool("check", false, "the fence: exit 0 while the seat holds --msg at --gen, 1 when it lost it")
	adopt := fs.Bool("adopt", false, "take --msg if no live lock holds it (hub-down recovery); exit 0 either way")
	release := fs.String("release", "", "give this message (its msg id, or --msg) back now; needs --reason")
	done := fs.String("done", "", "close this message (its msg id, or --msg); --how says how")
	msgID := fs.String("msg", "", "the message id for --check, --adopt, --release, --done")
	as := fs.String("as", "", "the seat, <ID> or <ID>@<box> (a bare id is this box's)")
	seat := fs.String("seat", "", "the same as --as")
	harness := fs.String("harness", "", "optional: the seat's harness; refused unless it is the id's kind (c- claude, g- grok, ...)")
	max := fs.Int("max", 0, "poll: the most messages to lock (default 3)")
	ttl := fs.Int("ttl", 0, "poll|renew|adopt: the lock in seconds, 10..600 (default 120)")
	how := fs.String("how", "", "done: answered (default), handed:<lane> or no-reply:<reason>")
	reason := fs.String("reason", "", "release: why (harness-refused:<step>, send-failed, ...)")
	gen := fs.Int64("gen", 0, "check: the fence the poll returned; release|done: refused if it moved")
	full := fs.Bool("full", false, "print the hub's answer object, not the --poll / --renew array")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "claim: unexpected argument %q\n", fs.Arg(0))
		return 1
	}
	in := action.ClaimArgs{Max: *max, TTLS: *ttl, How: *how, Reason: *reason, Gen: *gen, MsgID: *msgID}
	var ops []string
	for op, on := range map[string]bool{"poll": *poll, "renew": *renew, "check": *check, "adopt": *adopt,
		"release": *release != "", "done": *done != ""} {
		if on {
			ops, in.Op = append(ops, op), op
		}
	}
	if len(ops) != 1 {
		fmt.Fprintln(os.Stderr, "claim: exactly one of --poll, --renew, --release <msg>, --done <msg>, --check, --adopt")
		return 1
	}
	if *release != "" {
		in.MsgID = *release
	}
	if *done != "" {
		in.MsgID = *done
	}
	failCode := func(err error) int {
		code := fail(err)
		if in.Op == "check" {
			return 2
		}
		return code
	}
	if *seat != "" {
		if *as != "" && *as != *seat {
			return failCode(fmt.Errorf("claim: --as and --seat name different seats"))
		}
		*as = *seat
	}
	if err := edgeIDs(cfg, map[string]*string{"as": as}); err != nil {
		return failCode(err)
	}
	if *harness != "" && *harness != agentid.Kind(*as) {
		return failCode(fmt.Errorf("claim: --harness %s is not the kind of %s (%q): the hub derives it from the id", *harness, *as, agentid.Kind(*as)))
	}
	in.Seat = *as
	ctx, stop := interruptible()
	defer stop()
	out, err := action.Claim(ctx, cfg, in)
	if err != nil {
		return failCode(err)
	}
	return claimPrint(in.Op, out, *full)
}

// claimPrint writes the answer in the op's shape and returns the exit code.
func claimPrint(op string, out json.RawMessage, full bool) int {
	if (op == "poll" || op == "renew") && !full {
		flat, err := action.ClaimFlat(out)
		if err != nil {
			return fail(err)
		}
		out = flat
	}
	fmt.Println(string(out))
	if op == "check" {
		var ans struct {
			Held bool `json:"held"`
		}
		if json.Unmarshal(out, &ans) != nil {
			return 2
		}
		if !ans.Held {
			return 1
		}
	}
	return 0
}
