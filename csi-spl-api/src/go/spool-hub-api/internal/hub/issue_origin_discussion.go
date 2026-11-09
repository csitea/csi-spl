package hub

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// An issue can name the discussion it came from in another workspace
// (SPL-5126; owner HUM-10, t1 ef94396b msg 61bf7791: "at least 1 discussion
// where this issue originated from"; c-001 ruling bf29c39c, B + X). The
// member route refuses such a topic, since a member cannot read it. This
// route is operator auth only and takes the origin workspace by name. Neither
// its answer nor its log names that workspace.

// issueOriginLinkedBy is the linked_by of a foreign link: the operator's
// account is no member of the issue's workspace.
const issueOriginLinkedBy = "operator"

type issueOriginBody struct {
	Tenant       string `json:"tenant"`
	OriginTenant string `json:"origin_tenant"`
	Discussion   string `json:"discussion"`
}

// handleIssueOriginDiscussion is POST /v1/operator/issues/{ref}/origin-discussion
// {tenant, origin_tenant, discussion}: 200 {key, added}. The discussion is a
// topic of origin_tenant, by its id, short id or /t/ link.
func (s *Server) handleIssueOriginDiscussion(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.operatorAuth(w, r); !ok {
		return
	}
	var q issueOriginBody
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&q); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {tenant, origin_tenant, discussion}")
		return
	}
	if q.Tenant == "" || q.OriginTenant == "" || q.Tenant == q.OriginTenant {
		writeErr(w, http.StatusBadRequest, "bad_json", "tenant and a different origin_tenant are required")
		return
	}
	for _, id := range []string{q.Tenant, q.OriginTenant} {
		if _, err := s.o.Store.GetTenant(r.Context(), id); err != nil {
			writeErr(w, http.StatusNotFound, "not_found", "no such workspace")
			return
		}
	}
	key, added, ie := s.linkOriginDiscussion(r, q, r.PathValue("ref"))
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	s.o.Log.Info().Str("tenant", q.Tenant).Str("issue", key).Bool("added", added).Msg("operator.issue_origin_linked")
	writeJSON(w, http.StatusOK, map[string]any{"key": key, "added": added})
}

// linkOriginDiscussion checks the issue and the topic, links it and fans the
// issue out with the link opaque.
func (s *Server) linkOriginDiscussion(r *http.Request, q issueOriginBody, ref string) (string, bool, *issueErr) {
	ctx := r.Context()
	is, ie := s.issueStore()
	if ie != nil {
		return "", false, ie
	}
	d, ok := s.issueDiscussionStore()
	if !ok {
		return "", false, &issueErr{http.StatusServiceUnavailable, "unavailable", "this hub keeps no issue discussions"}
	}
	n, ok := store.ParseIssueRef(ref)
	if !ok {
		return "", false, &issueErr{http.StatusNotFound, "not_found", "no such issue"}
	}
	if _, err := is.GetIssue(ctx, q.Tenant, n); err != nil {
		return "", false, storeIssueErr(err)
	}
	task, ie := s.originTopic(r, d, q)
	if ie != nil {
		return "", false, ie
	}
	added, err := d.LinkIssueOriginDiscussion(ctx, q.Tenant, n, q.OriginTenant, task, issueOriginLinkedBy, s.o.Now())
	if err != nil {
		return "", false, storeIssueErr(err)
	}
	i, err := is.GetIssue(ctx, q.Tenant, n)
	if ie := storeIssueErr(err); ie != nil {
		return "", false, ie
	}
	out := toIssueJSON(i, s.storeGetter(ctx, q.Tenant))
	if links := s.tenantDiscussionLinks(ctx, q.Tenant); links != nil {
		out.Discussions = linksJSON(links[n])
	}
	s.fanoutIssue(ctx, q.Tenant, map[string]any{"type": issueFrame, "op": "update", "issue": out})
	return out.Key, added, nil
}

// originTopic resolves q.Discussion to a topic that exists in the origin
// workspace.
func (s *Server) originTopic(r *http.Request, d store.IssueDiscussions, q issueOriginBody) (string, *issueErr) {
	unknown := &issueErr{http.StatusBadRequest, "unknown_discussion", "no such discussion in that workspace"}
	task, ok := discussionRef(q.Discussion)
	if !ok {
		return "", badIssue("discussion must be a topic id or a /t/<topic id> link")
	}
	if store.TopicPrefixRe.MatchString(task) {
		ids, err := d.TopicsByPrefix(r.Context(), q.OriginTenant, task, 2)
		switch {
		case err != nil:
			return "", &issueErr{http.StatusInternalServerError, "internal", "discussion unavailable"}
		case len(ids) == 0:
			return "", unknown
		case len(ids) > 1:
			return "", &issueErr{http.StatusBadRequest, "ambiguous_discussion", "give the full topic id"}
		}
		task = strings.ToLower(ids[0])
	}
	states, err := d.DiscussionStates(r.Context(), q.OriginTenant, []string{task})
	if err != nil {
		return "", &issueErr{http.StatusInternalServerError, "internal", "discussion unavailable"}
	}
	if st := states[task].State; st == "" || st == store.DiscussionGone {
		return "", unknown
	}
	return task, nil
}
