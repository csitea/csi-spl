package action

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// AskArgs is one call on the fleet's asks to the orchestrator (CLE-77929):
// the verb behind `spool ask`. Op picks it:
//
//	list                          the open asks (All: + the closed week)
//	put                           record AskID (the msg_id that raised it) as open
//	ack | done | decline          work it, By = the acting <ID>@<box>
//	raise | escalate              the lease tick's re-raise / owner leg
//	release | dead                the lease tick's lock timeout / dead-letter (CLE-77942)
type AskArgs struct {
	Fleet    string
	Op       string
	AskID    string
	Role     string // the recipient role: put defaults to orch; list "" = every role
	Kind     string
	From     string
	Topic    string
	Summary  string
	Deadline string // RFC 3339, put only
	By       string
	Reason   string
	All      bool
	Hub      *hubclient.Client // nil = hubclient.New(cfg)
}

// Ask runs one op and returns the hub's answer {fleet, created, asks}. Hub
// mode only: the asks live on the hub, shared by every machine. The client
// refuses what the hub would, before dialling.
func Ask(ctx context.Context, cfg *config.Config, in AskArgs) (json.RawMessage, error) {
	if cfg.HubURL == "" {
		return nil, fmt.Errorf("asks need hub mode ($SPOOL_HUB_URL is not set)")
	}
	if !store.FleetNameRe.MatchString(in.Fleet) {
		return nil, fmt.Errorf("--fleet must be a lowercase slug ([a-z0-9-], up to 32)")
	}
	if in.Op == "" {
		in.Op = "list"
	}
	body, err := askBody(in)
	if err != nil {
		return nil, err
	}
	hc := in.Hub
	if hc == nil {
		hc = hubclient.New(cfg)
	}
	return hc.Ask(ctx, in.Op, in.Fleet, body)
}

// askBody checks the op and builds its ask object.
func askBody(in AskArgs) (json.RawMessage, error) {
	var v any
	switch in.Op {
	case "list":
		v = map[string]any{"role": in.Role, "all": in.All}
	case "put":
		if in.Role == "" {
			in.Role = "orch"
		}
		a := store.FleetAsk{Fleet: in.Fleet, AskID: in.AskID, Role: in.Role, Kind: in.Kind, From: in.From, Topic: in.Topic, Summary: in.Summary}
		if why := store.CheckFleetAsk(a); why != "" {
			return nil, fmt.Errorf("ask: %s", why)
		}
		if in.Deadline != "" {
			if _, err := time.Parse(time.RFC3339, in.Deadline); err != nil {
				return nil, fmt.Errorf("ask: --deadline must be RFC 3339 (e.g. 2026-10-02T06:00:00Z)")
			}
		}
		v = map[string]any{"ask_id": a.AskID, "role": a.Role, "kind": a.Kind, "from": a.From, "topic": a.Topic,
			"summary": a.Summary, "deadline_at": in.Deadline}
	default:
		if why := store.CheckFleetAskOp(in.Op, in.By, in.Reason); why != "" {
			return nil, fmt.Errorf("ask: %s", why)
		}
		if !store.AskIDRe.MatchString(in.AskID) {
			return nil, fmt.Errorf("ask: --id must be the ask's id (a lowercase UUID)")
		}
		v = map[string]any{"ask_id": in.AskID, "by": in.By, "reason": in.Reason}
	}
	return json.Marshal(v)
}
