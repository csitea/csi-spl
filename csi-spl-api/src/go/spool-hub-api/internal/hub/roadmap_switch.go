package hub

import (
	"errors"
	"net/http"
	"slices"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A workspace's roadmap visibility switch (specs/112 HUB-2, spec 12.5, OQ3;
// rdb 0162 tenants.roadmap_public, store.RoadmapSwitch):
//
//   - GET   /v1/workspaces/{slug}/roadmap  any member of that workspace reads
//     {workspace, public}.
//   - PATCH /v1/workspaces/{slug}/roadmap  {public: bool}, a biz_owner or an
//     admin of THAT workspace only (the roles that approve its goals, 12.3);
//     every other member is 403. It re-audiences the workspace's synced
//     goal:, release: and spec: events in the same transaction; db: events
//     stay internal.
//
// The workspace is the path's, never the Host's or the session's active
// one: the caller must hold a member session of it, so an admin of A who
// names B is refused (403 not_member) and writes nothing.

type roadmapSwitchBody struct {
	Workspace string `json:"workspace"`
	Public    bool   `json:"public"`
}

// roadmapSwitchActor resolves the path's workspace and the caller's member
// id there, or writes 403 / 404.
func (s *Server) roadmapSwitchActor(w http.ResponseWriter, r *http.Request) (store.RoadmapSwitch, string, string, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	ws := r.PathValue("slug")
	hum := ""
	if msg.ValidTenantID(ws) {
		hum, _ = s.memberID(r, ws)
	}
	if hum == "" {
		writeErr(w, http.StatusForbidden, "not_member", "a member session of this workspace is required")
		return nil, "", "", false
	}
	if _, err := s.access(r.Context(), hum, ws); err != nil {
		writeErr(w, http.StatusForbidden, "not_member", "not a member of this workspace")
		return nil, "", "", false
	}
	if _, ok := s.loadTenant(w, r, ws); !ok {
		return nil, "", "", false
	}
	rs, ok := s.o.Store.(store.RoadmapSwitch)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no roadmap switch")
		return nil, "", "", false
	}
	return rs, ws, hum, true
}

func (s *Server) writeRoadmapSwitch(w http.ResponseWriter, r *http.Request, rs store.RoadmapSwitch, ws string) {
	on, err := rs.RoadmapPublic(r.Context(), ws)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "roadmap switch unavailable")
		return
	}
	writeJSON(w, http.StatusOK, roadmapSwitchBody{Workspace: ws, Public: on})
}

// GET /v1/workspaces/{slug}/roadmap
func (s *Server) handleRoadmapSwitch(w http.ResponseWriter, r *http.Request) {
	if rs, ws, _, ok := s.roadmapSwitchActor(w, r); ok {
		s.writeRoadmapSwitch(w, r, rs, ws)
	}
}

// PATCH /v1/workspaces/{slug}/roadmap {public}
func (s *Server) handlePatchRoadmapSwitch(w http.ResponseWriter, r *http.Request) {
	rs, ws, hum, ok := s.roadmapSwitchActor(w, r)
	if !ok {
		return
	}
	if a, err := s.access(r.Context(), hum, ws); err != nil || !slices.Contains(roadmapApproverRoles, a.Role) {
		writeForbidden(w, "", "only a biz_owner or an admin of this workspace switches its roadmap")
		return
	}
	var body struct {
		Public *bool `json:"public"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	if body.Public == nil {
		writeErr(w, http.StatusBadRequest, "bad_setting", "public (true or false) is required")
		return
	}
	n, err := rs.SetRoadmapPublic(r.Context(), ws, *body.Public, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "unknown_tenant", "no such tenant")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", ws).Msg("roadmap switch")
		writeErr(w, http.StatusInternalServerError, "internal", "roadmap switch unavailable")
		return
	}
	s.o.Log.Info().Str("tenant", ws).Bool("public", *body.Public).Int("reaudienced", n).Msg("roadmap switch")
	s.writeRoadmapSwitch(w, r, rs, ws)
}

func (s *Server) roadmapSwitchPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, PATCH")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) routeRoadmapSwitch(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/workspaces/{slug}/roadmap", s.handleRoadmapSwitch)
	mux.HandleFunc("PATCH /v1/workspaces/{slug}/roadmap", s.handlePatchRoadmapSwitch)
	mux.HandleFunc("OPTIONS /v1/workspaces/{slug}/roadmap", s.roadmapSwitchPreflight)
}
