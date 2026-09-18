// Package mcp is the spool's stdio MCP server (`spool mcp`, spec 002 US4). It
// exposes five canonical, kind-agnostic tools, each a thin wrapper over the same
// internal/action verb the CLI calls, so a tool and its verb return the same
// text (contracts/mcp-tools.md). A verb's CLI failure surfaces as a tool error
// carrying the same reason and exit code (78 = verify/refuse).
package mcp

import (
	"context"
	"fmt"

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
	From    string   `json:"from" jsonschema:"sender agent id, e.g. GRK-03"`
	To      string   `json:"to" jsonschema:"recipient agent id, e.g. CLE-07"`
	TaskID  string   `json:"task_id,omitempty" jsonschema:"thread uuid; a new one is minted when empty"`
	Kind    string   `json:"kind" jsonschema:"one of task, result, note, reject"`
	Body    string   `json:"body" jsonschema:"message text"`
	FileIDs []string `json:"file_ids,omitempty" jsonschema:"file_ids from spool_put_file to attach"`
	ToBox   string   `json:"to_box,omitempty" jsonschema:"hub mode only: the recipient's box id when the agent id exists on several boxes"`
}

// RecvIn is the input of spool_recv.
type RecvIn struct {
	As  string `json:"as" jsonschema:"receiving agent id"`
	Ack bool   `json:"ack,omitempty" jsonschema:"move the returned messages to archive/"`
}

// GetFileIn is the input of spool_get_file.
type GetFileIn struct {
	FileID string `json:"file_id" jsonschema:"sha256 file_id of the blob"`
	Dest   string `json:"dest" jsonschema:"path to write the verified bytes to"`
}

// TailIn is the input of spool_tail.
type TailIn struct {
	TaskID string `json:"task_id" jsonschema:"thread uuid"`
	JSON   bool   `json:"json,omitempty" jsonschema:"emit raw v:1 NDJSON instead of human lines"`
}

// NewServer returns the spool MCP server with its five tools registered.
func NewServer(cfg *config.Config, version string) *sdk.Server {
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
		Description: "Send a v:1 message to another agent, on this box or (hub mode) another box (== spool send).",
	}, func(ctx context.Context, _ *sdk.CallToolRequest, in SendIn) (*sdk.CallToolResult, action.SendResult, error) {
		out, err := action.SendCtx(ctx, cfg, action.SendArgs{
			From: in.From, To: in.To, TaskID: in.TaskID, Kind: in.Kind, Body: in.Body, FileIDs: in.FileIDs,
			ToBox: in.ToBox,
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
		msgs, err := action.Recv(cfg, in.As, in.Ack)
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
		Description: "List a thread oldest-first: human lines, or raw v:1 NDJSON with json=true (== spool tail).",
	}, func(_ context.Context, _ *sdk.CallToolRequest, in TailIn) (*sdk.CallToolResult, any, error) {
		out, err := action.Tail(cfg, in.TaskID, in.JSON)
		if err != nil {
			return nil, nil, toolErr(err)
		}
		return text(out), nil, nil
	})

	return s
}

// Run serves the tools over stdin/stdout until the client disconnects or ctx
// ends. One process per agent session; stdout carries only the protocol.
func Run(ctx context.Context, cfg *config.Config, version string) error {
	return NewServer(cfg, version).Run(ctx, &sdk.StdioTransport{})
}

func text(s string) *sdk.CallToolResult {
	return &sdk.CallToolResult{Content: []sdk.Content{&sdk.TextContent{Text: s}}}
}

// toolErr renders err as the CLI's stderr line plus the exit code it maps to.
func toolErr(err error) error {
	return fmt.Errorf("spool: %v (exit %d)", err, action.ExitCode(err))
}
