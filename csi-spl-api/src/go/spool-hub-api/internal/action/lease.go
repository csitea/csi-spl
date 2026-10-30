package action

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// LeaseArgs is one read, or compare-and-set, of a fleet-wide lease
// (CLE-77911): the verb behind `spool lease`. Holder "" = read; with Holder,
// IfGen is the gen the caller read (0 = no row yet). Reason, write only, is
// why the loop moves the row (one of wire.LeaseReasons, spec 162 3.3).
type LeaseArgs struct {
	Fleet  string            `json:"fleet"`
	Role   string            `json:"role"`
	Holder string            `json:"holder,omitempty"`
	IfGen  int64             `json:"if_gen"`
	Reason string            `json:"reason,omitempty"`
	Hub    *hubclient.Client `json:"-"` // nil = hubclient.New(cfg)
}

// Lease reads or compare-and-sets the lease and returns the hub's answer.
// Hub mode only: the lease lives on the hub, shared by every machine.
func Lease(ctx context.Context, cfg *config.Config, in LeaseArgs) (json.RawMessage, error) {
	if cfg.HubURL == "" {
		return nil, fmt.Errorf("the fleet lease needs hub mode ($SPOOL_HUB_URL is not set)")
	}
	if !store.FleetNameRe.MatchString(in.Fleet) || !store.FleetNameRe.MatchString(in.Role) {
		return nil, fmt.Errorf("--fleet and --role must be lowercase slugs ([a-z0-9-], up to 32)")
	}
	if !wire.ValidLeaseReason(in.Reason) {
		return nil, fmt.Errorf("--reason must be one of %s", strings.Join(wire.LeaseReasons, ", "))
	}
	if in.Reason != "" && in.Holder == "" {
		return nil, fmt.Errorf("--reason names why a write moves the lease: it needs --holder")
	}
	op := "get"
	if in.Holder != "" {
		if !store.ValidFleetHolder(in.Holder) {
			return nil, fmt.Errorf("--holder must be <agent id>@<box>")
		}
		if in.IfGen < 0 {
			return nil, fmt.Errorf("--if-gen (the gen read, 0 = no row yet) is required with --holder")
		}
		op = "cas"
	}
	hc := in.Hub
	if hc == nil {
		hc = hubclient.New(cfg)
	}
	return hc.LeaseFor(ctx, op, in.Fleet, in.Role, in.Holder, in.IfGen, in.Reason)
}
