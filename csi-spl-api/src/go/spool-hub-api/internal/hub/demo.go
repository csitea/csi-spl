package hub

import (
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Demo users (specs/077, slice 1). Options.DemoWorkspace is the one workspace
// a demo_user may act in; "" = the demo is off (SPOOL_HUB_DEMO_ENABLED false,
// the default in dev and prd). The fence sits in access(), so EVERY
// permission check of the hub sees it: a demo_user membership grants nothing
// with the demo off, nor in any other workspace, whatever a bug elsewhere
// lets a request name.

// Demo limits the greeting and the admission read (spec 3.6, owner answers
// 37c34381 and ba3983eb). Settings at build of T018; the live cap is a
// constant until then, the stay is Options.DemoMaxStay (demo_stay.go).
const demoMaxLive = 9

// demoFenced reports whether a's role is demo_user outside the open demo
// workspace: such an access is treated as no membership at all.
func (s *Server) demoFenced(a rbac.Access, tenant string) bool {
	return a.Role == rbac.DemoUser && (s.o.DemoWorkspace == "" || tenant != s.o.DemoWorkspace)
}

// selfKeys writes 403 unless hum may write its own keys and event log
// (self.keys, specs/077 G2). Those routes are per human, not per tenant, so
// the check is made in the demo workspace, the one place a role without it
// lives; with the demo off every signed-in human passes, as before.
func (s *Server) selfKeys(w http.ResponseWriter, r *http.Request, hum string) bool {
	if s.o.DemoWorkspace == "" {
		return true
	}
	a, err := s.access(r.Context(), hum, s.o.DemoWorkspace)
	if err != nil || a.Can(rbac.SelfKeys) { // not a member there: not a demo visitor
		return true
	}
	writeForbidden(w, rbac.SelfKeys, "your role does not grant "+rbac.SelfKeys)
	return false
}

// tokenMayWriteFiles writes 403 unless the upload token's member may write
// files (files.write, specs/077 G1). A box token carries no member and
// passes; a WUI socket's token is checked per request, so a demotion bites
// on an open socket.
func (s *Server) tokenMayWriteFiles(w http.ResponseWriter, r *http.Request, tenant string) bool {
	tok, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	s.mu.Lock()
	member := s.tokens[tok].member
	s.mu.Unlock()
	if member == "" {
		return true
	}
	return s.permit(w, r, tenant, member, rbac.FilesWrite)
}

// memberRoles is roles without demo_user: no member route offers or grants
// it (only the open demo admission will, T007). A copy: roles may be the
// authorizer's cached map.
func memberRoles(roles map[string]rbac.Role) map[string]rbac.Role {
	out := make(map[string]rbac.Role, len(roles))
	for id, r := range roles {
		if id != rbac.DemoUser {
			out[id] = r
		}
	}
	return out
}

// archivePolicy is t's "Who can archive topics" in force: the demo workspace
// is always starter (spec gap G4), so one visitor never archives another's
// topic whatever its row says.
func (s *Server) archivePolicy(t store.Tenant) string {
	if s.o.DemoWorkspace != "" && t.ID == s.o.DemoWorkspace {
		return store.ArchivePolicyStarter
	}
	return store.EffectiveArchivePolicy(t.TopicArchivePolicy)
}

func (s *Server) routeDemo(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/demo", s.handleDemo)
}

// GET /v1/demo: the demo workspace and its limits, public (the login page's
// "Try the demo" button reads it). 404 while the demo is off, so a probe of
// a dev or prd hub with the flag off finds nothing.
func (s *Server) handleDemo(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	if s.o.DemoWorkspace == "" {
		writeErr(w, http.StatusNotFound, "not_found", "the demo is off")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"workspace": s.o.DemoWorkspace,
		"max_live": demoMaxLive, "max_stay": demoStayText(s.demoMaxStay())})
}
