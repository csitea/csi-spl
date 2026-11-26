package hub

import (
	"context"
	"encoding/json"
	"net/http"
	"regexp"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The Queue tab's route and the placer's holds (spec 153 sections 3.22.3,
// 3.22.4 and the hold part of 3.22.8, row Q3, SPL-6596):
//
//	GET /v1/operator/fleet-queue?fleet=<fleet, default main>&placed=<0|1>
//
// Who may: operatorReadCaller, as GET /v1/operator/fleet-lanes. The rows are
// the operator workspace's orch asks in the placer's line, exactly as
// spl_spawn_q_rows (csi-spl-orc run/spl-spawn-queue.func.sh) reads them, so
// the tab and do_spl_spawn_queue agree (C103): state queued, or acked with
// an enqueued_at (placing), the placing ones first, then by position.
// placed=1 adds the closed rows that were queued (the hub keeps them a
// week, rdb 0097), after the line, newest close first.
//
// lane (C104): a row closed with reason "placed: <ID>@<box>" (the placer's
// TAKE, do_spl_spawn_placed) names that lane; any other reason names none,
// and it is never guessed from the summary.

const fleetQueueRole = "orch"

// fleetQueuePlacedRe is the one reason a lane is read from.
var fleetQueuePlacedRe = regexp.MustCompile(`^placed: ([acgmoqu]-[0-9]{3})@([a-z0-9][a-z0-9-]{0,31})$`)

type fleetQueueRowJSON struct {
	AskID          string `json:"ask_id"`
	State          string `json:"state"` // queued | placing (acked) | done | declined | dead
	Position       int    `json:"position,omitempty"`
	QueueLen       int    `json:"queue_len,omitempty"`
	Priority       int    `json:"priority"`
	PrioritySource string `json:"priority_source"`
	PriorityBy     string `json:"priority_by,omitempty"`
	QueueRank      int64  `json:"queue_rank,omitempty"`
	RankBy         string `json:"rank_by,omitempty"`
	Class          string `json:"class"`
	Flag           string `json:"flag,omitempty"`
	Summary        string `json:"summary"`
	Discussion     string `json:"discussion,omitempty"`
	IssueKey       string `json:"issue_key,omitempty"`
	Placement      string `json:"placement,omitempty"`
	Vendor         string `json:"vendor,omitempty"`
	From           string `json:"from"`
	Topic          string `json:"topic"`
	EnqueuedAt     string `json:"enqueued_at,omitempty"`
	InLineS        int64  `json:"in_line_s"`
	HoldReason     string `json:"hold_reason,omitempty"` // "" = waits for room
	Reason         string `json:"reason,omitempty"`
	Lane           string `json:"lane,omitempty"` // <ID>@<box>, only from "placed: <ID>@<box>"
}

type fleetQueueViewJSON struct {
	AsOf  string              `json:"as_of"`
	Fleet string              `json:"fleet"`
	Total int                 `json:"total"` // the queued rows (Position's n/total)
	Rows  []fleetQueueRowJSON `json:"rows"`
}

func (s *Server) routeFleetQueue(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/fleet-queue", s.handleFleetQueueView)
	mux.HandleFunc("OPTIONS /v1/operator/fleet-queue", s.operatorWorkspacesPreflight)
}

// GET /v1/operator/fleet-queue?fleet=&placed=
func (s *Server) handleFleetQueueView(w http.ResponseWriter, r *http.Request) {
	tenant, _, _, ok := s.operatorReadCaller(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	fleet := q.Get("fleet")
	if fleet == "" {
		fleet = fleetLanesFleet
	}
	if !store.FleetNameRe.MatchString(fleet) {
		writeErr(w, http.StatusBadRequest, "bad_query", "fleet must be a lowercase slug ([a-z0-9-], up to 32)")
		return
	}
	placed := q.Get("placed")
	if placed != "" && placed != "0" && placed != "1" {
		writeErr(w, http.StatusBadRequest, "bad_query", "placed must be 0 or 1")
		return
	}
	out, err := s.fleetQueueView(r.Context(), tenant, fleet, placed == "1")
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("fleet", fleet).Msg("fleet queue view")
		writeErr(w, http.StatusInternalServerError, "internal", "asks unavailable")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// fleetQueueView is the line of tenant's fleet as spl_spawn_q_rows reads it,
// and with placed the closed rows that were queued.
func (s *Server) fleetQueueView(ctx context.Context, tenant, fleet string, placed bool) (fleetQueueViewJSON, error) {
	now := s.o.Now()
	out := fleetQueueViewJSON{AsOf: now.UTC().Format(time.RFC3339), Fleet: fleet, Rows: []fleetQueueRowJSON{}}
	as, err := s.o.Store.ListFleetAsks(ctx, tenant, fleet, fleetQueueRole, placed, now)
	if err != nil {
		return out, err
	}
	line := slices.DeleteFunc(slices.Clone(as), func(a store.FleetAsk) bool { return !store.AskInLine(a) })
	// spl_spawn_q_rows: sort_by((acked first), .position), stable over the list order
	slices.SortStableFunc(line, func(a, b store.FleetAsk) int {
		return fleetQueueKey(a) - fleetQueueKey(b)
	})
	for _, a := range line {
		if a.State == "queued" {
			out.Total++
		}
		out.Rows = append(out.Rows, fleetQueueRow(a, now))
	}
	if placed {
		closed := slices.DeleteFunc(as, func(a store.FleetAsk) bool { return a.Open() || a.EnqueuedAt.IsZero() })
		slices.SortStableFunc(closed, func(a, b store.FleetAsk) int { return b.UpdatedAt.Compare(a.UpdatedAt) })
		for _, a := range closed {
			out.Rows = append(out.Rows, fleetQueueRow(a, now))
		}
	}
	return out, nil
}

// fleetQueueKey orders the line: placing (acked) rows first (position 0),
// then the queue by position.
func fleetQueueKey(a store.FleetAsk) int {
	if a.State == "acked" {
		return 0
	}
	return 1 + a.Position
}

func fleetQueueRow(a store.FleetAsk, now time.Time) fleetQueueRowJSON {
	state := a.State
	if state == "acked" {
		state = "placing"
	}
	vendor, _, _ := strings.Cut(a.Placement, ":")
	row := fleetQueueRowJSON{AskID: a.AskID, State: state, Position: a.Position, QueueLen: a.QueueLen,
		Priority: a.Priority, PrioritySource: a.PrioritySource, PriorityBy: a.PriorityBy, QueueRank: a.QueueRank, RankBy: a.RankBy,
		Class: a.Class, Flag: a.Flag, Summary: a.Summary, Discussion: a.Discussion, IssueKey: a.IssueKey,
		Placement: a.Placement, Vendor: vendor, From: a.From, Topic: a.Topic, EnqueuedAt: askTime(a.EnqueuedAt),
		HoldReason: a.HoldReason, Reason: a.Reason, Lane: fleetQueueLane(a)}
	if !a.EnqueuedAt.IsZero() && a.Open() {
		row.InLineS = int64(now.Sub(a.EnqueuedAt).Seconds())
	}
	return row
}

// fleetQueueLane is the lane a closed row was placed as, "" for any other
// row or reason (C104).
func fleetQueueLane(a store.FleetAsk) string {
	if a.State != "done" {
		return ""
	}
	m := fleetQueuePlacedRe.FindStringSubmatch(a.Reason)
	if m == nil {
		return ""
	}
	return m[1] + "@" + m[2]
}

// askHoldsReq is a holds request's Ask object.
type askHoldsReq struct {
	By    string            `json:"by"`
	Role  string            `json:"role"`
	Holds map[string]string `json:"holds"`
}

// askHolds writes the placer's hold map (ask_op holds, spec 153 3.22.8,
// C122); the answer's asks are the rows it wrote, none when nothing changed.
func (s *Server) askHolds(ctx context.Context, x *session, f wire.Frame) (askAnswer, *issueErr) {
	var in askHoldsReq
	if err := json.Unmarshal(f.Ask, &in); err != nil {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "ask must be {by, role, holds: {ask_id: reason}}"}
	}
	var ae *issueErr
	if in.By, ae = s.resolveAgent(ctx, x.tenant, in.By, ""); ae != nil {
		return askAnswer{}, ae
	}
	in.By = store.AskAtBox(in.By, x.box)
	if in.Role == "" {
		in.Role = fleetQueueRole
	}
	if why := checkAskHolds(in); why != "" {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", why}
	}
	st, ok := s.o.Store.(store.FleetAskHolder)
	if !ok {
		return askAnswer{}, &issueErr{http.StatusNotImplemented, "unsupported", "this hub's store keeps no hold reasons"}
	}
	got, err := st.SetFleetAskHolds(ctx, x.tenant, store.AskHolds{Fleet: f.Fleet, Role: in.Role, Holds: in.Holds}, s.o.Now().UTC())
	if err != nil {
		s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Msg("fleet ask holds")
		return askAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "asks unavailable"}
	}
	if len(got) > 0 {
		s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("fleet", f.Fleet).Str("by", in.By).
			Int("holds", len(in.Holds)).Int("written", len(got)).Msg("fleet ask holds")
	}
	return askAnswer{Fleet: f.Fleet, Asks: askRows(got)}, nil
}

// checkAskHolds is a holds request's shape: the writer, a role slug, at most
// store.AskHoldsMax entries, each a lowercase ask id to a one-line reason of
// 1..store.AskTextMax bytes.
func checkAskHolds(in askHoldsReq) string {
	switch {
	case !store.ValidAskAgent(in.By) || in.By == "":
		return "by must be the placer, <ID>@<box>"
	case !store.FleetNameRe.MatchString(in.Role):
		return "role must be a lowercase slug"
	case len(in.Holds) > store.AskHoldsMax:
		return "holds names at most 500 asks"
	}
	for id, why := range in.Holds {
		if !store.AskIDRe.MatchString(id) {
			return "each holds key must be an ask id (a lowercase UUID)"
		}
		if why == "" || len(why) > store.AskTextMax || !utf8.ValidString(why) || strings.ContainsAny(why, "\n\r") {
			return "each hold reason must be one line of 1..500 bytes"
		}
	}
	return ""
}
