package hub

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Every blocker issue goes under the workspace's blocker epic (SPL-2409).
//
// Owner HUM-10, t1 7a98c2d1 (msgs ef77b762 + 5863d0d6): no issue without an
// epic and a git spec. An unanswered blocker has no spec of its own, so its
// issue goes under one epic per workspace that holds them all: the live epic
// titled BlockerEpicTitle (t1 had SPL-2394, made by hand), else one the hub
// makes the first time. The sweep and the owner's "Make an issue" both pass
// through blockerIssueOn, so both get the parent.

// BlockerEpicTitle is the title the blocker epic is found by, exactly.
const BlockerEpicTitle = "Area: unanswered blockers - issues with no spec"

const blockerEpicDescription = "Every issue the hub makes of an unanswered blocker (the blocker sweep, " +
	"or \"Make an issue\" on the message) goes under this epic: such an issue has no spec of its own. " +
	"The hub finds this epic by its exact title. It closes by itself when its last open issue closes; the next blocker then starts a new one."

// blockerEpicChainMax bounds the walk over the epics the hub made before.
const blockerEpicChainMax = 64

// BlockerEpicTask is the topic of the blocker epic the hub makes in tenant
// after the one numbered prev (0: the first). An epic closes and archives
// itself with its issues when its last open issue closes (SPL-1729), so the
// hub may need a next one; deriving each topic from the one before means
// two hub processes walk the same chain, and issues' UNIQUE (tenant_id,
// task_id) lets only one of them make the next epic.
func BlockerEpicTask(tenant string, prev int) string {
	return uid.FromSeed(fmt.Sprintf("spool-blocker-epic:%s:%d", tenant, prev))
}

// blockerEpic is the number of the workspace's open blocker epic, made on
// topic discussion (by actor) when the workspace has none.
func (s *Server) blockerEpic(ctx context.Context, tenant, actor, discussion string) (int, *issueErr) {
	is, ie := s.issueStore()
	bi, ok := s.o.Store.(store.BlockerIssues)
	if ie != nil || !ok {
		return 0, &issueErr{http.StatusServiceUnavailable, "unavailable", "this hub keeps no issues"}
	}
	n, err := findBlockerEpic(ctx, is, tenant)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("blocker issues: epic lookup")
		return 0, &issueErr{http.StatusInternalServerError, "internal", "issues unavailable"}
	}
	if n > 0 {
		return n, nil
	}
	prev := 0
	for range blockerEpicChainMax {
		task := BlockerEpicTask(tenant, prev)
		ref, err := bi.IssueByTask(ctx, tenant, task)
		switch {
		case errors.Is(err, store.ErrNotFound):
			out, ie := s.makeBlockerEpic(ctx, tenant, actor, task, discussion)
			if ie == nil || ie.token != "conflict" {
				return out, ie
			}
			continue // another hub made it first: read it on the next turn
		case err != nil:
			return 0, storeIssueErr(err)
		case ref.Status != "" && !issueResolved(ref.Status):
			return ref.Number, nil // open, though renamed
		}
		prev = ref.Number // closed or archived: the next one
	}
	return 0, &issueErr{http.StatusInternalServerError, "internal", "no blocker epic after " +
		strconv.Itoa(blockerEpicChainMax) + " closed ones"}
}

func (s *Server) makeBlockerEpic(ctx context.Context, tenant, actor, task, discussion string) (int, *issueErr) {
	title, desc, kind, ds := BlockerEpicTitle, blockerEpicDescription, store.IssueKindEpic, []string{discussion}
	out, ie := s.createIssueOn(ctx, tenant, actor, task, issueRequest{Title: &title, Description: &desc,
		Kind: &kind, Discussions: &ds, trusted: true})
	if ie != nil {
		return 0, ie
	}
	s.o.Log.Info().Str("tenant", tenant).Str("issue", out.Key()).Msg("blocker issues: made the blocker epic")
	return out.Number, nil
}

// findBlockerEpic is the oldest open live epic titled BlockerEpicTitle; 0
// when there is none.
func findBlockerEpic(ctx context.Context, is store.Issues, tenant string) (int, error) {
	all, err := is.ListIssues(ctx, tenant) // live rows, newest number first
	if err != nil {
		return 0, err
	}
	n := 0
	for _, i := range all {
		if i.IsEpic() && i.Title == BlockerEpicTitle && !issueResolved(i.Status) {
			n = i.Number
		}
	}
	return n, nil
}
