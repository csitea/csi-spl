package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/evlog"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// cmdEvlog is the box reader's side of the backend error log (spec 162
// 10.4.4, SPL-5882 row T6):
//
//	spool evlog cursor --env <env>
//	    prints the hub's cursor {env, read_until, gen, by}
//	spool evlog put --env <env> --from <ts> --to <ts> --gen <n> [--dry-run]
//	    reads `gcloud logging read --format=json` on stdin, classifies and
//	    groups it (evlog.Classify, at most evlog.CapReader groups) and sends
//	    ONE frame; --dry-run prints that frame's body and sends nothing
//
// Raw log lines never leave the box: the frame carries only grouped,
// redacted, normalized groups. A put another box won first (409
// cursor_moved) prints one SKIP line and exits 0.
func cmdEvlog(cfg *config.Config, args []string) int {
	if len(args) == 0 || (args[0] != wire.EvlogOpCursor && args[0] != wire.EvlogOpPut) {
		fmt.Fprintln(os.Stderr, "usage: spool evlog cursor --env <env> | put --env <env> --from <ts> --to <ts> --gen <n> [--dry-run] < entries.json")
		return 1
	}
	op := args[0]
	fs := flag.NewFlagSet("evlog "+op, flag.ContinueOnError)
	env := fs.String("env", "", "the env whose reader cursor this is: dev or prd")
	from := fs.String("from", "", "put: the window's start, RFC 3339 (the cursor's read_until)")
	to := fs.String("to", "", "put: the window's end, RFC 3339")
	gen := fs.Int64("gen", -1, "put: the cursor gen read (0 = no cursor yet)")
	dry := fs.Bool("dry-run", false, "put: print the frame body, send nothing")
	if err := fs.Parse(args[1:]); err != nil {
		return 1
	}
	if *env != "dev" && *env != "prd" {
		return fail(errors.New("--env must be dev or prd"))
	}
	var body any = wire.EvlogCursorReq{Env: *env}
	if op == wire.EvlogOpPut {
		put, err := evlogPutBody(os.Stdin, *env, *from, *to, *gen)
		if err != nil {
			return fail(err)
		}
		if *dry {
			return printJSON(put)
		}
		body = put
	}
	return evlogSend(cfg, op, body)
}

// evlogPutBody reads the entries and builds the put of window [from, to).
func evlogPutBody(in io.Reader, env, from, to string, gen int64) (wire.EvlogPutReq, error) {
	f, err1 := time.Parse(time.RFC3339Nano, from)
	t, err2 := time.Parse(time.RFC3339Nano, to)
	switch {
	case err1 != nil || err2 != nil:
		return wire.EvlogPutReq{}, errors.New("--from and --to must be RFC 3339 times")
	case !t.After(f):
		return wire.EvlogPutReq{}, errors.New("--to must be after --from")
	case gen < 0:
		return wire.EvlogPutReq{}, errors.New("--gen (the cursor gen read, 0 = no cursor yet) is required")
	}
	raw, err := io.ReadAll(in)
	if err != nil {
		return wire.EvlogPutReq{}, fmt.Errorf("reading the entries: %w", err)
	}
	es, err := evlog.ParseEntries(raw)
	if err != nil {
		return wire.EvlogPutReq{}, err
	}
	return wire.EvlogPutReq{Env: env, Gen: gen, From: f.UTC(), To: t.UTC(), Groups: evlogGroups(es, t.UTC())}, nil
}

// evlogGroups classifies es and groups them for one frame.
func evlogGroups(es []evlog.Entry, at time.Time) []wire.EvlogGroup {
	traces := evlog.HubTraces(es)
	b := evlog.NewBatch(evlog.CapReader)
	for _, e := range es {
		if c, ok := evlog.Classify(e, traces); ok {
			b.Add(c)
		}
	}
	gs, origin := b.Take(at)
	out := make([]wire.EvlogGroup, 0, len(gs))
	for _, g := range gs {
		out = append(out, wire.EvlogGroup{Kind: g.Kind, Level: g.Level, Message: g.Message, Fingerprint: g.Fingerprint,
			FirstAt: g.FirstAt, LastAt: g.LastAt, N: g.N, OriginRef: origin[g.Fingerprint]})
	}
	return out
}

// evlogSend sends the frame and prints the hub's cursor, or the SKIP line
// of a put another box won.
func evlogSend(cfg *config.Config, op string, body any) int {
	if cfg.HubURL == "" {
		return fail(errors.New("evlog needs hub mode ($SPOOL_HUB_URL is not set)"))
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return fail(err)
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := hubclient.New(cfg).Evlog(ctx, op, raw)
	var he *hubclient.HubError
	if op == wire.EvlogOpPut && errors.As(err, &he) && he.Token == "cursor_moved" {
		fmt.Println("SKIP cursor_moved: another box read this window first")
		return 0
	}
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}

func printJSON(v any) int {
	raw, err := json.Marshal(v)
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(raw))
	return 0
}
