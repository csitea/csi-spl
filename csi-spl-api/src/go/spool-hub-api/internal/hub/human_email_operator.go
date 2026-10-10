package hub

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The operator twin of POST /v1/members/{human_id}/emails (owner HUM-10, t1
// f265541a, msg 1ee61a2b: "make sure that these two emails ... are assigned
// to him"): an agent adds a PENDING sign-in address to a human with no member
// session (do_spl_human_email_add).
//
//	POST /v1/operator/humans/{human_id}/emails {email, agent_id, ordered_by}
//	GET  /v1/operator/humans/{human_id}/emails   (the read-back)
//
//   - Who: the env service account's Google ID token on the operator
//     allow-list (operatorAuth), as the other /v1/operator routes.
//   - The rules are store/sign_in_emails.go's, called, not copied: the add is
//     PENDING only; active or pending on another human is 409 email_taken
//     (never whose); it turns ACTIVE only through a provider sign-in started
//     from that human's own session (auth start?link=1). Nothing here
//     activates an address.
//   - Audit: added_in "operator", added_by "<agent_id> for <ordered_by>".
//   - Hub-wide like humans: no workspace, so no tenant in the body.

// addedInOperator is human_pending_emails.added_in of an operator add.
const addedInOperator = "operator"

// operatorHumanEmailTarget is the operator check and the path's human id of
// both routes; it writes the error itself.
func (s *Server) operatorHumanEmailTarget(w http.ResponseWriter, r *http.Request) (string, string, store.SignInEmails, bool) {
	op, ok := s.operatorAuth(w, r)
	if !ok {
		return "", "", nil, false
	}
	hum := r.PathValue("human_id")
	if !humanIDRe.MatchString(hum) {
		writeErr(w, http.StatusBadRequest, "bad_human_id", "human_id must be a HUM-* id")
		return "", "", nil, false
	}
	e, ok := s.signInEmailStore(w)
	return op, hum, e, ok
}

func (s *Server) handleOperatorHumanEmailAdd(w http.ResponseWriter, r *http.Request) {
	op, hum, e, ok := s.operatorHumanEmailTarget(w, r)
	if !ok {
		return
	}
	var body struct {
		Email     string `json:"email"`
		AgentID   string `json:"agent_id"`
		OrderedBy string `json:"ordered_by"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {email, agent_id, ordered_by}")
		return
	}
	agent, orderedBy := strings.TrimSpace(body.AgentID), strings.TrimSpace(body.OrderedBy)
	switch {
	case !agentid.IsAgent(agent):
		writeErr(w, http.StatusBadRequest, "bad_agent_id", "agent_id must be an agent id, e.g. c-042")
		return
	case !humanIDRe.MatchString(orderedBy):
		writeErr(w, http.StatusBadRequest, "bad_ordered_by", "ordered_by must be the HUM-* id of the human who ordered it")
		return
	}
	email := signInAddress(w, body.Email)
	if email == "" {
		return
	}
	state, err := e.AddPendingEmail(r.Context(), hum, email, addedInOperator, agent+" for "+orderedBy, s.o.Now())
	switch {
	case errors.Is(err, store.ErrEmailTaken):
		// No hint of whose it is, and no merge.
		writeErr(w, http.StatusConflict, "email_taken", "this address belongs to another account")
		return
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such human")
		return
	case errors.Is(err, store.ErrTechnicalHuman):
		writeErr(w, http.StatusConflict, "technical", "an agent or a clone has no sign-in emails")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "address not added")
		return
	}
	s.o.Log.Info().Str("human", hum).Str("state", state).Str("agent", agent).Str("operator", op).
		Str("ordered_by", orderedBy).Msg("operator.sign_in_email_added")
	reason := reasonPendingProvider
	if state == store.EmailActive {
		reason = reasonAlreadyActive
	}
	writeJSON(w, http.StatusOK, map[string]any{"human_id": hum, "email": email, "state": state, "reason": reason})
}

// handleOperatorHumanEmails reads a human's addresses back: {email, state,
// providers, main}, the main one first.
func (s *Server) handleOperatorHumanEmails(w http.ResponseWriter, r *http.Request) {
	_, hum, e, ok := s.operatorHumanEmailTarget(w, r)
	if !ok {
		return
	}
	list, err := e.SignInEmails(r.Context(), hum)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such human")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "addresses unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"human_id": hum, "emails": list})
}

func (s *Server) routeOperatorHumanEmails(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/operator/humans/{human_id}/emails", s.handleOperatorHumanEmailAdd)
	mux.HandleFunc("GET /v1/operator/humans/{human_id}/emails", s.handleOperatorHumanEmails)
}
