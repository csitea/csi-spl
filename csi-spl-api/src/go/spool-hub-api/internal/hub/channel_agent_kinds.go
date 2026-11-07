package hub

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// The agent kinds a channel can be given (SPL-5000, owner HUM-10 msgs de2fdb16
// and 9089e3fe: "if the orchestrator can spawn a new AJY agent, I should be
// able to add it as an agent of a channel"). Usable is the setting every
// box's do_spl_lane_mix obeys: store.AgentKinds minus the instance's kinds off
// and running pauses, and (holder ruling 15040649 W2) only a kind whose CLI
// some live box has measured: installedKinds below. The WUI holds no list.
//
//	GET  /v1/channels/{channel}/agent-kinds  {channel, kinds: [{kind, online}], asks: [{kind, state, reason}]}
//	POST /v1/channels/{channel}/agent-kinds  {kind} -> 202 {channel, kind, ask_id, created}
//
// online: an agent of the kind can be picked here already, its box online and
// the agent not yet in the channel. POST asks the orchestrator for a new agent
// of the kind, seated in this channel: one role orch ask in the operator
// workspace (the one the fleet's lease lives in), which the asks tick raises
// to the holder and do_spl_channel_seat_place carries out. The same people may
// ask as may invite an agent. A second ask while one is open answers the open
// one with created false. asks is the newest seat ask per kind for this
// channel, open or closed in the last week, so the person sees a refusal
// (R7 W2: a kind installed on no box is declined with the launcher's reason).
//
// Only the operator workspace may ask (SPL-5000 R7 W1): the ask lands in the
// operator's fleet and the seat is an operator box's agent, so another
// workspace's member would spend the operator's fleet. Any other workspace
// lists no kinds and gets 403 operator_only, until spec 147 P5 caps the
// seating paths.

// boxRowID is the lane map's reserved load-row id (LANE_BOX_ROW_ID).
const boxRowID = "BOX-0"

// boxRowMaxAge is how old a box's BOX-0@<box> lane-map row may be and still
// count: the lane map's LANE_BOX_ROW_MAX_S (3600 s), past which spawn-window.sh
// no longer reads that box either. A box rewrites its row every 300 s while
// its map runs, so a row this old is a box that stopped.
const boxRowMaxAge = time.Hour

// channelSeatAskTopic is the ask's task id; the holder's action lists by it.
const channelSeatAskTopic = "channel-seat"

// agentKindRow is one usable kind on GET /v1/channels/{channel}/agent-kinds.
type agentKindRow struct {
	Kind   string `json:"kind"`
	Online bool   `json:"online"`
}

// seatAskRow is the newest seat ask of one kind for the channel.
type seatAskRow struct {
	Kind   string `json:"kind"`
	State  string `json:"state"`
	Reason string `json:"reason"`
}

func (s *Server) routeChannelAgentKinds(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/channels/{channel}/agent-kinds", s.handleChannelAgentKinds)
	mux.HandleFunc("POST /v1/channels/{channel}/agent-kinds", s.handleRequestChannelAgent)
	mux.HandleFunc("OPTIONS /v1/channels/{channel}/agent-kinds", s.channelMembersPreflight)
}

// usableAgentKinds is the kinds a box may start a lane of now for tenant, in
// AgentKinds order. A hub with no operator workspace has no orchestrator, and
// a workspace that is not the operator's may not ask it: none.
func (s *Server) usableAgentKinds(ctx context.Context, tenant string) ([]string, *issueErr) {
	op, err := s.operatorTenant(ctx)
	if err != nil {
		return nil, &issueErr{http.StatusServiceUnavailable, "unavailable", "the operator workspace was not read"}
	}
	if op == "" || tenant != op {
		return []string{}, nil
	}
	fl, ie := s.fleetLoadInForce(ctx)
	if ie != nil {
		return nil, ie
	}
	installed, measured := s.installedKinds(ctx, op)
	out := []string{}
	for _, k := range store.AgentKinds {
		if _, paused := fl.Paused[k]; paused || slices.Contains(fl.AgentKindsOff, k) {
			continue
		}
		if !measured || installed[k] {
			out = append(out, k)
		}
	}
	return out, nil
}

// installedKinds is the kinds named in the cli= of a live BOX-0@<box> row of
// the operator's orch fleet: the CLIs each box measured as its agent user
// (spool_vendor_clis, SPL-1649) and published in its lane-map load row. Live =
// state live and written within boxRowMaxAge. measured is false when no live
// row carries a cli= at all (no fleet, no box row, or only boxes older than
// the cli= field): then nothing filters, as spawn-window.sh treats an
// unmeasured box as a candidate; listing nothing would hide every kind on a
// fleet that never published one. A failed read is the same.
func (s *Server) installedKinds(ctx context.Context, op string) (map[string]bool, bool) {
	out := map[string]bool{}
	fleet, err := s.orchFleet(ctx, op)
	if err != nil || fleet == "" {
		return out, false
	}
	ls, err := s.o.Store.ListFleetLanes(ctx, op, fleet, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", op).Msg("box rows for channel agent kinds")
		return out, false
	}
	measured := false
	for _, l := range ls {
		if l.AgentID != boxRowID || l.State != "live" || l.Age > boxRowMaxAge {
			continue
		}
		for _, tok := range strings.Fields(l.Scope) {
			list, ok := strings.CutPrefix(tok, "cli=")
			if !ok {
				continue
			}
			measured = true
			for _, k := range strings.Split(list, ",") {
				if k != "" {
					out[k] = true
				}
			}
		}
	}
	return out, measured
}

// pickableKinds is the kinds with an agent the channel can still pick: on an
// online box of the tenant and not in the channel. A failed read answers none,
// so the kind is offered as a new agent rather than the dialog failing.
func (s *Server) pickableKinds(ctx context.Context, tenant, ch string) map[string]bool {
	out := map[string]bool{}
	roster, err := s.o.Store.Roster(ctx, tenant)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("roster for channel agent kinds")
		return out
	}
	members, err := s.o.Store.ChannelMembers(ctx, tenant, ch)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("members for channel agent kinds")
		return out
	}
	online := s.boxesOnline(ctx, tenant)
	for box, ids := range roster {
		if box == "box-wui" || !(online[box] || s.boxSession(tenant, box) != nil) {
			continue
		}
		for _, id := range ids {
			if !contains(members[box], id) {
				out[agentid.Kind(id)] = true
			}
		}
	}
	return out
}

func (s *Server) handleChannelAgentKinds(w http.ResponseWriter, r *http.Request) {
	t, ch, _, ok := s.channelDoor(w, r)
	if !ok {
		return
	}
	kinds, ie := s.usableAgentKinds(r.Context(), t.ID)
	if ie != nil {
		writeErr(w, ie.status, ie.token, ie.detail)
		return
	}
	pickable := s.pickableKinds(r.Context(), t.ID, ch)
	rows := make([]agentKindRow, 0, len(kinds))
	for _, k := range kinds {
		rows = append(rows, agentKindRow{Kind: k, Online: pickable[k]})
	}
	asks := []seatAskRow{}
	if len(kinds) > 0 {
		asks = s.channelSeatAsks(r.Context(), t.ID, ch)
	}
	writeJSON(w, http.StatusOK, map[string]any{"channel": ch, "kinds": rows, "asks": asks})
}

// channelSeatAsks is the newest seat ask per kind for the channel, in the
// order they were made. A failed read answers none: the list still works.
func (s *Server) channelSeatAsks(ctx context.Context, tenant, ch string) []seatAskRow {
	out := []seatAskRow{}
	fleet, err := s.orchFleet(ctx, tenant)
	if err != nil || fleet == "" {
		return out
	}
	all, err := s.o.Store.ListFleetAsks(ctx, tenant, fleet, "orch", true, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("seat asks for channel agent kinds")
		return out
	}
	rx := regexp.MustCompile(`^channel seat: kind=([a-z0-9]+) tenant=` + regexp.QuoteMeta(tenant) + ` channel=` + regexp.QuoteMeta(ch) + ` `)
	newest := map[string]store.FleetAsk{}
	for _, a := range all {
		m := rx.FindStringSubmatch(a.Summary)
		if a.Topic != channelSeatAskTopic || m == nil {
			continue
		}
		if prev, ok := newest[m[1]]; !ok || a.CreatedAt.After(prev.CreatedAt) {
			newest[m[1]] = a
		}
	}
	for k, a := range newest {
		out = append(out, seatAskRow{Kind: k, State: a.State, Reason: a.Reason})
	}
	slices.SortFunc(out, func(x, y seatAskRow) int { return newest[x.Kind].CreatedAt.Compare(newest[y.Kind].CreatedAt) })
	return out
}

// orchFleet is the fleet whose orch lease the operator workspace holds; "" when
// no fleet has one (nobody would ever read the ask).
func (s *Server) orchFleet(ctx context.Context, op string) (string, error) {
	leases, err := s.o.Store.FleetLeases(ctx, op, s.o.Now())
	if err != nil {
		return "", err
	}
	for _, l := range leases {
		if l.Role == "orch" {
			return l.Fleet, nil
		}
	}
	return "", nil
}

func (s *Server) handleRequestChannelAgent(w http.ResponseWriter, r *http.Request) {
	t, ch, hum, ok := s.channelDoor(w, r)
	if !ok {
		return
	}
	row, ok := s.channelRecord(w, r, t.ID, ch)
	if !ok {
		return
	}
	if !mayInviteChannel(row.CreatedBy, hum, row.MembersOpenInvite) || hum == "" {
		writeErr(w, http.StatusForbidden, "forbidden", "only the channel owner may add members")
		return
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return
	}
	var body struct {
		Kind string `json:"kind"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxMemberJSONBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil || body.Kind == "" {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {kind}")
		return
	}
	op, err := s.operatorTenant(r.Context())
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the operator workspace was not read")
		return
	}
	if op != "" && t.ID != op {
		writeErr(w, http.StatusForbidden, "operator_only", "only the operator workspace may ask for a new agent")
		return
	}
	kinds, ie := s.usableAgentKinds(r.Context(), t.ID)
	if ie != nil {
		writeErr(w, ie.status, ie.token, ie.detail)
		return
	}
	if !slices.Contains(kinds, body.Kind) {
		writeErr(w, http.StatusConflict, "kind_not_usable", body.Kind+" cannot be started now")
		return
	}
	got, created, err := s.putChannelSeatAsk(r.Context(), t.ID, ch, body.Kind, hum)
	switch {
	case errors.Is(err, errNoOrchestrator):
		writeErr(w, http.StatusConflict, "no_orchestrator", "this instance has no orchestrator")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Str("channel", ch).Msg("channel seat ask")
		writeErr(w, http.StatusInternalServerError, "internal", "the ask was not stored")
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("channel", ch).Str("kind", body.Kind).Str("by", hum).
		Str("ask", got.AskID).Bool("created", created).Msg("channel agent asked of the orchestrator")
	writeJSON(w, http.StatusAccepted, map[string]any{"channel": ch, "kind": body.Kind, "ask_id": got.AskID, "created": created})
}

var errNoOrchestrator = errors.New("no orchestrator")

// putChannelSeatAsk records the ask, or finds the open one for the same seat.
// The summary is the hand-over: do_spl_channel_seat_place reads its fields.
func (s *Server) putChannelSeatAsk(ctx context.Context, tenant, ch, kind, hum string) (store.FleetAsk, bool, error) {
	op, err := s.operatorTenant(ctx)
	if err != nil {
		return store.FleetAsk{}, false, err
	}
	if op == "" {
		return store.FleetAsk{}, false, errNoOrchestrator
	}
	fleet, err := s.orchFleet(ctx, op)
	if err != nil {
		return store.FleetAsk{}, false, err
	}
	if fleet == "" {
		return store.FleetAsk{}, false, errNoOrchestrator
	}
	now := s.o.Now()
	seat := fmt.Sprintf("channel seat: kind=%s tenant=%s channel=%s", kind, tenant, ch)
	open, err := s.o.Store.ListFleetAsks(ctx, op, fleet, "orch", false, now)
	if err != nil {
		return store.FleetAsk{}, false, err
	}
	for _, a := range open {
		if a.Topic == channelSeatAskTopic && strings.HasPrefix(a.Summary, seat+" ") {
			return a, false, nil
		}
	}
	id := uid.New()
	a := store.FleetAsk{Fleet: fleet, AskID: id, Role: "orch", Kind: "task", From: hum, Topic: channelSeatAskTopic,
		Summary: fmt.Sprintf("%s by=%s; run: ASK_ID=%s DRY_RUN=0 ./run -a do_spl_channel_seat_place", seat, hum, id[:8])}
	if why := store.CheckFleetAsk(a); why != "" {
		return store.FleetAsk{}, false, errors.New(why)
	}
	return s.o.Store.PutFleetAsk(ctx, op, a, "box-wui", now)
}
