package hubclient

import (
	"context"
	"encoding/json"

	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// React adds (add=true) or removes an emoji reaction on msgID of a topic -
// or, msgID "", on the topic's opening card - acting as agent as (one this
// box announced), over a one-shot role=cli session (CLE-77895). It returns
// the hub's answer object {msg_id, task_id, reactions}. A refusal is a
// *HubError.
func (c *Client) React(ctx context.Context, taskID, msgID, emoji, as string, add bool) (json.RawMessage, error) {
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	op := "remove"
	if add {
		op = "add"
	}
	id := uid.New()
	f, err := sess.request(ctx, wire.Frame{Type: wire.TReact, MsgID: id, TaskID: taskID, ReactMsg: msgID, ReactOp: op, Emoji: emoji, As: as}, wire.TReact,
		func(f wire.Frame) bool { return f.MsgID == id || (f.Type == wire.TError && f.MsgID == "") })
	if err != nil {
		return nil, err
	}
	return f.Reaction, nil
}
