package hub

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// POST /v1/messages/{msg_id}/issue — the owner makes an issue of a blocker.
//
// Owner HUM-10, t1 5ea2e615 msg db5ed497: "An owner question should not
// become an issue until the owner decides that." The sweep (blocker_issue.go)
// skips a workspace owner, so the blocker mark stays their open question; this
// call is the decision. It makes the issue the sweep would have made (todo,
// label blocker, linked both ways through BlockerIssueTask), reported by the
// owner.
//
// Who may call it: a workspace owner (tenant_owner role), on a message that
// still carries the blocker mark. The assignee is one id the blocker tags:
// the body's "assignee", else the caller when tagged, else the only tagged
// id. A second call answers the issue already made, 200.

type makeIssueRequest struct {
	Assignee string `json:"assignee"`
}

func (s *Server) handleMakeBlockerIssue(w http.ResponseWriter, r *http.Request) {
	t, actor, ok := s.issueWriter(w, r)
	if !ok {
		return
	}
	if !s.workspaceOwner(r.Context(), t.ID, actor) {
		writeErr(w, http.StatusForbidden, "not_allowed", "only a workspace owner makes an issue of a blocker")
		return
	}
	id := strings.ToLower(r.PathValue("msg_id"))
	if !uuidRe.MatchString(id) {
		writeErr(w, http.StatusBadRequest, "bad_json", "msg_id must be a UUID")
		return
	}
	var body makeIssueRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil && !errors.Is(err, io.EOF) {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {} or {assignee}")
		return
	}
	m, err := s.o.Store.GetEditable(r.Context(), t.ID, id, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("make issue: message lookup")
		writeErr(w, http.StatusInternalServerError, "internal", "message unavailable")
		return
	}
	if !s.messageDoor(w, r, t.ID, m) {
		return
	}
	if m.Kind != blockerKind {
		writeErr(w, http.StatusConflict, "not_blocker", "only a message marked blocker becomes an issue")
		return
	}
	p := blockerPostOf(m)
	a, ok := makeIssueAssignee(p.Assignees(), body.Assignee, actor)
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_assignee", "assignee must be one id the blocker tags")
		return
	}
	s.makeBlockerIssue(w, r, t.ID, actor, p, a)
}

// makeBlockerIssue answers the issue of (p, a): 200 when it exists, else 201
// with the new one.
func (s *Server) makeBlockerIssue(w http.ResponseWriter, r *http.Request, tenant, actor string, p store.BlockerPost, a string) {
	task := store.BlockerIssueTask(tenant, p.MsgID, a)
	code := http.StatusCreated
	i, ie := s.blockerIssueOn(r.Context(), tenant, actor, p, a, task, blockerOwnerDescription(p, a, actor))
	if ie != nil && ie.token == "conflict" { // made before: by an earlier call, or by the sweep for an ex-owner
		code = http.StatusOK
		i, ie = s.blockerIssueOf(r, tenant, task)
	}
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	if code == http.StatusCreated {
		s.o.Log.Info().Str("tenant", tenant).Str("msg_id", p.MsgID).Str("assignee", a).Str("by", actor).
			Str("issue", i.Key()).Msg("blocker issues: the owner made an issue")
	}
	writeJSON(w, code, map[string]any{"issue": toIssueJSON(i, s.storeGetter(r.Context(), tenant))})
}

// blockerIssueOf reads the issue already made on task.
func (s *Server) blockerIssueOf(r *http.Request, tenant, task string) (store.Issue, *issueErr) {
	is, ie := s.issueStore()
	bi, ok := s.o.Store.(store.BlockerIssues)
	if ie != nil || !ok {
		return store.Issue{}, &issueErr{http.StatusServiceUnavailable, "unavailable", "this hub keeps no issues"}
	}
	ref, err := bi.IssueByTask(r.Context(), tenant, task)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("make issue: issue lookup")
		return store.Issue{}, &issueErr{http.StatusInternalServerError, "internal", "issue unavailable"}
	}
	i, err := is.GetIssue(r.Context(), tenant, ref.Number)
	return i, storeIssueErr(err)
}

// makeIssueAssignee picks the assignee among tagged: want when given, else
// the caller when tagged, else the only tagged id.
func makeIssueAssignee(tagged []string, want, caller string) (string, bool) {
	switch {
	case want != "":
		return want, slices.Contains(tagged, want)
	case slices.Contains(tagged, caller):
		return caller, true
	case len(tagged) == 1:
		return tagged[0], true
	}
	return "", false
}

func blockerOwnerDescription(p store.BlockerPost, a, owner string) string {
	return fmt.Sprintf("Blocker from %s to @%s: %s made it this issue.\n\n%s\n\n"+
		"[Open the message](/m/%s) in topic `%s`. An answer by @%s in that discussion resolves this issue; "+
		"resolving it clears the blocker mark.", p.FromID, bareAgentID(a), owner, blockerQuote(p.Body), p.MsgID, p.TaskID, bareAgentID(a))
}

// makeIssuePreflight answers CORS preflight for POST /v1/messages/{msg_id}/issue.
func (s *Server) makeIssuePreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "POST")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}
