package action

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
)

// NoteItemArg is one checklist line of a note an agent adds.
type NoteItemArg struct {
	Text string `json:"text"`
	Done bool   `json:"done,omitempty"`
}

// NoteLinkArg is one link of a note an agent adds (spec 155 2.3): kind msg |
// topic | issue | event | doc | channel | url. A workspace kind with no
// workspace_id takes the ask's workspace; url takes none.
type NoteLinkArg struct {
	Kind        string `json:"kind"`
	WorkspaceID string `json:"workspace_id,omitempty"`
	Ref         string `json:"ref"`
	Day         string `json:"day,omitempty"`
	Label       string `json:"label,omitempty"`
}

// NoteAddArgs is one note an agent adds to the Notes of the person who asked
// for it (spec 155 2.11): the verb `spool note add` and the MCP tool
// spool_note_add share it. The note goes to the author of AskMsgID, never to
// a person the agent names.
type NoteAddArgs struct {
	As       string            `json:"as"`
	AskMsgID string            `json:"ask_msg_id"`
	Title    string            `json:"title,omitempty"`
	Body     string            `json:"body,omitempty"`
	Pinned   bool              `json:"pinned,omitempty"`
	Priority int               `json:"priority,omitempty"` // 1 (highest) .. 5; 0 = the hub's 5
	Archived bool              `json:"archived,omitempty"`
	Items    []NoteItemArg     `json:"items,omitempty"`
	Links    []NoteLinkArg     `json:"links,omitempty"`
	Hub      *hubclient.Client `json:"-"` // nil = hubclient.New(cfg)
}

// noteAddReq is the note_add frame's note object.
type noteAddReq struct {
	AskMsgID string        `json:"ask_msg_id"`
	Title    string        `json:"title,omitempty"`
	Body     string        `json:"body,omitempty"`
	Pinned   bool          `json:"pinned,omitempty"`
	Priority *int          `json:"priority,omitempty"`
	Archived bool          `json:"archived,omitempty"`
	Items    []NoteItemArg `json:"items,omitempty"`
	Links    []NoteLinkArg `json:"links,omitempty"`
}

// NoteAdd adds the note and returns the hub's {msg_id, id, created_at}. The
// limits (spec 155 2.4) are the hub's: a refusal is a *hubclient.HubError
// (bad_note, notes_full, not_found, ask_not_person, notes_off). Hub mode only.
func NoteAdd(ctx context.Context, cfg *config.Config, in NoteAddArgs) (json.RawMessage, error) {
	if cfg.HubURL == "" {
		return nil, fmt.Errorf("a note needs hub mode ($SPOOL_HUB_URL is not set)")
	}
	if in.As == "" {
		return nil, fmt.Errorf("--as (the acting agent id) is required")
	}
	raw, err := noteAddRequest(in)
	if err != nil {
		return nil, err
	}
	hc := in.Hub
	if hc == nil {
		hc = hubclient.New(cfg)
	}
	return hc.NoteAdd(ctx, in.As, raw)
}

// noteAddRequest is the frame's note object: the ask lower-cased and
// trimmed, priority only when set, empty fields left out.
func noteAddRequest(in NoteAddArgs) (json.RawMessage, error) {
	req := noteAddReq{AskMsgID: strings.ToLower(strings.TrimSpace(in.AskMsgID)), Title: in.Title, Body: in.Body,
		Pinned: in.Pinned, Archived: in.Archived, Items: in.Items, Links: in.Links}
	if req.AskMsgID == "" {
		return nil, fmt.Errorf("--ask-msg (the msg_id of the person's message that asked for the note) is required")
	}
	if in.Priority != 0 {
		p := in.Priority
		req.Priority = &p
	}
	return json.Marshal(req)
}
