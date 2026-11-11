package main

import (
	"errors"
	"fmt"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
)

// cmdBoxPresence is this box's own presence (SPL-5318), over the
// authenticated hello like `spool fleet-load get`, signed by the box's key:
//
//	box-presence   {box, socket, agents} as JSON
//
// socket is true when the answering hub instance holds a role=box socket for
// this box; the one-shot cli session that asks never counts. A false is per
// instance (the hub may run two), so a caller proving a desk is live retries.
// agents is the box's seated roster. No member login, no password file: the
// desk move's proof (csi-spl-orc do_spl_desk_move) reads it.
func cmdBoxPresence(cfg *config.Config, args []string) int {
	if len(args) != 0 {
		return fail(errors.New("usage: spool box-presence"))
	}
	if cfg.HubURL == "" {
		return fail(errors.New("box presence needs hub mode ($SPOOL_HUB_URL is not set)"))
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := hubclient.New(cfg).Lane(ctx, "box_presence_get", "", nil)
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
