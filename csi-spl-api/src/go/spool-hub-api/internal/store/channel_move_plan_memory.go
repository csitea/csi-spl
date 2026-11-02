// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"fmt"
	"sort"
)

// PlanChannelMove on Memory plans what Memory holds: the channel, its posts
// (M2), its issues (M7, with the shared-issue and epic rules of C7), the
// mentions in staying posts, and the channel's people who stay behind.
// Memory has no SQL, so the catalogue counts cover only channels and
// messages; docs, hours, files and spec links are Postgres's
// (channel_move_plan_postgres.go), where C1 runs.
func (s *Memory) PlanChannelMove(_ context.Context, req ChannelMovePlanRequest) (ChannelMovePlan, error) {
	if err := mpCheckRequest(req); err != nil {
		return ChannelMovePlan{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.ch.rows[[2]string{req.Src, req.Channel}]; !ok {
		return ChannelMovePlan{}, fmt.Errorf("channel %q in %q: %w", req.Channel, req.Src, ErrNotFound)
	}
	plan := ChannelMovePlan{Src: req.Src, Channel: req.Channel, Dst: req.Dst}
	b := &plan.Binds
	b.Channel = req.Channel
	inMsg, inTask := s.planWalkLocked(req.Src, req.Channel)
	for m := range inMsg {
		b.Msgs = append(b.Msgs, m)
	}
	for t := range inTask {
		b.Tasks = append(b.Tasks, t)
	}
	s.iss.init()
	prefix := s.iss.prefixOf(req.Src)
	for n, is := range s.iss.rows[req.Src] {
		if s.planIssueInSetLocked(req.Src, n, is, inTask) {
			b.Numbers = append(b.Numbers, n)
			b.IssueKeys = append(b.IssueKeys, planIssueKey(prefix, n))
		}
	}
	b.mpFinish()
	plan.Counts = s.planCountsLocked(req, len(b.Msgs))
	if !req.noSharedCheck {
		plan.Shared = s.planSharedIssuesLocked(req.Src, prefix, b.Numbers, inTask)
	}
	plan.Mentions = s.planMentionsLocked(req, plan.Binds, inMsg)
	inDst := func(h string) bool {
		s.hum.init()
		m, ok := s.hum.members[[2]string{req.Dst, h}]
		return ok && m.live(s.hum.humans[h], s.now())
	}
	var humans []string
	for h := range s.ch.humans[[2]string{req.Src, req.Channel}] {
		humans = append(humans, h)
	}
	plan.Leaving = mpLeavingOf(humans, inDst, req.Keep)
	return plan, nil
}

// planWalkLocked is the M2 walk (the Postgres walk's rule) over s.messages.
func (s *Memory) planWalkLocked(tenant, channel string) (inMsg, inTask map[string]bool) {
	inMsg, inTask = map[string]bool{}, map[string]bool{}
	for grew := true; grew; {
		grew = false
		for k, m := range s.messages {
			if k[0] != tenant || inMsg[m.MsgID] {
				continue
			}
			if m.Channel == channel || inTask[m.TaskID] || (m.ParentTaskID != "" && inTask[m.ParentTaskID]) {
				inMsg[m.MsgID], inTask[m.MsgID], inTask[m.TaskID] = true, true, true
				grew = true
			}
		}
	}
	return inMsg, inTask
}

func (s *Memory) planIssueInSetLocked(tenant string, n int, is Issue, inTask map[string]bool) bool {
	if inTask[is.TaskID] {
		return true
	}
	for _, l := range s.iss.linksOf(tenant, n) {
		if inTask[l.TaskID] {
			return true
		}
	}
	return false
}

func (s *Memory) planCountsLocked(req ChannelMovePlanRequest, msgs int) []MoveCount {
	var out []MoveCount
	for _, t := range req.Tables {
		switch t.Table {
		case "channels":
			out = append(out, MoveCount{Table: t.Table, Class: t.Class, Set: 1})
		case "messages":
			out = append(out, MoveCount{Table: t.Table, Class: t.Class, Set: msgs})
		}
	}
	return out
}

// planSharedIssuesLocked is C7 on Memory: a topic outside the set that an
// issue of the set is linked to (its own or a discussion), and an epic link
// across the set's edge.
func (s *Memory) planSharedIssuesLocked(tenant, prefix string, numbers []int, inTask map[string]bool) []SharedItem {
	inSet := map[int]bool{}
	for _, n := range numbers {
		inSet[n] = true
	}
	var out []SharedItem
	for _, n := range numbers {
		is := s.iss.rows[tenant][n]
		tasks := []string{is.TaskID}
		for _, l := range s.iss.linksOf(tenant, n) {
			tasks = append(tasks, l.TaskID)
		}
		sort.Strings(tasks)
		for i, t := range tasks {
			if inTask[t] || (i > 0 && tasks[i-1] == t) {
				continue
			}
			if ch, ok := s.planTopicChannelLocked(tenant, t); ok {
				out = append(out, SharedItem{Kind: "issue", ID: planIssueKey(prefix, n),
					Why: fmt.Sprintf("also linked to topic %s in %s", t, mpChannelLabel(ch))})
			}
		}
	}
	for n, is := range s.iss.rows[tenant] {
		if is.Parent != 0 && inSet[n] != inSet[is.Parent] {
			out = append(out, SharedItem{Kind: "epic", ID: planIssueKey(prefix, is.Parent),
				Why: fmt.Sprintf("its child %s is on the other side of the move", planIssueKey(prefix, n))})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Kind+out[i].ID+out[i].Why < out[j].Kind+out[j].ID+out[j].Why })
	return out
}

// planTopicChannelLocked answers the channel of a topic with rows in tenant.
func (s *Memory) planTopicChannelLocked(tenant, task string) (string, bool) {
	for k, m := range s.messages {
		if k[0] == tenant && (m.TaskID == task || m.MsgID == task) {
			return m.Channel, true
		}
	}
	return "", false
}

func (s *Memory) planMentionsLocked(req ChannelMovePlanRequest, b ChannelMoveBinds, inMsg map[string]bool) []Mention {
	mm := mpNewMentionMatcher(b)
	var rows []*Message
	for k, m := range s.messages {
		if k[0] == req.Src && !inMsg[m.MsgID] {
			rows = append(rows, m)
		}
	}
	sort.Slice(rows, func(i, j int) bool {
		if !rows[i].ReceivedAt.Equal(rows[j].ReceivedAt) {
			return rows[i].ReceivedAt.Before(rows[j].ReceivedAt)
		}
		return rows[i].MsgID < rows[j].MsgID
	})
	var out []Mention
	for _, m := range rows {
		for _, line := range mm.mpLines(m.Body) {
			out = append(out, Mention{MsgID: m.MsgID, TaskID: m.TaskID, Channel: m.Channel, Author: m.FromID, Line: line})
		}
	}
	return out
}
