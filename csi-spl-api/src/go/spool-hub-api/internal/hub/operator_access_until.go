package hub

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// PATCH /v1/operator/members/{human_id} {tenant, access_until, ordered_by?,
// ordered_via?}: the operator twin of PATCH /v1/members/{human_id}'s
// access_until (rdb 0113, spec 072 A27), so a box sets or clears the end of a
// membership with no member session (do_spl_hub_member_access_until). The same
// store call, so the same last-owner / last-admin guards; access_until is an
// RFC 3339 time or null (no end), and must be present. 200 with the result.
func (s *Server) handleOperatorMemberAccessUntil(w http.ResponseWriter, r *http.Request) {
	op, ok := s.operatorAuth(w, r)
	if !ok {
		return
	}
	var body struct {
		Tenant      string          `json:"tenant"`
		AccessUntil json.RawMessage `json:"access_until"`
		OrderedBy   string          `json:"ordered_by"`
		OrderedVia  string          `json:"ordered_via"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	if !msg.ValidTenantID(body.Tenant) {
		writeErr(w, http.StatusBadRequest, "bad_tenant", "tenant must be a valid slug")
		return
	}
	target := r.PathValue("human_id")
	if !humanIDRe.MatchString(target) {
		writeErr(w, http.StatusBadRequest, "bad_human_id", "human_id must be a HUM-* id")
		return
	}
	if body.AccessUntil == nil {
		writeErr(w, http.StatusBadRequest, "bad_access_until", "access_until is required: an RFC 3339 time or null")
		return
	}
	orderedBy := strings.TrimSpace(body.OrderedBy)
	if orderedBy != "" && !humanIDRe.MatchString(orderedBy) {
		writeErr(w, http.StatusBadRequest, "bad_ordered_by", "ordered_by must be a HUM-* id")
		return
	}
	until, ok := parseAccessUntil(w, body.AccessUntil)
	if !ok || !s.setAccessUntil(w, r, body.Tenant, target, until) {
		return
	}
	out := map[string]any{"tenant_id": body.Tenant, "human_id": target, "access_until": nil, "access_ended": false}
	if until != nil {
		out["access_until"], out["access_ended"] = rfc(*until), !s.o.Now().Before(*until)
	}
	s.o.Log.Info().Str("tenant", body.Tenant).Str("member", target).Str("operator", op).
		Str("ordered_by", orderedBy).Str("ordered_via", strings.TrimSpace(body.OrderedVia)).
		Bool("cleared", until == nil).Msg("operator.member_access_until")
	writeJSON(w, http.StatusOK, out)
}
