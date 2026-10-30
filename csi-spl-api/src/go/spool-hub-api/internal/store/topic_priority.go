package store

import (
	"context"
	"errors"
	"strings"
	"time"
)

// A priority 1..5 per discussion (spec 150 v1.0 section 3.3, row B1, rdb
// 0214, SPL-3052). 1 is the most urgent; the orchestrator serves 1 first
// (section 3.4). A topic nobody set reads TopicPriorityDefault, 3: the
// owner's "radio buttons whith default 3" (prd t1 0344254d, msg f5ed1396,
// spec 150 v1.1 D7, SPL-4367; issues keep their 5). There is no clear,
// setting 3 is the default. It is not stored: no row means the default.

// Topic priority bounds (rdb 0214's CHECK).
const (
	TopicPriorityMin     = 1
	TopicPriorityMax     = 5
	TopicPriorityDefault = 3
)

// ErrBadTopicPriority refuses a priority outside 1..5 before any write (the
// hub answers 400, spec 150 3.3 API).
var ErrBadTopicPriority = errors.New("store: priority must be 1..5")

// ErrBadTopicTask refuses a task id that is not a uuid (rdb 0214's column).
var ErrBadTopicTask = errors.New("store: topic task id must be a uuid")

// TopicPriority is one topic_priorities row.
type TopicPriority struct {
	TenantID string
	TaskID   string
	Priority int
	SetBy    string
	SetAt    time.Time
}

// TopicPriorityStore is implemented by Memory and Postgres. Both run in the
// workspace's own scope; who may set a priority is the hub's (the read door,
// then "Who can archive topics", spec 150 D8).
type TopicPriorityStore interface {
	// SetTopicPriority upserts the topic's priority, set by by at at, and
	// answers the row. ErrBadTopicPriority / ErrBadTopicTask before any
	// write; ErrNotFound: no such workspace.
	SetTopicPriority(ctx context.Context, tenant, taskID string, prio int, by string, at time.Time) (TopicPriority, error)
	// TopicPriorities answers every asked task id with its priority,
	// TopicPriorityDefault when nobody set it (or the id is no uuid). It
	// reads the asked ids only, on the primary key.
	TopicPriorities(ctx context.Context, tenant string, taskIDs []string) (map[string]int, error)
}

var (
	_ TopicPriorityStore = (*Memory)(nil)
	_ TopicPriorityStore = (*Postgres)(nil)
)

// checkTopicPriority validates a set before any write; it answers the task
// id in the form rdb 0214 stores it (lower case).
func checkTopicPriority(tenant, taskID string, prio int) (string, error) {
	if err := checkTenant(tenant); err != nil {
		return "", err
	}
	if prio < TopicPriorityMin || prio > TopicPriorityMax {
		return "", ErrBadTopicPriority
	}
	if !isUUID(taskID) {
		return "", ErrBadTopicTask
	}
	return strings.ToLower(taskID), nil
}

// defaultTopicPriorities is every asked id at the default, and the distinct
// stored forms of the uuid ones, the keys a read looks up.
func defaultTopicPriorities(taskIDs []string) (map[string]int, []string) {
	out := make(map[string]int, len(taskIDs))
	seen := map[string]bool{}
	var keys []string
	for _, id := range taskIDs {
		out[id] = TopicPriorityDefault
		if k := strings.ToLower(id); isUUID(id) && !seen[k] {
			seen[k] = true
			keys = append(keys, k)
		}
	}
	return out, keys
}

// foldTopicPriorities writes the stored rows (key -> priority) into out under
// every asked id of that key.
func foldTopicPriorities(out, stored map[string]int) map[string]int {
	for id := range out {
		if p, ok := stored[strings.ToLower(id)]; ok {
			out[id] = p
		}
	}
	return out
}
