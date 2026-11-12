// SPDX-License-Identifier: AGPL-3.0-only

package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The "Move to workspace" menu entry's reads (spec 169 T14, sections 8.5.2 to
// 8.5.4), on the member session in <SRC>'s host:
//
//	GET  /v1/channels/{channel}/workspace-move       the probe and the targets
//	POST /v1/channels/{channel}/workspace-move/plan  {dst, keep, keep_emails, leave_hours}
//
//   - Who: a member of <SRC> who is the biz owner of the operator workspace,
//     the test channelMoveGo makes (channelMoveOwner), never operatorActor's
//     Admin. Anyone else, no session included, gets 403 channel_move_owner
//     before the channel is read, so a refusal says nothing about the channel.
//   - Targets: the person's own workspaces (Memberships), <SRC> and a suspended
//     one left out; a workspace they are not in is never named (Q10, W5).
//   - The plan is the operator plan's answer plus .blocked: its stops, and the
//     two P2 checks the plan leaves out, no orchestrator seat in <DST> and a
//     file total over <DST>'s quota (8.5.4), so the dialog shows them before
//     the confirm.
//   - Reads only: no journal row, no P1, no write (the confirm is T15).

const tokenChannelMoveOwner = "channel_move_owner"

// channelMoveTarget is one workspace the channel may move into.
type channelMoveTarget struct {
	Slug string `json:"slug"`
	Name string `json:"name"`
}

// channelMoveMenu is the probe's answer; a refusal is an error answer.
type channelMoveMenu struct {
	Allowed bool                `json:"allowed"`
	Targets []channelMoveTarget `json:"targets"`
}

// channelMoveBrowserPlan is the operator plan's answer and every stop the
// confirm would meet: .refuse and the P2 checks; [] when nothing stops it.
type channelMoveBrowserPlan struct {
	channelMovePlanAnswer
	Blocked []string `json:"blocked"`
}

// channelMoveBrowserBody is the plan's request; the dialog offers no copy and
// no new name (8.5.1), so neither is in it.
type channelMoveBrowserBody struct {
	Dst        string   `json:"dst"`
	Keep       []string `json:"keep"`
	KeepEmails []string `json:"keep_emails"`
	LeaveHours []string `json:"leave_hours"`
}

func (s *Server) routeChannelMoveBrowser(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/channels/{channel}/workspace-move", s.handleChannelMoveProbe)
	mux.HandleFunc("POST /v1/channels/{channel}/workspace-move/plan", s.handleChannelMoveBrowserPlan)
	mux.HandleFunc("OPTIONS /v1/channels/{channel}/workspace-move", s.channelMoveBrowserPreflight)
	mux.HandleFunc("OPTIONS /v1/channels/{channel}/workspace-move/plan", s.channelMoveBrowserPreflight)
}

func (s *Server) channelMoveBrowserPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, POST")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// channelMoveBrowserDoor is the door of both routes: the session, the owner
// test, then the channel. It answers <SRC>, the person and the channel id, or
// writes the error.
func (s *Server) channelMoveBrowserDoor(w http.ResponseWriter, r *http.Request) (string, string, string, bool) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return "", "", "", false
	}
	if !s.channelMoveBrowserOwner(r.Context(), t.ID, hum) {
		writeErr(w, http.StatusForbidden, tokenChannelMoveOwner, "only the owner of the operator workspace moves a channel")
		return "", "", "", false
	}
	ch := store.NormalizeChannel(strings.TrimSpace(r.PathValue("channel")))
	switch {
	case !store.ValidChannelID(ch):
		writeErr(w, http.StatusBadRequest, "bad_channel", "channel must match ^[a-z0-9][a-z0-9-]{0,63}$")
		return "", "", "", false
	case store.ChannelPublic(ch):
		writeErr(w, http.StatusBadRequest, "bad_channel", "a default channel never moves")
		return "", "", "", false
	}
	if _, ok := s.channelRecord(w, r, t.ID, ch); !ok {
		return "", "", "", false
	}
	return t.ID, hum, ch, true
}

// channelMoveBrowserOwner: hum is a member of src and the biz owner of the
// operator workspace (8.5.2).
func (s *Server) channelMoveBrowserOwner(ctx context.Context, src, hum string) bool {
	h, ok := s.o.Store.(store.Humans)
	if !ok || !humanIDRe.MatchString(hum) {
		return false
	}
	if _, err := h.MemberRole(ctx, hum, src); err != nil {
		return false
	}
	op, err := s.operatorTenant(ctx)
	return err == nil && op != "" && s.channelMoveOwner(ctx, op, hum)
}

// handleChannelMoveProbe is GET /v1/channels/{channel}/workspace-move.
func (s *Server) handleChannelMoveProbe(w http.ResponseWriter, r *http.Request) {
	src, hum, _, ok := s.channelMoveBrowserDoor(w, r)
	if !ok {
		return
	}
	targets, err := s.channelMoveTargets(r.Context(), src, hum)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("browser.channel_move_probe")
		writeErr(w, http.StatusInternalServerError, "internal", "workspaces unavailable")
		return
	}
	writeJSON(w, http.StatusOK, channelMoveMenu{Allowed: true, Targets: targets})
}

// channelMoveTargets are hum's own workspaces but src, live ones only, in the
// switcher's order.
func (s *Server) channelMoveTargets(ctx context.Context, src, hum string) ([]channelMoveTarget, error) {
	ml, ok := s.o.Store.(store.MembershipLister)
	if !ok {
		return nil, errors.New("this hub's store lists no memberships")
	}
	ms, err := ml.Memberships(ctx, hum)
	if err != nil {
		return nil, err
	}
	out := []channelMoveTarget{}
	for _, m := range ms {
		if m.TenantID == src {
			continue
		}
		t, err := s.o.Store.GetTenant(ctx, m.TenantID)
		if err != nil || t.Suspended() {
			continue
		}
		name := m.DisplayName
		if name == "" {
			name = m.TenantID
		}
		out = append(out, channelMoveTarget{Slug: m.TenantID, Name: name})
	}
	return out, nil
}

// handleChannelMoveBrowserPlan is POST /v1/channels/{channel}/workspace-move/plan.
func (s *Server) handleChannelMoveBrowserPlan(w http.ResponseWriter, r *http.Request) {
	src, hum, ch, ok := s.channelMoveBrowserDoor(w, r)
	if !ok {
		return
	}
	q, ok := s.channelMoveBrowserRequest(w, r, src, hum, ch)
	if !ok {
		return
	}
	pl, ok := s.o.Store.(store.ChannelMovePlanner)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store cannot plan a channel move")
		return
	}
	plan, err := pl.PlanChannelMove(r.Context(), channelMovePlanRequest(q))
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "unknown_channel", "no channel "+ch+" in this workspace")
		return
	case errors.Is(err, store.ErrMoveRequest):
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	case err != nil:
		s.o.Log.Error().Err(err).Msg("browser.channel_move_plan")
		writeErr(w, http.StatusInternalServerError, "internal", "plan unavailable")
		return
	}
	refuse, ok := s.channelMoveRefusals(w, r, q, plan)
	if !ok {
		return
	}
	p2, err := s.channelMoveP2Stops(r.Context(), q, plan)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("browser.channel_move_plan p2")
		writeErr(w, http.StatusInternalServerError, "internal", "plan unavailable")
		return
	}
	a := channelMoveBrowserPlan{channelMovePlanAnswer: channelMovePlanOf(plan, refuse)}
	a.Blocked = append(append([]string{}, refuse...), p2...)
	writeJSON(w, http.StatusOK, a)
}

// channelMoveBrowserRequest reads the body into the operator plan's request.
// A dst that is not one of hum's targets answers as an unknown one: a hidden
// workspace is never confirmed to exist (W5).
func (s *Server) channelMoveBrowserRequest(w http.ResponseWriter, r *http.Request, src, hum, ch string) (channelMoveRequest, bool) {
	var b channelMoveBrowserBody
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, channelMoveBodyMax))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&b); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {dst, keep, keep_emails, leave_hours}")
		return channelMoveRequest{}, false
	}
	dst := strings.ToLower(strings.TrimSpace(b.Dst))
	if !msg.ValidTenantID(dst) || dst == src {
		writeErr(w, http.StatusBadRequest, "bad_tenant", "dst must be another workspace's slug")
		return channelMoveRequest{}, false
	}
	targets, err := s.channelMoveTargets(r.Context(), src, hum)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "workspaces unavailable")
		return channelMoveRequest{}, false
	}
	if !channelMoveTargetOf(targets, dst) {
		writeErr(w, http.StatusNotFound, "unknown_tenant", "no such tenant")
		return channelMoveRequest{}, false
	}
	raw, _ := json.Marshal(channelMoveInputs{Keep: b.Keep, KeepEmails: b.KeepEmails, LeaveHours: b.LeaveHours})
	in, why := parseChannelMoveInputs(raw)
	if why != "" {
		writeErr(w, http.StatusBadRequest, "bad_detail", why)
		return channelMoveRequest{}, false
	}
	return channelMoveRequest{Op: "plan", Src: src, Channel: ch, Dst: dst, Mode: "move", ToName: ch, in: in}, true
}

func channelMoveTargetOf(ts []channelMoveTarget, slug string) bool {
	for _, t := range ts {
		if t.Slug == slug {
			return true
		}
	}
	return false
}

// channelMoveP2Stops are the P2 checks the plan leaves out (8.5.4), in P2's
// words: no orchestrator seat in <DST> (W2) and the channel's files over the
// file quota of <DST>. A store that cannot list the set's files stops the move
// under a quota: the total was not read, so it is not shown as fitting.
func (s *Server) channelMoveP2Stops(ctx context.Context, q channelMoveRequest, plan store.ChannelMovePlan) ([]string, error) {
	var out []string
	run := &channelMoveRun{s: s, q: q}
	seat, err := run.dstHasOrchestrator(ctx)
	if err != nil {
		return nil, err
	}
	if !seat {
		out = append(out, q.Dst+" has no orchestrator seat, the probe's recipient (W2)")
	}
	quota := s.quota()
	if quota.FileBytes <= 0 {
		return out, nil
	}
	jr, ok := s.o.Store.(store.ChannelMoveJournals)
	if !ok {
		return append(out, "the channel's files were not counted against the file quota of "+q.Dst), nil
	}
	objects, err := jr.ChannelMoveObjectLists(ctx, q.Src, plan.Binds.Msgs, plan.Binds.Docs)
	if err != nil {
		return nil, err
	}
	over, err := s.fileUsage.over(ctx, s.o.Blob, quota, q.Dst, objects.FileBytes, s.o.Now())
	if err != nil {
		return nil, err
	}
	if over {
		out = append(out, "the channel's files do not fit the file quota of "+q.Dst)
	}
	return out, nil
}
