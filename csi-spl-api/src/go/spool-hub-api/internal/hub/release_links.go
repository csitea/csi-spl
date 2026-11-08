package hub

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The issue and discussion links of a release note (SPL-4789, rdb 0261).
// Owner HUM-10, t1 ef94396b (msg 61bf7791): every commit carries "at least 1
// link for an issue , which was used to justify the work of the commit and at
// least 1 discussion where this issue originated from and the links must be
// clickable". A note's issue_keys are issues of its issue_tenant, the
// workspace that owns them (t1 for this repo), not the viewer's; the
// discussions are read live from that workspace's issue_discussions.
//
// What a viewer gets of the owning workspace is what it may open there: a
// session that is a member of it and may read the topic gets the topic id,
// title and state; anyone else gets the key, whether the issue exists and
// how many discussions it links, never a topic id or title. A read that
// fails leaves the links out (logged), never a 500.

// releaseTopicJSON is one discussion of an issue. TaskID and Title are set
// only when the viewer may open the topic (CanOpen).
type releaseTopicJSON struct {
	TaskID  string `json:"task_id,omitempty"`
	Title   string `json:"title,omitempty"`
	State   string `json:"state,omitempty"`
	CanOpen bool   `json:"can_open"`
}

// releaseIssueJSON is one issue a commit cites. Found is false for a key
// its workspace has no issue for (a typo, an example key in the body).
type releaseIssueJSON struct {
	Key         string             `json:"key"`
	Tenant      string             `json:"tenant"`
	Found       bool               `json:"found"`
	Member      bool               `json:"member"`
	Discussions []releaseTopicJSON `json:"discussions"`
}

// releaseNoteLinksJSON is a release note with its issue links.
type releaseNoteLinksJSON struct {
	store.ReleaseNote
	Issues []releaseIssueJSON `json:"issues"`
}

// withReleaseLinks answers notes with their issues and discussions, one
// links read and one states read per owning workspace.
func (s *Server) withReleaseLinks(r *http.Request, notes []store.ReleaseNote) []releaseNoteLinksJSON {
	out := make([]releaseNoteLinksJSON, len(notes))
	byTenant := map[string][]int{}
	for i, n := range notes {
		out[i] = releaseNoteLinksJSON{ReleaseNote: n, Issues: []releaseIssueJSON{}}
		if n.IssueTenant != "" && len(n.IssueKeys) > 0 {
			byTenant[n.IssueTenant] = append(byTenant[n.IssueTenant], i)
		}
	}
	for tenant, idx := range byTenant {
		hum, err := s.memberID(r, tenant)
		member := err == nil && hum != ""
		links, states := s.releaseTenantLinks(r.Context(), tenant, notes, idx)
		for _, i := range idx {
			for _, k := range notes[i].IssueKeys {
				out[i].Issues = append(out[i].Issues, s.releaseIssue(r.Context(), tenant, k, links, states, member, hum))
			}
		}
	}
	return out
}

// releaseTenantLinks is the discussions of every issue the notes idx cite in
// tenant, and the state of each of those topics; nil maps on a failed read.
func (s *Server) releaseTenantLinks(ctx context.Context, tenant string, notes []store.ReleaseNote, idx []int) (map[int][]store.IssueDiscussion, map[string]store.DiscussionState) {
	d, ok := s.issueDiscussionStore()
	if !ok {
		return nil, nil
	}
	seen := map[int]bool{}
	numbers := []int{}
	for _, i := range idx {
		for _, k := range notes[i].IssueKeys {
			if n, ok := store.ParseIssueRef(k); ok && !seen[n] {
				seen[n] = true
				numbers = append(numbers, n)
			}
		}
	}
	links, err := d.IssueDiscussionLinks(ctx, tenant, numbers)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("release note issue links")
		return nil, nil
	}
	tasks := []string{}
	for _, ls := range links {
		for _, l := range ls {
			tasks = append(tasks, l.TaskID)
		}
	}
	states, err := d.DiscussionStates(ctx, tenant, tasks)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("release note discussion states")
		return links, nil
	}
	return links, states
}

// releaseIssue is one cited key with its discussions as this viewer sees
// them. An issue always links >= 1 discussion (rdb 0194), so a key with
// none has no issue.
func (s *Server) releaseIssue(ctx context.Context, tenant, key string, links map[int][]store.IssueDiscussion,
	states map[string]store.DiscussionState, member bool, hum string) releaseIssueJSON {
	j := releaseIssueJSON{Key: key, Tenant: tenant, Member: member, Discussions: []releaseTopicJSON{}}
	n, _ := store.ParseIssueRef(key)
	for _, l := range links[n] {
		j.Found = true
		st := states[l.TaskID]
		t := releaseTopicJSON{}
		if member && st.State != "" && st.State != store.DiscussionGone {
			may, _, err := s.canReadTopic(ctx, tenant, l.TaskID, hum)
			if err != nil {
				s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("release note topic door")
			}
			if may {
				t = releaseTopicJSON{TaskID: l.TaskID, Title: st.Title, State: st.State, CanOpen: true}
			}
		}
		j.Discussions = append(j.Discussions, t)
	}
	return j
}

// releaseVersionLinks is one version's notes with their issue links (GET
// /v1/release-notes/v<X.Y.Z>); the list page keeps releaseVersion.
type releaseVersionLinks struct {
	Version string                 `json:"version"`
	Display string                 `json:"display"`
	Notes   []releaseNoteLinksJSON `json:"notes"`
}

// The pre-push and CI gate's check (SPL-4789): POST /v1/operator/commit-links
// {tenant, keys} answers, per key, whether tenant has that issue and how many
// discussions it links, other than the tenant's default discussion (the
// backlog every issue falls back to is not where an issue originated).
// Operator auth only: the env's service account, like the ingest.

// commitLinksMax is the most keys one check takes.
const commitLinksMax = 200

type commitLinksBody struct {
	Tenant string   `json:"tenant"`
	Keys   []string `json:"keys"`
}

type commitLinkJSON struct {
	Key         string `json:"key"`
	Found       bool   `json:"found"`
	Discussions int    `json:"discussions"`
	DefaultOnly bool   `json:"default_only"`
	// RelayHashOnly: every link other than the default is a version-5 uuid
	// (store.RelayTaskHashRe), the hash of a task name, not a discussion
	// (SPL-5126). Discussions still counts them; the check decides.
	RelayHashOnly bool `json:"relay_hash_only"`
}

func (s *Server) handleCommitLinks(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.operatorAuth(w, r); !ok {
		return
	}
	var body commitLinksBody
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {tenant, keys: [...]}")
		return
	}
	if body.Tenant == "" || len(body.Keys) == 0 || len(body.Keys) > commitLinksMax {
		writeErr(w, http.StatusBadRequest, "bad_json", "tenant and 1..200 keys are required")
		return
	}
	if _, err := s.o.Store.GetTenant(r.Context(), body.Tenant); err != nil {
		writeErr(w, http.StatusNotFound, "not_found", "no such workspace")
		return
	}
	d, ok := s.issueDiscussionStore()
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "this hub keeps no issue discussions")
		return
	}
	numbers := []int{}
	for _, k := range body.Keys {
		if n, ok := store.ParseIssueRef(k); ok {
			numbers = append(numbers, n)
		}
	}
	links, err := d.IssueDiscussionLinks(r.Context(), body.Tenant, numbers)
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "issue links not readable", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string][]commitLinkJSON{"keys": commitLinks(body.Tenant, body.Keys, links)})
}

// commitLinks is the answer per key, in the order asked.
func commitLinks(tenant string, keys []string, links map[int][]store.IssueDiscussion) []commitLinkJSON {
	def := store.IssueDiscussionDefault(tenant)
	out := make([]commitLinkJSON, 0, len(keys))
	for _, k := range keys {
		j, hashes := commitLinkJSON{Key: k}, 0
		if n, ok := store.ParseIssueRef(k); ok {
			for _, l := range links[n] {
				j.Found = true
				if l.TaskID == def {
					continue
				}
				j.Discussions++
				if store.RelayTaskHashRe.MatchString(l.TaskID) {
					hashes++
				}
			}
		}
		j.DefaultOnly = j.Found && j.Discussions == 0
		j.RelayHashOnly = j.Discussions > 0 && hashes == j.Discussions
		out = append(out, j)
	}
	return out
}
