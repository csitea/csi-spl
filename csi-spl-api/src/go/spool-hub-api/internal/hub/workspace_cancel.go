package hub

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A private workspace's cancel (spec 181 row B9, section 4.5, gap G8).
// Owner HUM-10, msg 9beaf299, Q-12 C: "The VM is deleted at once; only the
// hub data stays 30 days".
//
//	POST /v1/operator/workspaces/{id}/cancel  {"workspace_id": "<id>"}
//	  201 {workspace_id, cancelled_at, purge_after, revoked_boxes, revoked_join_tokens}
//	  200 the same, replayed: true, on a second call
//
// operatorAuth only (a Google id token of the env's service account): the
// orc action do_spl_private_ws_cancel calls it with spl_hub_operator_call,
// before it deletes the VM on the owner's go. The body names the workspace
// again, so a wrong URL cancels nothing (400 workspace_id_mismatch). The
// store (CancelWorkspace) revokes every live pin and open join token of the
// workspace (spec 108 3.7, the T012 revoke), turns its joins off and writes
// the cancellation row and its operator_audit row in one transaction; the
// hub then closes the revoked boxes' sessions. A workspace off the
// private_vm plan is 409 not_private_workspace; none is 404.
//
// The agents stop at once: from the cancel on, a vendor key lease of the
// workspace is 403 workspace_cancelled (vendorKeyBox), whatever token the
// seat still holds. The purge tick (runWorkspacePurge) deletes the hub data
// once the 30 days have passed (store.PurgeDueWorkspaces).

// workspacePurgeEvery is the purge tick: hourly is soon enough for a
// 30-day deadline.
const workspacePurgeEvery = time.Hour

type workspaceCancelBody struct {
	WorkspaceID string `json:"workspace_id"`
}

// POST /v1/operator/workspaces/{id}/cancel
func (s *Server) handleWorkspaceCancel(w http.ResponseWriter, r *http.Request) {
	actor, ok := s.operatorAuth(w, r)
	if !ok {
		return
	}
	wc, ok := s.o.Store.(store.WorkspaceCancels)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store cancels no workspace")
		return
	}
	tenant := r.PathValue("id")
	var in workspaceCancelBody
	if !readJSONStrict(w, r, &in, keysMaxBody, "invalid JSON body (only workspace_id)") {
		return
	}
	if in.WorkspaceID != tenant {
		writeErr(w, http.StatusBadRequest, "workspace_id_mismatch", "the body's workspace_id must name the workspace of the URL")
		return
	}
	actorTenant := s.o.OperatorTenant
	if actorTenant == "" {
		actorTenant = "operator"
	}
	c, created, err := wc.CancelWorkspace(r.Context(), tenant, actorTenant, actor, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such workspace")
		return
	case errors.Is(err, store.ErrNotPrivateWorkspace):
		writeErr(w, http.StatusConflict, "not_private_workspace", "only a private workspace (price plan private_vm) is cancelled here")
		return
	case err != nil:
		writeErrCause(w, http.StatusInternalServerError, "internal", "the cancel was not stored", err)
		return
	}
	for _, box := range c.RevokedBoxes {
		s.closeBoxSessions(tenant, box)
	}
	s.o.Log.Info().Str("tenant", tenant).Str("by", actor).Bool("replayed", !created).
		Strs("revoked_boxes", c.RevokedBoxes).Int("revoked_join_tokens", c.RevokedTokens).Msg("workspace.cancelled")
	code := http.StatusCreated
	if !created {
		code = http.StatusOK
	}
	boxes := c.RevokedBoxes
	if boxes == nil {
		boxes = []string{}
	}
	writeJSON(w, code, map[string]any{"workspace_id": tenant, "cancelled_at": c.CancelledAt, "purge_after": c.PurgeAfter,
		"revoked_boxes": boxes, "revoked_join_tokens": c.RevokedTokens, "replayed": !created})
}

// workspaceCancelled answers 403 workspace_cancelled when tenant is
// cancelled; false = answered. A store without cancels never cancels.
func (s *Server) workspaceCancelled(w http.ResponseWriter, r *http.Request, tenant string) bool {
	wc, ok := s.o.Store.(store.WorkspaceCancels)
	if !ok {
		return false
	}
	_, err := wc.WorkspaceCancellation(r.Context(), tenant)
	switch {
	case errors.Is(err, store.ErrNotFound):
		return false
	case err != nil:
		writeErrCause(w, http.StatusInternalServerError, "internal", "the workspace state is unavailable", err)
	default:
		writeErr(w, http.StatusForbidden, "workspace_cancelled", "this workspace is cancelled: no key is leased to its boxes")
	}
	return true
}

// runWorkspacePurge purges the due cancelled workspaces every
// workspacePurgeEvery until ctx ends.
func (s *Server) runWorkspacePurge(ctx context.Context) {
	t := time.NewTicker(workspacePurgeEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.WorkspacePurgeOnce(ctx)
		}
	}
}

// WorkspacePurgeOnce deletes the hub data of every cancelled workspace
// whose 30 days have passed (Q-12 C), holding one with an unpaid invoice
// (Q-17 B). It answers what it purged and held.
func (s *Server) WorkspacePurgeOnce(ctx context.Context) store.PurgeResult {
	wc, ok := s.o.Store.(store.WorkspaceCancels)
	if !ok {
		return store.PurgeResult{}
	}
	res, err := wc.PurgeDueWorkspaces(ctx, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("workspace_purge.failed")
	}
	if len(res.Purged) > 0 || len(res.Held) > 0 {
		s.o.Log.Info().Strs("purged", res.Purged).Strs("held_unpaid_invoice", res.Held).Msg("workspace_purge")
	}
	return res
}

// routeWorkspaceCancel registers the operator cancel.
func (s *Server) routeWorkspaceCancel(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/operator/workspaces/{id}/cancel", s.handleWorkspaceCancel)
}
