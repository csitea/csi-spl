package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// cmdClaim is `spool claim` (spec 068 4.1, spec 093 section 4): a peer seat
// locks, keeps, gives back, closes, fences and adopts messages - the
// primitive do_spl_peer_poll builds on, in the call shape of its header.
// Exactly one of --poll, --renew, --accept, --park, --unpark, --reoffer,
// --touch, --release, --done, --check, --adopt.
//
// Spec 093's two-phase claim: `--poll --state idle|busy` is the round poll
// (stubs of the rounds the seat is in, no body); `--accept <msg> --round <n>`
// takes it (the first accept wins the body and the fence, a loser exits 1
// with claim_refused); `--park <msg> --gen <g> --until <ts|30m> --wait <token>
// --reason <r>`, `--unpark`, `--reoffer`, `--touch` are the holder's calls;
// `--renew --hb fresh|able|stale --anchor-age <s>` is the heartbeat renew.
//
// stdout: --poll and --renew print a JSON array, one object per message (the
// v:1 fields plus msg_id and responsible_gen; a row the poll closed dead
// carries "dead": true); the others, and --full, print the hub's answer
// {seat, msgs, dead, held, adopted}. Exit: 0 done; --check 1 = the seat lost
// the message; any other failure 2 for --check (so 1 always means "lost",
// 2 "hub unconfirmed": do not act, do not assume lost), else the usual spool
// exit code.
func cmdClaim(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("claim", flag.ContinueOnError)
	ops := claimOpFlags(fs)
	msgID := fs.String("msg", "", "the message id for --check, --adopt and the calls that take one")
	as := fs.String("as", "", "the seat, <ID> or <ID>@<box> (a bare id is this box's)")
	seat := fs.String("seat", "", "the same as --as")
	harness := fs.String("harness", "", "optional: the seat's harness; refused unless it is the id's kind (c- claude, g- grok, ...)")
	in := action.ClaimArgs{}
	fs.IntVar(&in.Max, "max", 0, "poll: the most messages to lock / rounds to be in (default 3)")
	fs.IntVar(&in.TTLS, "ttl", 0, "068 poll|renew|adopt: the lock in seconds, 10..600 (default 120)")
	fs.StringVar(&in.How, "how", "", "done: answered (default), handed:<lane> or no-reply:<reason>")
	fs.StringVar(&in.Reason, "reason", "", "release|park: why (harness-refused:<step>, send-failed, ...)")
	fs.Int64Var(&in.Gen, "gen", 0, "check: the fence; release|done: refused if it moved; park|unpark|reoffer|touch: required")
	fs.StringVar(&in.State, "state", "", "poll: idle | busy = spec 093's round poll (none = 068's one-step poll)")
	ready := fs.String("ready", "", "poll --state: the ready seats the loop knows, comma separated")
	fs.IntVar(&in.Round, "round", 0, "accept: the round number of the stub")
	fs.StringVar(&in.Until, "until", "", "park: until when, RFC 3339 or a duration such as 30m (at most 60m)")
	fs.StringVar(&in.Wait, "wait", "", "park: what it waits on (a lane id, a task id, a CI run)")
	fs.StringVar(&in.HB, "hb", "", "renew: the seat's heartbeat verdict, fresh | able | stale (spec 093)")
	fs.IntVar(&in.AnchorAgeS, "anchor-age", 0, "renew --hb fresh: seconds since the heartbeat's anchor")
	full := fs.Bool("full", false, "print the hub's answer object, not the --poll / --renew array")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "claim: unexpected argument %q\n", fs.Arg(0))
		return 1
	}
	in.MsgID = *msgID
	if !claimPickOp(ops, &in) {
		fmt.Fprintln(os.Stderr, "claim: exactly one of --poll, --renew, --accept <msg>, --park <msg>, --unpark <msg>, --reoffer <msg>, --touch <msg>, --release <msg>, --done <msg>, --check, --adopt")
		return 1
	}
	if *ready != "" {
		in.Ready = strings.Split(*ready, ",")
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

// claimOps are the op flags: a bool for the seat-wide ops, the message id
// for the ones on one message.
type claimOps struct {
	on  map[string]*bool
	msg map[string]*string
}

func claimOpFlags(fs *flag.FlagSet) claimOps {
	return claimOps{
		on: map[string]*bool{
			"poll":  fs.Bool("poll", false, "lock up to --max free peer messages (068), or with --state the rounds (093)"),
			"renew": fs.Bool("renew", false, "extend the seat's locks; lists what it holds (with --hb: 093's heartbeat renew)"),
			"check": fs.Bool("check", false, "the fence: exit 0 while the seat holds --msg at --gen, 1 when it lost it, 2 unconfirmed"),
			"adopt": fs.Bool("adopt", false, "take --msg if no live lock holds it (hub-down recovery); exit 0 either way"),
		},
		msg: map[string]*string{
			"release": fs.String("release", "", "give this message (its msg id, or --msg) back now; needs --reason"),
			"done":    fs.String("done", "", "close this message (its msg id, or --msg); --how says how"),
			"accept":  fs.String("accept", "", "take this job's round --round (spec 093 T2); the first accept wins"),
			"park":    fs.String("park", "", "park this job at --gen: --until, --wait, --reason (T6)"),
			"unpark":  fs.String("unpark", "", "parked -> owned at --gen (T7a)"),
			"reoffer": fs.String("reoffer", "", "parked -> a round for the holder alone at --gen (T7b)"),
			"touch":   fs.String("touch", "", "mark this held job touched at --gen (keeps it past JOB_IDLE_MAX)"),
		},
	}
}

// claimPickOp sets in.Op (and in.MsgID from a message op's value, when it
// names one) and reports whether exactly one op was given.
func claimPickOp(ops claimOps, in *action.ClaimArgs) bool {
	n := 0
	for op, on := range ops.on {
		if *on {
			n, in.Op = n+1, op
		}
	}
	for op, id := range ops.msg {
		if *id != "" {
			n, in.Op, in.MsgID = n+1, op, *id
		}
	}
	return n == 1
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
