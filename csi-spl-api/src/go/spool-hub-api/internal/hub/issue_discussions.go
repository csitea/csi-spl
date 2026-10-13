package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Every issue links to one or more discussions (SPL-1593, rdb 0194,
// issues-v1 §2.1). The owner (HUM-10, t1 fcf09921): "Issues must be linked
// to one or more discussions." (msg 3e75e13e) "We must create a special part
// of the UI somewhere in the bottom panel where one could click on that one
// or more discussions." (msg 9a8e4764) A create names them in `discussions`;
// POST / DELETE /v1/issues/{ref}/discussions add and remove one, and the
// last one is never removed. Reads return them; a single-issue read adds
// each one's state (live, archived, gone) and, when the reader may read the
// topic, its title.

// issueDiscussionJSON is one link on the wire. State, title and channel are
// set on a single-issue read only.
type issueDiscussionJSON struct {
	TaskID   string `json:"task_id"`
	State    string `json:"state,omitempty"`
	Title    string `json:"title,omitempty"`
	Channel  string `json:"channel,omitempty"`
	LinkedBy string `json:"linked_by,omitempty"`
	LinkedAt string `json:"linked_at,omitempty"`
}

var (
	topicIDRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
	// a /t/ link: the full topic id, or its 8-hex short id
	topicLinkRe = regexp.MustCompile(`/t/([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})?)(?:[^0-9a-fA-F-]|$)`)
)

// discussionRef reads one discussion as given: a topic id, its 8-hex short
// id, or a link that carries /t/<either> (a copied topic link, the card's
// Source line). A short id still has to be resolved (resolveDiscussion).
func discussionRef(v string) (string, bool) {
	v = strings.ToLower(strings.TrimSpace(v))
	if topicIDRe.MatchString(v) || store.TopicPrefixRe.MatchString(v) {
		return v, true
	}
	if m := topicLinkRe.FindStringSubmatch(v); m != nil {
		return strings.ToLower(m[1]), true
	}
	return "", false
}

// resolveDiscussion turns a discussion ref into the topic id the actor may
// link: a full id is checked (checkDiscussion); a short id must match
// exactly ONE topic of the tenant, never a guess between two (c-002,
// dispatch-fcf09921 msg c5c7d032).
func (s *Server) resolveDiscussion(ctx context.Context, tenant, actor, ref string) (string, *issueErr) {
	if store.TopicPrefixRe.MatchString(ref) {
		d, ok := s.issueDiscussionStore()
		if !ok {
			return "", &issueErr{http.StatusBadRequest, "unknown_discussion", "no such discussion: " + ref}
		}
		ids, err := d.TopicsByPrefix(ctx, tenant, ref, 2)
		switch {
		case err != nil:
			s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("issue discussion prefix")
			return "", &issueErr{http.StatusInternalServerError, "internal", "discussion unavailable"}
		case len(ids) == 0:
			return "", &issueErr{http.StatusBadRequest, "unknown_discussion", "no such discussion: " + ref}
		case len(ids) > 1:
			return "", &issueErr{http.StatusBadRequest, "ambiguous_discussion", "more than one topic starts with " + ref + ": give the full topic id"}
		}
		ref = ids[0]
	}
	if ie := s.checkDiscussion(ctx, tenant, actor, ref); ie != nil {
		return "", ie
	}
	return ref, nil
}

// legacyCreateDefault is the rollout step (SPL-1593): until every client
// sends `discussions` (the WUI's create form, its "make an issue" and the
// subtask dialog land in the WUI step), a create that carries no
// `discussions` field and no /t/ link that resolves links the tenant's
// default discussion, the one the backfill and the relink use, and the hub
// logs it. An explicit `discussions: []` is refused either way. The WUI step
// turns it off.
var legacyCreateDefault = true

// discussionsFor is a create's discussions, resolved and checked. The
// `discussions` field is strict: every entry must resolve. Without it, the
// /t/ links in the description (the spec 135 card's Source line, which a
// `spool` binary older than SPL-1593 still sends) link the ones that
// resolve, and those that do not are left out. None is a refusal.
func (s *Server) discussionsFor(ctx context.Context, tenant, actor string, q issueRequest) ([]string, *issueErr) {
	out, ie := s.namedDiscussions(ctx, tenant, actor, q)
	if ie != nil {
		return nil, ie
	}
	if len(out) == 0 && q.Discussions == nil && legacyCreateDefault {
		def := store.IssueDiscussionDefault(tenant)
		s.o.Log.Warn().Str("tenant", tenant).Str("actor", actor).Str("discussion", def).
			Msg("issue create named no discussion: linked the tenant's default (an older client)")
		if ie := s.checkDiscussion(ctx, tenant, actor, def); ie != nil {
			return nil, ie
		}
		return []string{def}, nil
	}
	if len(out) == 0 {
		return nil, &issueErr{http.StatusBadRequest, "discussion_required",
			"an issue must link to at least one discussion: discussions: [<topic id>]"}
	}
	return out, nil
}

// namedDiscussions resolves the discussions a create names: the explicit
// list, else the /t/<id> links in its description (an unreadable link there
// is skipped, a store error is not).
func (s *Server) namedDiscussions(ctx context.Context, tenant, actor string, q issueRequest) ([]string, *issueErr) {
	out := []string{}
	if q.Discussions != nil {
		for _, v := range *q.Discussions {
			id, ie := s.namedDiscussion(ctx, tenant, actor, v, q.trusted)
			if ie != nil {
				return nil, ie
			}
			out = append(out, id)
		}
		return out, nil
	}
	if q.Description == nil {
		return out, nil
	}
	for _, m := range topicLinkRe.FindAllStringSubmatch(*q.Description, store.IssueDiscussionsMax) {
		id, ie := s.resolveDiscussion(ctx, tenant, actor, strings.ToLower(m[1]))
		if ie != nil && ie.status == http.StatusInternalServerError {
			return nil, ie
		}
		if ie == nil {
			out = append(out, id)
		}
	}
	return out, nil
}

// namedDiscussion is one entry of an explicit discussions list; a trusted
// (hub-filed) create skips the actor's read check.
func (s *Server) namedDiscussion(ctx context.Context, tenant, actor, v string, trusted bool) (string, *issueErr) {
	ref, ok := discussionRef(v)
	if !ok {
		return "", badIssue("each discussion must be a topic id or a /t/<topic id> link")
	}
	if trusted {
		return ref, nil
	}
	return s.resolveDiscussion(ctx, tenant, actor, ref)
}

func (s *Server) issueDiscussionStore() (store.IssueDiscussions, bool) {
	d, ok := s.o.Store.(store.IssueDiscussions)
	return d, ok
}

// checkDiscussion: task is a topic of the tenant the actor may read, or the
// tenant's default discussion (which the database itself links to).
func (s *Server) checkDiscussion(ctx context.Context, tenant, actor, task string) *issueErr {
	if task == store.IssueDiscussionDefault(tenant) {
		if task == store.IssueBacklogID(tenant) { // it is a message: post it now, not at the next sweep
			if _, err := s.postIssueBacklog(ctx, tenant); err != nil {
				s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("issue backlog")
			}
		}
		return nil
	}
	reader := actor
	if !humanIDRe.MatchString(reader) {
		reader = "" // an agent or the hub: the tenant's topics, as its sends
	}
	ok, found, err := s.canReadTopic(ctx, tenant, task, reader)
	switch {
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("issue discussion check")
		return &issueErr{http.StatusInternalServerError, "internal", "discussion unavailable"}
	case !found || !ok:
		return &issueErr{http.StatusBadRequest, "unknown_discussion", "no such discussion: " + task}
	}
	return nil
}

// linksJSON is the links alone, as a list read carries them.
func linksJSON(ls []store.IssueDiscussion) []issueDiscussionJSON {
	out := make([]issueDiscussionJSON, len(ls))
	for k, l := range ls {
		out[k] = issueDiscussionJSON{TaskID: l.TaskID, LinkedBy: l.LinkedBy, LinkedAt: rfc(l.LinkedAt)}
	}
	return out
}

// tenantDiscussionLinks is every link of the tenant (nil when the store keeps
// none or the read failed: the list then carries no discussions).
func (s *Server) tenantDiscussionLinks(ctx context.Context, tenant string) map[int][]store.IssueDiscussion {
	d, ok := s.issueDiscussionStore()
	if !ok {
		return nil
	}
	links, err := d.IssueDiscussionLinks(ctx, tenant, nil)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("issue discussion links")
		return nil
	}
	return links
}

// fullDiscussions is one issue's links with each topic's state; the title and
// channel only for a topic the reader may read ("" reader: an agent or the
// hub, which reads the tenant's topics).
func (s *Server) fullDiscussions(ctx context.Context, tenant string, number int, reader string) ([]issueDiscussionJSON, error) {
	d, ok := s.issueDiscussionStore()
	if !ok {
		return nil, nil
	}
	links, err := d.IssueDiscussionLinks(ctx, tenant, []int{number})
	if err != nil {
		return nil, err
	}
	ls := links[number]
	tasks := make([]string, len(ls))
	for k, l := range ls {
		tasks[k] = l.TaskID
	}
	states, err := d.DiscussionStates(ctx, tenant, tasks)
	if err != nil {
		return nil, err
	}
	out := linksJSON(ls)
	for k := range out {
		st := states[out[k].TaskID]
		out[k].State = st.State
		if out[k].State == "" {
			out[k].State = store.DiscussionGone
		}
		if st.State == store.DiscussionGone || st.State == "" {
			continue
		}
		may, _, err := s.canReadTopic(ctx, tenant, out[k].TaskID, reader)
		if err != nil {
			return nil, err
		}
		if may {
			out[k].Title, out[k].Channel = st.Title, st.Channel
		}
	}
	return out, nil
}

// withFullDiscussions sets j.Discussions for a single-issue read; a failed
// read is logged and leaves them out.
func (s *Server) withFullDiscussions(ctx context.Context, tenant, reader string, j *issueJSON) {
	ds, err := s.fullDiscussions(ctx, tenant, j.Number, reader)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Int("issue", j.Number).Msg("issue discussions")
		return
	}
	if ds != nil {
		j.Discussions = ds
	}
}

// linkDiscussion adds one link for actor; removeDiscussion removes one. Both
// answer the issue with its full discussions and fan the issue frame out.
func (s *Server) linkDiscussion(ctx context.Context, tenant, actor, ref, raw string) (issueJSON, *issueErr) {
	return s.changeDiscussion(ctx, tenant, actor, ref, raw, true)
}

func (s *Server) removeDiscussion(ctx context.Context, tenant, actor, ref, raw string) (issueJSON, *issueErr) {
	return s.changeDiscussion(ctx, tenant, actor, ref, raw, false)
}

func (s *Server) changeDiscussion(ctx context.Context, tenant, actor, ref, raw string, add bool) (issueJSON, *issueErr) {
	is, ie := s.issueStore()
	if ie != nil {
		return issueJSON{}, ie
	}
	d, ok := s.issueDiscussionStore()
	if !ok {
		return issueJSON{}, &issueErr{http.StatusServiceUnavailable, "unavailable", "this hub keeps no issue discussions"}
	}
	n, ok := store.ParseIssueRef(ref)
	if !ok {
		return issueJSON{}, &issueErr{http.StatusNotFound, "not_found", "no such issue"}
	}
	task, ok := discussionRef(raw)
	if !ok {
		return issueJSON{}, badIssue("discussion must be a topic id or a /t/<topic id> link")
	}
	if _, err := is.GetIssue(ctx, tenant, n); err != nil {
		return issueJSON{}, storeIssueErr(err)
	}
	if add {
		if task, ie = s.resolveDiscussion(ctx, tenant, actor, task); ie != nil {
			return issueJSON{}, ie
		}
		if _, err := d.LinkIssueDiscussion(ctx, tenant, n, task, actor, s.o.Now()); err != nil {
			return issueJSON{}, storeIssueErr(err)
		}
	} else if err := d.UnlinkIssueDiscussion(ctx, tenant, n, task); err != nil {
		if errors.Is(err, store.ErrIssueDiscussionLast) {
			return issueJSON{}, &issueErr{http.StatusConflict, "last_discussion", "an issue keeps at least one discussion: link another one first"}
		}
		if errors.Is(err, store.ErrNotFound) {
			return issueJSON{}, &issueErr{http.StatusNotFound, "not_found", "the issue does not link that discussion"}
		}
		return issueJSON{}, storeIssueErr(err)
	}
	i, err := is.GetIssue(ctx, tenant, n)
	if ie := storeIssueErr(err); ie != nil {
		return issueJSON{}, ie
	}
	out := toIssueJSON(i, s.storeGetter(ctx, tenant))
	if links := s.tenantDiscussionLinks(ctx, tenant); links != nil {
		out.Discussions = linksJSON(links[n])
	}
	s.fanoutIssue(ctx, tenant, map[string]any{"type": issueFrame, "op": "update", "issue": out})
	reader := actor
	if !humanIDRe.MatchString(reader) {
		reader = ""
	}
	s.withFullDiscussions(ctx, tenant, reader, &out)
	return out, nil
}

// handleIssueDiscussionAdd is POST /v1/issues/{ref}/discussions
// {"discussion": "<topic id or link>"}: 200 with the issue.
func (s *Server) handleIssueDiscussionAdd(w http.ResponseWriter, r *http.Request) {
	t, actor, ok := s.issueWriter(w, r)
	if !ok {
		return
	}
	var body struct {
		Discussion string `json:"discussion"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "body must be {\"discussion\": \"<topic id>\"}")
		return
	}
	out, ie := s.linkDiscussion(r.Context(), t.ID, actor, r.PathValue("ref"), body.Discussion)
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"issue": out})
}

// handleIssueDiscussionRemove is DELETE /v1/issues/{ref}/discussions/{task}:
// 200 with the issue, 409 last_discussion for the last one.
func (s *Server) handleIssueDiscussionRemove(w http.ResponseWriter, r *http.Request) {
	t, actor, ok := s.issueWriter(w, r)
	if !ok {
		return
	}
	out, ie := s.removeDiscussion(r.Context(), t.ID, actor, r.PathValue("ref"), r.PathValue("task"))
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"issue": out})
}
