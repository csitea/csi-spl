package store

import (
	"context"
	"time"
)

// Memory side of topic_priority.go (rdb 0214, spec 150 row B1).

// SetTopicPriority implements TopicPriorityStore.
func (s *Memory) SetTopicPriority(_ context.Context, tenant, taskID string, prio int, by string, at time.Time) (TopicPriority, error) {
	key, err := checkTopicPriority(tenant, taskID, prio)
	if err != nil {
		return TopicPriority{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return TopicPriority{}, ErrNotFound
	}
	if s.topicPrio == nil {
		s.topicPrio = map[[2]string]TopicPriority{}
	}
	p := TopicPriority{TenantID: tenant, TaskID: key, Priority: prio, SetBy: by, SetAt: at.UTC()}
	s.topicPrio[[2]string{tenant, key}] = p
	return p, nil
}

// TopicPriorities implements TopicPriorityStore.
func (s *Memory) TopicPriorities(_ context.Context, tenant string, taskIDs []string) (map[string]int, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	out, keys := defaultTopicPriorities(taskIDs)
	s.mu.Lock()
	defer s.mu.Unlock()
	stored := map[string]int{}
	for _, k := range keys {
		if p, ok := s.topicPrio[[2]string{tenant, k}]; ok {
			stored[k] = p.Priority
		}
	}
	return foldTopicPriorities(out, stored), nil
}
