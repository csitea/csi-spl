package hub

import (
	"encoding/json"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The operator's registration of a workspace's software projects (spec 143
// releases-projects.md section 4.5, row B-5): the operator registers, a
// workspace admin does not, since a project's repos decide what the fleet
// GitHub App reads for it. Operator auth: a Google ID token of the env's
// SA, like the release note ingest, so the box action that registers a
// project (row B-6) drives it.
//
//	PUT /v1/operator/workspaces/{id}/projects/{project}  {"name", "is_default"}
//	    creates or renames the project; is_default moves the workspace's
//	    default to it, and a workspace's first project becomes its default.

// projectPutMax is the most bytes a project body takes.
const projectPutMax = 4 << 10

type operatorProjectIn struct {
	Name      string `json:"name"`
	IsDefault bool   `json:"is_default"`
}

type operatorProjectOut struct {
	Workspace string `json:"workspace"`
	Project   string `json:"project"`
	Name      string `json:"name"`
	IsDefault bool   `json:"is_default"`
}

func (s *Server) routeOperatorProjects(mux *http.ServeMux) {
	mux.HandleFunc("PUT /v1/operator/workspaces/{id}/projects/{project}", s.handleOperatorProjectPut)
}

// PUT /v1/operator/workspaces/{id}/projects/{project}
func (s *Server) handleOperatorProjectPut(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.operatorAuth(w, r); !ok {
		return
	}
	sp, ok := s.o.Store.(store.SoftwareProjects)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "projects_off", "this hub's store keeps no software projects")
		return
	}
	var in operatorProjectIn
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, projectPutMax))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {name, is_default}: "+err.Error())
		return
	}
	id, project := r.PathValue("id"), r.PathValue("project")
	if err := store.CheckSoftwareProject(id, project, in.Name); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if _, ok := s.loadTenant(w, r, id); !ok {
		return
	}
	def, err := sp.PutSoftwareProject(r.Context(), id, project, in.Name, in.IsDefault)
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "the project is not stored", err)
		return
	}
	s.o.Log.Info().Str("tenant", id).Str("project", project).Bool("is_default", def).Msg("operator.project_put")
	writeJSON(w, http.StatusOK, operatorProjectOut{Workspace: id, Project: project, Name: in.Name, IsDefault: def})
}
