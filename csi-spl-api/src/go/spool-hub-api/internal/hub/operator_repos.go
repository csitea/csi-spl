package hub

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The operator's registration of a workspace's repo (spec 143
// releases-projects.md section 4.5, row B-6), spec 171's repos route with a
// required project. Operator auth, like the project route and the ingest:
// the box action do_workspace_repo_register (csi-spl-orc) drives it, and a
// workspace admin never reaches it, since a typed slug could point one
// workspace at another's private repo.
//
//	PUT /v1/operator/workspaces/{id}/repos
//	    {"repo_slug", "project_slug", "repo_web_url", "trunk_branch",
//	     "auth_mode", "is_primary", "notes_public"}
//	    creates or updates the repo under the project. 404 unknown_project
//	    for a project the workspace lacks, 409 repo_taken for a slug another
//	    workspace holds. A workspace's first repo becomes its primary.

// repoPutMax is the most bytes a repo body takes.
const repoPutMax = 4 << 10

type operatorRepoIn struct {
	RepoSlug    string `json:"repo_slug"`
	ProjectSlug string `json:"project_slug"`
	RepoWebURL  string `json:"repo_web_url"`
	TrunkBranch string `json:"trunk_branch"`
	AuthMode    string `json:"auth_mode"`
	IsPrimary   bool   `json:"is_primary"`
	NotesPublic bool   `json:"notes_public"`
}

type operatorRepoOut struct {
	Workspace   string `json:"workspace"`
	RepoSlug    string `json:"repo_slug"`
	ProjectSlug string `json:"project_slug"`
	IsPrimary   bool   `json:"is_primary"`
	NotesPublic bool   `json:"notes_public"`
}

func (s *Server) routeOperatorRepos(mux *http.ServeMux) {
	mux.HandleFunc("PUT /v1/operator/workspaces/{id}/repos", s.handleOperatorRepoPut)
}

// PUT /v1/operator/workspaces/{id}/repos
func (s *Server) handleOperatorRepoPut(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.operatorAuth(w, r); !ok {
		return
	}
	rw, ok := s.o.Store.(store.WorkspaceRepoWriter)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "repos_off", "this hub's store keeps no workspace repos")
		return
	}
	var in operatorRepoIn
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, repoPutMax))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {repo_slug, project_slug, repo_web_url, ...}: "+err.Error())
		return
	}
	put := store.WorkspaceRepoPut{Tenant: r.PathValue("id"), Slug: in.RepoSlug, Project: in.ProjectSlug, WebURL: in.RepoWebURL,
		TrunkBranch: in.TrunkBranch, AuthMode: in.AuthMode, IsPrimary: in.IsPrimary, NotesPublic: in.NotesPublic}
	if err := store.CheckWorkspaceRepo(&put); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if _, ok := s.loadTenant(w, r, put.Tenant); !ok {
		return
	}
	primary, err := rw.PutWorkspaceRepo(r.Context(), put)
	switch {
	case errors.Is(err, store.ErrNoProject):
		writeErr(w, http.StatusNotFound, "unknown_project", "this workspace has no project "+put.Project+": PUT it first")
		return
	case errors.Is(err, store.ErrRepoTaken):
		writeErr(w, http.StatusConflict, "repo_taken", "another workspace has registered "+put.Slug)
		return
	case err != nil:
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "the repo is not stored", err)
		return
	}
	s.o.Log.Info().Str("tenant", put.Tenant).Str("repo", put.Slug).Str("project", put.Project).Bool("is_primary", primary).Msg("operator.repo_put")
	writeJSON(w, http.StatusOK, operatorRepoOut{Workspace: put.Tenant, RepoSlug: put.Slug, ProjectSlug: put.Project,
		IsPrimary: primary, NotesPublic: put.NotesPublic})
}
