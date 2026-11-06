package hub

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Another member's Flow (spec 130 section 3.1; owner HUM-10, t1 82dff03c,
// msg 47ec5aab, and poll 3c02fb10 answered C in msg 6a0ec650: "That
// person's whole Flow, for every member of the workspace"). GET
// /v1/view/flow?member=<id> reads the Flow of <id>: a HUM-* member of the
// session's workspace, or an agent <id>@<box> on one of its boxes. Never of
// another workspace: the target is looked up in the session's tenant only.
// The read is a read: it writes no mark of the viewer's or the target's.

// flowTarget is whose Flow the request reads: the viewer when ?member= is
// absent or names the viewer, else the checked target. It answers the
// refusal itself (false): 403 for a viewer who may read only their own Flow
// (a guest or a demo visitor) or while a box of the workspace is locked to
// someone other than the viewer, 404 for a target that is no member of this workspace.
func (s *Server) flowTarget(w http.ResponseWriter, r *http.Request, tenant, viewer string) (string, bool) {
	target := r.URL.Query().Get("member")
	if target == "" || target == viewer {
		return viewer, true
	}
	ctx := r.Context()
	full, err := s.flowFullMember(ctx, tenant, viewer)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "flow unavailable")
		return "", false
	}
	if !full {
		writeForbidden(w, rbac.TopicsRead, "a guest reads only their own flow")
		return "", false
	}
	lv, err := s.lockViewFor(ctx, tenant, viewer)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "flow unavailable")
		return "", false
	}
	found, err := s.flowTargetIn(ctx, tenant, target, lv)
	switch {
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "flow unavailable")
		return "", false
	case !found:
		writeErr(w, http.StatusNotFound, "not_member", "no member or agent of this workspace has that id")
		return "", false
	case lv.any():
		// Fail closed (row B5): a folded line names no box, and the
		// target's counts, unread and keys are not cut per box either, so
		// a box locked to someone else would leak its topics' ids.
		writeForbidden(w, rbac.TopicsRead, "a box of this workspace is locked: only your own flow")
		return "", false
	}
	return target, true
}

// flowFullMember reports a viewer who may read others' flows: a HUM-*
// member of tenant whose role is not a guest's (demo_user, channel_guest).
func (s *Server) flowFullMember(ctx context.Context, tenant, viewer string) (bool, error) {
	h, ok := s.o.Store.(store.Humans)
	if !ok || !strings.HasPrefix(viewer, "HUM-") {
		return false, nil
	}
	role, err := h.MemberRole(ctx, viewer, tenant)
	if errors.Is(err, store.ErrNotFound) {
		return false, nil
	}
	return err == nil && !rbac.Exclusive(role), err
}

// flowTargetIn reports a target of tenant: a member seat with a role there,
// or an agent <id>@<box> whose box is tenant's and not hidden by lv.
func (s *Server) flowTargetIn(ctx context.Context, tenant, target string, lv lockView) (bool, error) {
	if store.IsFlowMember(target) {
		h, ok := s.o.Store.(store.Humans)
		if !ok {
			return false, nil
		}
		_, err := h.MemberRole(ctx, target, tenant)
		if errors.Is(err, store.ErrNotFound) {
			return false, nil
		}
		return err == nil, err
	}
	if !store.IsFlowAgent(target) {
		return false, nil
	}
	_, box := agentid.SplitAtBox(target)
	if lv.hides(box) {
		return false, nil
	}
	boxes, err := s.o.Store.ViewBoxes(ctx, tenant)
	if err != nil {
		return false, err
	}
	for _, b := range boxes {
		if b.BoxID == box {
			return true, nil
		}
	}
	return false, nil
}
