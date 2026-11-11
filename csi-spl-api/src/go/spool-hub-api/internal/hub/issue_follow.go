package hub

import (
	"context"
	"fmt"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// An issue follows its discussion (SPL-5284; owner HUM-10, t1 fcf09921, msgs
// a081dcf2 and eae27b5d, poll 063a4bdd). The store closes, reopens or
// deletes the issues in the discussion's own transaction
// (store/issue_follow.go) and answers which; the hub around it tells every
// open tab (an `issue` frame) and leaves one comment on each closed or
// reopened issue naming the discussion. A deleted issue gets the frame only:
// its thread is gone from every list.

// afterIssueFollow sends the frames and comments for fs, what actor's
// archive, unarchive or delete of a discussion did. A failure is logged; the
// change itself has been stored.
func (s *Server) afterIssueFollow(ctx context.Context, tenant, actor string, fs []store.IssueFollow) {
	if len(fs) == 0 {
		return
	}
	is, ie := s.issueStore()
	if ie != nil {
		return
	}
	s.o.Log.Info().Str("tenant", tenant).Str("by", actor).Str("op", fs[0].Op).Int("issues", len(fs)).Msg("issue follows discussion")
	at := s.o.Now().UTC().Format(time.RFC3339)
	for _, f := range fs {
		if f.Op == store.IssueFollowDelete {
			s.issueFollowGone(ctx, tenant, is, f)
			continue
		}
		i, err := is.GetIssue(ctx, tenant, f.Number)
		if err != nil {
			s.o.Log.Warn().Err(err).Str("tenant", tenant).Int("number", f.Number).Msg("issue follow: read")
			continue
		}
		s.fanoutIssue(ctx, tenant, map[string]any{"type": issueFrame, "op": "update", "issue": toIssueJSON(i, s.storeGetter(ctx, tenant))})
		body := issueFollowNote(f, actor, at)
		if err := s.postIssueNote(ctx, tenant, i.TaskID, uid.FromSeed("spool-issue-follow:"+i.TaskID+":"+f.Op+":"+at), body); err != nil {
			s.o.Log.Warn().Err(err).Str("tenant", tenant).Str("issue", i.Key()).Msg("issue follow: comment")
		}
	}
}

// issueFollowGone tells every tab a deleted issue left: the frame needs its
// key only (issues-view.mjs applyIssueFrame).
func (s *Server) issueFollowGone(ctx context.Context, tenant string, is store.Issues, f store.IssueFollow) {
	prefix, err := is.IssuePrefix(ctx, tenant)
	if err != nil {
		s.o.Log.Warn().Err(err).Str("tenant", tenant).Msg("issue follow: prefix")
		return
	}
	key := store.IssueKey(prefix, f.Number)
	s.fanoutIssue(ctx, tenant, map[string]any{"type": issueFrame, "op": "delete",
		"issue": map[string]any{"key": key, "number": f.Number, "status": f.From}})
}

// issueFollowNote is the comment on an issue its discussion closed or
// reopened.
func issueFollowNote(f store.IssueFollow, actor, at string) string {
	if f.Op == store.IssueFollowArchive {
		return fmt.Sprintf("Closed (%s, was %s) because its discussion /t/%s was archived by %s at %s. Unarchiving the discussion reopens it as %s.",
			f.To, f.From, f.TaskID, actor, at, f.From)
	}
	return fmt.Sprintf("Reopened as %s because its discussion /t/%s was unarchived by %s at %s.", f.To, f.TaskID, actor, at)
}
