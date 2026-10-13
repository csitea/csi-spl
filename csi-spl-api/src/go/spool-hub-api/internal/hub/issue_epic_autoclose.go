package hub

import (
	"context"
	"fmt"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// An epic closes by itself when its last open issue closes (SPL-1729; owner
// HUM-10, t1 1ccf3a20, poll 954cd02f: "B — Close it automatically"). The
// store does it in UpdateIssue's transaction (store.ClosesChild) through the
// epic close of SPL-1643, so the epic and its issues are archived; the hub
// around it tells the tabs, comments on the epic, and files a bug when the
// cascade failed (afterEpicClose).
func (s *Server) afterEpicAutoClose(ctx context.Context, tenant, actor string, child store.Issue) {
	epic := child.AutoClosedEpic
	if epic == nil {
		return
	}
	op := "update"
	if epic.ClosedArchived {
		op = "archive"
	}
	s.fanoutIssue(ctx, tenant, map[string]any{"type": issueFrame, "op": op, "issue": toIssueJSON(*epic, s.storeGetter(ctx, tenant)),
		"descendants": descendantKeys(epic.Prefix, epic.ArchivedWith)})
	at := s.o.Now().UTC().Format(time.RFC3339)
	body := fmt.Sprintf("Closed as %s automatically: its last open issue %s was closed by %s at %s.", epic.Status, child.Key(), actor, at)
	if err := s.postIssueNote(ctx, tenant, epic.TaskID, uid.FromSeed("spool-epic-autoclose:"+epic.TaskID+":"+at), body); err != nil {
		s.o.Log.Warn().Err(err).Str("tenant", tenant).Str("epic", epic.Key()).Msg("epic auto-close: comment")
	}
	s.afterEpicClose(ctx, tenant, actor, *epic, epicTree{})
}

// epicAutoCloseAnswer adds the auto-closed epic to an update's answer.
func epicAutoCloseAnswer(ans map[string]any, out store.Issue) map[string]any {
	if e := out.AutoClosedEpic; e != nil {
		ans["epic_closed"] = map[string]any{"key": e.Key(), "status": e.Status, "archived": e.ClosedArchived,
			"descendants": descendantKeys(e.Prefix, e.ArchivedWith)}
	}
	return ans
}
