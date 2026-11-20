package store

import (
	"context"
	"slices"
	"sort"
	"strings"
	"time"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Memory side of topic_loop.go (rdb 0299, spec 182 row L1). The rows live
// beside the Memory value, as memTopicPauses does, under s.mu. Each rule is
// the shared one of topic_loop.go (newTopicLoop, applyTopicLoopEdit,
// topicLoopFire, topicLoopClaim), so the two stores cannot drift.

// memTopicLoops is one Memory store's topic_loops, (tenant, loop id) -> row.
var memTopicLoops = map[*Memory]map[[2]string]TopicLoop{}

// topicLoopsLocked is s's rows, made on first use. The caller holds s.mu.
func (s *Memory) topicLoopsLocked() map[[2]string]TopicLoop {
	tl := memTopicLoops[s]
	if tl == nil {
		tl = map[[2]string]TopicLoop{}
		memTopicLoops[s] = tl
	}
	return tl
}

// topicLoopCopy is l with its own Triggers, so a caller cannot write the
// stored row through the slice.
func topicLoopCopy(l TopicLoop) TopicLoop {
	l.Triggers, l.Due = slices.Clone(l.Triggers), slices.Clone(l.Due)
	return l
}

// sortTopicLoops orders ls as TopicLoops does: SetAt, then LoopID.
func sortTopicLoops(ls []TopicLoop) {
	sort.Slice(ls, func(i, j int) bool {
		if !ls[i].SetAt.Equal(ls[j].SetAt) {
			return ls[i].SetAt.Before(ls[j].SetAt)
		}
		return ls[i].LoopID < ls[j].LoopID
	})
}

// sortTopicLoopsDue orders claimed loops oldest due first; the move has put
// them all on one clock, so the tie breaks on tenant and loop id.
func sortTopicLoopsDue(ls []TopicLoop) {
	sort.Slice(ls, func(i, j int) bool {
		if ls[i].TenantID != ls[j].TenantID {
			return ls[i].TenantID < ls[j].TenantID
		}
		return ls[i].LoopID < ls[j].LoopID
	})
}

// TopicLoops implements TopicLoopStore.
func (s *Memory) TopicLoops(_ context.Context, tenant, taskID string) ([]TopicLoop, error) {
	return s.topicLoops(tenant, taskID, false)
}

// TopicLoopsOn implements TopicLoopStore.
func (s *Memory) TopicLoopsOn(_ context.Context, tenant, taskID string) ([]TopicLoop, error) {
	return s.topicLoops(tenant, taskID, true)
}

// topicLoops is taskID's loops, only the on ones with on.
func (s *Memory) topicLoops(tenant, taskID string, on bool) ([]TopicLoop, error) {
	key, err := checkTopicLoopTask(tenant, taskID)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []TopicLoop
	for k, l := range s.topicLoopsLocked() {
		if k[0] == tenant && l.TaskID == key && (!on || l.State == TopicLoopOn) {
			out = append(out, topicLoopCopy(l))
		}
	}
	sortTopicLoops(out)
	return out, nil
}

// AddTopicLoop implements TopicLoopStore.
func (s *Memory) AddTopicLoop(_ context.Context, tenant string, l TopicLoop) (TopicLoop, error) {
	row, err := newTopicLoop(tenant, l)
	if err != nil {
		return TopicLoop{}, err
	}
	if row.LoopID == "" {
		row.LoopID = uuid.New()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return TopicLoop{}, ErrNotFound
	}
	k := [2]string{tenant, row.LoopID}
	tl := s.topicLoopsLocked()
	if _, dup := tl[k]; dup {
		return TopicLoop{}, ErrConflict
	}
	tl[k] = row
	return topicLoopCopy(row), nil
}

// EditTopicLoop implements TopicLoopStore.
func (s *Memory) EditTopicLoop(_ context.Context, tenant, taskID, loopID string, e TopicLoopEdit) (TopicLoop, error) {
	key, err := checkTopicLoopTask(tenant, taskID)
	if err != nil {
		return TopicLoop{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]string{tenant, strings.ToLower(loopID)}
	tl := s.topicLoopsLocked()
	old, ok := tl[k]
	if !ok || old.TaskID != key {
		return TopicLoop{}, ErrNotFound
	}
	l, err := applyTopicLoopEdit(old, e)
	if err != nil {
		return TopicLoop{}, err
	}
	tl[k] = l
	return topicLoopCopy(l), nil
}

// DeleteTopicLoop implements TopicLoopStore.
func (s *Memory) DeleteTopicLoop(_ context.Context, tenant, taskID, loopID string) (bool, error) {
	key, err := checkTopicLoopTask(tenant, taskID)
	if err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]string{tenant, strings.ToLower(loopID)}
	tl := s.topicLoopsLocked()
	if l, ok := tl[k]; !ok || l.TaskID != key {
		return false, nil
	}
	delete(tl, k)
	return true, nil
}

// DeleteTopicLoops implements TopicLoopStore.
func (s *Memory) DeleteTopicLoops(_ context.Context, tenant, taskID string) (int, error) {
	key, err := checkTopicLoopTask(tenant, taskID)
	if err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	n, tl := 0, s.topicLoopsLocked()
	for k, l := range tl {
		if k[0] == tenant && l.TaskID == key {
			delete(tl, k)
			n++
		}
	}
	return n, nil
}

// CountTopicLoopFire implements TopicLoopStore: topicLoopFire under s.mu.
func (s *Memory) CountTopicLoopFire(_ context.Context, tenant, loopID string, at time.Time, cap int) (TopicLoop, bool, error) {
	if err := checkTenant(tenant); err != nil {
		return TopicLoop{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]string{tenant, strings.ToLower(loopID)}
	tl := s.topicLoopsLocked()
	l, ok := tl[k]
	if !ok {
		return TopicLoop{}, false, nil
	}
	l, fired := topicLoopFire(l, followAt(at), cap)
	if fired {
		tl[k] = l
	}
	return topicLoopCopy(l), fired, nil
}

// topicLoopEarliest is l's earliest set due time (the topic_loops_due
// index key, least() skipping NULLs).
func topicLoopEarliest(l TopicLoop) time.Time {
	var out time.Time
	for _, t := range []time.Time{l.NextDueAt, l.IdleDueAt, l.DailyDueAt} {
		if !t.IsZero() && (out.IsZero() || t.Before(out)) {
			out = t
		}
	}
	return out
}

// ClaimDueTopicLoops implements TopicLoopStore: every workspace's on loops
// with a due time <= at, earliest due first, up to limit, each moved on by
// topicLoopClaim. The stored row drops IdlePost with the idle count; the
// returned row keeps it, as Postgres returns the old idle_post.
func (s *Memory) ClaimDueTopicLoops(_ context.Context, at time.Time, limit int) ([]TopicLoop, error) {
	if limit <= 0 {
		limit = topicLoopClaimDefault
	}
	at = followAt(at)
	s.mu.Lock()
	defer s.mu.Unlock()
	tl := s.topicLoopsLocked()
	var due []TopicLoop
	for _, l := range tl {
		if _, ok := topicLoopClaim(l, at); ok {
			due = append(due, l)
		}
	}
	sort.Slice(due, func(i, j int) bool {
		a, b := topicLoopEarliest(due[i]), topicLoopEarliest(due[j])
		if !a.Equal(b) {
			return a.Before(b)
		}
		if due[i].TenantID != due[j].TenantID {
			return due[i].TenantID < due[j].TenantID
		}
		return due[i].LoopID < due[j].LoopID
	})
	if len(due) > limit {
		due = due[:limit]
	}
	for i, old := range due {
		l, _ := topicLoopClaim(old, at)
		stored := l
		if l.IdleDueAt.IsZero() && !old.IdleDueAt.IsZero() {
			stored.IdlePost = ""
		}
		stored.Due, stored.DueAt = nil, time.Time{}
		tl[[2]string{l.TenantID, l.LoopID}] = stored
		due[i] = topicLoopCopy(l)
	}
	sortTopicLoopsDue(due)
	return due, nil
}

// ArmTopicLoopIdle implements TopicLoopStore.
func (s *Memory) ArmTopicLoopIdle(_ context.Context, tenant, taskID, postID string, at time.Time) (int, error) {
	key, err := checkTopicLoopTask(tenant, taskID)
	if err != nil {
		return 0, err
	}
	if !isUUID(postID) {
		return 0, ErrBadTopicLoop
	}
	at = followAt(at)
	s.mu.Lock()
	defer s.mu.Unlock()
	n, tl := 0, s.topicLoopsLocked()
	for k, l := range tl {
		if k[0] == tenant && l.TaskID == key && l.State == TopicLoopOn && l.Has(LoopNoReplyAfterHuman) {
			l.IdleDueAt, l.IdlePost = at.Add(time.Duration(l.IdleMin)*time.Minute), strings.ToLower(postID)
			tl[k] = l
			n++
		}
	}
	return n, nil
}

// ClearTopicLoopIdle implements TopicLoopStore.
func (s *Memory) ClearTopicLoopIdle(_ context.Context, tenant, taskID string) (int, error) {
	key, err := checkTopicLoopTask(tenant, taskID)
	if err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	n, tl := 0, s.topicLoopsLocked()
	for k, l := range tl {
		if k[0] == tenant && l.TaskID == key && (!l.IdleDueAt.IsZero() || l.IdlePost != "") {
			l.IdleDueAt, l.IdlePost = time.Time{}, ""
			tl[k] = l
			n++
		}
	}
	return n, nil
}

// SetTopicLoopAwaiting implements TopicLoopStore.
func (s *Memory) SetTopicLoopAwaiting(_ context.Context, tenant, loopID, agent string, until time.Time) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	if len(agent) > 64 {
		return ErrBadTopicLoop
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]string{tenant, strings.ToLower(loopID)}
	tl := s.topicLoopsLocked()
	l, ok := tl[k]
	if !ok {
		return ErrNotFound
	}
	l.Awaiting, l.AwaitUntil = agent, time.Time{}
	if agent != "" && !until.IsZero() {
		l.AwaitUntil = followAt(until)
	}
	tl[k] = l
	return nil
}

// TenantHasTopicLoops implements TopicLoopStore.
func (s *Memory) TenantHasTopicLoops(_ context.Context, tenant string) (bool, error) {
	if err := checkTenant(tenant); err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for k := range s.topicLoopsLocked() {
		if k[0] == tenant {
			return true, nil
		}
	}
	return false, nil
}
