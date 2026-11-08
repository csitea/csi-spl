package hub

import (
	"errors"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// ingestScope places a release note ingest or a deploy record (spec 171 Lane 2,
// spec 143 releases-projects.md section 4.3): the workspace is the body's or
// ?tenant=, else the request host's, else on the api or apex host the operator
// workspace in force, so the deploy-time callers that name none keep landing
// there. The repo is the named one, which the workspace must have registered,
// else its primary. On a refusal it writes the error and answers ok=false.
func (s *Server) ingestScope(w http.ResponseWriter, r *http.Request, tenant, repo string) (string, string, bool) {
	id := strings.TrimSpace(tenant)
	if id == "" {
		id = strings.TrimSpace(r.URL.Query().Get("tenant"))
	}
	if id == "" {
		id = s.hostTenantID(r)
	}
	if id == "" {
		op, err := s.operatorTenant(r.Context())
		if err != nil {
			writeErrCause(w, http.StatusServiceUnavailable, "internal", "the operator workspace is not readable", err)
			return "", "", false
		}
		id = op
	}
	if id == "" {
		writeErr(w, http.StatusBadRequest, "tenant_required", "name a tenant: this hub has no operator workspace")
		return "", "", false
	}
	if _, ok := s.loadTenant(w, r, id); !ok {
		return "", "", false
	}
	repos, ok := s.o.Store.(store.WorkspaceRepos)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "repos_off", "this hub's store keeps no workspace repos")
		return "", "", false
	}
	slug, err := repos.WorkspaceRepo(r.Context(), id, strings.TrimSpace(repo))
	switch {
	case errors.Is(err, store.ErrRepoNotRegistered):
		writeErr(w, http.StatusConflict, "repo_not_registered", "this workspace has not registered that repo")
		return "", "", false
	case err != nil:
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "the workspace repo is not readable", err)
		return "", "", false
	}
	return id, slug, true
}
