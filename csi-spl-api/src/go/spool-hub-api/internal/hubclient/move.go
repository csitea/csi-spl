package hubclient

import (
	"context"
	"encoding/json"

	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// MoveTopic moves a topic by its task id to channel toChannel, acting as
// agent as (one this box announced) and, when actingFor is a HUM-* id, for
// that human (a box operator the hub checks is a workspace owner or admin),
// over a one-shot role=cli session. It returns the hub's answer object
// {kind, msg_id, task_id, channel, from_channel, moved, moved_by, moved_at,
// msg_ids, undo}. A refusal is a *HubError.
func (c *Client) MoveTopic(ctx context.Context, taskID, toChannel, as, actingFor string) (json.RawMessage, error) {
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	id := uid.New()
	f, err := sess.request(ctx, wire.Frame{Type: wire.TMove, MsgID: id, TaskID: taskID, MoveTo: toChannel, As: as, TypedBy: actingFor},
		wire.TMove, func(f wire.Frame) bool { return f.MsgID == id || (f.Type == wire.TError && f.MsgID == "") })
	if err != nil {
		return nil, err
	}
	return f.Move, nil
}

// MoveMessage moves one message by its msg id (and its thread) into the
// topic toTask, acting as agent as and, when actingFor is a HUM-* id, for
// that human, over a one-shot role=cli session (SPL-1988). It returns the
// hub's answer object {kind: message, msg_id, task_id, from_task, channel,
// from_channel, moved, moved_by, moved_at, received_at, msg_ids, undo}. A
// refusal is a *HubError.
func (c *Client) MoveMessage(ctx context.Context, msgID, toTask, as, actingFor string) (json.RawMessage, error) {
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	id := uid.New()
	f, err := sess.request(ctx, wire.Frame{Type: wire.TMove, MsgID: id, MoveMsg: msgID, MoveToTask: toTask, As: as, TypedBy: actingFor},
		wire.TMove, func(f wire.Frame) bool { return f.MsgID == id || (f.Type == wire.TError && f.MsgID == "") })
	if err != nil {
		return nil, err
	}
	return f.Move, nil
}
