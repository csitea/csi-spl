package hub

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The operator link of two accounts of one person (spec 042 "Note to self",
// SPL-5372; owner HUM-10, t1 df36f210, poll 3193d41f answer C, msg 20528286:
// "Operator-set link only, no self-service"). An agent links, by a human's
// order, a person's second account to the first (do_spl_human_link); the
// mention rule then reads a tag of it as a note to self (note_to_self.go).
//
//	POST /v1/operator/humans/{human_id}/links {linked_human_id, agent_id, ordered_by}
//	GET  /v1/operator/humans/{human_id}/links   (the read-back)
//
//   - Who: the env service account's Google ID token on the operator
//     allow-list (operatorAuth), as the other /v1/operator routes. No member
//     route writes a link.
//   - Both directions, idempotent; created_by "<agent_id> for <ordered_by>".
//   - Hub-wide like humans: no workspace, so no tenant in the body.

// operatorHumanLinkTarget is the operator check and the path's human id of
// both routes; it writes the error itself.
func (s *Server) operatorHumanLinkTarget(w http.ResponseWriter, r *http.Request) (string, string, store.HumanLinks, bool) {
	op, ok := s.operatorAuth(w, r)
	if !ok {
		return "", "", nil, false
	}
	hum := r.PathValue("human_id")
	if !humanIDRe.MatchString(hum) {
		writeErr(w, http.StatusBadRequest, "bad_human_id", "human_id must be a HUM-* id")
		return "", "", nil, false
	}
	hl, ok := s.o.Store.(store.HumanLinks)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "not_supported", "this store has no human links")
		return "", "", nil, false
	}
	return op, hum, hl, true
}

func (s *Server) handleOperatorHumanLinkAdd(w http.ResponseWriter, r *http.Request) {
	op, hum, hl, ok := s.operatorHumanLinkTarget(w, r)
	if !ok {
		return
	}
	var body struct {
		LinkedHumanID string `json:"linked_human_id"`
		AgentID       string `json:"agent_id"`
		OrderedBy     string `json:"ordered_by"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {linked_human_id, agent_id, ordered_by}")
		return
	}
	linked, agent, orderedBy := strings.TrimSpace(body.LinkedHumanID), strings.TrimSpace(body.AgentID), strings.TrimSpace(body.OrderedBy)
	switch {
	case !humanIDRe.MatchString(linked):
		writeErr(w, http.StatusBadRequest, "bad_linked_human_id", "linked_human_id must be a HUM-* id")
		return
	case !agentid.IsAgent(agent):
		writeErr(w, http.StatusBadRequest, "bad_agent_id", "agent_id must be an agent id, e.g. c-042")
		return
	case !humanIDRe.MatchString(orderedBy):
		writeErr(w, http.StatusBadRequest, "bad_ordered_by", "ordered_by must be the HUM-* id of the human who ordered it")
		return
	}
	err := hl.LinkHumans(r.Context(), hum, linked, agent+" for "+orderedBy, s.o.Now())
	switch {
	case errors.Is(err, store.ErrSameHuman):
		writeErr(w, http.StatusBadRequest, "same_human", "a human is not linked to itself")
		return
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such human")
		return
	case errors.Is(err, store.ErrTechnicalHuman):
		writeErr(w, http.StatusConflict, "technical", "an agent or a clone is not a person's account")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "link not written")
		return
	}
	s.o.Log.Info().Str("human", hum).Str("linked", linked).Str("agent", agent).Str("operator", op).
		Str("ordered_by", orderedBy).Msg("operator.human_linked")
	s.writeHumanLinks(w, r, hl, hum)
}

// handleOperatorHumanLinks reads a human's links back.
func (s *Server) handleOperatorHumanLinks(w http.ResponseWriter, r *http.Request) {
	if _, hum, hl, ok := s.operatorHumanLinkTarget(w, r); ok {
		s.writeHumanLinks(w, r, hl, hum)
	}
}

// writeHumanLinks answers {human_id, linked: [HUM-*]}.
func (s *Server) writeHumanLinks(w http.ResponseWriter, r *http.Request, hl store.HumanLinks, hum string) {
	ids, err := hl.LinkedHumans(r.Context(), hum)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "links unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"human_id": hum, "linked": ids})
}

func (s *Server) routeOperatorHumanLinks(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/operator/humans/{human_id}/links", s.handleOperatorHumanLinkAdd)
	mux.HandleFunc("GET /v1/operator/humans/{human_id}/links", s.handleOperatorHumanLinks)
}
