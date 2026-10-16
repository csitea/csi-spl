package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// fleetTokensPushMax caps what `fleet-tokens push` reads: 2000 samples of
// ~250 bytes each, with room to spare.
const fleetTokensPushMax = 4 << 20

// cmdFleetTokens is the box collector's push of its live token burn buckets
// (spec 140 section 3.4, csi-spl-orc spl_token_burn_spool), over the
// authenticated hello like `spool fleet-load`:
//
//	fleet-tokens push --json <file|->   {samples: [...]} -> the hub's ack {type, lane_op, inserted, at}
//
// The input is the collector's frame, {type, lane_op, samples}; only samples
// is sent, checked here first by the hub's own rule (wire.DecodeFleetTokensPush)
// so a bad bucket fails on the box with the sample it names.
func cmdFleetTokens(cfg *config.Config, args []string) int {
	if len(args) != 3 || args[0] != "push" || args[1] != "--json" {
		return fail(errors.New("usage: spool fleet-tokens push --json <file|->"))
	}
	var raw []byte
	var err error
	if args[2] == "-" {
		raw, err = io.ReadAll(io.LimitReader(os.Stdin, fleetTokensPushMax))
	} else {
		raw, err = os.ReadFile(args[2])
	}
	if err != nil {
		return fail(err)
	}
	var in struct {
		Samples json.RawMessage `json:"samples"`
	}
	if err := json.Unmarshal(raw, &in); err != nil {
		return fail(fmt.Errorf("fleet-tokens push: not a {samples: [...]} object: %w", err))
	}
	row, err := json.Marshal(map[string]json.RawMessage{"samples": in.Samples})
	if err != nil {
		return fail(err)
	}
	if _, err := wire.DecodeFleetTokensPush(row); err != nil {
		return fail(fmt.Errorf("fleet-tokens push: %w", err))
	}
	if cfg.HubURL == "" {
		return fail(errors.New("the fleet token burn needs hub mode ($SPOOL_HUB_URL is not set)"))
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := hubclient.New(cfg).Lane(ctx, wire.FleetBurnPushOp, "", row)
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
