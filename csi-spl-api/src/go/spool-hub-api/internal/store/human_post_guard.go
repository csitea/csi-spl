package store

import (
	"context"
	"strings"
	"time"
)

// Human post guard (SPL-2584, owner HUM-10 t1 4b49e47d msgs 6c089b4a,
// 8b351386, 85a20ac7; rdb 0211). Two deterministic rules the hub applies to
// an agent's post to a person (internal/hub/human_post_guard.go):
//
//   - a DM to a person is a blocker, or answers a DM that person started;
//     everything else belongs in the channel topic;
//   - the same person never gets the same text twice in a day: a post whose
//     normalized body equals one an agent already sent that person in the
//     last 24 h, in a DM or a channel topic, is refused.
//
// Normalized = whitespace runs collapsed to one space, trimmed, lower-cased
// (NormalizeBody here, rdb 0211 spool_norm_body() in Postgres: the same rule).

// TopicOpener is the first message of a topic: who wrote it, to whom, and
// its kind. The zero value = the topic has no message yet.
type TopicOpener struct {
	FromID, ToID, Kind string
}

// HumanPostGuard is the store half of the guard. Optional: a store without it
// applies neither rule.
type HumanPostGuard interface {
	// TopicOpener is the earliest message of the task (received_at, then
	// msg_id), at any level.
	TopicOpener(ctx context.Context, tenant, taskID string) (TopicOpener, error)
	// HumanGotBody is the msg_id of a message an agent (a non-HUM sender)
	// sent to human since `since`, other than exceptMsgID, whose normalized
	// body equals body's; "" = none.
	HumanGotBody(ctx context.Context, tenant, human, body string, since time.Time, exceptMsgID string) (string, error)
}

// NormalizeBody is rdb 0211 spool_norm_body(): every run of ASCII whitespace
// (the Postgres regex class [[:space:]]: space, \t, \n, \v, \f, \r) becomes
// one space, the ends are trimmed, the rest lower-cased.
func NormalizeBody(body string) string {
	f := strings.FieldsFunc(body, func(r rune) bool {
		switch r {
		case ' ', '\t', '\n', '\v', '\f', '\r':
			return true
		}
		return false
	})
	return strings.ToLower(strings.Join(f, " "))
}

// TopicOpener implements HumanPostGuard over the in-memory messages.
func (s *Memory) TopicOpener(_ context.Context, tenant, taskID string) (TopicOpener, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var first *Message
	for k, m := range s.messages {
		if k[0] != tenant || m.TaskID != taskID {
			continue
		}
		if first == nil || m.ReceivedAt.Before(first.ReceivedAt) ||
			(m.ReceivedAt.Equal(first.ReceivedAt) && m.MsgID < first.MsgID) {
			first = m
		}
	}
	if first == nil {
		return TopicOpener{}, nil
	}
	return TopicOpener{FromID: first.FromID, ToID: first.ToID, Kind: first.Kind}, nil
}

// HumanGotBody implements HumanPostGuard over the in-memory messages.
func (s *Memory) HumanGotBody(_ context.Context, tenant, human, body string, since time.Time, exceptMsgID string) (string, error) {
	want := NormalizeBody(body)
	s.mu.Lock()
	defer s.mu.Unlock()
	for k, m := range s.messages {
		if k[0] != tenant || m.ToID != human || m.MsgID == exceptMsgID || strings.HasPrefix(m.FromID, "HUM-") ||
			m.ReceivedAt.Before(since) {
			continue
		}
		if NormalizeBody(m.Body) == want {
			return m.MsgID, nil
		}
	}
	return "", nil
}
