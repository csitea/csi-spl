// Package action is the one verb layer behind both spool front ends: the CLI
// (cmd/spool) and the stdio MCP server (internal/mcp). Each function runs a verb
// and returns the value the CLI prints, so a tool and its verb cannot drift
// (Constitution VIII: one uniform API).
package action

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
)

// typedByRe is rdb 0006 humans.human_id: a typed_by claim names a human.
var typedByRe = regexp.MustCompile(`^HUM-[0-9]+$`)

// channelRe is the hub's channel id (store.ValidChannelID, channels-v1 §1).
var channelRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,63}$`)

// Broadcast is the v:1 `to` of a channel post: no single recipient, every
// member of the channel reads it - the same `to` a human's post carries.
const Broadcast = "ALL-0"

// ChannelID normalizes a --channel value: trimmed, lower case, an optional
// leading '#' dropped (agents write "#spool-hub-devel" the way the WUI shows it).
func ChannelID(c string) string {
	return strings.TrimPrefix(strings.ToLower(strings.TrimSpace(c)), "#")
}

// PutResult is what put-file / put-dir return. Fields are in key order so the
// JSON matches the map the CLI printed before this layer existed.
type PutResult struct {
	Bytes  int64  `json:"bytes"`
	FileID string `json:"file_id"`
	Kind   string `json:"kind"`
	Name   string `json:"name"`
	SHA256 string `json:"sha256"`
}

// SendArgs are the inputs of send. Attachments are added in the CLI's order:
// file ids, put-file, dir blobs, file refs, dir refs. ToBox is hub-only
// (spec 003, OQ-01: an additive change to the box API).
type SendArgs struct {
	From, To, TaskID, Kind, Body string
	ToBox                        string
	FileIDs, FileRefs            []string
	DirBlobs, DirRefs            []string
	PutFile                      string
	// TypedBy is the HUM-* who typed this line at the agent's terminal
	// (specs/036 FR-009, `spool send --typed-by`). Hub mode only: it rides on
	// the send frame and the hub accepts it only for a bound box operator.
	TypedBy string
	// Channel makes the send a POST INTO that channel (specs/038): a new
	// topic every member of the channel reads, exactly like a human's post -
	// to ALL-0, to_box box-wui, the channel signed into the envelope. Hub mode
	// only; the hub refuses it (unknown_channel, 404) unless From is a member.
	Channel string
	// Hub overrides the hub client (tests inject one with their transport).
	Hub *hubclient.Client
}

// SendResult is what send returns. Delivery is always "local" in 002; hub
// mode adds "sent", "queued" and "pending" (trust-modes §8 + 003 OQ-09).
type SendResult struct {
	Delivery string `json:"delivery"`
	MsgID    string `json:"msg_id"`
	TaskID   string `json:"task_id"`
	TS       string `json:"ts"`
}

// GetResult is what get-file / get-dir return.
type GetResult struct {
	FileID string `json:"file_id"`
	Path   string `json:"path"`
}

// Put blobs a file (or, with dir, a directory) into the content-addressed store.
func Put(cfg *config.Config, path string, dir bool) (PutResult, error) {
	var a msg.Attachment
	var err error
	if dir {
		a, err = files.PutDir(cfg.FilesDir(), path)
	} else {
		a, err = files.PutFile(cfg.FilesDir(), path)
	}
	if err != nil {
		return PutResult{}, err
	}
	return PutResult{Bytes: a.Bytes, FileID: a.FileID, Kind: a.Kind, Name: a.Name, SHA256: a.SHA256}, nil
}

// Send builds the attachments and writes the message: locally (no hub), or in
// hub mode ($SPOOL_HUB_URL set) through the box-signed envelope.
func Send(cfg *config.Config, in SendArgs) (SendResult, error) {
	return SendCtx(context.Background(), cfg, in)
}

// SendCtx is Send with a context for the hub round trip.
func SendCtx(ctx context.Context, cfg *config.Config, in SendArgs) (SendResult, error) {
	if err := checkSend(cfg, &in); err != nil {
		return SendResult{}, err
	}
	atts, err := attachments(cfg, in)
	if err != nil {
		return SendResult{}, err
	}
	if cfg.HubURL == "" {
		m, err := spool.New(cfg).SendKnown(in.From, in.To, in.TaskID, in.Kind, in.Body, atts)
		if err != nil {
			return SendResult{}, err
		}
		return SendResult{Delivery: "local", MsgID: m.MsgID, TaskID: m.TaskID, TS: m.TS}, nil
	}
	return sendHub(ctx, cfg, in, atts)
}

// checkSend refuses the hub-only flags in local mode and a malformed channel
// post or typed_by claim. A channel post is normalized in place: the channel
// id, to ALL-0, kind note by default.
func checkSend(cfg *config.Config, in *SendArgs) error {
	if err := splitToBox(cfg, in); err != nil {
		return err
	}
	if in.ToBox != "" && cfg.HubURL == "" {
		return fmt.Errorf("--to-box / to_box needs hub mode ($SPOOL_HUB_URL)")
	}
	if in.Channel != "" {
		in.Channel = ChannelID(in.Channel)
		switch {
		case cfg.HubURL == "":
			return fmt.Errorf("--channel needs hub mode ($SPOOL_HUB_URL)")
		case !channelRe.MatchString(in.Channel):
			return fmt.Errorf("--channel must match ^[a-z0-9][a-z0-9-]{0,63}$, got %q", in.Channel)
		case in.ToBox != "":
			return fmt.Errorf("--channel posts to every member of the channel: drop --to-box")
		case in.To != "" && in.To != Broadcast:
			return fmt.Errorf("--channel posts to every member of the channel: --to must be empty or %s, got %q", Broadcast, in.To)
		}
		in.To = Broadcast
		if in.Kind == "" {
			in.Kind = "note"
		}
	}
	if in.TypedBy != "" {
		if cfg.HubURL == "" {
			return fmt.Errorf("--typed-by needs hub mode ($SPOOL_HUB_URL)")
		}
		if !typedByRe.MatchString(in.TypedBy) {
			return fmt.Errorf("--typed-by must be a HUM-<n> id, got %q", in.TypedBy)
		}
	}
	return nil
}

// splitToBox takes the box out of a qualified recipient (spec 061 3.3.1:
// agents are unique as <ID>@<box>, so --to c-004@box-desk names one agent).
// Hub mode: the box becomes to_box, and a different --to-box is refused. Local
// mode reaches only this machine, so the box must be its own.
func splitToBox(cfg *config.Config, in *SendArgs) error {
	id, box, qualified := strings.Cut(in.To, "@")
	if !qualified {
		return nil
	}
	switch {
	case !msg.ValidID(id) || !msg.ValidBoxID(box):
		return fmt.Errorf("--to %q is not <agent id>@<box id>", in.To)
	case cfg.HubURL == "" && box != cfg.DeskBox && box != cfg.BoxID:
		return fmt.Errorf("--to %q names box %s; local mode reaches only this machine (no $SPOOL_HUB_URL)", in.To, box)
	case cfg.HubURL != "" && in.ToBox != "" && in.ToBox != box:
		return fmt.Errorf("--to %q and --to-box %q name different boxes", in.To, in.ToBox)
	}
	in.To = id
	if cfg.HubURL != "" {
		in.ToBox = box
	}
	return nil
}

// attachments builds the message's files in a fixed order: blob ids, the
// put file, dir blobs, file refs, dir refs.
func attachments(cfg *config.Config, in SendArgs) ([]msg.Attachment, error) {
	var atts []msg.Attachment
	for _, id := range in.FileIDs {
		atts = append(atts, files.RefBlob(cfg.FilesDir(), id))
	}
	var puts []string
	if in.PutFile != "" {
		puts = []string{in.PutFile}
	}
	for _, src := range []struct {
		paths []string
		make  func(string) (msg.Attachment, error)
	}{
		{puts, func(p string) (msg.Attachment, error) { return files.PutFile(cfg.FilesDir(), p) }},
		{in.DirBlobs, func(p string) (msg.Attachment, error) { return files.PutDir(cfg.FilesDir(), p) }},
		{in.FileRefs, files.RefFile},
		{in.DirRefs, files.RefDir},
	} {
		for _, p := range src.paths {
			a, err := src.make(p)
			if err != nil {
				return nil, err
			}
			atts = append(atts, a)
		}
	}
	return atts, nil
}

// sendHub signs the composed message into the box envelope and sends it:
// into a channel, or to one recipient.
func sendHub(ctx context.Context, cfg *config.Config, in SendArgs, atts []msg.Attachment) (SendResult, error) {
	m, err := spool.New(cfg).Compose(in.From, in.To, in.TaskID, in.Kind, in.Body, atts)
	if err != nil {
		return SendResult{}, err
	}
	hc := in.Hub
	if hc == nil {
		hc = hubclient.New(cfg)
	}
	var d string
	if in.Channel != "" {
		d, err = hc.SendChannelTyped(ctx, m, in.Channel, in.TypedBy)
	} else {
		d, err = hc.SendMessageTyped(ctx, m, in.ToBox, in.TypedBy)
	}
	if err != nil {
		return SendResult{}, err
	}
	return SendResult{Delivery: d, MsgID: m.MsgID, TaskID: m.TaskID, TS: m.TS}, nil
}

// Recv returns the well-formed messages of as's inbox. The slice is non-nil
// whenever the inbox was read, even alongside an error for malformed files (the
// good messages are still returned, and acked when ack is set); it is nil when
// nothing was read.
func Recv(cfg *config.Config, as string, ack bool) ([]*msg.Message, error) {
	res, err := spool.New(cfg).Recv(as, ack)
	if res == nil {
		return nil, err
	}
	if res.Messages == nil {
		return []*msg.Message{}, err
	}
	return res.Messages, err
}

// Get copies a blob (or, with dir, unpacks a dir blob) to dest, verifying its hash.
func Get(cfg *config.Config, fileID, dest string, dir bool) (GetResult, error) {
	var err error
	if dir {
		err = files.GetDir(cfg.FilesDir(), fileID, dest)
	} else {
		err = files.GetFile(cfg.FilesDir(), fileID, dest)
	}
	if err != nil {
		return GetResult{}, err
	}
	return GetResult{FileID: fileID, Path: dest}, nil
}

// Tail renders a topic oldest-first: one human line per message, or with
// asJSON one raw v:1 object per line (NDJSON). Every line ends in a newline.
func Tail(cfg *config.Config, taskID string, asJSON bool) (string, error) {
	if taskID == "" {
		return "", fmt.Errorf("--task is required")
	}
	msgs, err := spool.New(cfg).Tail(taskID)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	for _, m := range msgs {
		if asJSON {
			raw, _ := msg.Marshal(m)
			b.Write(raw)
			b.WriteByte('\n')
		} else {
			fmt.Fprintf(&b, "%s  %s -> %s  [%s]  %s\n", m.TS, m.From, m.To, m.Kind, m.Body)
		}
	}
	return b.String(), nil
}

// JSON renders a verb result exactly as the CLI prints it (without the newline).
func JSON(v any) string {
	out, _ := json.Marshal(v)
	return string(out)
}

// ExitCode maps an error to the CLI convention: 0 ok, 78 verify/refuse
// (unpinned author, bad signature, hash mismatch), 1 other.
func ExitCode(err error) int {
	if errors.Is(err, files.ErrHashMismatch) {
		return 78
	}
	return spool.ExitCode(err)
}
