package hub

import (
	"context"
	"errors"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// An issue its assignee has not opened yet is marked in the Issues list the
// way an unread line is (SPL-1559, rdb 0184). The owner (HUM-10, t1
// 7edebc75, msg 7d76ce22): "A new issue should be marked as a new issue,
// which has not been opened yet, so it will be distinguishable from the rest
// of the issues." The Issues tab counts exactly those rows (WUI
// my-issues-count.mjs). Opening the issue in the WUI posts
// POST /v1/issues/{ref}/opened, which clears the mark for that member only.

// issueUnopened: i is still to do (not done, not discarded, not a level-1
// row), assigned to viewer, not created by viewer, and viewer never opened it.
func issueUnopened(i store.Issue, viewer string, opened map[int]bool) bool {
	if viewer == "" || i.Assignee != viewer || i.CreatedBy == viewer || i.IsEpic() {
		return false
	}
	if i.Status == store.IssueDone || i.Status == store.IssueDiss {
		return false
	}
	return !opened[i.Number]
}

func (s *Server) issueOpenStore() (store.IssueOpens, bool) {
	o, ok := s.o.Store.(store.IssueOpens)
	return o, ok
}

// issuesOpenedBy is the viewer's opened issues; none for no viewer or a store
// without the table (every row then reads as opened, never as new).
func (s *Server) issuesOpenedBy(ctx context.Context, tenant, viewer string) (map[int]bool, *issueErr) {
	o, ok := s.issueOpenStore()
	if viewer == "" || !ok {
		return nil, nil
	}
	opened, err := o.IssuesOpenedBy(ctx, tenant, viewer)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("issue opens")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "issues unavailable"}
	}
	return opened, nil
}

// handleIssueOpened is POST /v1/issues/{ref}/opened: the signed-in member
// opened the issue. It answers {"key", "unopened": false}.
func (s *Server) handleIssueOpened(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	if hum == "" {
		writeForbidden(w, rbac.TopicsRead, "opening an issue needs a signed-in member session")
		return
	}
	o, ok := s.issueOpenStore()
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "issue opens unavailable")
		return
	}
	n, ok := store.ParseIssueRef(r.PathValue("ref"))
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "no such issue")
		return
	}
	err := o.MarkIssueOpened(r.Context(), t.ID, hum, n, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such issue")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("issue opened")
		writeErr(w, http.StatusInternalServerError, "internal", "issue open not stored")
		return
	}
	prefix := store.IssuePrefixDefault
	if is, ok := s.o.Store.(store.Issues); ok {
		if p, err := is.IssuePrefix(r.Context(), t.ID); err == nil {
			prefix = p
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"key": store.IssueKey(prefix, n), "unopened": false})
}
