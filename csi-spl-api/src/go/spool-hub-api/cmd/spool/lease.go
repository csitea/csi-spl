package main

import (
	"flag"
	"fmt"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// cmdLease reads one role's fleet-wide lease or, with --holder, writes it by
// compare-and-set on --if-gen (CLE-77911): the primitive the lease loop
// (do_spl_dispatch_lease LEASE_CMD=fleet) builds on. Prints the hub's answer
// {fleet, role, holder, box, gen, age_s, won}; a lost race is won=false and
// exit 0, so the caller reads the current holder from the same line.
// --reason (spec 162 3.3) names why a write moves the lease; the hub logs a
// won handover in the System log.
func cmdLease(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("lease", flag.ContinueOnError)
	fleet := fs.String("fleet", "", "the fleet (a lowercase slug)")
	role := fs.String("role", "", "the role, e.g. orch or dispatch")
	holder := fs.String("holder", "", "write: the new holder, <agent id>@<box>")
	ifGen := fs.Int64("if-gen", -1, "write: the gen read (0 = no row yet)")
	reason := fs.String("reason", "", "write: why the lease moves, one of "+strings.Join(wire.LeaseReasons, ", "))
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if err := edgeIDs(cfg, map[string]*string{"holder": holder}); err != nil {
		return fail(err)
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := action.Lease(ctx, cfg, action.LeaseArgs{Fleet: *fleet, Role: *role, Holder: *holder, IfGen: *ifGen, Reason: *reason})
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
