package hub

import (
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// handleViewLocate is GET /v1/view/locate/{id} (SPL-959): the tenant a topic
// or message uuid belongs to, so an old apex link
// (https://<fqdn>/channel?topic=<uuid>, /t/<uuid>, ?thread=) can move to that
// tenant's host. uuids are globally unique, so the answer is unambiguous. It
// searches ONLY the tenants the signed-in human is a member of, each in its
// own tenant scope. A uuid of any other tenant reads exactly like an unknown
// one (404), so no tenant is revealed. Not tenant-bound by the page: that is
// the point of it.
func (s *Server) handleViewLocate(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	id := r.PathValue("id")
	if !uuidRe.MatchString(id) {
		writeErr(w, http.StatusBadRequest, "bad_id", "id must be a lowercase uuid")
		return
	}
	if s.o.Auth == nil {
		writeErr(w, http.StatusUnauthorized, "view_door", "a member session is required")
		return
	}
	_, tenants, err := s.o.Auth.MemberTenants(r)
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "view_door", "a member session is required")
		return
	}
	ctx := store.WithMemo(r.Context())
	for _, t := range tenants {
		ok, err := s.o.Store.HasTopicOrMessage(ctx, t.TenantID, id)
		if err != nil {
			writeErr(w, http.StatusServiceUnavailable, "unavailable", "locate")
			return
		}
		if ok {
			writeJSON(w, http.StatusOK, map[string]string{"id": id, "tenant": t.TenantID})
			return
		}
	}
	writeErr(w, http.StatusNotFound, "not_found", "no topic or message with that id in your tenants")
}
