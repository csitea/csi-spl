package hub

import (
	"context"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Closing an epic closes and archives its issues (SPL-1643; owner HUM-10, t1
// 1ccf3a20, msgs 4913b500, d6300003, 7c07c95d). The store does the cascade in
// UpdateIssue's transaction (store.ClosesEpic); the hub around it:
//
//   - asks for the confirmation: closing an epic that has open issues needs
//     cascade: true in the request (the WUI's Close button, spool issue
//     update --cascade), else 409 epic_close_confirm naming the count;
//   - posts the automated comment on every issue the cascade closed, and on
//     every issue an epic's unarchive restored;
//   - files a bug when the cascade or a comment failed: label bug, assigned
//     to whoever closed the epic, naming the epic, the issues and the reason.

// epicCloseBugLabel is the label of the bug the hub files.
const epicCloseBugLabel = "bug"

// epicTree is the live subtree of an epic as it was before the close,
// keyed by number: the comments need each issue's topic once it is archived.
type epicTree map[int]store.Issue

// epicCloseGate runs before an update. When it closes an epic (the store's
// rule), it answers the subtree; with open issues in it and no confirm it
// refuses. nil tree: the update closes no epic.
func (s *Server) epicCloseGate(ctx context.Context, is store.Issues, tenant string, number int, p store.IssuePatch, confirm bool) (epicTree, *issueErr) {
	if p.Status == nil || !store.IssueClosed(store.NormalizeIssueStatus(*p.Status)) {
		return nil, nil
	}
	cur, err := is.GetIssue(ctx, tenant, number)
	if err != nil {
		return nil, nil // the update itself answers the missing row
	}
	after := cur
	after.Status = store.NormalizeIssueStatus(*p.Status)
	if !store.ClosesEpic(cur.Status, after) {
		return nil, nil
	}
	all, err := is.ListIssues(ctx, tenant)
	if ie := storeIssueErr(err); ie != nil {
		return nil, ie
	}
	tree := subtreeOf(all, number)
	open := 0
	for _, i := range tree {
		if !store.IssueClosed(i.Status) {
			open++
		}
	}
	if open > 0 && !confirm {
		return nil, &issueErr{http.StatusConflict, "epic_close_confirm", fmt.Sprintf(
			"%s has %d open issues: closing it closes and archives them; send cascade: true to confirm (spool issue update --cascade)",
			cur.Key(), open)}
	}
	return tree, nil
}

// subtreeOf is every row under number in all (target excluded).
func subtreeOf(all []store.Issue, number int) epicTree {
	kids := map[int][]store.Issue{}
	for _, i := range all {
		kids[i.Parent] = append(kids[i.Parent], i)
	}
	tree := epicTree{}
	queue := []int{number}
	for len(queue) > 0 {
		p := queue[0]
		queue = queue[1:]
		for _, c := range kids[p] {
			if _, seen := tree[c.Number]; !seen && c.Number != number {
				tree[c.Number] = c
				queue = append(queue, c.Number)
			}
		}
	}
	return tree
}

// afterEpicClose posts the comments and files the bug of a failure.
func (s *Server) afterEpicClose(ctx context.Context, tenant, actor string, out store.Issue, tree epicTree) {
	if !store.IsEpicClose(out) {
		return
	}
	at := s.o.Now().UTC().Format(time.RFC3339)
	var failed []int
	var reasons []string
	if out.CascadeErr != "" {
		failed = append(failed, out.CascadeOpen...)
		reasons = append(reasons, "the cascade failed: "+out.CascadeErr)
	}
	body := fmt.Sprintf("Closed because its epic %s was closed by %s at %s.", out.Key(), actor, at)
	for _, n := range out.ClosedWith {
		task := tree[n].TaskID
		if err := s.postIssueNote(ctx, tenant, task, uid.FromSeed("spool-epic-close:"+task+":"+at), body); err != nil {
			failed = append(failed, n)
			reasons = append(reasons, fmt.Sprintf("%s: the comment was not posted: %v", store.IssueKey(out.Prefix, n), err))
		}
	}
	if len(reasons) > 0 {
		s.fileCascadeBug(ctx, tenant, actor, out, "close", failed, reasons)
	}
}

// afterEpicUnarchive posts the comment on every issue an epic's unarchive
// restored; their statuses stay as they were. was is the epic as answered by
// the store.
func (s *Server) afterEpicUnarchive(ctx context.Context, tenant, actor string, was store.Issue, kids []int) {
	if !was.IsEpic() || len(kids) == 0 {
		return
	}
	is, ie := s.issueStore()
	if ie != nil {
		return
	}
	at := s.o.Now().UTC().Format(time.RFC3339)
	var failed []int
	var reasons []string
	for _, n := range kids {
		i, err := is.GetIssue(ctx, tenant, n)
		if err == nil {
			body := fmt.Sprintf("Restored from the archive because its epic %s was restored by %s at %s; its status stays %s.",
				was.Key(), actor, at, i.Status)
			err = s.postIssueNote(ctx, tenant, i.TaskID, uid.FromSeed("spool-epic-unarchive:"+i.TaskID+":"+at), body)
		}
		if err != nil {
			failed = append(failed, n)
			reasons = append(reasons, fmt.Sprintf("%s: the comment was not posted: %v", store.IssueKey(was.Prefix, n), err))
		}
	}
	if len(reasons) > 0 {
		s.fileCascadeBug(ctx, tenant, actor, was, "unarchive", failed, reasons)
	}
}

// fileCascadeBug files the bug of a failed epic cascade (owner msg 7c07c95d:
// "if something doesn't work as expected, that should be filed as a bug").
// A failure to file it is logged; the close itself has succeeded.
func (s *Server) fileCascadeBug(ctx context.Context, tenant, actor string, epic store.Issue, op string, failed []int, reasons []string) {
	sort.Ints(failed)
	keys := descendantKeys(epic.Prefix, failed)
	s.o.Log.Warn().Str("tenant", tenant).Str("epic", epic.Key()).Strs("issues", keys).Str("op", op).
		Str("reason", strings.Join(reasons, "; ")).Msg("epic cascade failed: filing a bug")
	if _, ie := s.createIssueLabel(ctx, tenant, actor, epicCloseBugLabel, "#dc2626"); ie != nil && ie.token != "label_exists" {
		s.o.Log.Error().Str("tenant", tenant).Str("err", ie.Error()).Msg("epic cascade bug: label")
		return
	}
	title := fmt.Sprintf("Epic %s of %s left %d issues behind", op, epic.Key(), len(failed))
	var b strings.Builder
	fmt.Fprintf(&b, "The %s of epic [%s](/issues?issue=%s) by %s did not complete for every issue (SPL-1643).\n\n", op, epic.Key(), epic.Key(), actor)
	if len(keys) > 0 {
		fmt.Fprintf(&b, "Issues: %s\n\n", strings.Join(keys, ", "))
	}
	b.WriteString("Reason:\n")
	for _, r := range reasons {
		fmt.Fprintf(&b, "- %s\n", r)
	}
	desc, status, labels := b.String(), store.IssueTodo, []string{epicCloseBugLabel}
	q := issueRequest{Title: &title, Description: &desc, Status: &status, Labels: &labels}
	if s.checkAssignee(ctx, tenant, actor) == nil {
		q.Assignee = &actor
	}
	if _, ie := s.createIssue(ctx, tenant, actor, q); ie != nil {
		s.o.Log.Error().Str("tenant", tenant).Str("epic", epic.Key()).Str("err", ie.Error()).Msg("epic cascade bug: file")
	}
}

// epicCloseAnswer adds the cascade's outcome to an update's answer.
func epicCloseAnswer(ans map[string]any, out store.Issue) map[string]any {
	if !store.IsEpicClose(out) {
		return ans
	}
	ans["archived"] = out.ClosedArchived
	ans["closed"] = descendantKeys(out.Prefix, out.ClosedWith)
	ans["descendants"] = descendantKeys(out.Prefix, out.ArchivedWith)
	if out.CascadeErr != "" {
		ans["cascade_error"] = out.CascadeErr
	}
	return ans
}
