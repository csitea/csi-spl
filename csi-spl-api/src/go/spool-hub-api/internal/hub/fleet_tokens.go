package hub

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Live token burn of the fleet's agent lanes (spec 140 sections 3 and 4.4,
// rdb 0199; owner HUM-10, t1 e8ae0aad, poll aa31a0fe).
//
// Box side, over the authenticated hello (the box collector's
// `spool fleet-tokens push`), a box of the operator workspace only, since
// the rows are the instance's estate; the writing box is the session's,
// never the frame's:
//
//	lane_op fleet_tokens_push  {samples: [wire.FleetTokenSample]}
//	                           -> wire.FleetTokensAckFrame {type: ack, lane_op, inserted, at}
//
// Browser side (the Monitoring page's Tokens tab), the operator workspace's
// admin (a member session) or the operator service account (a Bearer id
// token), the fleet load doors:
//
//	GET /v1/operator/fleet-tokens?window=1h|24h|today&vendor=all|<kind>
//
// After each push the hub checks the pushing lanes for a sustained surge:
// fresh tokens (in + out + cache write) above fleetTokenSurgePerMin in each
// of fleetTokenSurgeMinutes consecutive minutes posts one alert into the
// operator workspace's #fleet-alerts, then that lane is quiet for
// fleetTokenSurgeCoolOff unless it first drops below fleetTokenSurgeRearm.
// The hub never creates the channel: without it the alert is logged only.

// Surge alert thresholds (spec 140 4.4.2, owner decision 3 = B).
const (
	fleetTokenSurgePerMin  = 60000
	fleetTokenSurgeRearm   = 30000
	fleetTokenSurgeMinutes = 3
	fleetTokenSurgeCoolOff = 30 * time.Minute
	// FleetAlertsChannel is the operator channel the alert goes to.
	FleetAlertsChannel = "fleet-alerts"
)

// fleetTokenFuture is how far ahead of the hub's clock a sample's minute may
// be (box clock skew); it may reach back as far as the retention.
const fleetTokenFuture = 2 * time.Minute

func (s *Server) routeFleetTokens(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/fleet-tokens", s.handleFleetTokens)
	mux.HandleFunc("OPTIONS /v1/operator/fleet-tokens", s.operatorWorkspacesPreflight)
}

// GET /v1/operator/fleet-tokens?window=&vendor=
func (s *Server) handleFleetTokens(w http.ResponseWriter, r *http.Request) {
	if _, _, _, ok := s.fleetLoadCaller(w, r); !ok {
		return
	}
	ft, ok := s.o.Store.(store.FleetTokenStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no fleet token burn")
		return
	}
	q := r.URL.Query()
	window, vendor := q.Get("window"), q.Get("vendor")
	if window == "" {
		window = "1h"
	}
	if vendor == "all" {
		vendor = ""
	}
	now := s.o.Now()
	_, since, ok := store.FleetTokenWindowStart(window, now)
	if !ok || (vendor != "" && !slices.Contains(wire.FleetTokenVendors, vendor)) {
		writeErr(w, http.StatusBadRequest, "bad_query", "window is 1h, 24h or today; vendor is all or one of "+strings.Join(wire.FleetTokenVendors, ", "))
		return
	}
	rows, err := ft.ListBuckets(r.Context(), since, vendor)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("fleet tokens list")
		writeErr(w, http.StatusInternalServerError, "internal", "fleet token burn unavailable")
		return
	}
	writeJSON(w, http.StatusOK, store.FleetTokenSummarize(rows, window, now))
}

// sweepFleetTokens is the retention pass (spec 140 3.6): roll the days up,
// then 30 days of minutes and 365 of days.
func (s *Server) sweepFleetTokens(ctx context.Context) {
	ft, ok := s.o.Store.(store.FleetTokenStore)
	if !ok {
		return
	}
	r, err := ft.PruneOldBuckets(ctx, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("fleet tokens retention sweep")
		return
	}
	if r.PrunedMinutes+r.PrunedDays > 0 {
		s.o.Log.Info().Int("rolled_days", r.RolledDays).Int("pruned_minutes", r.PrunedMinutes).Int("pruned_days", r.PrunedDays).Msg("fleet tokens retention sweep")
	}
}

// isFleetTokensLaneOp routes a lane frame to onFleetTokensLane.
func isFleetTokensLaneOp(op string) bool { return strings.HasPrefix(op, "fleet_tokens_") }

// onFleetTokensLane answers a fleet_tokens lane frame. A refusal is an error
// frame on the frame's msg_id; the connection stays open.
func (s *Server) onFleetTokensLane(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a lane frame needs msg_id (a UUID) to pair the reply")
		return
	}
	ack, ae := s.fleetTokensPush(ctx, x, f)
	if ae != nil {
		x.fail(ctx, id, ae.token, ae.status, ae.detail)
		return
	}
	raw, err := json.Marshal(ack)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TLane, MsgID: id, LaneOp: f.LaneOp, Lane: raw}) //nolint:errcheck
}

func (s *Server) fleetTokensPush(ctx context.Context, x *session, f wire.Frame) (*wire.FleetTokensAckFrame, *issueErr) {
	if f.LaneOp != wire.FleetBurnPushOp {
		return nil, &issueErr{http.StatusBadRequest, "bad_frame", "lane_op must be " + wire.FleetBurnPushOp}
	}
	ft, ok := s.o.Store.(store.FleetTokenStore)
	if !ok {
		return nil, &issueErr{http.StatusNotImplemented, "unsupported", "this hub's store keeps no fleet token burn"}
	}
	op, err := s.operatorTenant(ctx)
	switch {
	case err != nil:
		return nil, &issueErr{http.StatusServiceUnavailable, "unavailable", "the operator workspace was not read"}
	case op == "" || x.tenant != op:
		return nil, &issueErr{http.StatusForbidden, "not_operator", "only a box of the operator workspace pushes fleet token burn"}
	case !store.FleetNameRe.MatchString(x.box):
		return nil, &issueErr{http.StatusBadRequest, "bad_frame", "the session's box id is not a box tag ([a-z0-9-], up to 32)"}
	}
	p, err := wire.DecodeFleetTokensPush(f.Lane)
	if err != nil {
		return nil, &issueErr{http.StatusBadRequest, "bad_samples", err.Error()}
	}
	now := s.o.Now().UTC()
	for i, smp := range p.Samples {
		if smp.Minute.After(now.Add(fleetTokenFuture)) || smp.Minute.Before(now.Add(-store.FleetTokensRetention)) {
			return nil, &issueErr{http.StatusBadRequest, "bad_samples", fmt.Sprintf("sample %d: minute must be within the last 30 days and not ahead of the hub's clock", i)}
		}
	}
	n, err := ft.RecordSamples(ctx, x.box, p.Samples)
	if err != nil {
		s.o.Log.Error().Err(err).Str("box", x.box).Msg("fleet tokens record")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "fleet token samples not stored"}
	}
	s.checkFleetTokenSurge(ctx, ft, op, x.box, p.Samples)
	return &wire.FleetTokensAckFrame{Type: "ack", LaneOp: wire.FleetBurnPushOp, Inserted: n, At: now.Format(time.RFC3339)}, nil
}

// fleetSurgeState is one lane's alert state: the end minute of the surge it
// last alerted and when; rearmed once it burned below the rearm line after.
type fleetSurgeState struct {
	minute, at time.Time
	rearmed    bool
}

// fleetSurges is the hub's per-lane alert state, beside the Server (one per
// hub process: a second instance may alert once more, the msg_id of an
// alert is fixed per lane and cool-off slot, so it never posts the same
// slot twice).
type fleetSurges struct {
	mu sync.Mutex
	by map[*Server]map[[2]string]fleetSurgeState
}

var surges = fleetSurges{by: map[*Server]map[[2]string]fleetSurgeState{}}

// fleetTokenSurge is one alert: the lane's three minutes, oldest first.
type fleetTokenSurge struct {
	box, agent, vendor, model string
	minutes                   [fleetTokenSurgeMinutes]store.FleetTokenBucket
}

// checkFleetTokenSurge reads the pushing lanes' recent minutes and posts an
// alert for each lane that sustained a surge, outside its cool-off.
func (s *Server) checkFleetTokenSurge(ctx context.Context, ft store.FleetTokenStore, op, box string, samples []wire.FleetTokenSample) {
	lanes := map[string]bool{}
	var from time.Time
	for _, x := range samples {
		if !x.IsMetered {
			continue
		}
		lanes[x.AgentID] = true
		if from.IsZero() || x.Minute.Before(from) {
			from = x.Minute
		}
	}
	if len(lanes) == 0 {
		return
	}
	rows, err := ft.ListBuckets(ctx, from.Add(-(fleetTokenSurgeMinutes-1)*time.Minute), "")
	if err != nil {
		s.o.Log.Error().Err(err).Msg("fleet tokens surge read")
		return
	}
	byLane := map[string][]store.FleetTokenBucket{}
	for _, r := range rows {
		if r.BoxTag == box && lanes[r.AgentID] && r.IsMetered {
			byLane[r.AgentID] = append(byLane[r.AgentID], r)
		}
	}
	for agent, rs := range byLane {
		if sg, ok := s.fleetSurgeDue(box, agent, rs); ok {
			s.postFleetSurge(ctx, op, sg)
		}
	}
}

// fleetSurgeDue finds the lane's latest sustained surge in rs (oldest
// first) and says whether it alerts now, recording it when it does.
func (s *Server) fleetSurgeDue(box, agent string, rs []store.FleetTokenBucket) (fleetTokenSurge, bool) {
	sg, found := latestFleetSurge(rs)
	surges.mu.Lock()
	defer surges.mu.Unlock()
	st := surges.by[s]
	if st == nil {
		st = map[[2]string]fleetSurgeState{}
		surges.by[s] = st
	}
	k := [2]string{box, agent}
	prev, had := st[k]
	if had && !prev.rearmed {
		for _, r := range rs {
			if r.Minute.After(prev.minute) && r.Fresh() < fleetTokenSurgeRearm {
				prev.rearmed = true
			}
		}
		st[k] = prev
	}
	if !found {
		return sg, false
	}
	end := sg.minutes[fleetTokenSurgeMinutes-1].Minute
	now := s.o.Now()
	if had && (!end.After(prev.minute) || (!prev.rearmed && now.Sub(prev.at) < fleetTokenSurgeCoolOff)) {
		return sg, false
	}
	st[k] = fleetSurgeState{minute: end, at: now}
	return sg, true
}

// latestFleetSurge is the newest run of fleetTokenSurgeMinutes consecutive
// minutes in rs (one lane, oldest first) each above fleetTokenSurgePerMin.
func latestFleetSurge(rs []store.FleetTokenBucket) (fleetTokenSurge, bool) {
	for i := len(rs) - 1; i >= fleetTokenSurgeMinutes-1; i-- {
		var sg fleetTokenSurge
		ok := true
		for j := 0; j < fleetTokenSurgeMinutes; j++ {
			r := rs[i-fleetTokenSurgeMinutes+1+j]
			want := rs[i].Minute.Add(-time.Duration(fleetTokenSurgeMinutes-1-j) * time.Minute)
			if !r.Minute.Equal(want) || r.Fresh() <= fleetTokenSurgePerMin {
				ok = false
				break
			}
			sg.minutes[j] = r
		}
		if ok {
			l := rs[i]
			sg.box, sg.agent, sg.vendor, sg.model = l.BoxTag, l.AgentID, l.Vendor, l.Model
			return sg, true
		}
	}
	return fleetTokenSurge{}, false
}

// fleetSurgeBody is the alert (spec 140 4.4.2).
func fleetSurgeBody(sg fleetTokenSurge) string {
	model := sg.model
	if model == "" {
		model = "unknown model"
	}
	var b strings.Builder
	fmt.Fprintf(&b, ":warning: **Fleet Token Surge Alert**: Agent `%s` (`%s` / `%s`) on box `%s` has sustained high token burn "+
		"(>%dk fresh tokens/min) for %d consecutive minutes:\n", sg.agent, sg.vendor, model, sg.box, fleetTokenSurgePerMin/1000, fleetTokenSurgeMinutes)
	var cost float64
	cur := ""
	for i, m := range sg.minutes {
		fmt.Fprintf(&b, "- Minute %d (%s): %s fresh tokens/min (%s with cache reads)\n", i+1, m.Minute.Format("15:04Z"),
			groupDigits(m.Fresh()), groupDigits(m.Total()))
		cost += m.CostMicros
		if m.Priced {
			cur = m.Currency
		}
	}
	if cur != "" {
		fmt.Fprintf(&b, "Cumulative cost in window: %s %.2f. ", cur, cost/1e6)
	}
	b.WriteString("Immediate operator inspection recommended.")
	return b.String()
}

// groupDigits is n with thousands separators (64200 -> 64,200).
func groupDigits(n int64) string {
	s := fmt.Sprint(n)
	if n < 0 {
		return s
	}
	var b strings.Builder
	for i, c := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(c)
	}
	return b.String()
}

// fleetSurgeID is the alert's msg_id: fixed per lane and cool-off slot, so
// two hub instances never post the same slot twice.
func fleetSurgeID(sg fleetTokenSurge) string {
	slot := sg.minutes[fleetTokenSurgeMinutes-1].Minute.Unix() / int64(fleetTokenSurgeCoolOff/time.Second)
	h := sha256.Sum256(fmt.Appendf(nil, "spool-fleet-surge:%s:%s:%d", sg.box, sg.agent, slot))
	x := hex.EncodeToString(h[:16])
	return x[0:8] + "-" + x[8:12] + "-4" + x[13:16] + "-a" + x[17:20] + "-" + x[20:32]
}

// postFleetSurge stores the alert, signed as box-wui like the #public
// notice, in the operator workspace's #fleet-alerts. A missing channel is
// logged, never created.
func (s *Server) postFleetSurge(ctx context.Context, tenant string, sg fleetTokenSurge) {
	log := s.o.Log.Warn().Str("box", sg.box).Str("agent", sg.agent).Str("vendor", sg.vendor)
	if _, err := s.o.Store.Channel(ctx, tenant, FleetAlertsChannel); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			log.Msg("fleet token surge: #fleet-alerts does not exist in the operator workspace, alert not posted")
		} else {
			log.Err(err).Msg("fleet token surge: #fleet-alerts not read, alert not posted")
		}
		return
	}
	if len(s.o.WUIKey) == 0 {
		log.Msg("fleet token surge: this hub holds no box-wui key, alert not posted")
		return
	}
	if err := s.postFleetAlert(ctx, tenant, fleetSurgeID(sg), fleetSurgeBody(sg)); err != nil {
		log.Err(err).Msg("fleet token surge: alert not posted")
		return
	}
	log.Msg("fleet token surge: alert posted to #fleet-alerts")
}

// postFleetAlert stores one hub note as its own topic in #fleet-alerts; a
// second post of the same id is a no-op insert.
func (s *Server) postFleetAlert(ctx context.Context, tenant, id, body string) error {
	now := s.o.Now().UTC().Truncate(time.Second)
	m := &msg.Message{V: 1, MsgID: id, TaskID: id, TS: now.Format(time.RFC3339), From: PublicNoticeFrom,
		To: BroadcastID, Kind: "note", Body: body, Files: []msg.Attachment{}}
	env, err := wire.NewEnvelopeIn(s.o.WUIKey, WUIBox, WUIBox, FleetAlertsChannel, "", m)
	if err != nil {
		return err
	}
	canon, err := env.Marshal()
	if err != nil {
		return err
	}
	files, _ := json.Marshal(m.Files)
	at := s.o.Now().Truncate(time.Microsecond)
	row := store.Message{
		TenantID: tenant, MsgID: id, TaskID: id, TS: now,
		FromBox: WUIBox, FromID: m.From, ToBox: WUIBox, ToID: m.To, Kind: m.Kind, Body: m.Body,
		Files: files, Msg: env.Msg, EnvSig: env.Sig, Env: canon, Channel: FleetAlertsChannel,
		ReceivedAt: at, ExpiresAt: at.Add(s.retention(FleetAlertsChannel)), IsParent: 1,
	}
	inserted, sentInOne, err := s.insertRow(ctx, row)
	if err != nil {
		return err
	}
	if inserted && !sentInOne {
		if err := s.o.Store.Enqueue(ctx, tenant, id, WUIBox, row.ReceivedAt, row.ReceivedAt.Add(s.o.QueueTTL), s.o.QueueMaxPerBox); err != nil {
			return err
		}
	}
	if inserted {
		s.fanoutWUI(ctx, row)
	}
	return nil
}
