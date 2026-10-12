package hub

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"slices"
	"strconv"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// An agent lists the topics of one channel over its own box socket (SPL t1
// 1457bb6f): a topic_list frame, the box twin of GET /v1/view/topics, which
// takes a member session only. The acting agent must be one this box
// announced, as for a send, an issue or a flow read, and it reads only a
// channel it is seated in ON THIS BOX (channel_subscriptions: invited, not
// removed, channel not archived). Any other channel - private, unknown or
// archived - reads 0 topics, never an error that would tell it exists. The
// page is slim: task id, subject and last activity, no bodies. Two round
// trips per page whatever its size: the seat, then the topic walk.

// Topic-list page bounds: one socket frame carries the whole page, so it
// stays far below maxFrameBytes (a subject is at most a line).
const (
	agentTopicLimitDefault = 50
	agentTopicLimitMax     = 100
)

// agentTopic is one row of a topic_list page.
type agentTopic struct {
	TaskID  string `json:"task_id"`
	Subject string `json:"subject"`
	LastTS  string `json:"last_ts"`
}

// agentTopicPage is the topic_list reply body.
type agentTopicPage struct {
	Channel string       `json:"channel"`
	Topics  []agentTopic `json:"topics"`
	Next    *string      `json:"next"`
}

func (s *Server) onTopicList(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a topic_list frame needs msg_id (a UUID) to pair the reply")
		return
	}
	if detail := senderRefusal(x, f.As); detail != "" {
		x.fail(ctx, id, TokenFromNotAnnounced, http.StatusForbidden, detail)
		return
	}
	sq, ok := agentTopicQuery(f.Query)
	if !ok {
		x.fail(ctx, id, "bad_query", http.StatusBadRequest, "query: channel required; limit 1.."+strconv.Itoa(agentTopicLimitMax)+"; before a cursor")
		return
	}
	page, err := s.agentTopicPage(ctx, x.tenant, x.box, f.As, sq)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("channel", sq.Channel).Msg("agent topic list")
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "topics unavailable")
		return
	}
	raw, err := json.Marshal(page)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TTopicList, MsgID: id, TopicList: raw}) //nolint:errcheck
}

// agentTopicQuery parses the frame's URL-form query into a topic walk of one
// channel's root topics, issue talk left out (as the WUI list does). The
// limit is one past the page, as topicsPage expects. ok false = refused.
func agentTopicQuery(query string) (store.TopicQuery, bool) {
	v, err := url.ParseQuery(query)
	if err != nil {
		return store.TopicQuery{}, false
	}
	sq := store.TopicQuery{Channel: store.NormalizeChannel(v.Get("channel")), Roots: true, NoIssues: true}
	if sq.Channel == "" {
		return sq, false
	}
	n := agentTopicLimitDefault
	if l := v.Get("limit"); l != "" {
		if n, err = strconv.Atoi(l); err != nil || n < 1 || n > agentTopicLimitMax {
			return sq, false
		}
	}
	sq.Limit = n + 1
	if c := v.Get("before"); c != "" {
		if sq.BeforeAt, sq.BeforeTask, err = decCursor(c); err != nil {
			return sq, false
		}
	}
	return sq, true
}

// agentTopicPage reads one page for agent as on box: an empty page unless
// the agent is seated in the channel on that box.
func (s *Server) agentTopicPage(ctx context.Context, tenant, box, as string, sq store.TopicQuery) (agentTopicPage, error) {
	page := agentTopicPage{Channel: sq.Channel, Topics: []agentTopic{}}
	seats, err := s.o.Store.ChannelMembers(ctx, tenant, sq.Channel)
	if err != nil || !slices.Contains(seats[box], as) {
		return page, err
	}
	sq.Now, sq.Lobby = s.o.Now(), s.o.LobbyTaskID
	rows, err := s.o.Store.ViewTopics(ctx, tenant, sq)
	if err != nil {
		return page, err
	}
	out, next := topicsPage(rows, sq.Limit)
	mod, err := s.moderation(ctx, tenant, "")
	if err != nil {
		return page, err
	}
	for _, t := range mod.keepTopics(out) {
		page.Topics = append(page.Topics, agentTopic{TaskID: t.TaskID, Subject: t.Subject, LastTS: t.LastTS})
	}
	page.Next = next
	return page, nil
}
