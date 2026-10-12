package hubclient

import (
	"context"
	"encoding/json"

	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// TopicList lists one channel's topics for agent as (SPL t1 1457bb6f) over a
// one-shot role=cli session: query is the page's channel / limit / before in
// URL query form. It returns the page object {channel, topics, next}; a
// refusal is a *HubError.
func (c *Client) TopicList(ctx context.Context, as, query string) (json.RawMessage, error) {
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	return sess.TopicList(ctx, as, query)
}

// TopicList sends one topic_list frame on s and waits for its reply.
func (s *Session) TopicList(ctx context.Context, as, query string) (json.RawMessage, error) {
	id := uid.New()
	f, err := s.request(ctx, wire.Frame{Type: wire.TTopicList, MsgID: id, As: as, Query: query}, wire.TTopicList,
		func(f wire.Frame) bool { return f.MsgID == id || (f.Type == wire.TError && f.MsgID == "") })
	if err != nil {
		return nil, err
	}
	return f.TopicList, nil
}
