// Package mcp is the spool's stdio MCP server (`spool mcp`, spec 002 US4). It
// exposes five canonical, kind-agnostic tools (plus spool_issue, specs/039,
// spool_flow, spec 130, and spool_read_link / spool_reply, SPL-2112), each a thin wrapper over the same
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
	"os/exec"
	"strings"
	"time"

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
	From      string   `json:"from,omitempty" jsonschema:"sender agent id, e.g. GRK-03; a seated server defaults it to its seat and refuses any other"`
	To        string   `json:"to,omitempty" jsonschema:"recipient agent id, e.g. CLE-07; empty for a channel post"`
	TaskID    string   `json:"task_id,omitempty" jsonschema:"topic uuid; a new one is minted when empty"`
	Kind      string   `json:"kind" jsonschema:"one of task, result, note, reject, blocker (cannot proceed without input), msg (a plain message)"`
	Body      string   `json:"body" jsonschema:"message text; a longer post uses markdown (headers, bold, lists, GFM pipe tables), no fence needed: csi-spl-doc/doc/help/how-to-post.md"`
	FileIDs   []string `json:"file_ids,omitempty" jsonschema:"file_ids from spool_put_file to attach"`
	ToBox     string   `json:"to_box,omitempty" jsonschema:"hub mode only: the recipient's box id when the agent id exists on several boxes (a seated server sends HUM-* to box-wui by default)"`
	Channel   string   `json:"channel,omitempty" jsonschema:"hub mode only: post into this channel id (e.g. spool-hub-devel) as a new topic every member reads, like a human's post; leave to empty (or ALL-0) and to_box empty; refused unless the sender is a member"`
	RefTaskID string   `json:"ref_task_id,omitempty" jsonschema:"hub mode only: the channel topic (task_id uuid) this DM is about (== spool send --ref); kept only when the sender may read that topic"`
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
	Op    string         `json:"op" jsonschema:"one of list, get, create, update, comment, label, delete (only the issue's creator), link, unlink (one discussion, in body)"`
	As    string         `json:"as,omitempty" jsonschema:"the acting agent id; a seated server defaults it to its seat and refuses any other"`
	Ref   string         `json:"ref,omitempty" jsonschema:"issue key, e.g. SPL-12 (get, update, comment, delete)"`
	Issue map[string]any `json:"issue,omitempty" jsonschema:"create/update fields: title, description (markdown), status (eval|todo|wip|diss|blocked|onhold|qas|done = 01-eval, 02-todo, 03-wip, 03-diss, 05-blocked, 06-onhold, 07-qas, 09-done), priority (prio 1 highest .. 5 lowest), level (derived from the tree, read-only: 1 epic or feature, 2 issue, 3 subtask), assignee, labels, deadline (RFC 3339), epic (the epic / feature above it), parent (a level-2 issue: makes a subtask), kind (epic|feature|issue), discussions (create: the topic ids or /t/<id> links it links, at least one); for label: name, color"`
	Query string         `json:"query,omitempty" jsonschema:"list filters in URL query form, e.g. status=todo,wip&assignee=me&epic=SPL-17&kind=issue&sort=priority"`
	Body  string         `json:"body,omitempty" jsonschema:"comment text: your progress on the issue; markdown renders, no fence needed: csi-spl-doc/doc/help/how-to-post.md; link/unlink: the topic id or /t/<id> link"`
}

// FlowIn is the input of spool_flow (spec 130 section 5).
type FlowIn struct {
	As     string `json:"as,omitempty" jsonschema:"the acting agent id; a seated server defaults it to its seat and refuses any other"`
	Kind   string `json:"kind,omitempty" jsonschema:"mention (takes blocked and ready too), blocked, ready or release; empty = all"`
	Limit  int    `json:"limit,omitempty" jsonschema:"topic lines per page, 1..50 (default 30)"`
	Before string `json:"before,omitempty" jsonschema:"the next cursor the previous page ended with"`
}

// ReadLinkIn is the input of spool_read_link (SPL-2112).
type ReadLinkIn struct {
	URL  string `json:"url" jsonschema:"a WUI discussion link as the browser shows it: https://<workspace host>/t/<topic uuid>, /m/<id>, or a page with ?topic=<topic uuid>"`
	JSON bool   `json:"json,omitempty" jsonschema:"emit raw v:1 NDJSON instead of human lines"`
}

// ReplyIn is the input of spool_reply (SPL-2112).
type ReplyIn struct {
	URL  string `json:"url" jsonschema:"the WUI discussion link to reply in (the same forms as spool_read_link)"`
	Body string `json:"body" jsonschema:"the reply; markdown renders, no fence needed: csi-spl-doc/doc/help/how-to-post.md"`
	Kind string `json:"kind,omitempty" jsonschema:"one of task, result, note, reject, blocker, msg (default msg)"`
}

// Options shape a server. The zero value is the unseated server of spec 002.
type Options struct {
	// Seat is the one agent id this server acts for ("" = any, as before).
	Seat string
	// Desks is this box's hub desk dir (<state>/<env>/desk), DeskBox its desk
	// box: spool_read_link / spool_reply read a link through the desk of the
	// link's workspace. "" = the server's own config is the one desk.
	Desks   string
	DeskBox string
	// SeatCmd seats an agent on a workspace's desk: it runs with the tenant
	// and the agent id appended (spool-mcp.sh --seat). Empty = seats nobody.
	SeatCmd []string
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
	t := tools{cfg: cfg, o: o}
	sdk.AddTool(s, &sdk.Tool{
		Name:        "spool_put_file",
		Description: "Put a file into the content-addressed blob store (== spool put-file).",
	}, t.putFile)
	sdk.AddTool(s, &sdk.Tool{
		Name:        "spool_send",
		Description: "Send a v:1 message to another agent, on this box or (hub mode) another box; with channel, post a new topic into that channel for every member (== spool send [--channel]).",
	}, t.send)
	sdk.AddTool(s, &sdk.Tool{
		Name:        "spool_recv",
		Description: "Return the v:1 messages in an agent's inbox as a JSON array (== spool recv).",
	}, t.recv)
	sdk.AddTool(s, &sdk.Tool{
		Name:        "spool_get_file",
		Description: "Copy a blob to dest, verifying its sha256 (== spool get-file).",
	}, t.getFile)
	sdk.AddTool(s, &sdk.Tool{
		Name:        "spool_tail",
		Description: "List a topic oldest-first: human lines, or raw v:1 NDJSON with json=true (== spool tail).",
	}, t.tail)
	sdk.AddTool(s, &sdk.Tool{
		Name: "spool_issue",
		Description: "Issues, the way Linear keeps them (hub mode): file concrete, specced work as an issue and post your progress on it; " +
			"talk stays in messages (== spool issue <op> --as).",
	}, t.issue)
	sdk.AddTool(s, &sdk.Tool{
		Name: "spool_flow",
		Description: "What is happening for you (hub mode): one line per topic per UTC day of the lines that name you as <id>@<box>, " +
			"blocked and ready included, and one line per UTC day of releases; JSON with a next cursor (== spool flow --as --json).",
	}, t.flow)
	sdk.AddTool(s, &sdk.Tool{
		Name: "spool_read_link",
		Description: "Read the discussion a WUI link names (paste the browser's link): the workspace comes from the link, " +
			"read through this box's desk there; refuses with the reason when no desk on this box can see it (== spool tail --url).",
	}, t.readLink)
	sdk.AddTool(s, &sdk.Tool{
		Name: "spool_reply",
		Description: "Reply in the discussion a WUI link names, as this server's seat (never as a person): " +
			"seats it on the desk of the link's workspace first when it has no seat there, then posts into the topic.",
	}, t.reply)
	return s
}

// tools are the handlers of the tools, over one config and seat.
type tools struct {
	cfg *config.Config
	o   Options
}

func (t tools) putFile(_ context.Context, _ *sdk.CallToolRequest, in PutFileIn) (*sdk.CallToolResult, action.PutResult, error) {
	out, err := action.Put(t.cfg, in.Path, false)
	if err != nil {
		return nil, out, toolErr(err)
	}
	return text(action.JSON(out)), out, nil
}

func (t tools) send(ctx context.Context, _ *sdk.CallToolRequest, in SendIn) (*sdk.CallToolResult, action.SendResult, error) {
	from, err := t.o.who("from", in.From)
	if err != nil {
		return nil, action.SendResult{}, err
	}
	if err := t.deskRootGuard(from, in); err != nil {
		return nil, action.SendResult{}, err
	}
	if t.o.Seat != "" && in.ToBox == "" && in.Channel == "" && t.cfg.HubURL != "" && strings.HasPrefix(in.To, "HUM-") {
		in.ToBox = wuiBox
	}
	out, err := action.SendCtx(ctx, t.cfg, action.SendArgs{
		From: from, To: in.To, TaskID: in.TaskID, Kind: in.Kind, Body: in.Body, FileIDs: in.FileIDs,
		ToBox: in.ToBox, Channel: in.Channel, Ref: in.RefTaskID,
	})
	if err != nil {
		return nil, out, toolErr(err)
	}
	return text(action.JSON(out)), out, nil
}

func (t tools) recv(_ context.Context, _ *sdk.CallToolRequest, in RecvIn) (*sdk.CallToolResult, any, error) {
	as, err := t.o.who("as", in.As)
	if err != nil {
		return nil, nil, err
	}
	msgs, err := action.Recv(t.cfg, as, in.Ack)
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
}

func (t tools) getFile(_ context.Context, _ *sdk.CallToolRequest, in GetFileIn) (*sdk.CallToolResult, action.GetResult, error) {
	out, err := action.Get(t.cfg, in.FileID, in.Dest, false)
	if err != nil {
		return nil, out, toolErr(err)
	}
	return text(action.JSON(out)), out, nil
}

func (t tools) tail(_ context.Context, _ *sdk.CallToolRequest, in TailIn) (*sdk.CallToolResult, any, error) {
	out, err := action.Tail(t.cfg, t.o.Seat, in.TaskID, in.JSON)
	if err != nil {
		return nil, nil, toolErr(err)
	}
	return text(out), nil, nil
}

func (t tools) issue(ctx context.Context, _ *sdk.CallToolRequest, in IssueIn) (*sdk.CallToolResult, any, error) {
	as, err := t.o.who("as", in.As)
	if err != nil {
		return nil, nil, err
	}
	var raw json.RawMessage
	if in.Issue != nil {
		if raw, err = json.Marshal(in.Issue); err != nil {
			return nil, nil, toolErr(err)
		}
	}
	out, err := action.Issue(ctx, t.cfg, action.IssueArgs{Op: in.Op, As: as, Ref: in.Ref, Issue: raw, Query: in.Query, Body: in.Body})
	if err != nil {
		return nil, nil, toolErr(err)
	}
	return text(string(out)), nil, nil
}

func (t tools) flow(ctx context.Context, _ *sdk.CallToolRequest, in FlowIn) (*sdk.CallToolResult, any, error) {
	as, err := t.o.who("as", in.As)
	if err != nil {
		return nil, nil, err
	}
	out, err := action.Flow(ctx, t.cfg, action.FlowArgs{As: as, Kind: in.Kind, Limit: in.Limit, Before: in.Before})
	if err != nil {
		return nil, nil, toolErr(err)
	}
	return text(string(out)), nil, nil
}

func (t tools) desks() action.Desks {
	d := action.Desks{Dir: t.o.Desks, Box: t.o.DeskBox, Base: t.cfg}
	if len(t.o.SeatCmd) > 0 {
		d.Seat = t.seatAgent
	}
	return d
}

// seatAgent runs SeatCmd <tenant> <agent>; its output is the error's text.
func (t tools) seatAgent(ctx context.Context, tenant, agent string) error {
	ctx, cancel := context.WithTimeout(ctx, seatTimeout)
	defer cancel()
	args := append(append([]string{}, t.o.SeatCmd[1:]...), tenant, agent)
	out, err := exec.CommandContext(ctx, t.o.SeatCmd[0], args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(lastLines(string(out), 3)))
	}
	return nil
}

// seatTimeout bounds one seat: do_spl_desk_up waits up to 30 s for the roster.
const seatTimeout = 120 * time.Second

func lastLines(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, " | ")
}

func (t tools) readLink(ctx context.Context, _ *sdk.CallToolRequest, in ReadLinkIn) (*sdk.CallToolResult, any, error) {
	out, err := action.ReadLink(ctx, t.desks(), t.o.Seat, in.URL, in.JSON)
	if err != nil {
		return nil, nil, toolErr(err)
	}
	return text(out), nil, nil
}

func (t tools) reply(ctx context.Context, _ *sdk.CallToolRequest, in ReplyIn) (*sdk.CallToolResult, action.SendResult, error) {
	out, err := action.ReplyLink(ctx, t.desks(), action.ReplyArgs{Seat: t.o.Seat, URL: in.URL, Body: in.Body, Kind: in.Kind})
	if err != nil {
		return nil, out, toolErr(err)
	}
	return text(action.JSON(out)), out, nil
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
	return fmt.Errorf("spool: %w (exit %d)", err, action.ExitCode(err))
}
