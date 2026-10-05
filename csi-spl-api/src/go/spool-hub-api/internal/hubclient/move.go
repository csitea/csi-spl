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
