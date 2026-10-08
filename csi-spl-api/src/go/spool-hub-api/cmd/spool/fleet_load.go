package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
)

// cmdFleetLoad is the box's read of the instance's fleet load target (rdb
// 0118), over the authenticated hello like `spool lane`:
//
//	fleet-load get                            {low, high, box_order, boxes, agent_kinds_off, agent_kinds_paused,
//	                                          runner_cpu_pct, source} as JSON
//	fleet-load pause <kind> <until> [reason]  pause an agent kind for every box until <until> (RFC 3339)
//
// boxes (rdb 0134) is the per-box band, {"<box>": {"low", "high"}}, that
// overrides low / high for the boxes it names. agent_kinds_off (rdb 0149) is
// the kinds no box starts a lane of; agent_kinds_paused the running pauses,
// {"<kind>": {until, reason, box}}. runner_cpu_pct (rdb 0152) is the % of a
// box's cores CI runners plus agents may use, 1..100, default 80; a box's
// own is boxes.<box>.runner_cpu_pct (jq: .boxes[$box].runner_cpu_pct //
// .runner_cpu_pct).
//
// Only the operator workspace's admin changes the target, through
// PATCH /v1/operator/fleet-load; a box only reports a pause (a lane of that
// kind hit its usage limit, csi-spl-orc do_spl_lane_mix).
func cmdFleetLoad(cfg *config.Config, args []string) int {
	var op string
	var row json.RawMessage
	switch {
	case len(args) == 1 && args[0] == "get":
		op = "fleet_load_get"
	case len(args) >= 3 && args[0] == "pause":
		op = "fleet_load_pause"
		row, _ = json.Marshal(map[string]string{"kind": args[1], "until": args[2], "reason": strings.Join(args[3:], " ")})
	default:
		return fail(errors.New("usage: spool fleet-load get | spool fleet-load pause <kind> <until RFC 3339> [reason]"))
	}
	if cfg.HubURL == "" {
		return fail(errors.New("the fleet load target needs hub mode ($SPOOL_HUB_URL is not set)"))
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := hubclient.New(cfg).Lane(ctx, op, "", row)
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
