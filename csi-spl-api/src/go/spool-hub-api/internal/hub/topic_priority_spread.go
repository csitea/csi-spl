package hub

import (
	"context"
	"sort"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The issue's half of "the last prio change wins, both ways" (spec 150
// section 3.4 item 4 v1.3, SPL-5223; owner HUM-10, t1 20da7236, msg
// 76af2576: "I should be able to control the priority of the stuff which is
// getting built by just changing either the priority of the discussions or
// by changing the priority of the actual tasks"; msg 01c1f25e: an issue
// linked to two discussions sets both). A person's or an agent's change of
// an issue's priority (the update path, stamped issues.priority_set_at, rdb
// 0273) sets every discussion the issue links, the workspace's default
// discussion and a foreign link (SPL-5126) left out, at the issue's own
// time; then each of those discussions applies as a PUT does: their other
// issues follow, and lanes follow their issues. The 5-min sweep spreads a
// newer issue change the update path failed to, and never moves it back.
//
// A topic is written in the workspace that holds it: from the operator
// workspace the one topicWorkspace finds (the fleet's lane issue links the
// owner's topic there), from any other workspace that workspace only.

// prioSpreadJSON is one discussion set (or, on a dry run, to set) by a newer
// issue change: the topic's workspace and id, the issue, the old value (0:
// not set) and the new one.
type prioSpreadJSON struct {
	Workspace string `json:"workspace"`
	Topic     string `json:"topic"`
	Key       string `json:"key"`
	From      int    `json:"from"`
	To        int    `json:"to"`
}

// spreadIssuePriority is the update path's apply, after an update that
// carried a priority. A failure is logged, never the update's: the 5-min
// sweep spreads it again.
func (s *Server) spreadIssuePriority(ctx context.Context, tenant string, number int, by string) {
	run := prioRun{tenant: tenant, numbers: []int{number}, by: by, apply: true, spread: true}
	if ws, err := s.prioSyncWorkspaces(ctx, tenant); err != nil {
		s.o.Log.Warn().Err(err).Str("tenant", tenant).Msg("issue priority spread: workspaces not read, this one only")
	} else if len(ws) > 1 {
		run.lookIn = ws[1:]
	}
	if _, err := s.followDiscussionPriority(ctx, run); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Int("number", number).Msg("issue priority spread")
	}
}

// topicAt is one discussion a spread wrote: its workspace and id.
type topicAt struct{ ws, task string }

// spreadNewerIssues sets the discussions of every open issue of v whose own
// change is the newest, oldest change first so the newest is written last;
// then each written discussion's issues follow it.
func (s *Server) spreadNewerIssues(ctx context.Context, run prioRun, v prioView) ([]prioSpreadJSON, error) {
	ps, _ := s.o.Store.(store.TopicPriorityStore)
	var newer []store.Issue
	for _, i := range v.issues {
		if _, ok := v.own[i.Number]; ok && !issueResolved(i.Status) && v.ownNewer(i.Number) {
			newer = append(newer, i)
		}
	}
	sort.SliceStable(newer, func(a, b int) bool { return v.own[newer[a].Number].Before(v.own[newer[b].Number]) })
	out := []prioSpreadJSON{}
	var wrote []topicAt
	for _, i := range newer {
		for _, task := range spreadTopics(run.tenant, v.links[i.Number]) {
			if v.set[task].Priority == i.Priority {
				continue
			}
			ws := s.topicHome(ctx, run.tenant, task)
			out = append(out, prioSpreadJSON{Workspace: ws, Topic: task, Key: store.IssueKey(i.Prefix, i.Number), From: v.set[task].Priority, To: i.Priority})
			if !run.apply {
				continue
			}
			row, err := ps.SetTopicPriority(ctx, ws, task, i.Priority, run.by, v.own[i.Number])
			if err != nil {
				return out, err
			}
			v.set[task] = row
			s.announceTopicPriority(ctx, ws, row, store.IssueKey(i.Prefix, i.Number))
			wrote = append(wrote, topicAt{ws, task})
		}
	}
	for _, t := range wrote {
		s.followTopicPriority(ctx, t.ws, t.task, run.by)
	}
	return out, nil
}

// spreadTopics is the discussions an issue's change sets: its own links,
// the workspace's default discussion left out, each once.
func spreadTopics(tenant string, ls []store.IssueDiscussion) []string {
	def := strings.ToLower(store.IssueDiscussionDefault(tenant))
	var out []string
	for _, l := range ls {
		k := strings.ToLower(l.TaskID)
		if l.OriginTenant == "" && k != def && !contains(out, k) {
			out = append(out, k)
		}
	}
	return out
}

// topicHome is the workspace a spread from tenant writes task in: the one
// holding it when tenant is the operator workspace, else tenant itself.
func (s *Server) topicHome(ctx context.Context, tenant, task string) string {
	op, err := s.operatorTenant(ctx)
	if err != nil || op == "" || op != tenant {
		return tenant
	}
	if ws := s.topicWorkspace(ctx, op, task); ws != "" {
		return ws
	}
	return tenant
}

// announceTopicPriority logs a spread and sends the topic_priority frame to
// the topic's open views, as the PUT does.
func (s *Server) announceTopicPriority(ctx context.Context, ws string, row store.TopicPriority, key string) {
	s.o.Log.Info().Str("tenant", ws).Str("task", row.TaskID).Str("by", row.SetBy).Str("issue", key).Int("priority", row.Priority).Msg("topic priority set by its issue")
	card, found, err := s.openingCard(ctx, ws, row.TaskID)
	if err != nil || !found {
		return
	}
	out := map[string]any{"task_id": row.TaskID, "priority": row.Priority, "set_by": row.SetBy, "set_at": rfc(row.SetAt)}
	s.fanoutTopic(ctx, ws, card, withType(topicPriorityFrame, card, out))
}
