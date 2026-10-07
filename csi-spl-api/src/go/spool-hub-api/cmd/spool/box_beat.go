package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// cmdBoxBeat is the box beat of spec 102 10.2 (rdb 0147), over the
// authenticated hello like `spool box-stats`:
//
//	box-beat put --pid <n>                    one beat; prints the ack (the watchdog tick)
//	box-beat list [--box <b>] [--since 10m]   {box, since, rows} newest first
func cmdBoxBeat(cfg *config.Config, args []string) int {
	if len(args) == 0 {
		return fail(errors.New("usage: spool box-beat put --pid <n> | spool box-beat list [--box <b>] [--since 10m]"))
	}
	if cfg.HubURL == "" {
		return fail(errors.New("box beats need hub mode ($SPOOL_HUB_URL is not set)"))
	}
	var op string
	var q []byte
	var err error
	switch args[0] {
	case "put":
		fs := flag.NewFlagSet("box-beat put", flag.ContinueOnError)
		pid := fs.Int("pid", 0, "the watchdog loop's pid")
		if err := fs.Parse(args[1:]); err != nil {
			return 1
		}
		if *pid < 1 {
			return fail(errors.New("box-beat put: --pid <n> (1 or more) is required"))
		}
		op = "box_beat_put"
		q, err = json.Marshal(map[string]int{"pid": *pid})
	case "list":
		fs := flag.NewFlagSet("box-beat list", flag.ContinueOnError)
		box := fs.String("box", "", "one box (omit for every box)")
		since := fs.String("since", "10m", "the window: a duration back from now (10m, 2h)")
		if err := fs.Parse(args[1:]); err != nil {
			return 1
		}
		if *box != "" && !store.FleetNameRe.MatchString(*box) {
			return fail(errors.New("box-beat list: --box must be a box id ([a-z0-9-], up to 32)"))
		}
		op = "box_beat_list"
		q, err = json.Marshal(map[string]string{"box": *box, "since": *since})
	default:
		return fail(fmt.Errorf("box-beat: unknown sub-verb %q (put | list)", args[0]))
	}
	if err != nil {
		return fail(err)
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := hubclient.New(cfg).Lane(ctx, op, "", q)
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
