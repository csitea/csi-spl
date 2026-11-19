package store

import (
	"context"
	"errors"
	"strings"
	"time"
)

// Pause and resume the agents of a discussion (spec 179 v0.3.0, row B1,
// rdb 0297, SPL-5980). The owner (HUM-10, prd msg 8f7feda6): "Pause all
// agents on this discussion. No need to stand by".
//
//   - pause: one topic_pauses row (who, when, why); every OPEN issue the
//     discussion links goes to onhold, its status kept in
//     topic_pause_issues (spec 179 3.3.1);
//   - resume: the row goes; each held issue still onhold goes back to the
//     status it had, wip as todo (the lane that ran it was closed, spec 179
//     4.2 step 1). One moved out of onhold by hand is left as it is. The
//     guard is membership plus status, never updated_at: a comment or an
//     edit while paused does not stop the restore.
//
// Who may pause is the hub's ("Who can archive topics", spec 179 3.1, row
// B2); the issue comments and frames are the hub's too (hub/issue_follow.go
// afterIssueFollow, with the ops below).

// The ops of an IssueFollow a pause or resume made.
const (
	IssueFollowPause  = "pause"
	IssueFollowResume = "resume"
)

// TopicPauseReasonMax is rdb 0297's reason CHECK, in characters.
const TopicPauseReasonMax = 500

// TopicPauseHold are the statuses a pause puts on hold (spec 179 3.3.1).
// Done, diss, qas and onhold are left as they are.
var TopicPauseHold = []string{IssueEval, IssueTodo, IssueWIP, IssueBlocked}

// ErrBadTopicPauseBy refuses a pause or resume with no actor, or one longer
// than rdb 0297's paused_by column.
var ErrBadTopicPauseBy = errors.New("store: a topic pause needs who (1..64 characters)")

// TopicPause is one topic_pauses row. A zero PausedAt is "not paused".
type TopicPause struct {
	TenantID string
	TaskID   string
	PausedBy string
	PausedAt time.Time
	Reason   string
}

// Paused reports a stored pause.
func (p TopicPause) Paused() bool { return !p.PausedAt.IsZero() }

// TopicPauseState is what SetTopicPaused did. Pause is the row after the
// call (zero after a resume). Changed is false on a repeat: a pause of a
// paused topic (only a new non-empty reason is kept) or a resume of one
// that was not paused. Followed is what it did to the linked issues.
type TopicPauseState struct {
	Pause    TopicPause
	Changed  bool
	Followed []IssueFollow
}

// TopicPauseStore is implemented by Memory and Postgres, in the workspace's
// own scope.
type TopicPauseStore interface {
	// SetTopicPaused pauses (paused) or resumes taskID, by by at at, in one
	// transaction with its issues (spec 179 3.3.1, 4.2). reason is cut to
	// TopicPauseReasonMax and ignored on a resume. ErrBadTopicTask /
	// ErrBadTopicPauseBy before any write; ErrNotFound: no such workspace.
	SetTopicPaused(ctx context.Context, tenant, taskID, by, reason string, at time.Time, paused bool) (TopicPauseState, error)
	// AnyTopicPaused answers the first paused topic among taskIDs (the
	// topic and a DM's ref, spec 179 5.2 row 1): one primary key probe,
	// none when no id is a uuid. false: none is paused.
	AnyTopicPaused(ctx context.Context, tenant string, taskIDs ...string) (TopicPause, bool, error)
}

var (
	_ TopicPauseStore = (*Memory)(nil)
	_ TopicPauseStore = (*Postgres)(nil)
)

// checkTopicPause validates a pause or resume before any write; it answers
// the task id as rdb 0297 stores it (lower case) and the reason cut to its
// column.
func checkTopicPause(tenant, taskID, by, reason string) (string, string, error) {
	if err := checkTenant(tenant); err != nil {
		return "", "", err
	}
	if !isUUID(taskID) {
		return "", "", ErrBadTopicTask
	}
	if by == "" || len(by) > 64 {
		return "", "", ErrBadTopicPauseBy
	}
	reason = strings.TrimSpace(reason)
	if r := []rune(reason); len(r) > TopicPauseReasonMax {
		reason = string(r[:TopicPauseReasonMax])
	}
	return strings.ToLower(taskID), reason, nil
}

// topicPauseKeys are the distinct stored forms of the uuid ids, in order.
func topicPauseKeys(taskIDs []string) []string {
	seen := map[string]bool{}
	var keys []string
	for _, id := range taskIDs {
		if k := strings.ToLower(id); isUUID(id) && !seen[k] {
			seen[k] = true
			keys = append(keys, k)
		}
	}
	return keys
}

// topicPauseRestore is the status a held issue goes back to: its own, wip
// as todo (spec 179 4.2 step 1).
func topicPauseRestore(prev string) string {
	if prev == IssueWIP {
		return IssueTodo
	}
	return prev
}

// topicPauseHolds reports a status a pause puts on hold.
func topicPauseHolds(status string) bool {
	for _, s := range TopicPauseHold {
		if s == status {
			return true
		}
	}
	return false
}
