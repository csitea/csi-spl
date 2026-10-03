package action

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// ClaimArgs is one call on the peer claim of messages (spec 068 4.1): the
// verb behind `spool claim`. Op picks it:
//
//	poll      lock up to Max free peer messages for the seat (TTLS, default 120)
//	renew     extend the seat's locks; lists what it holds
//	release   give MsgID back now, Reason required (harness-refused:<step>, send-failed)
//	done      close MsgID: How = answered (default) | handed:<lane> | no-reply:<reason>;
//	          Gen > 0 is a compare-and-set on the fence
//	check     the fence: the answer's held says whether Seat still holds MsgID at Gen
//	adopt     insert-if-absent: take MsgID if no live lock holds it (hub-down recovery)
type ClaimArgs struct {
	Op     string
	Seat   string // <ID> or <ID>@<box>; a bare id is this box's
	Max    int
	TTLS   int
	MsgID  string
	Gen    int64
	How    string
	Reason string
	Hub    *hubclient.Client // nil = hubclient.New(cfg)
}

// Claim runs one op and returns the hub's answer {seat, msgs, dead}. Hub
// mode only: the claims live on the message rows on the hub. The client
// refuses what the hub would, before dialling.
func Claim(ctx context.Context, cfg *config.Config, in ClaimArgs) (json.RawMessage, error) {
	if cfg.HubURL == "" {
		return nil, fmt.Errorf("claims need hub mode ($SPOOL_HUB_URL is not set)")
	}
	body, err := claimBody(in)
	if err != nil {
		return nil, err
	}
	hc := in.Hub
	if hc == nil {
		hc = hubclient.New(cfg)
	}
	return hc.Claim(ctx, in.Op, body)
}

// claimBody checks the op and builds its claim object.
func claimBody(in ClaimArgs) (json.RawMessage, error) {
	if in.Seat == "" {
		return nil, fmt.Errorf("claim: --as must name the seat, <ID> or <ID>@<box>")
	}
	if in.TTLS != 0 && (in.TTLS < 10 || in.TTLS > 600) {
		return nil, fmt.Errorf("claim: --ttl must be 10..600 seconds")
	}
	v := map[string]any{"seat": in.Seat, "ttl_s": in.TTLS}
	switch in.Op {
	case "poll":
		if in.Max < 0 || in.Max > store.ClaimPollMax {
			return nil, fmt.Errorf("claim: --max must be 1..%d", store.ClaimPollMax)
		}
		v["max"] = in.Max
	case "renew":
	case "check", "adopt":
		if !store.AskIDRe.MatchString(in.MsgID) {
			return nil, fmt.Errorf("claim: --%s needs --msg, the message id (a lowercase UUID)", in.Op)
		}
		if in.Op == "check" && in.Gen < 1 {
			return nil, fmt.Errorf("claim: --check needs --gen, the fence the poll returned")
		}
		v["msg_id"], v["gen"] = in.MsgID, in.Gen
	case "release", "done":
		if !store.AskIDRe.MatchString(in.MsgID) {
			return nil, fmt.Errorf("claim: --%s needs the message id (a lowercase UUID)", in.Op)
		}
		if in.Op == "release" {
			if why := store.CheckClaimReason(in.Reason); why != "" {
				return nil, fmt.Errorf("claim: --reason: %s", why)
			}
		} else {
			if in.How == "" {
				in.How = "answered"
			}
			if why := store.CheckClaimHow(in.How); why != "" {
				return nil, fmt.Errorf("claim: --how: %s", why)
			}
		}
		v["msg_id"], v["gen"], v["how"], v["reason"] = in.MsgID, in.Gen, in.How, in.Reason
	default:
		return nil, fmt.Errorf("claim: one of --poll, --renew, --release <msg>, --done <msg>, --check, --adopt")
	}
	return json.Marshal(v)
}

// ClaimFlat turns a claim answer into the JSON array the peer poll loop
// reads (do_spl_peer_poll, spec 068 L3): one object per row of msgs, then
// per row of dead with "dead": true. A row that carries its v:1 message
// starts from that message's fields (task_id, ts, from, to, kind, body,
// files); the claim fields (msg_id, responsible_gen, responsible,
// locked_until, claim_n, handled_how, not_by, channel) are laid over it.
func ClaimFlat(raw json.RawMessage) (json.RawMessage, error) {
	var ans struct {
		Msgs []map[string]json.RawMessage `json:"msgs"`
		Dead []map[string]json.RawMessage `json:"dead"`
	}
	if err := json.Unmarshal(raw, &ans); err != nil {
		return nil, fmt.Errorf("claim: the hub's answer does not decode: %w", err)
	}
	out := []map[string]json.RawMessage{}
	flat := func(row map[string]json.RawMessage, dead bool) {
		o := map[string]json.RawMessage{}
		if m, ok := row["msg"]; ok {
			json.Unmarshal(m, &o) //nolint:errcheck // a row without a v:1 object keeps its own fields
		}
		for k, v := range row {
			if k == "msg" || (k == "from" || k == "to" || k == "ts" || k == "task_id" || k == "kind") && o[k] != nil {
				continue
			}
			o[k] = v
		}
		if dead {
			o["dead"] = json.RawMessage("true")
		}
		out = append(out, o)
	}
	for _, r := range ans.Msgs {
		flat(r, false)
	}
	for _, r := range ans.Dead {
		flat(r, true)
	}
	return json.Marshal(out)
}
