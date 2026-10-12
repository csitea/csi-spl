package hub

import (
	"net/http"
	"strconv"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// GET /v1/view/issues/{ref}/history: the Jira-like History tab of one issue
// (rdb 0181, owner HUM-10 t1 62e48cef). Oldest first: created, every field
// change (old -> new), each comment, delete / archive. Readable by every
// member who can read the issue (the view door), like the issue itself.

type issueEventJSON struct {
	At    string  `json:"at"`
	Actor string  `json:"actor"`
	Event string  `json:"event"`
	Field string  `json:"field,omitempty"`
	Old   *string `json:"old"`
	New   *string `json:"new"`
	MsgID string  `json:"msg_id,omitempty"`
}

// parentKey renders a parent number the way the issue JSON does (SPL-12).
func parentKey(prefix string, v *string) *string {
	if v == nil {
		return nil
	}
	n, err := strconv.Atoi(*v)
	if err != nil {
		return v
	}
	k := store.IssueKey(prefix, n)
	return &k
}

func toIssueEventJSON(e store.IssueEvent, prefix string) issueEventJSON {
	out := issueEventJSON{At: rfc(e.At), Actor: e.Actor, Event: e.Event, Field: e.Field, Old: e.Old, New: e.New, MsgID: e.MsgID}
	if e.Field == "parent" {
		out.Old, out.New = parentKey(prefix, e.Old), parentKey(prefix, e.New)
	}
	return out
}

func (s *Server) handleViewIssueHistory(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	is, ie := s.issueStore()
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	hs, ok := s.o.Store.(store.IssueHistories)
	if !ok {
		writeIssueErr(w, &issueErr{http.StatusServiceUnavailable, "unavailable", "this hub keeps no issue history"})
		return
	}
	n, ok := store.ParseIssueRef(r.PathValue("ref"))
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "no such issue")
		return
	}
	evs, err := hs.IssueHistory(r.Context(), t.ID, n)
	if ie := storeIssueErr(err); ie != nil {
		writeIssueErr(w, ie)
		return
	}
	prefix, err := is.IssuePrefix(r.Context(), t.ID)
	if ie := storeIssueErr(err); ie != nil {
		writeIssueErr(w, ie)
		return
	}
	out := make([]issueEventJSON, 0, len(evs))
	for _, e := range evs {
		out = append(out, toIssueEventJSON(e, prefix))
	}
	writeJSON(w, http.StatusOK, map[string]any{"key": store.IssueKey(prefix, n), "events": out})
}
