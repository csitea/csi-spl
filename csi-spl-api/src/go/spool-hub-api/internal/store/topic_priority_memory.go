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

// InheritTopicPriority implements TopicPriorityStore.
func (s *Memory) InheritTopicPriority(_ context.Context, tenant, source, target, by string, at time.Time) (TopicPriority, bool, error) {
	from, err := checkTopicPriority(tenant, source, TopicPriorityMin)
	if err != nil {
		return TopicPriority{}, false, err
	}
	to, err := checkTopicPriority(tenant, target, TopicPriorityMin)
	if err != nil {
		return TopicPriority{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	src, ok := s.topicPrio[[2]string{tenant, from}]
	if _, set := s.topicPrio[[2]string{tenant, to}]; !ok || set {
		return TopicPriority{}, false, nil
	}
	p := TopicPriority{TenantID: tenant, TaskID: to, Priority: src.Priority, SetBy: by, SetAt: at.UTC()}
	s.topicPrio[[2]string{tenant, to}] = p
	return p, true, nil
}

// TopicPriorities implements TopicPriorityStore.
func (s *Memory) TopicPriorities(_ context.Context, tenant string, taskIDs []string) (map[string]int, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	out, keys := defaultTopicPriorities(taskIDs)
	return foldTopicPriorities(out, s.storedTopicPriorities(tenant, keys)), nil
}

// SetTopicPriorities implements TopicPriorityStore.
func (s *Memory) SetTopicPriorities(_ context.Context, tenant string, taskIDs []string) (map[string]int, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	_, keys := defaultTopicPriorities(taskIDs)
	return setOnly(taskIDs, s.storedTopicPriorities(tenant, keys)), nil
}

// storedTopicPriorities is key -> priority for the keys with a row.
func (s *Memory) storedTopicPriorities(tenant string, keys []string) map[string]int {
	s.mu.Lock()
	defer s.mu.Unlock()
	stored := map[string]int{}
	for _, k := range keys {
		if p, ok := s.topicPrio[[2]string{tenant, k}]; ok {
			stored[k] = p.Priority
		}
	}
	return stored
}

// SetTopicPriorityRows implements TopicPriorityStore.
func (s *Memory) SetTopicPriorityRows(_ context.Context, tenant string, taskIDs []string) (map[string]TopicPriority, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	_, keys := defaultTopicPriorities(taskIDs)
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]TopicPriority{}
	for _, k := range keys {
		if p, ok := s.topicPrio[[2]string{tenant, k}]; ok {
			out[k] = p
		}
	}
	return out, nil
}
