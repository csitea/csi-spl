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
	if in.ToBox != "" && cfg.HubURL == "" {
		return SendResult{}, fmt.Errorf("--to-box / to_box needs hub mode ($SPOOL_HUB_URL)")
	}
	if in.TypedBy != "" {
		if cfg.HubURL == "" {
			return SendResult{}, fmt.Errorf("--typed-by needs hub mode ($SPOOL_HUB_URL)")
		}
		if !typedByRe.MatchString(in.TypedBy) {
			return SendResult{}, fmt.Errorf("--typed-by must be a HUM-<n> id, got %q", in.TypedBy)
		}
	}
	var atts []msg.Attachment
	for _, id := range in.FileIDs {
		atts = append(atts, files.RefBlob(cfg.FilesDir(), id))
	}
	if in.PutFile != "" {
		a, err := files.PutFile(cfg.FilesDir(), in.PutFile)
		if err != nil {
			return SendResult{}, err
		}
		atts = append(atts, a)
	}
	for _, p := range in.DirBlobs {
		a, err := files.PutDir(cfg.FilesDir(), p)
		if err != nil {
			return SendResult{}, err
		}
		atts = append(atts, a)
	}
	for _, p := range in.FileRefs {
		a, err := files.RefFile(p)
		if err != nil {
			return SendResult{}, err
		}
		atts = append(atts, a)
	}
	for _, p := range in.DirRefs {
		a, err := files.RefDir(p)
		if err != nil {
			return SendResult{}, err
		}
		atts = append(atts, a)
	}
	if cfg.HubURL == "" {
		m, err := spool.New(cfg).Send(in.From, in.To, in.TaskID, in.Kind, in.Body, atts)
		if err != nil {
			return SendResult{}, err
		}
		return SendResult{Delivery: "local", MsgID: m.MsgID, TaskID: m.TaskID, TS: m.TS}, nil
	}
	m, err := spool.New(cfg).Compose(in.From, in.To, in.TaskID, in.Kind, in.Body, atts)
	if err != nil {
		return SendResult{}, err
	}
	hc := in.Hub
	if hc == nil {
		hc = hubclient.New(cfg)
	}
	d, err := hc.SendMessageTyped(ctx, m, in.ToBox, in.TypedBy)
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
