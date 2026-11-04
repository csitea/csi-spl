// SPDX-License-Identifier: AGPL-3.0-only

package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/channelmove"
	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The hub's steps of a channel move (spec 169 T7 step 2, sections 8.2, 8.3): op
// journal reads the journal, op step runs P1, P2, P3, P4, P6 and P7, and op mark
// records the box's P2b and P5. The shell resumes from the journal (C17).
//
//   - Each step needs the one before it done, the journal's GO and its move id,
//     so a stray call cannot reach P4 or P6; P1..P4 close once P4 commits.
//   - P4 clears the seats P2 listed, and only with a stored probe for each (W2).
//   - P3 copies the objects P1 froze; P6 copies again from what P4 moved, since a
//     post can land between them, and only then deletes (5.3).
//   - The log names the journal id and the step, never a channel, a slug or an
//     error text (C13); the operator's answer carries the reason.

// channelMovePrior is the step each one waits for (8.2).
var channelMovePrior = map[string]string{"P2": "P1", "P2b": "P2", "P3": "P2b", "P4": "P3", "P5": "P4", "P6": "P5", "P7": "P6"}

// channelMoveRefused is a step's refusal, as the operator reads it.
type channelMoveRefused struct {
	code          int
	token, detail string
}

func (e channelMoveRefused) Error() string { return e.detail }

func moveConflict(detail string) error {
	return channelMoveRefused{http.StatusConflict, "move_refused", detail}
}

// channelMoveRun is one request's step.
type channelMoveRun struct {
	s  *Server
	q  channelMoveRequest
	op string
	jr store.ChannelMoveJournals
	j  *store.ChannelMoveJournalRow
}

// channelMoveJournals answers 501 on a store with no journal (Memory: no P4).
func (s *Server) channelMoveJournals(w http.ResponseWriter) (store.ChannelMoveJournals, bool) {
	jr, ok := s.o.Store.(store.ChannelMoveJournals)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store has no channel move journal")
	}
	return jr, ok
}

// channelMoveDrive runs one step or mark; the GO and TO_NAME are already checked.
func (s *Server) channelMoveDrive(w http.ResponseWriter, r *http.Request, op string, q channelMoveRequest) {
	jr, ok := s.channelMoveJournals(w)
	if !ok {
		return
	}
	if q.Step == nil {
		writeErr(w, http.StatusBadRequest, "bad_step", "step is required")
		return
	}
	run := &channelMoveRun{s: s, q: q, op: op, jr: jr}
	step := *q.Step
	var answer map[string]any
	var err error
	if q.Op == "mark" {
		answer, err = run.mark(r.Context(), step)
	} else {
		answer, err = run.step(r.Context(), step)
	}
	var failed channelMoveProofsFailed
	if errors.As(err, &failed) { // P7 stays not done; the shell reads the counts
		s.o.Log.Error().Str("move_id", run.moveID()).Str("step", step).Msg("operator.channel_move_proofs failed")
		writeJSON(w, http.StatusOK, failed.answer)
		return
	}
	if err != nil {
		s.channelMoveFail(w, run, step, err)
		return
	}
	s.o.Log.Info().Str("operator", op).Str("move_id", run.moveID()).Str("step", step).Msg("operator.channel_move_step")
	writeJSON(w, http.StatusOK, answer)
}

func (run *channelMoveRun) moveID() string {
	if run.j != nil {
		return run.j.MoveID
	}
	return ""
}

// channelMoveFail answers a step's error. The text goes to the operator only.
func (s *Server) channelMoveFail(w http.ResponseWriter, run *channelMoveRun, step string, err error) {
	var ref channelMoveRefused
	switch {
	case errors.As(err, &ref):
		writeErr(w, ref.code, ref.token, ref.detail)
	case errors.Is(err, store.ErrChannelMoveRefused), errors.Is(err, store.ErrConflict):
		writeErr(w, http.StatusConflict, "move_refused", err.Error())
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "unknown_channel", err.Error())
	case errors.Is(err, store.ErrMoveRequest):
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
	default:
		s.o.Log.Error().Str("move_id", run.moveID()).Str("step", step).Msg("operator.channel_move_step failed")
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
	}
}

// load reads the journal and checks this call belongs to it.
func (run *channelMoveRun) load(ctx context.Context) error {
	j, err := run.jr.ChannelMoveJournal(ctx, run.q.Dst, run.q.Src, run.q.Channel)
	switch {
	case err != nil:
		return err
	case j == nil:
		return moveConflict("no journal of this move: run P1 first")
	case run.q.MoveID == nil || *run.q.MoveID != j.MoveID:
		return moveConflict("move_id must be the journal's, " + j.MoveID)
	case !strings.EqualFold(*run.q.GoMsgID, j.GoMsgID):
		return moveConflict("the journal holds another GO for this move")
	}
	run.j = j
	return nil
}

// gate is the order of 8.2: the step before is done, and P1..P4 close at P4's commit.
func (run *channelMoveRun) gate(step string) error {
	if prior := channelMovePrior[step]; !run.j.StepDone(prior) {
		return moveConflict(step + " needs " + prior + " done")
	}
	switch step {
	case "P2", "P2b", "P3", "P4":
		if run.j.StepDone("P4") {
			return moveConflict("P4 committed: only P5, P6 and P7 resume")
		}
	}
	return nil
}

func (run *channelMoveRun) step(ctx context.Context, step string) (map[string]any, error) {
	if step == "P1" {
		return run.p1(ctx)
	}
	steps := map[string]func(context.Context) (map[string]any, store.ChannelMoveStepDone, error){
		"P2": run.p2, "P3": run.p3, "P4": run.p4, "P6": run.p6, "P7": run.p7}
	fn, ok := steps[step]
	if !ok {
		return nil, channelMoveRefused{http.StatusBadRequest, "bad_step", "step must be P1, P2, P3, P4, P6 or P7"}
	}
	if err := run.load(ctx); err != nil {
		return nil, err
	}
	if err := run.gate(step); err != nil {
		return nil, err
	}
	detail, err := run.startDetail(ctx, step)
	if err != nil {
		return nil, err
	}
	if err := run.jr.StartChannelMoveStep(ctx, run.q.Dst, run.j.MoveID, run.q.Channel, step, detail); err != nil {
		return nil, err
	}
	answer, done, err := fn(ctx)
	if err != nil {
		return nil, err
	}
	if step != "P4" { // P4 writes its own step, in its own transaction
		if err := run.jr.FinishChannelMoveStep(ctx, run.q.Dst, run.j.MoveID, run.q.Channel, step, done); err != nil {
			return nil, err
		}
	}
	answer["move_id"] = run.j.MoveID
	return answer, nil
}

// startDetail is P4's lanes on the set's old keys (W4), in its step row: P4 keeps
// the row's detail. A lane filed on a moved key after P1 gets no note.
func (run *channelMoveRun) startDetail(ctx context.Context, step string) (any, error) {
	if step != "P4" {
		return nil, nil
	}
	f, err := run.frozen()
	if err != nil {
		return nil, err
	}
	lanes, err := run.jr.ChannelMoveLanes(ctx, run.q.Src, f.IssueKeys)
	if err != nil {
		return nil, err
	}
	return map[string]any{"lanes": lanes}, nil
}

// planNow reads the plan: the set of this moment.
func (run *channelMoveRun) planNow(ctx context.Context) (store.ChannelMovePlan, error) {
	pl, ok := run.s.o.Store.(store.ChannelMovePlanner)
	if !ok {
		return store.ChannelMovePlan{}, channelMoveRefused{http.StatusNotImplemented, "unsupported", "this hub's store cannot plan a channel move"}
	}
	return pl.PlanChannelMove(ctx, channelMovePlanRequest(run.q))
}

// p1 freezes the set in <DST> (8.3). A stop is P2's to refuse.
func (run *channelMoveRun) p1(ctx context.Context) (map[string]any, error) {
	plan, err := run.planNow(ctx)
	if err != nil {
		return nil, err
	}
	open := store.ChannelMoveOpen{Dst: run.q.Dst, Src: run.q.Src, Channel: run.q.Channel, GoMsgID: *run.q.GoMsgID, StartedBy: channelMoveBy(run.op), Binds: plan.Binds}
	if run.q.MoveID != nil {
		open.MoveID = *run.q.MoveID
	}
	id, err := run.jr.OpenChannelMove(ctx, open)
	if err != nil {
		return nil, err
	}
	run.j = &store.ChannelMoveJournalRow{MoveID: id}
	return map[string]any{"move_id": id}, nil
}

// channelMoveBy fits the journal's started_by column.
func channelMoveBy(op string) string {
	if len(op) > 64 {
		return op[:64]
	}
	return op
}

// p2 refuses on every stop of the plan, on a name taken in <DST>, on a file quota
// <DST> cannot hold, and with no orchestrator seat (W2's probe recipient): the
// caller's, when the detail names it. What it lists in .seats is what P2b probes
// and P4 clears; .inputs is the detail P4 has to carry again (T7d).
func (run *channelMoveRun) p2(ctx context.Context) (map[string]any, store.ChannelMoveStepDone, error) {
	var none store.ChannelMoveStepDone
	plan, err := run.planNow(ctx)
	if err != nil {
		return nil, none, err
	}
	refuse, err := run.nameAndStops(ctx, plan)
	if err != nil {
		return nil, none, err
	}
	seat, err := run.dstHasOrchestrator(ctx)
	if err != nil {
		return nil, none, err
	}
	switch {
	case !seat && run.q.in.Caller != "":
		refuse = append(refuse, "caller "+run.q.in.Caller+" is no orchestrator seat on the roster of "+run.q.Dst+", the probe's recipient (W2)")
	case !seat:
		refuse = append(refuse, run.q.Dst+" has no orchestrator seat, the probe's recipient (W2)")
	}
	objects, err := run.jr.ChannelMoveObjectLists(ctx, run.q.Src, plan.Binds.Msgs, plan.Binds.Docs)
	if err != nil {
		return nil, none, err
	}
	over, err := run.s.fileUsage.over(ctx, run.s.o.Blob, run.s.quota(), run.q.Dst, objects.FileBytes, run.s.o.Now())
	if err != nil {
		return nil, none, err
	}
	if over {
		refuse = append(refuse, "the channel's files do not fit the file quota of "+run.q.Dst)
	}
	if len(refuse) > 0 {
		return nil, none, moveConflict(strings.Join(refuse, "; "))
	}
	return map[string]any{"seats": plan.Seats}, store.ChannelMoveStepDone{Detail: map[string]any{"seats": plan.Seats, "inputs": run.q.in}}, nil
}

// nameAndStops is plan's refusals as the plan path reads them.
func (run *channelMoveRun) nameAndStops(ctx context.Context, plan store.ChannelMovePlan) ([]string, error) {
	refuse := append([]string{}, channelMoveStops(plan, run.q.in)...)
	taken, err := run.s.channelMoveNameTaken(ctx, run.q.Dst, run.q.ToName)
	if err != nil {
		return nil, err
	}
	if taken {
		refuse = append(refuse, channelMoveTakenLine(run.q))
	}
	return refuse, nil
}

// dstHasOrchestrator: an agent with the orch role's number on <DST>'s roster;
// with a caller, that agent (on that box, when it names one).
func (run *channelMoveRun) dstHasOrchestrator(ctx context.Context) (bool, error) {
	roster, err := run.s.o.Store.Roster(ctx, run.q.Dst)
	if err != nil {
		return false, err
	}
	caller, box := channelMoveCallerAgent(run.q.in.Caller), channelMoveCallerBox(run.q.in.Caller)
	for b, agents := range roster {
		for _, a := range agents {
			if caller != "" && (a != caller || (box != "" && b != box)) {
				continue
			}
			if agentid.IsAgent(a) && slices.Contains(roleNumbers["orch"], agentid.Number(a)) {
				return true, nil
			}
		}
	}
	return false, nil
}

// channelMoveFrozen is the journal's frozen lists the hub reads.
type channelMoveFrozen struct {
	Msgs      []string `json:"msgs"`
	Docs      []string `json:"docs"`
	IssueKeys []string `json:"issue_keys"`
}

func (run *channelMoveRun) frozen() (channelMoveFrozen, error) {
	var f channelMoveFrozen
	err := json.Unmarshal(run.j.Frozen, &f)
	return f, err
}

// objects is the hub's object stores (T6).
func (run *channelMoveRun) objects() (channelmove.Objects, error) {
	s := run.s
	held, ok := s.o.Store.(channelmove.Holder)
	if !ok {
		return channelmove.Objects{}, channelMoveRefused{http.StatusNotImplemented, "unsupported", "this hub's store cannot say who holds a blob"}
	}
	docs := func(ctx context.Context, tenant string) (blob.Store, error) {
		st, _, err := s.docAssetBucket(ctx, tenant)
		return st, err
	}
	return channelmove.Objects{Files: s.o.Blob, Docs: docs, Held: held, Now: s.o.Now}, nil
}

func objectSet(l store.ChannelMoveObjectList) channelmove.ObjectSet {
	return channelmove.ObjectSet{Files: l.Files, DocAssets: l.DocAssets}
}

func objectCounts(r channelmove.ObjectReport) map[string]any {
	return map[string]any{"copied": r.Copied, "present": r.Present, "deleted": r.Deleted, "gone": r.Gone, "kept": len(r.Kept)}
}

// p3 copies what P1 froze; a re-run counts it as present.
func (run *channelMoveRun) p3(ctx context.Context) (map[string]any, store.ChannelMoveStepDone, error) {
	var none store.ChannelMoveStepDone
	f, err := run.frozen()
	if err != nil {
		return nil, none, err
	}
	list, err := run.jr.ChannelMoveObjectLists(ctx, run.q.Src, f.Msgs, f.Docs)
	if err != nil {
		return nil, none, err
	}
	o, err := run.objects()
	if err != nil {
		return nil, none, err
	}
	rep, err := o.Copy(ctx, run.q.Src, run.q.Dst, objectSet(list))
	if err != nil {
		return nil, none, err
	}
	counts := objectCounts(rep)
	return map[string]any{"counts": counts}, store.ChannelMoveStepDone{Counts: counts}, nil
}

// checkedInputs refuses a P4 whose detail is not the one P2 checked (T7d): a
// keep or a leave P2 did not see would apply what no check passed.
func (run *channelMoveRun) checkedInputs() error {
	var d struct {
		Inputs channelMoveInputs `json:"inputs"`
	}
	if err := json.Unmarshal(run.j.Steps["P2"].Detail, &d); err != nil {
		return err
	}
	if !run.q.in.sameDecisions(d.Inputs) {
		return moveConflict("P4's detail (keep, keep_emails, leave_hours, rule_doc) is not the one P2 checked: run P2 again with it")
	}
	return nil
}

// clearedSeats are the seats P2 listed; each needs its stored probe (W2).
func (run *channelMoveRun) clearedSeats() ([]store.MoveSeat, error) {
	var d struct {
		Seats []store.MoveSeat `json:"seats"`
	}
	if err := json.Unmarshal(run.j.Steps["P2"].Detail, &d); err != nil {
		return nil, err
	}
	var p struct {
		Probes []channelMoveProbe `json:"probes"`
	}
	if err := json.Unmarshal(run.j.Steps["P2b"].Detail, &p); err != nil {
		return nil, err
	}
	probed := map[string]bool{}
	for _, x := range p.Probes {
		probed[x.Agent] = true
	}
	for _, seat := range d.Seats {
		if !probed[seat.Agent] {
			return nil, moveConflict("seat " + seat.Agent + " has no probe from P2b: run P2b again")
		}
	}
	return d.Seats, nil
}

// p4 is ApplyChannelMove (T5): the one transaction.
func (run *channelMoveRun) p4(ctx context.Context) (map[string]any, store.ChannelMoveStepDone, error) {
	var none store.ChannelMoveStepDone
	ap, ok := run.s.o.Store.(store.ChannelMoveApplier)
	if !ok {
		return nil, none, channelMoveRefused{http.StatusNotImplemented, "unsupported", "this hub's store cannot apply a channel move"}
	}
	if err := run.checkedInputs(); err != nil {
		return nil, none, err
	}
	seats, err := run.clearedSeats()
	if err != nil {
		return nil, none, err
	}
	cleared := make([]string, 0, len(seats))
	for _, seat := range seats {
		cleared = append(cleared, seat.Agent+"@"+seat.Box)
	}
	res, err := ap.ApplyChannelMove(ctx, store.ChannelMoveApplyRequest{ChannelMovePlanRequest: channelMovePlanRequest(run.q),
		MoveID: run.j.MoveID, GoMsgID: run.j.GoMsgID, StartedBy: channelMoveBy(run.op), Seats: cleared, GcalDelete: run.s.channelMoveGcalDelete(),
		KeepEmails: run.q.in.KeepEmails, LeaveHours: run.q.in.LeaveHours})
	if err != nil {
		return nil, none, err
	}
	return map[string]any{"lost": res.Lost, "new_keys": res.NewKeys, "report": []string{res.DeliveriesLine()}}, none, nil
}

// channelMoveGcalDelete deletes one mapped Google event (5.1a). The store holds
// the member's lease and drops the map row. A token it refreshes is not stored:
// the next sync cycle refreshes again. nil with no Google Calendar on this hub:
// the store then refuses a mapped event by name.
func (s *Server) channelMoveGcalDelete() func(context.Context, store.GcalConnection, string) error {
	g := s.o.Gcal
	gs, ok := s.o.Store.(store.Gcal)
	if g == nil || g.Google == nil || g.Sealer == nil || !ok {
		return nil
	}
	return func(ctx context.Context, c store.GcalConnection, googleID string) error {
		tok, err := gs.GcalTokens(ctx, c.Tenant, c.Human)
		if err != nil {
			return err
		}
		access, err := g.Sealer.Open(ctx, tok.AccessSealed)
		if err != nil {
			return err
		}
		err = g.Google.DeleteEvent(ctx, access, c.CalendarID, googleID)
		if !errors.Is(err, gcal.ErrUnauthorized) {
			return err
		}
		access, err = channelMoveGcalRefresh(ctx, s, g, tok)
		if err != nil {
			return err
		}
		return g.Google.DeleteEvent(ctx, access, c.CalendarID, googleID)
	}
}

func channelMoveGcalRefresh(ctx context.Context, s *Server, g *GcalConnect, tok store.GcalTokens) (marketing.Plaintext, error) {
	ref, err := g.Sealer.Open(ctx, tok.RefreshSealed)
	if err != nil {
		return marketing.Plaintext{}, err
	}
	fresh, err := g.Google.Refresh(ctx, ref, s.o.Now())
	return fresh.Access, err
}

// p6 copies what P4 moved, then deletes in <SRC> what no <SRC> row lists (5.3).
func (run *channelMoveRun) p6(ctx context.Context) (map[string]any, store.ChannelMoveStepDone, error) {
	var none store.ChannelMoveStepDone
	f, err := run.frozen()
	if err != nil {
		return nil, none, err
	}
	list, err := run.jr.ChannelMoveObjectLists(ctx, run.q.Dst, f.Msgs, f.Docs)
	if err != nil {
		return nil, none, err
	}
	o, err := run.objects()
	if err != nil {
		return nil, none, err
	}
	if _, err := o.Copy(ctx, run.q.Src, run.q.Dst, objectSet(list)); err != nil {
		return nil, none, err
	}
	rep, err := o.Delete(ctx, run.q.Src, run.q.Dst, objectSet(list))
	if err != nil {
		return nil, none, err
	}
	counts := objectCounts(rep)
	return map[string]any{"counts": counts, "kept_objects": rep.Kept}, store.ChannelMoveStepDone{Counts: counts}, nil
}

// channelMoveProofSet is the frozen lists as the proofs bind them.
func channelMoveProofSet(src, channel, name string, frozen json.RawMessage) (channelmove.ProofSet, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(frozen, &raw); err != nil {
		return channelmove.ProofSet{}, err
	}
	binds := pgx.NamedArgs{}
	for k, v := range raw {
		switch channelmove.Binds[k] {
		case "text[]", "uuid[]":
			var l []string
			if err := json.Unmarshal(v, &l); err != nil {
				return channelmove.ProofSet{}, err
			}
			binds[k] = l
		case "int[]":
			var l []int32
			if err := json.Unmarshal(v, &l); err != nil {
				return channelmove.ProofSet{}, err
			}
			binds[k] = l
		case "text":
			var t string
			if err := json.Unmarshal(v, &t); err != nil {
				return channelmove.ProofSet{}, err
			}
			binds[k] = t
		}
	}
	ids, _ := binds["ids"].([]string)
	likes := make([]string, len(ids))
	for i, id := range ids {
		likes[i] = "%" + id + "%"
	}
	binds["id_likes"] = likes
	return channelmove.ProofSet{Src: src, Channel: channel, Name: name, Binds: binds,
		Skip: []string{"channel_move_redirects"}}, nil
}

// channelMoveFleetTopics are the fleet tables' topic ids the move keeps (5.1,
// 5.2): Scan's only known hits, counted here so that any other is a failure.
func channelMoveFleetTopics(ctx context.Context, q channelmove.Querier, src string, tasks []string) (map[string]int64, error) {
	known := map[string]int64{}
	for _, table := range []string{"fleet_lanes", "fleet_asks"} {
		rows, err := q.Query(ctx, `SELECT count(*) FROM `+table+` WHERE tenant_id = $1 AND topic = ANY($2::text[])`, src, tasks)
		if err != nil {
			return nil, err
		}
		n, err := pgx.CollectExactlyOneRow(rows, pgx.RowTo[int64])
		if err != nil {
			return nil, err
		}
		known["scan "+table+".topic"] = n
	}
	return known, nil
}

// p7 runs the proofs (section 5) and marks the move done only when they hold. The
// shell fails on any .proofs count that is not 0: a known hit goes there as 0 with
// its count in the name, so it is reported and is no failure (5.2).
func (run *channelMoveRun) p7(ctx context.Context) (map[string]any, store.ChannelMoveStepDone, error) {
	var none store.ChannelMoveStepDone
	ch, err := run.s.o.Store.Channel(ctx, run.q.Dst, run.q.Channel)
	if err != nil {
		return nil, none, err
	}
	set, err := channelMoveProofSet(run.q.Src, run.q.Channel, ch.Name, run.j.Frozen)
	if err != nil {
		return nil, none, err
	}
	var proofs []channelmove.Proof
	err = run.jr.ChannelMoveProofRead(ctx, func(tx pgx.Tx) error {
		tasks, _ := set.Binds["tasks"].([]string)
		var err error
		if set.Known, err = channelMoveFleetTopics(ctx, tx, run.q.Src, tasks); err != nil {
			return err
		}
		if proofs, err = channelmove.SetProofs(ctx, tx, set); err != nil {
			return err
		}
		scan, err := channelmove.Scan(ctx, tx, set)
		proofs = append(proofs, scan...)
		return err
	})
	if err != nil {
		return nil, none, err
	}
	answer := map[string]any{"proofs": channelMoveProofLines(proofs), "kept": channelMoveKeptList, "report": run.report()}
	if len(channelmove.Failed(proofs)) > 0 {
		return answer, none, channelMoveProofsFailed{answer}
	}
	if err := run.jr.CloseChannelMove(ctx, run.q.Dst, run.j.MoveID); err != nil {
		return nil, none, err
	}
	return answer, store.ChannelMoveStepDone{Proofs: map[string]any{"proofs": proofs}}, nil
}

// channelMoveProofsFailed: P7 did not hold, so it stays not done; the operator
// still reads the proofs in a 200, as the shell's _spl_cwm_proofs expects.
type channelMoveProofsFailed struct{ answer map[string]any }

func (channelMoveProofsFailed) Error() string { return "a proof of section 5 is not 0" }

// channelMoveProofLines are the proofs as the shell reads them.
func channelMoveProofLines(ps []channelmove.Proof) []channelmove.Proof {
	out := make([]channelmove.Proof, 0, len(ps))
	for _, p := range ps {
		if p.OK() && p.Known > 0 {
			p.Name += " (known " + strconv.FormatInt(p.Count, 10) + " of " + strconv.FormatInt(p.Known, 10) + ", kept: 5.2)"
			p.Count = 0
		}
		p.Known = 0
		out = append(out, p)
	}
	return out
}

// report is P4's deliveries line for the move's report (C28).
func (run *channelMoveRun) report() []string {
	var c struct {
		Expired int `json:"deliveries_expired"`
		NoPin   int `json:"deliveries_expired_no_pin"`
	}
	if err := json.Unmarshal(run.j.Steps["P4"].Counts, &c); err != nil {
		return []string{"deliveries: not read from the P4 step"}
	}
	return []string{store.ChannelMoveResult{DeliveriesExpired: c.Expired, DeliveriesExpiredNoPin: c.NoPin}.DeliveriesLine()}
}

// channelMoveProbe is one row of P2b's mark.
type channelMoveProbe struct {
	Agent string `json:"agent"`
	MsgID string `json:"msg_id"`
}

// mark records a box step: P2b only with a stored probe per seat, from that agent
// on the move's topic in <DST> (W2), and P5 once P4 committed.
func (run *channelMoveRun) mark(ctx context.Context, step string) (map[string]any, error) {
	if step != "P2b" && step != "P5" {
		return nil, channelMoveRefused{http.StatusBadRequest, "bad_step", "mark is for P2b and P5"}
	}
	if err := run.load(ctx); err != nil {
		return nil, err
	}
	if err := run.gate(step); err != nil {
		return nil, err
	}
	var detail map[string]any
	if len(run.q.Detail) > 0 {
		if err := json.Unmarshal(run.q.Detail, &detail); err != nil {
			return nil, channelMoveRefused{http.StatusBadRequest, "bad_detail", "detail must be a JSON object"}
		}
	}
	if step == "P2b" {
		if err := run.checkProbes(ctx); err != nil {
			return nil, err
		}
	}
	if err := run.jr.FinishChannelMoveStep(ctx, run.q.Dst, run.j.MoveID, run.q.Channel, step, store.ChannelMoveStepDone{Detail: detail}); err != nil {
		return nil, err
	}
	return map[string]any{"move_id": run.j.MoveID}, nil
}

func (run *channelMoveRun) checkProbes(ctx context.Context) error {
	var d struct {
		Probes []channelMoveProbe `json:"probes"`
	}
	if len(run.q.Detail) > 0 {
		if err := json.Unmarshal(run.q.Detail, &d); err != nil {
			return channelMoveRefused{http.StatusBadRequest, "bad_detail", "detail.probes must be [{agent, msg_id}]"}
		}
	}
	stored := map[string]bool{}
	for _, p := range d.Probes {
		m, err := run.s.o.Store.GetMessageClaim(ctx, run.q.Dst, p.MsgID)
		if err != nil || m.FromID != p.Agent || m.TaskID != run.j.MoveID {
			return moveConflict("the probe " + p.MsgID + " of " + p.Agent + " is not on the move's topic in " + run.q.Dst)
		}
		stored[p.Agent] = true
	}
	var seats struct {
		Seats []store.MoveSeat `json:"seats"`
	}
	if err := json.Unmarshal(run.j.Steps["P2"].Detail, &seats); err != nil {
		return err
	}
	for _, seat := range seats.Seats {
		if !stored[seat.Agent] {
			return moveConflict("seat " + seat.Agent + " has no probe")
		}
	}
	return nil
}

// channelMoveJournalAnswer is what the shell resumes from: .move_id, .steps, the
// seats P2 cleared for P2b, and after P4 the lanes whose key changed (W4).
func (s *Server) channelMoveJournalAnswer(w http.ResponseWriter, r *http.Request, q channelMoveRequest) {
	jr, ok := s.channelMoveJournals(w)
	if !ok {
		return
	}
	run := &channelMoveRun{s: s, q: q, jr: jr}
	answer, err := run.journal(r.Context())
	if err != nil {
		s.channelMoveFail(w, run, "journal", err)
		return
	}
	writeJSON(w, http.StatusOK, answer)
}

func (run *channelMoveRun) journal(ctx context.Context) (map[string]any, error) {
	answer := map[string]any{"move_id": nil, "done": false, "steps": map[string]string{}, "seats": []store.MoveSeat{}, "lanes": []store.ChannelMoveLane{}}
	j, err := run.jr.ChannelMoveJournal(ctx, run.q.Dst, run.q.Src, run.q.Channel)
	if err != nil || j == nil {
		return answer, err
	}
	run.j = j
	answer["move_id"], answer["done"] = j.MoveID, j.Done
	steps := map[string]string{}
	for name, st := range j.Steps {
		steps[name] = "started"
		if st.Done {
			steps[name] = "done"
		}
	}
	answer["steps"] = steps
	var d struct {
		Seats []store.MoveSeat `json:"seats"`
	}
	if p2, ok := j.Steps["P2"]; ok && len(p2.Detail) > 0 {
		if err := json.Unmarshal(p2.Detail, &d); err != nil {
			return nil, err
		}
		if d.Seats != nil {
			answer["seats"] = d.Seats
		}
	}
	lanes, err := run.lanes()
	if err != nil {
		return nil, err
	}
	answer["lanes"] = lanes
	return answer, nil
}

// lanes are P4's lanes whose key did change (a free number keeps it).
func (run *channelMoveRun) lanes() ([]store.ChannelMoveLane, error) {
	out := []store.ChannelMoveLane{}
	p4, ok := run.j.Steps["P4"]
	if !ok || !p4.Done {
		return out, nil
	}
	var c struct {
		NewKeys map[string]string `json:"new_keys"`
	}
	if err := json.Unmarshal(p4.Counts, &c); err != nil {
		return nil, err
	}
	var d struct {
		Lanes []store.ChannelMoveLane `json:"lanes"`
	}
	if err := json.Unmarshal(p4.Detail, &d); err != nil {
		return nil, err
	}
	for _, l := range d.Lanes {
		if n := c.NewKeys[l.OldKey]; n != "" && n != l.OldKey {
			l.NewKey = n
			out = append(out, l)
		}
	}
	return out, nil
}
