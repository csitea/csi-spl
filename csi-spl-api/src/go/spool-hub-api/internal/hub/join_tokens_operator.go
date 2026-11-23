package hub

import (
	"errors"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The operator join-token mint (spec 181 row B7, 4.2; spec 122 4 point 5):
// the spool-hub admin mints, for a private workspace <tenant>, a one-use join
// token bound to its private VM's box id <vm>, so the VM joins <tenant> as a
// dedicated box (spec 108 3.8) with no tenant root key on it.
//
//	POST /v1/operator/workspaces/{id}/join-tokens  {box_id, label?}  the token, once
//
// Only an admin of the operator workspace reaches it (operatorActor, the
// workspace CRUD rule); the workspace's own admin mints with
// POST /v1/tenant/agents/join-tokens instead. The token is redeemed by
// POST /v1/pins/join like any join token: a box naming another box id is
// refused join_token_box_mismatch. The store writes the token and its
// operator_audit row (mint_join_token) in one transaction, and refuses a box
// id another workspace holds (409 vm_bound_elsewhere).

const (
	codeVMBoundElsewhere = "vm_bound_elsewhere"
	vmBoundElsewhereMsg  = "this box id is seated, or bound by an open join token, in another workspace; a private VM serves one workspace"
)

type operatorJoinMintBody struct {
	BoxID string `json:"box_id"`
	Label string `json:"label"`
}

// opJoinMintCheck validates the mint body; false = answered.
func opJoinMintCheck(w http.ResponseWriter, in *operatorJoinMintBody) bool {
	in.Label = strings.TrimSpace(in.Label)
	switch {
	case in.BoxID == "":
		writeErr(w, http.StatusBadRequest, "box_id_required", "an operator join token is bound to the box id of the private VM: name box_id")
	case in.BoxID == WUIBox:
		writeErr(w, http.StatusBadRequest, "reserved_box", WUIBox+" is the reserved browser box")
	case !msg.ValidBoxID(in.BoxID):
		writeErr(w, http.StatusBadRequest, "bad_request", "box_id is not a box id ([a-z0-9-], up to 32)")
	case utf8.RuneCountInString(in.Label) > joinLabelMax:
		writeErr(w, http.StatusBadRequest, "bad_request", "label is longer than 80 characters")
	default:
		return true
	}
	return false
}

// opJoinMintTarget authorises the route and resolves the workspace, the
// store and the switch; false = answered.
func (s *Server) opJoinMintTarget(w http.ResponseWriter, r *http.Request) (opActor, store.OperatorJoinMint, string, bool) {
	a, ok := s.operatorActor(w, r)
	if !ok {
		return opActor{}, nil, "", false
	}
	ms, ok := s.o.Store.(store.OperatorJoinMint)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no join tokens")
		return opActor{}, nil, "", false
	}
	ws, ok := s.workspaceTarget(w, r, a)
	if !ok || !s.boxJoinAllowed(w, r, ws.ID) {
		return opActor{}, nil, "", false
	}
	if s.o.JoinTokenTTL <= 0 {
		writeErr(w, http.StatusServiceUnavailable, "join_tokens_off", "this hub has no join token lifetime (SPOOL_HUB_JOIN_TOKEN_TTL)")
		return opActor{}, nil, "", false
	}
	return a, ms, ws.ID, true
}

// POST /v1/operator/workspaces/{id}/join-tokens {box_id, label?}
func (s *Server) handleOperatorJoinMint(w http.ResponseWriter, r *http.Request) {
	a, ms, tenant, ok := s.opJoinMintTarget(w, r)
	if !ok {
		return
	}
	var in operatorJoinMintBody
	if !readJSONStrict(w, r, &in, keysMaxBody, "invalid JSON body (only box_id, label)") ||
		!opJoinMintCheck(w, &in) || !s.joinWrite(w, a.hum) {
		return
	}
	// The box owner lock (path 8c, row B5): no token seats a locked box id.
	if rf := s.adminLockRefusal(r.Context(), tenant, in.BoxID, "", boxLockPathJoin); rf != nil {
		writeLockRefusal(w, rf)
		return
	}
	token, hash, err := newJoinToken(tenant)
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "no join token minted", err)
		return
	}
	now := s.o.Now().UTC()
	jt := store.JoinToken{Hash: hash, TenantID: tenant, CreatedBy: a.hum, Label: in.Label, BoxID: in.BoxID,
		CreatedAt: now, ExpiresAt: now.Add(s.o.JoinTokenTTL)}
	switch err := ms.MintOperatorJoinToken(r.Context(), jt, a.tenant); {
	case errors.Is(err, store.ErrVMBoundElsewhere):
		writeErr(w, http.StatusConflict, codeVMBoundElsewhere, vmBoundElsewhereMsg)
		return
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such workspace")
		return
	case err != nil:
		writeErrCause(w, http.StatusInternalServerError, "internal", "join token not stored", err)
		return
	}
	s.o.Log.Info().Str("tenant", tenant).Str("join_token", jt.ID()).Str("by", a.hum).Str("actor_tenant", a.tenant).
		Str("box_id", in.BoxID).Msg("operator join token minted")
	s.workspaceEvent(r.Context(), tenant, boxEvent(store.LogKindJoinMinted, a.hum, joinMintedMessage(jt)+" by the operator"))
	writeJSON(w, http.StatusCreated, map[string]any{
		"id": jt.ID(), "token": token, "expires_at": jt.ExpiresAt, "box_id": in.BoxID, "workspace_id": tenant,
		"join_line": "SPOOL_JOIN_TOKEN=" + token + " spool join " + hubURL(r),
	})
}

func (s *Server) operatorJoinMintPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "POST")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// routeOperatorJoinMint registers the operator mint beside the workspace's
// own join-token routes (routeJoinTokens).
func (s *Server) routeOperatorJoinMint(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/operator/workspaces/{id}/join-tokens", s.handleOperatorJoinMint)
	mux.HandleFunc("OPTIONS /v1/operator/workspaces/{id}/join-tokens", s.operatorJoinMintPreflight)
}
