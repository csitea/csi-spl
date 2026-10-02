package store

import (
	"context"
	"strings"
	"time"
)

// TopicMsgMeta is the slice of one message the DM counts read (cut 1 of the
// DB payload audit 2026-10-02): who and when, never the envelope.
type TopicMsgMeta struct {
	MsgID      string
	ReceivedAt time.Time
	FromID     string
	FromBox    string
	ToID       string
	ToBox      string
	TypedBy    string
	Channel    string // messages.channel, where the row is now ("" = a DM)
}

// DMRead is the reader's read cursor for one DM peer: utils/read-cursor.mjs
// { ts, id }, the ts as the WUI holds it (a string).
type DMRead struct{ TS, MsgID string }

// TopicDMCounts is one topic's DM counts over its newest page of lines.
type TopicDMCounts struct {
	Page   int            // lines on the page, channel rows included
	Unread map[string]int // per peer "<id>@<box>", only > 0
	Total  map[string]int // DM lines per peer on the page, only > 0
}

// DMPageCounts counts one topic's page (newest first). The rules are the
// WUI's (utils/channel-feed.mjs unreadFromDms / dmTotalsFromDms,
// utils/read-cursor.mjs isUnread, utils/typed-by.mjs isViewersOwn), and
// ViewTopicsDMCounts is the same rules in SQL:
//
//   - unread: an incoming DM line newer than the reader's cursor for that
//     peer. Our own lines - and one we typed at the agent's terminal
//     (typed_by, CLE-77889) - are never new; a channel row is not a DM. The
//     times compare as strings, as the WUI's did (CLE-77873).
//   - total (CLE-77845): every DM line under its peer.
func DMPageCounts(msgs []TopicMsgMeta, self string, reads map[string]DMRead) TopicDMCounts {
	out := TopicDMCounts{Page: len(msgs), Unread: map[string]int{}, Total: map[string]int{}}
	for _, m := range msgs {
		peer := dmPeerOf(m, self)
		if m.Channel != "" || peer == "" {
			continue
		}
		out.Total[peer]++
		if m.FromID == "" || isViewersOwn(m, self) {
			continue
		}
		c, ok := reads[peer]
		if dmUnread(m, c, ok) {
			out.Unread[peer]++
		}
	}
	return out
}

// bareID is the id part of "<id>@<box>".
func bareID(s string) string {
	id, _, _ := strings.Cut(s, "@")
	return id
}

// isViewersOwn is utils/typed-by.mjs isViewersOwn.
func isViewersOwn(m TopicMsgMeta, self string) bool {
	me := bareID(self)
	if me == "" {
		return false
	}
	if bareID(m.FromID) == me {
		return true
	}
	typed := bareID(m.TypedBy)
	return humanIDRe.MatchString(typed) && typed == me
}

// dmPeerOf is utils/channel-feed.mjs dmPeerOf: the end that is not us.
func dmPeerOf(m TopicMsgMeta, self string) string {
	for _, e := range [2][2]string{{m.FromID, m.FromBox}, {m.ToID, m.ToBox}} {
		if e[0] == "" || e[0] == self || e[0] == "ALL-0" {
			continue
		}
		if e[1] != "" {
			return e[0] + "@" + e[1]
		}
		return e[0]
	}
	return ""
}

// dmUnread is utils/read-cursor.mjs isUnread over the view's received_at.
func dmUnread(m TopicMsgMeta, c DMRead, ok bool) bool {
	if !ok || c.TS == "" {
		return true
	}
	ts := m.ReceivedAt.UTC().Format(time.RFC3339Nano)
	if ts != c.TS {
		return ts > c.TS
	}
	return m.MsgID != c.MsgID
}

var _ TopicsDMCounter = (*Memory)(nil)

// ViewTopicsDMCounts is ViewTopic's page per topic (the same door) counted
// by DMPageCounts.
func (s *Memory) ViewTopicsDMCounts(ctx context.Context, tenant string, q TopicsMsgQuery, reads map[string]DMRead) (map[string]TopicDMCounts, error) {
	out := map[string]TopicDMCounts{}
	if q.PerTopic <= 0 {
		return out, nil
	}
	for _, id := range q.TaskIDs {
		rows, err := s.ViewTopic(ctx, tenant, TopicMsgQuery{TaskID: id, Desc: true, Limit: q.PerTopic,
			Reader: q.Reader, ReaderChannels: q.ReaderChannels, HideArchived: id == q.HideArchivedIn && id != "", Now: q.Now})
		if err != nil {
			return nil, err
		}
		if len(rows) == 0 {
			continue
		}
		s.mu.Lock()
		msgs := make([]TopicMsgMeta, 0, len(rows))
		for _, v := range rows {
			if m := s.messages[[2]string{tenant, v.MsgID}]; m != nil {
				msgs = append(msgs, TopicMsgMeta{MsgID: m.MsgID, ReceivedAt: m.ReceivedAt, FromID: m.FromID, FromBox: m.FromBox,
					ToID: m.ToID, ToBox: m.ToBox, TypedBy: m.TypedBy, Channel: m.Channel})
			}
		}
		s.mu.Unlock()
		out[id] = DMPageCounts(msgs, q.Reader, reads)
	}
	return out, nil
}
