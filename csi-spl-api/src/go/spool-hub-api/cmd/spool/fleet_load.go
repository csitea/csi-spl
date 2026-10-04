package main

import (
	"errors"
	"fmt"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
)

// cmdFleetLoad is the box's read of the instance's fleet load target (rdb
// 0118), over the authenticated hello like `spool lane`:
//
//	fleet-load get   {low, high, box_order, source} as JSON
//
// Only the operator workspace's admin changes it, through
// PATCH /v1/operator/fleet-load; a box never writes it.
func cmdFleetLoad(cfg *config.Config, args []string) int {
	if len(args) != 1 || args[0] != "get" {
		return fail(errors.New("usage: spool fleet-load get"))
	}
	if cfg.HubURL == "" {
		return fail(errors.New("the fleet load target needs hub mode ($SPOOL_HUB_URL is not set)"))
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := hubclient.New(cfg).Lane(ctx, "fleet_load_get", "", nil)
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
