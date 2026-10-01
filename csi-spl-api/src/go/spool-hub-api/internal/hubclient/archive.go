package hubclient

import (
	"context"
	"encoding/json"

	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// ArchiveTopic archives (archive=true) or unarchives a topic by its task id,
// acting as agent as (one this box announced), over a one-shot role=cli
// session (CLE-77869). It returns the hub's answer object {msg_id, task_id,
// archived, archived_at, archived_by}. A refusal is a *HubError.
func (c *Client) ArchiveTopic(ctx context.Context, taskID, as string, archive bool) (json.RawMessage, error) {
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	op := "unarchive"
	if archive {
		op = "archive"
	}
	id := uid.New()
	f, err := sess.request(ctx, wire.Frame{Type: wire.TArchive, MsgID: id, TaskID: taskID, ArchiveOp: op, As: as}, wire.TArchive,
		func(f wire.Frame) bool { return f.MsgID == id || (f.Type == wire.TError && f.MsgID == "") })
	if err != nil {
		return nil, err
	}
	return f.Archive, nil
}
