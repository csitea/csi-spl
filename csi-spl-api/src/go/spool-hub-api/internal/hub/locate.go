package hub

import (
	"context"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
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
	sess, tenants, err := s.o.Auth.MemberTenants(r)
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "view_door", "a member session is required")
		return
	}
	ids := make([]string, 0, len(tenants))
	for _, t := range tenants {
		if !s.demoFenced(rbac.Access{Role: t.Role}, t.TenantID) { // a fenced demo seat is no membership (specs/077 T015)
			ids = append(ids, t.TenantID)
		}
	}
	ctx := store.WithMemo(r.Context())
	found, err := s.locateTopicOrMessage(ctx, ids, id)
	if err == nil && found != "" {
		var v modView // specs/077 T016: a hidden message is not found
		if v, err = s.moderation(ctx, found, sess.HumanID); v.drops(id) {
			found = ""
		}
	}
	switch {
	case err != nil:
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "locate")
	case found != "":
		writeJSON(w, http.StatusOK, map[string]string{"id": id, "tenant": found})
	default:
		writeErr(w, http.StatusNotFound, "not_found", "no topic or message with that id in your tenants")
	}
}

// locateTopicOrMessage is the first of tenants holding id, "" when none (perf
// r4 G2): one store batch for every tenant, each probed in its own scope,
// where the loop paid one round trip a tenant. A store without
// store.SetReads keeps the loop.
func (s *Server) locateTopicOrMessage(ctx context.Context, tenants []string, id string) (string, error) {
	if sr, ok := s.o.Store.(store.SetReads); ok {
		return sr.LocateTopicOrMessage(ctx, tenants, id)
	}
	for _, t := range tenants {
		ok, err := s.o.Store.HasTopicOrMessage(ctx, t, id)
		if err != nil {
			return "", err
		}
		if ok {
			return t, nil
		}
	}
	return "", nil
}
