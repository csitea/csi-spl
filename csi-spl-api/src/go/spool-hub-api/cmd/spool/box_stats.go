package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// cmdBoxStats is the box's door to the hardware history (rdb 0117), over the
// authenticated hello like `spool lane`:
//
//	box-stats put --json <file|->              append one sample (the lane-map tick)
//	box-stats list [--box <b>] [--since 20h]   {since, rows, hours} as JSON
func cmdBoxStats(cfg *config.Config, args []string) int {
	if len(args) == 0 {
		return fail(errors.New("usage: spool box-stats put --json <file|-> | spool box-stats list [--box <b>] [--since 20h]"))
	}
	if cfg.HubURL == "" {
		return fail(errors.New("box stats need hub mode ($SPOOL_HUB_URL is not set)"))
	}
	switch args[0] {
	case "put":
		return boxStatsPut(cfg, args[1:])
	case "list":
		return boxStatsList(cfg, args[1:])
	}
	return fail(fmt.Errorf("box-stats: unknown sub-verb %q (put | list)", args[0]))
}

func boxStatsPut(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("box-stats put", flag.ContinueOnError)
	src := fs.String("json", "", "the sample object: a file, or - for stdin")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if *src == "" {
		return fail(errors.New("box-stats put: --json <file|-> is required"))
	}
	var raw []byte
	var err error
	if *src == "-" {
		raw, err = io.ReadAll(io.LimitReader(os.Stdin, 64<<10))
	} else {
		raw, err = os.ReadFile(*src)
	}
	if err != nil {
		return fail(err)
	}
	var b store.BoxStat
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&b); err != nil {
		return fail(fmt.Errorf("box-stats put: not one sample object: %w", err))
	}
	if why := store.CheckBoxStat(b); why != "" {
		return fail(fmt.Errorf("box-stats put: %s", why))
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := hubclient.New(cfg).Lane(ctx, "box_stats_put", "", json.RawMessage(raw))
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}

func boxStatsList(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("box-stats list", flag.ContinueOnError)
	box := fs.String("box", "", "one box (omit for every box)")
	since := fs.String("since", "24h", "the window: a duration back (20h), days (7d) or an RFC 3339 time")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if *box != "" && !store.FleetNameRe.MatchString(*box) {
		return fail(errors.New("box-stats list: --box must be a box id ([a-z0-9-], up to 32)"))
	}
	q, err := json.Marshal(map[string]string{"box": *box, "since": *since})
	if err != nil {
		return fail(err)
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := hubclient.New(cfg).Lane(ctx, "box_stats_list", "", q)
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
