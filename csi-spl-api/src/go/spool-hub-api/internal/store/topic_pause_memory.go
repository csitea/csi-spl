package store

import (
	"context"
	"sort"
	"strings"
	"time"
)

// Memory side of topic_pause.go (rdb 0297, spec 179 row B1). The rows live
// beside the Memory value, as memQuotas does, under s.mu.

// memTopicPause is one Memory store's topic_pauses and topic_pause_issues.
type memTopicPause struct {
	pauses map[[2]string]TopicPause          // (tenant, task)
	held   map[string]map[int]memTopicPaused // tenant -> number
}

// memTopicPaused is one Memory topic_pause_issues row.
type memTopicPaused struct {
	task, prev, by string
	at             time.Time
}

var memTopicPauses = map[*Memory]*memTopicPause{}

// topicPausesLocked is s's rows, made on first use. The caller holds s.mu.
func (s *Memory) topicPausesLocked() *memTopicPause {
	tp := memTopicPauses[s]
	if tp == nil {
		tp = &memTopicPause{pauses: map[[2]string]TopicPause{}, held: map[string]map[int]memTopicPaused{}}
		memTopicPauses[s] = tp
	}
	return tp
}

// topicPauseLocked is task's pause, zero when it is not paused (Postgres:
// the LEFT JOIN of the topic list and the door). The caller holds s.mu.
func (s *Memory) topicPauseLocked(tenant, task string) TopicPause {
	if tp := memTopicPauses[s]; tp != nil {
		return tp.pauses[[2]string{tenant, strings.ToLower(task)}]
	}
	return TopicPause{}
}

// SetTopicPaused implements TopicPauseStore.
func (s *Memory) SetTopicPaused(_ context.Context, tenant, taskID, by, reason string, at time.Time, paused bool) (TopicPauseState, error) {
	key, reason, err := checkTopicPause(tenant, taskID, by, reason)
	if err != nil {
		return TopicPauseState{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return TopicPauseState{}, ErrNotFound
	}
	at = followAt(at)
	tp, k := s.topicPausesLocked(), [2]string{tenant, key}
	if !paused {
		_, was := tp.pauses[k]
		delete(tp.pauses, k)
		return TopicPauseState{Changed: was, Followed: s.topicResumeLocked(tenant, key, by, at)}, nil
	}
	if p, ok := tp.pauses[k]; ok {
		if reason != "" {
			p.Reason = reason
			tp.pauses[k] = p
		}
		return TopicPauseState{Pause: p}, nil
	}
	p := TopicPause{TenantID: tenant, TaskID: key, PausedBy: by, PausedAt: at, Reason: reason}
	tp.pauses[k] = p
	return TopicPauseState{Pause: p, Changed: true, Followed: s.topicHoldLocked(tenant, key, by, at)}, nil
}

// topicHoldLocked is the Memory twin of the pause's issue statement: every
// open, non-epic issue that links key goes onhold, its status kept.
func (s *Memory) topicHoldLocked(tenant, key, by string, at time.Time) []IssueFollow {
	tp, want := s.topicPausesLocked(), map[string]bool{key: true}
	var out []IssueFollow
	for n, i := range s.iss.rows[tenant] {
		if s.followTaskLocked(tenant, n, want) == "" || !topicPauseHolds(i.Status) || i.IsEpic() {
			continue
		}
		if tp.held[tenant] == nil {
			tp.held[tenant] = map[int]memTopicPaused{}
		}
		tp.held[tenant][n] = memTopicPaused{task: key, prev: i.Status, by: by, at: at}
		out = append(out, IssueFollow{Number: n, TaskID: key, Op: IssueFollowPause, From: i.Status, To: IssueOnHold})
		i.Status, i.UpdatedAt, i.UpdatedBy = IssueOnHold, at, by
		s.iss.rows[tenant][n] = i
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Number < out[j].Number })
	return out
}

// topicResumeLocked is the Memory twin of topicResumeTx.
func (s *Memory) topicResumeLocked(tenant, key, by string, at time.Time) []IssueFollow {
	tp := s.topicPausesLocked()
	var out []IssueFollow
	for n, h := range tp.held[tenant] {
		if h.task != key {
			continue
		}
		delete(tp.held[tenant], n)
		i, ok := s.iss.rows[tenant][n]
		if !ok || i.Status != IssueOnHold {
			continue
		}
		i.Status, i.UpdatedAt, i.UpdatedBy = topicPauseRestore(h.prev), at, by
		s.iss.rows[tenant][n] = i
		out = append(out, IssueFollow{Number: n, TaskID: key, Op: IssueFollowResume, From: IssueOnHold, To: i.Status})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Number < out[j].Number })
	return out
}

// AnyTopicPaused implements TopicPauseStore.
func (s *Memory) AnyTopicPaused(_ context.Context, tenant string, taskIDs ...string) (TopicPause, bool, error) {
	if err := checkTenant(tenant); err != nil {
		return TopicPause{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, k := range topicPauseKeys(taskIDs) {
		if p := s.topicPauseLocked(tenant, k); p.Paused() {
			return p, true, nil
		}
	}
	return TopicPause{}, false, nil
}
