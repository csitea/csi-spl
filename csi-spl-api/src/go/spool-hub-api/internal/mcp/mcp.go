// Package mcp is the spool's stdio MCP server (`spool mcp`, spec 002 US4). It
// exposes five canonical, kind-agnostic tools (plus spool_issue, specs/039), each a thin wrapper over the same
// internal/action verb the CLI calls, so a tool and its verb return the same
// text (contracts/mcp-tools.md). A verb's CLI failure surfaces as a tool error
// carrying the same reason and exit code (78 = verify/refuse).
//
// A SEATED server (`spool mcp --as <ID>`, Options.Seat) acts for that one agent
// only: spool_send's from and spool_recv's as default to the seat, and any
// other value is refused with exit 78 before anything is read or written. It is
// how a desk agent gets direct tool calls without a key of its own: the box
// user runs the server (one sudo at session start, never per call), the server
// holds the box key, and the agent can name no inbox but its own. A seated
// send to a human (HUM-*) with no to_box goes to box-wui, where every human
// lives.
package mcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	sdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// PutFileIn is the input of spool_put_file.
type PutFileIn struct {
	Path string `json:"path" jsonschema:"file to put into the content-addressed store"`
}

// SendIn is the input of spool_send.
type SendIn struct {
	From    string   `json:"from,omitempty" jsonschema:"sender agent id, e.g. GRK-03; a seated server defaults it to its seat and refuses any other"`
	To      string   `json:"to,omitempty" jsonschema:"recipient agent id, e.g. CLE-07; empty for a channel post"`
	TaskID  string   `json:"task_id,omitempty" jsonschema:"topic uuid; a new one is minted when empty"`
	Kind    string   `json:"kind" jsonschema:"one of task, result, note, reject"`
	Body    string   `json:"body" jsonschema:"message text"`
	FileIDs []string `json:"file_ids,omitempty" jsonschema:"file_ids from spool_put_file to attach"`
	ToBox   string   `json:"to_box,omitempty" jsonschema:"hub mode only: the recipient's box id when the agent id exists on several boxes (a seated server sends HUM-* to box-wui by default)"`
	Channel string   `json:"channel,omitempty" jsonschema:"hub mode only: post into this channel id (e.g. spool-hub-devel) as a new topic every member reads, like a human's post; leave to empty (or ALL-0) and to_box empty; refused unless the sender is a member"`
}

// RecvIn is the input of spool_recv.
type RecvIn struct {
	As  string `json:"as,omitempty" jsonschema:"receiving agent id; a seated server defaults it to its seat and refuses any other"`
	Ack bool   `json:"ack,omitempty" jsonschema:"move the returned messages to archive/"`
}

// GetFileIn is the input of spool_get_file.
type GetFileIn struct {
	FileID string `json:"file_id" jsonschema:"sha256 file_id of the blob"`
	Dest   string `json:"dest" jsonschema:"path to write the verified bytes to"`
}

// TailIn is the input of spool_tail.
type TailIn struct {
	TaskID string `json:"task_id" jsonschema:"topic uuid"`
	JSON   bool   `json:"json,omitempty" jsonschema:"emit raw v:1 NDJSON instead of human lines"`
}

// IssueIn is the input of spool_issue (specs/039 issues-v1 §6).
type IssueIn struct {
	Op    string         `json:"op" jsonschema:"one of list, get, create, update, comment, label"`
	As    string         `json:"as,omitempty" jsonschema:"the acting agent id; a seated server defaults it to its seat and refuses any other"`
	Ref   string         `json:"ref,omitempty" jsonschema:"issue key, e.g. SPL-12 (get, update, comment)"`
	Issue map[string]any `json:"issue,omitempty" jsonschema:"create/update fields: title, description (markdown), status (backlog|todo|in_progress|in_review|done|canceled), priority (0 none,1 urgent,2 high,3 medium,4 low), level (0 none,1 XS..5 XL), assignee, labels, deadline (RFC 3339), epic (the parent epic key - every issue needs one), kind (epic|issue); for label: name, color"`
	Query string         `json:"query,omitempty" jsonschema:"list filters in URL query form, e.g. status=todo,in_progress&assignee=me&epic=SPL-17&kind=issue&sort=priority"`
	Body  string         `json:"body,omitempty" jsonschema:"comment text: your progress on the issue"`
}

// Options shape a server. The zero value is the unseated server of spec 002.
type Options struct {
	// Seat is the one agent id this server acts for ("" = any, as before).
	Seat string
}

// wuiBox is the hub-held browser signer: every human (HUM-*) lives there.
const wuiBox = "box-wui"

// errNotSeat refuses a seated server's call for another agent.
var errNotSeat = errors.New("not this server's seat")

// who resolves a seated id field: empty or the seat itself -> the seat.
func (o Options) who(field, v string) (string, error) {
	if o.Seat == "" || v == o.Seat {
		return v, nil
	}
	if v == "" {
		return o.Seat, nil
	}
	return "", fmt.Errorf("spool: %s %q: this server is seated as %s and acts for no other agent: %w (exit 78)", field, v, o.Seat, errNotSeat)
}

// NewServer returns the unseated spool MCP server with its five tools registered.
func NewServer(cfg *config.Config, version string) *sdk.Server {
	return NewServerOpts(cfg, version, Options{})
}

// NewServerOpts returns the spool MCP server shaped by o.
func NewServerOpts(cfg *config.Config, version string, o Options) *sdk.Server {
	s := sdk.NewServer(&sdk.Implementation{Name: "spool", Version: version}, nil)

	sdk.AddTool(s, &sdk.Tool{
		Name:        "spool_put_file",
		Description: "Put a file into the content-addressed blob store (== spool put-file).",
	}, func(_ context.Context, _ *sdk.CallToolRequest, in PutFileIn) (*sdk.CallToolResult, action.PutResult, error) {
		out, err := action.Put(cfg, in.Path, false)
		if err != nil {
			return nil, out, toolErr(err)
		}
		return text(action.JSON(out)), out, nil
	})

	sdk.AddTool(s, &sdk.Tool{
		Name:        "spool_send",
		Description: "Send a v:1 message to another agent, on this box or (hub mode) another box; with channel, post a new topic into that channel for every member (== spool send [--channel]).",
	}, func(ctx context.Context, _ *sdk.CallToolRequest, in SendIn) (*sdk.CallToolResult, action.SendResult, error) {
		from, err := o.who("from", in.From)
		if err != nil {
			return nil, action.SendResult{}, err
		}
		if o.Seat != "" && in.ToBox == "" && in.Channel == "" && cfg.HubURL != "" && strings.HasPrefix(in.To, "HUM-") {
			in.ToBox = wuiBox
		}
		out, err := action.SendCtx(ctx, cfg, action.SendArgs{
			From: from, To: in.To, TaskID: in.TaskID, Kind: in.Kind, Body: in.Body, FileIDs: in.FileIDs,
			ToBox: in.ToBox, Channel: in.Channel,
		})
		if err != nil {
			return nil, out, toolErr(err)
		}
		return text(action.JSON(out)), out, nil
	})

	sdk.AddTool(s, &sdk.Tool{
		Name:        "spool_recv",
		Description: "Return the v:1 messages in an agent's inbox as a JSON array (== spool recv).",
	}, func(_ context.Context, _ *sdk.CallToolRequest, in RecvIn) (*sdk.CallToolResult, any, error) {
		as, err := o.who("as", in.As)
		if err != nil {
			return nil, nil, err
		}
		msgs, err := action.Recv(cfg, as, in.Ack)
		if err == nil {
			return text(action.JSON(msgs)), nil, nil
		}
		if msgs == nil {
			return nil, nil, toolErr(err)
		}
		// Like the CLI (stdout + non-zero exit): the good, possibly already acked,
		// messages are still returned alongside the error.
		res := text(action.JSON(msgs))
		res.Content = append(res.Content, &sdk.TextContent{Text: toolErr(err).Error()})
		res.IsError = true
		return res, nil, nil
	})

	sdk.AddTool(s, &sdk.Tool{
		Name:        "spool_get_file",
		Description: "Copy a blob to dest, verifying its sha256 (== spool get-file).",
	}, func(_ context.Context, _ *sdk.CallToolRequest, in GetFileIn) (*sdk.CallToolResult, action.GetResult, error) {
		out, err := action.Get(cfg, in.FileID, in.Dest, false)
		if err != nil {
			return nil, out, toolErr(err)
		}
		return text(action.JSON(out)), out, nil
	})

	sdk.AddTool(s, &sdk.Tool{
		Name:        "spool_tail",
		Description: "List a topic oldest-first: human lines, or raw v:1 NDJSON with json=true (== spool tail).",
	}, func(_ context.Context, _ *sdk.CallToolRequest, in TailIn) (*sdk.CallToolResult, any, error) {
		out, err := action.Tail(cfg, in.TaskID, in.JSON)
		if err != nil {
			return nil, nil, toolErr(err)
		}
		return text(out), nil, nil
	})

	sdk.AddTool(s, &sdk.Tool{
		Name: "spool_issue",
		Description: "Issues, the way Linear keeps them (hub mode): file concrete, specced work as an issue and post your progress on it; " +
			"talk stays in messages (== spool issue <op> --as).",
	}, func(ctx context.Context, _ *sdk.CallToolRequest, in IssueIn) (*sdk.CallToolResult, any, error) {
		as, err := o.who("as", in.As)
		if err != nil {
			return nil, nil, err
		}
		var raw json.RawMessage
		if in.Issue != nil {
			if raw, err = json.Marshal(in.Issue); err != nil {
				return nil, nil, toolErr(err)
			}
		}
		out, err := action.Issue(ctx, cfg, action.IssueArgs{Op: in.Op, As: as, Ref: in.Ref, Issue: raw, Query: in.Query, Body: in.Body})
		if err != nil {
			return nil, nil, toolErr(err)
		}
		return text(string(out)), nil, nil
	})

	return s
}

// Run serves the tools over stdin/stdout until the client disconnects or ctx
// ends. One process per agent session; stdout carries only the protocol.
func Run(ctx context.Context, cfg *config.Config, version string, o Options) error {
	return NewServerOpts(cfg, version, o).Run(ctx, &sdk.StdioTransport{})
}

func text(s string) *sdk.CallToolResult {
	return &sdk.CallToolResult{Content: []sdk.Content{&sdk.TextContent{Text: s}}}
}

// toolErr renders err as the CLI's stderr line plus the exit code it maps to.
func toolErr(err error) error {
	return fmt.Errorf("spool: %v (exit %d)", err, action.ExitCode(err))
}
