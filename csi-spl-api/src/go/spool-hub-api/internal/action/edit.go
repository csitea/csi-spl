package action

import (
	"context"
	"fmt"
	"os"
	"regexp"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// EditArgs is one box edit or delete of a message this box sent (specs/032
// message-edit-v1 §10): the verb behind `spool edit` and `spool delete`.
type EditArgs struct {
	MsgID    string            `json:"msg_id"`
	As       string            `json:"as,omitempty"` // "" = any agent of this box
	Body     string            `json:"body,omitempty"`
	BodyFile string            `json:"body_file,omitempty"`
	Hub      *hubclient.Client `json:"-"` // nil = hubclient.New(cfg)
}

var editMsgIDRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func (in EditArgs) check(cfg *config.Config) (*hubclient.Client, error) {
	if cfg.HubURL == "" {
		return nil, fmt.Errorf("editing a sent message needs hub mode ($SPOOL_HUB_URL is not set)")
	}
	if !editMsgIDRe.MatchString(strings.ToLower(in.MsgID)) {
		return nil, fmt.Errorf("--msg-id must be the message's UUID")
	}
	if in.As != "" && !msg.ValidID(in.As) {
		return nil, fmt.Errorf("--as must be an agent id")
	}
	if in.Hub != nil {
		return in.Hub, nil
	}
	return hubclient.New(cfg), nil
}

// Edit replaces the body of a message this box sent. Hub mode only.
func Edit(ctx context.Context, cfg *config.Config, in EditArgs) (hubclient.EditResult, error) {
	hc, err := in.check(cfg)
	if err != nil {
		return hubclient.EditResult{}, err
	}
	body := in.Body
	if in.BodyFile != "" {
		if body != "" {
			return hubclient.EditResult{}, fmt.Errorf("--body and --body-file are exclusive")
		}
		b, err := os.ReadFile(in.BodyFile)
		if err != nil {
			return hubclient.EditResult{}, err
		}
		body = string(b)
	}
	if strings.TrimSpace(body) == "" {
		return hubclient.EditResult{}, fmt.Errorf("--body or --body-file must carry the new text")
	}
	return hc.EditMessage(ctx, in.MsgID, body, in.As)
}

// Delete removes a message this box sent and returns its task id.
func Delete(ctx context.Context, cfg *config.Config, in EditArgs) (string, error) {
	hc, err := in.check(cfg)
	if err != nil {
		return "", err
	}
	return hc.DeleteMessage(ctx, in.MsgID, in.As)
}
