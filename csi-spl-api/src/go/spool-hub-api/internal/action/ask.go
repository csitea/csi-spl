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
//	queue                         a spawn request waits for room (rdb 0180), Placement optional;
//	                              Class required unless stored, Flag urgent | bypass (+ FlagMsg) (rdb 0195)
//	category                      a spawn request's WorkKind and CategoryPath, By acting (spec 143 4.4, rdb 0204)
//
// The OD pool's jobs, role od (spec 134 3.4, rdb 0183):
//
//	enqueue                       insert a job: Kind, From, Topic, IssueKey, DedupeKey, ...
//	lock-next                     lock the next job for Seat (Vendor, Harness, Caps)
//	renew | done | decline | release  the holder By at its Gen; release with no AskID
//	                              frees every job of By; Refuse adds a harness to not_by
//	reopen                        needs_owner -> open
//	pool                          read od_pool; PoolSet writes the Pool* fields given
//	list Free                     role od: the jobs a seat could lock now
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
	Place    string // queue: "<vendor>:<slug>"
	Class    string // queue: ci | refactor | bug | feature
	Flag     string // queue: urgent | bypass
	FlagMsg  string // queue, bypass: the owner message id
	All      bool
	// role od
	Gen         int64
	Refuse      string
	Free        bool
	Seat        string
	Vendor      string
	Harness     string
	Caps        []string
	IssueKey    string
	DedupeKey   string
	VendorAllow string
	Needs       string
	LeaseS      int
	NeedsOwner  bool
	PoolSet     bool
	Pool        map[string]any // pool set: the od_pool fields to write (claude_n, grok_n, min_boxes, vendor_out, out_until, kinds)
	// category (spec 143 4.4): a spawn request's brief header; "" = not given
	WorkKind     string
	CategoryPath string
	Hub          *hubclient.Client // nil = hubclient.New(cfg)
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
		if in.Free && in.Role != store.OdRole {
			return nil, fmt.Errorf("ask: --free lists --role od only")
		}
		v = map[string]any{"role": in.Role, "all": in.All, "free": in.Free}
	case "put":
		m, err := askPutBody(in)
		if err != nil {
			return nil, err
		}
		v = m
	case "enqueue", "lock-next", "pool":
		return odBody(in)
	case "category":
		switch {
		case !store.ValidAskAgent(in.By) || in.By == "":
			return nil, fmt.Errorf("ask: category needs --by, the acting agent <ID>@<box>")
		case !store.AskIDRe.MatchString(in.AskID):
			return nil, fmt.Errorf("ask: --id must be the ask's id (a lowercase UUID)")
		}
		if why := store.CheckAskCategory(in.WorkKind, in.CategoryPath); why != "" {
			return nil, fmt.Errorf("ask: %s", why)
		}
		v = map[string]any{"ask_id": in.AskID, "by": in.By, "work_kind": in.WorkKind, "category_path": in.CategoryPath}
	case "release":
		if in.AskID == "" {
			if !store.ValidAskAgent(in.By) || in.By == "" {
				return nil, fmt.Errorf("ask: a seat release needs --by, the seat <ID>@<box>")
			}
			v = map[string]any{"by": in.By}
			break
		}
		fallthrough
	default:
		m, err := askOpBody(in)
		if err != nil {
			return nil, err
		}
		v = m
	}
	return json.Marshal(v)
}

// askPutBody checks a put (role defaults to orch on this copy) and builds its ask object.
func askPutBody(in AskArgs) (map[string]any, error) {
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
	return map[string]any{"ask_id": a.AskID, "role": a.Role, "kind": a.Kind, "from": a.From, "topic": a.Topic,
		"summary": a.Summary, "deadline_at": in.Deadline}, nil
}

// askOpBody checks an op on one ask (ack, done, queue, release at gen, ...) and builds its object.
func askOpBody(in AskArgs) (map[string]any, error) {
	if why := store.CheckFleetAskOp(in.Op, in.By, in.Reason); why != "" {
		return nil, fmt.Errorf("ask: %s", why)
	}
	if !store.AskIDRe.MatchString(in.AskID) {
		return nil, fmt.Errorf("ask: --id must be the ask's id (a lowercase UUID)")
	}
	if !store.AskPlacementRe.MatchString(in.Place) {
		return nil, fmt.Errorf("ask: --placement must be <vendor>:<slug> (lowercase)")
	}
	if why := store.CheckAskClass(in.Class, in.Flag, in.FlagMsg); why != "" {
		return nil, fmt.Errorf("ask: %s", why)
	}
	if (in.Class != "" || in.Flag != "") && in.Op != store.AskQueue {
		return nil, fmt.Errorf("ask: --class and --flag go with queue only")
	}
	m := map[string]any{"ask_id": in.AskID, "by": in.By, "reason": in.Reason}
	if in.Place != "" {
		m["placement"] = in.Place
	}
	for k, v := range map[string]string{"class": in.Class, "flag": in.Flag, "flag_msg": in.FlagMsg} {
		if v != "" {
			m[k] = v
		}
	}
	if in.Gen != 0 {
		m["gen"] = in.Gen
	}
	if in.Refuse != "" {
		m["refuse"] = in.Refuse
	}
	return m, nil
}

// odBody checks and builds the OD pool's insert, lock and pool ops (spec 134).
func odBody(in AskArgs) (json.RawMessage, error) {
	var v any
	switch in.Op {
	case "enqueue":
		a := store.FleetAsk{Fleet: in.Fleet, AskID: in.AskID, Kind: in.Kind, From: in.From, Topic: in.Topic, Summary: in.Summary,
			IssueKey: in.IssueKey, DedupeKey: in.DedupeKey, VendorAllow: in.VendorAllow, Needs: in.Needs, LeaseS: in.LeaseS}
		if why := store.CheckOdJob(a); why != "" {
			return nil, fmt.Errorf("ask: %s", why)
		}
		if in.Deadline != "" {
			if _, err := time.Parse(time.RFC3339, in.Deadline); err != nil {
				return nil, fmt.Errorf("ask: --deadline must be RFC 3339 (e.g. 2026-10-02T06:00:00Z)")
			}
		}
		v = map[string]any{"ask_id": a.AskID, "kind": a.Kind, "from": a.From, "topic": a.Topic, "summary": a.Summary,
			"deadline_at": in.Deadline, "issue_key": a.IssueKey, "dedupe_key": a.DedupeKey, "vendor_allow": a.VendorAllow,
			"needs": a.Needs, "lease_s": a.LeaseS, "needs_owner": in.NeedsOwner}
	case "lock-next":
		q := store.OdLock{Fleet: in.Fleet, Seat: in.Seat, Vendor: in.Vendor, Harness: in.Harness, Caps: in.Caps}
		if why := store.CheckOdLock(q); why != "" {
			return nil, fmt.Errorf("ask: %s", why)
		}
		v = map[string]any{"seat": q.Seat, "vendor": q.Vendor, "harness": q.Harness, "caps": q.Caps}
	case "pool":
		m := map[string]any{}
		for k, x := range in.Pool {
			m[k] = x
		}
		if in.PoolSet {
			m["set"], m["by"] = true, in.By
		}
		v = m
	}
	return json.Marshal(v)
}
