// SPDX-License-Identifier: AGPL-3.0-only

package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/channelmove"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// What a stuck move shows (spec 169 T17, section 8.5.6):
//
//	GET /v1/channel-moves/{move_id}   in <DST>'s host, on the member session
//
//   - The stored refusal: a step the operator route refuses (P2 to P7, and the
//     P2b mark) keeps its reason in its own row in <DST>, detail.refused
//     (store.ChannelMoveStatuses); the hub-wide log still names no channel (C13).
//   - The state is read from the journal only, and nothing says "Moved" before
//     its done_at: waiting (P1 alone; stuck after 15 minutes), running,
//     not_moved (P2 to P4 refused), cleanup_failed (P4 done, P5 or P6
//     refused), traces (P7's proofs not 0) and moved.
//   - The status line: one hub note per state in the GO's topic of the
//     operator workspace, under an id seeded by the move, the state and the
//     reason, so a re-run refused for the same reason posts nothing new.
//     running and a waiting move not yet stuck post nothing.
//   - The #alerts line: once per move, when it has waited 15 minutes for a box
//     (SweepChannelMoves, on the hub's retention sweep). It names the move id
//     and the topic, not the channel.
//   - Who reads: the session door first (humanTenant, as C29), then the biz
//     owner of the operator workspace; anyone else, and an unknown move id,
//     gets the same 404.

// channelMoveWaitAfter is how long a move waits for a box before it is stuck.
const channelMoveWaitAfter = 15 * time.Minute

// channelMoveOrder is 8.2's order of the steps.
var channelMoveOrder = []string{"P1", "P2", "P2b", "P3", "P4", "P5", "P6", "P7"}

// The states of 8.5.6's table, and the two before it.
const (
	moveStateWaiting       = "waiting"
	moveStateRunning       = "running"
	moveStateNotMoved      = "not_moved"
	moveStateCleanupFailed = "cleanup_failed"
	moveStateTraces        = "traces"
	moveStateMoved         = "moved"
)

// channelMoveRefusal is a step's detail.refused.
type channelMoveRefusal struct {
	Token  string              `json:"token"`
	Reason string              `json:"reason"`
	At     string              `json:"at"`
	Proofs []channelmove.Proof `json:"proofs,omitempty"`
}

// channelMoveStepView is one step as the status shows it.
type channelMoveStepView struct {
	State     string `json:"state"` // started, done or refused
	StartedAt string `json:"started_at"`
	DoneAt    string `json:"done_at,omitempty"`
	Reason    string `json:"reason,omitempty"`
}

// channelMoveStatus is the route's answer and the source of the status line.
type channelMoveStatus struct {
	MoveID  string                         `json:"move_id"`
	Src     string                         `json:"src"`
	Channel string                         `json:"channel"`
	Dst     string                         `json:"dst"`
	State   string                         `json:"state"`
	Stuck   bool                           `json:"stuck"`
	Line    string                         `json:"line"`
	Step    string                         `json:"step,omitempty"`
	Reason  string                         `json:"reason"`
	Proofs  []channelmove.Proof            `json:"proofs"`
	Kept    json.RawMessage                `json:"kept"`
	Link    string                         `json:"link"`
	Steps   map[string]channelMoveStepView `json:"steps"`
}

func (s *Server) routeChannelMoveStatus(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/channel-moves/{move_id}", s.handleChannelMoveStatus)
	mux.HandleFunc("OPTIONS /v1/channel-moves/{move_id}", s.channelMoveStatusPreflight)
}

func (s *Server) channelMoveStatusPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleChannelMoveStatus is GET /v1/channel-moves/{move_id}.
func (s *Server) handleChannelMoveStatus(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	const unknown = "no such move"
	op, err := s.operatorTenant(r.Context())
	if err != nil || op == "" || !s.channelMoveOwner(r.Context(), op, hum) {
		writeErr(w, http.StatusNotFound, "unknown_move", unknown)
		return
	}
	cs, ok := s.o.Store.(store.ChannelMoveStatuses)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store has no channel move journal")
		return
	}
	id := strings.ToLower(r.PathValue("move_id"))
	if !msg.IsUUID(id) {
		writeErr(w, http.StatusNotFound, "unknown_move", unknown)
		return
	}
	j, err := cs.ChannelMoveByID(r.Context(), t.ID, id)
	switch {
	case err != nil:
		s.o.Log.Error().Err(err).Str("move_id", id).Msg("browser.channel_move_status")
		writeErr(w, http.StatusInternalServerError, "internal", "status unavailable")
	case j == nil:
		writeErr(w, http.StatusNotFound, "unknown_move", unknown)
	default:
		writeJSON(w, http.StatusOK, s.channelMoveStatusOf(t.ID, j))
	}
}

// channelMoveRefusalOf is a step's stored refusal; nil when it has none or is done.
func channelMoveRefusalOf(st store.ChannelMoveStep) *channelMoveRefusal {
	var d struct {
		Refused *channelMoveRefusal `json:"refused"`
	}
	if st.Done || json.Unmarshal(st.Detail, &d) != nil {
		return nil
	}
	return d.Refused
}

func moveTime(at time.Time) string {
	if at.IsZero() {
		return ""
	}
	return at.UTC().Format(time.RFC3339)
}

// channelMoveStepViews are the journal's steps, each with its state.
func channelMoveStepViews(j *store.ChannelMoveJournalRow) map[string]channelMoveStepView {
	out := map[string]channelMoveStepView{}
	for name, st := range j.Steps {
		v := channelMoveStepView{State: "started", StartedAt: moveTime(st.StartedAt), DoneAt: moveTime(st.DoneAt)}
		if st.Done {
			v.State = "done"
		} else if ref := channelMoveRefusalOf(st); ref != nil {
			v.State, v.Reason = "refused", ref.Reason
		}
		out[name] = v
	}
	return out
}

// channelMoveLastRefused is the latest step in 8.2's order with a stored refusal.
func channelMoveLastRefused(j *store.ChannelMoveJournalRow) (string, *channelMoveRefusal) {
	for i := len(channelMoveOrder) - 1; i >= 0; i-- {
		if ref := channelMoveRefusalOf(j.Steps[channelMoveOrder[i]]); ref != nil {
			return channelMoveOrder[i], ref
		}
	}
	return "", nil
}

// channelMoveStatusOf reads the state from the journal (8.5.6's table).
func (s *Server) channelMoveStatusOf(dst string, j *store.ChannelMoveJournalRow) channelMoveStatus {
	st := channelMoveStatus{MoveID: j.MoveID, Src: j.Src, Channel: j.Channel, Dst: dst, Proofs: []channelmove.Proof{},
		Kept: json.RawMessage(`[]`), Steps: channelMoveStepViews(j),
		Link: GcalWorkspaceURL(s.o.TenantHostPattern, s.o.WUIApexTenant, "")(dst) + "/channel/" + j.Channel}
	in := "The channel is in " + dst
	step, ref := channelMoveLastRefused(j)
	switch {
	case j.Done:
		st.State, st.Line = moveStateMoved, "Moved. "+in+": "+st.Link
		st.Kept = channelMoveKeptOf(j.Steps["P7"])
	case step == "P7":
		st.State, st.Proofs = moveStateTraces, ref.Proofs
		st.Line = in + ", but " + j.Src + " still holds traces: " + channelMoveTraceNames(ref.Proofs) + ". " + st.Link
	case ref != nil && j.StepDone("P4"):
		st.State = moveStateCleanupFailed
		st.Line = in + ", the clean-up did not finish: " + ref.Reason + ". " + st.Link
	case ref != nil:
		st.State = moveStateNotMoved
		st.Line = "Not moved. Nothing of the channel changed: " + ref.Reason + ". A re-run comes with the next pick-up."
	case len(j.Steps) == 1 && j.StepDone("P1"):
		st.State, st.Stuck = moveStateWaiting, s.o.Now().Sub(j.Steps["P1"].DoneAt) >= channelMoveWaitAfter
		st.Line = "Waiting for a box to pick this up. Nothing has moved."
	case j.StepDone("P4"):
		st.State, st.Line = moveStateRunning, in+"; the clean-up runs."
	default:
		st.State, st.Line = moveStateRunning, "A box is moving it. Nothing has moved yet."
	}
	if ref != nil && !j.Done {
		st.Step, st.Reason = step, ref.Reason
	}
	return st
}

// channelMoveKeptOf is P7's kept list with its dates (p7 keeps it with the proofs).
func channelMoveKeptOf(p7 store.ChannelMoveStep) json.RawMessage {
	var p struct {
		Kept json.RawMessage `json:"kept"`
	}
	if json.Unmarshal(p7.Proofs, &p) != nil || len(p.Kept) == 0 || string(p.Kept) == "null" {
		return json.RawMessage(`[]`)
	}
	return p.Kept
}

// channelMoveTraceNames is each failed proof's name and count.
func channelMoveTraceNames(ps []channelmove.Proof) string {
	names := make([]string, 0, len(ps))
	for _, p := range ps {
		names = append(names, p.Name+" "+strconv.FormatInt(p.Count, 10))
	}
	return strings.Join(names, ", ")
}

// channelMoveRecord stores the refusal of a step the run attempted, then posts
// the move's status line. It runs before the answer, even when the request is
// gone: a refusal the journal does not hold is one only the caller saw.
func (s *Server) channelMoveRecord(ctx context.Context, run *channelMoveRun, step string, err error) {
	cs, ok := s.o.Store.(store.ChannelMoveStatuses)
	if !ok || run.j == nil {
		return
	}
	ctx = context.WithoutCancel(ctx)
	if run.attempted && err != nil {
		ref := channelMoveRefusalFor(err, s.o.Now())
		if rerr := cs.RefuseChannelMoveStep(ctx, run.q.Dst, run.j.MoveID, run.q.Channel, step, ref); rerr != nil {
			s.o.Log.Error().Err(rerr).Str("move_id", run.j.MoveID).Str("step", step).Msg("operator.channel_move_refusal not stored")
		}
	}
	j, rerr := cs.ChannelMoveByID(ctx, run.q.Dst, run.j.MoveID)
	if rerr != nil || j == nil {
		s.o.Log.Error().Err(rerr).Str("move_id", run.j.MoveID).Msg("operator.channel_move_status not read")
		return
	}
	s.channelMoveStatusPost(ctx, run.q.Dst, j)
}

// channelMoveRefusalFor is what the journal keeps of err: the operator's token
// and reason (channelMoveFailure), and P7's failed proofs.
func channelMoveRefusalFor(err error, now time.Time) channelMoveRefusal {
	ref := channelMoveRefusal{At: now.UTC().Format(time.RFC3339)}
	var failed channelMoveProofsFailed
	if errors.As(err, &failed) {
		lines, _ := failed.answer["proofs"].([]channelmove.Proof)
		ref.Token, ref.Reason, ref.Proofs = "proofs_failed", err.Error(), channelmove.Failed(lines)
		return ref
	}
	_, ref.Token, ref.Reason = channelMoveFailure(err)
	return ref
}

// channelMoveStatusPost posts the state's line in the GO's topic, and the
// #alerts line of a stuck wait. running and an early wait post nothing.
func (s *Server) channelMoveStatusPost(ctx context.Context, dst string, j *store.ChannelMoveJournalRow) {
	st := s.channelMoveStatusOf(dst, j)
	if st.State == moveStateRunning || (st.State == moveStateWaiting && !st.Stuck) {
		return
	}
	log := s.o.Log.Error().Str("move_id", j.MoveID).Str("state", st.State)
	op, err := s.operatorTenant(ctx)
	if err != nil || op == "" {
		log.Err(err).Msg("channel_move_status: no operator workspace, line not posted")
		return
	}
	g, err := s.o.Store.GetMessageClaim(ctx, op, j.GoMsgID)
	if err != nil {
		log.Err(err).Msg("channel_move_status: the GO was not read, line not posted")
		return
	}
	ch := g.Channel
	if ch == "" {
		ch = store.ChannelLobby
	}
	id := uid.FromSeed("spool-channel-move-status:" + j.MoveID + ":" + st.State + ":" + st.Step + ":" + st.Reason)
	if err := s.postHubNote(ctx, op, ch, g.TaskID, id, st.Line); err != nil {
		log.Err(err).Msg("channel_move_status: line not posted")
	}
	if st.State == moveStateWaiting {
		s.channelMoveWaitAlert(ctx, op, j.MoveID, g.TaskID)
	}
}

// channelMoveWaitAlert is the #alerts line of a move no box picked up, once.
func (s *Server) channelMoveWaitAlert(ctx context.Context, op, moveID, topic string) {
	log := s.o.Log.Warn().Str("move_id", moveID)
	if _, err := s.o.Store.Channel(ctx, op, FleetAlertsChannel); err != nil || len(s.o.WUIKey) == 0 {
		log.Err(err).Msg("channel_move_status: #alerts or the box-wui key missing, alert not posted")
		return
	}
	body := "A channel move waits for a box: P1 is done and no step started for 15 minutes. Nothing has moved. " +
		"Move `" + moveID + "`, its status in [its topic](/t/" + topic + ")."
	if err := s.postFleetAlert(ctx, op, uid.FromSeed("spool-channel-move-waiting:"+moveID), body); err != nil {
		log.Err(err).Msg("channel_move_status: alert not posted")
	}
}

// SweepChannelMoves posts the line and the alert of every move that waited 15
// minutes for a box (8.5.6), on the retention sweep. A move already posted is
// a no-op insert. It answers how many it read.
func (s *Server) SweepChannelMoves(ctx context.Context) int {
	cs, ok := s.o.Store.(store.ChannelMoveStatuses)
	if !ok {
		return 0
	}
	waiting, err := cs.WaitingChannelMoves(ctx, s.o.Now().Add(-channelMoveWaitAfter))
	if err != nil {
		s.o.Log.Error().Err(err).Msg("channel_move_status: waiting moves not read")
		return 0
	}
	for _, w := range waiting {
		j, err := cs.ChannelMoveByID(ctx, w.Dst, w.MoveID)
		if err != nil || j == nil {
			s.o.Log.Error().Err(err).Str("move_id", w.MoveID).Msg("channel_move_status: journal not read")
			continue
		}
		s.channelMoveStatusPost(ctx, w.Dst, j)
	}
	return len(waiting)
}
