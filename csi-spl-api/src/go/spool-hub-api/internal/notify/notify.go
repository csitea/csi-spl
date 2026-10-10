// Package notify is the terminal leg of a delivery (specs/028-spool-terminal-delivery):
// after a v:1 message lands in a LOCAL agent's inbox, the agent's terminal
// pane is made to show it.
//
// The binary carries no tmux knowledge. It runs one command, $SPOOL_NOTIFY_CMD
// — on a box that is csi-spl-orc's spool-notify.sh — and hands it the message's
// fields as flags and the body on stdin. That one command owns the safe-poke
// rules (contracts/poke-line.md) and is the same code path spool-send.sh uses,
// so there is exactly one renderer on the box.
//
// Nothing here can fail a delivery. The file is the record (002); this is the
// second leg, and a notifier that is missing, slow or angry is logged and
// forgotten.
package notify

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/logging"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/trace"
)

// Off is the $SPOOL_NOTIFY_CMD value that disables the terminal leg explicitly
// (spool-send.sh sets it for its own send: it rings the pane itself).
const Off = "off"

// Enabled reports whether cfg asks for a terminal leg at all. Unset is the
// default, so a hub, a CI job and every test behave exactly as before.
func Enabled(cfg *config.Config) bool {
	if cfg == nil {
		return false
	}
	c := strings.TrimSpace(cfg.NotifyCmd)
	return c != "" && c != Off
}

// poked is an exit code that means the notifier did its job and decided, under
// the safe-poke rules, what to do with the pane: 0 shown, 5 no live window,
// 6 refused (unsent text), 7 the agent has exited. None of them is a fault.
func poked(code int) bool {
	switch code {
	case 0, 5, 6, 7:
		return true
	}
	return false
}

// Run shows m in the terminal of agent `to` on this box. `to` is passed
// separately because a mention-routed channel message (003 channels-v1 §4) is
// delivered to several local agents and m.To names only one of them.
//
// It blocks for at most cfg.NotifyTimeout plus the one-second WaitDelay that
// bounds a grandchild still holding the output pipe, and returns nothing:
// every outcome is a log line.
func Run(cfg *config.Config, m *msg.Message, to string) {
	RunCtx(context.Background(), cfg, m, to)
}

// RunCtx is Run under a caller ctx: cancelling ctx kills the notifier at once
// (then the same WaitDelay applies). cfg.NotifyTimeout still bounds a ctx that is never cancelled.
// Queue.Stop() closes the lanes and waits for queued pokes to drain, but does not
// interrupt a running notifier.
func RunCtx(ctx context.Context, cfg *config.Config, m *msg.Message, to string) {
	if !Enabled(cfg) || m == nil || to == "" {
		return
	}
	argv := strings.Fields(cfg.NotifyCmd)
	argv = append(argv,
		"--to", to,
		"--from", m.From,
		"--kind", m.Kind,
		"--task", m.TaskID,
		"--msg-id", m.MsgID,
		"--body-stdin",
	)

	trace.Mark(trace.Event{Stage: trace.StageNotifyStart, MsgID: m.MsgID, To: to})
	ctx, cancel := context.WithTimeout(ctx, cfg.NotifyTimeoutOr())
	defer cancel()
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...) //nolint:gosec // operator-set command, no shell
	// The notifier is a shell script that runs tmux; its OWN children inherit
	// the output pipe, so killing it on the deadline is not enough - Wait would
	// block on that pipe until the grandchild exits. WaitDelay gives up on the
	// pipe shortly after the kill, which is what actually bounds Run.
	cmd.WaitDelay = time.Second
	cmd.Stdin = strings.NewReader(withAttachments(m))
	// The notifier resolves the recipient's pane from $SPOOL_ROOT/registry.tsv,
	// so it must see the same root this store wrote into, whatever the parent
	// process inherited.
	cmd.Env = append(os.Environ(), "SPOOL_ROOT="+cfg.SpoolRoot)
	// The notifier reports its own "the line is on the screen" instant into
	// the same trace file; this one brackets the whole leg, submit wait and
	// all, which is what blocks the caller.
	if trace.On() {
		cmd.Env = append(cmd.Env, "SPOOL_TRACE="+os.Getenv("SPOOL_TRACE"),
			"SPOOL_TRACE_MSG_ID="+m.MsgID, "SPOOL_TRACE_TO="+to)
	}
	out, err := cmd.CombinedOutput()

	var ee *exec.ExitError
	rc := 0
	if errors.As(err, &ee) {
		rc = ee.ExitCode()
	}
	trace.Mark(trace.Event{Stage: trace.StageNotifyDone, MsgID: m.MsgID, To: to, RC: rc})

	log := logging.New(cfg).With().Str("to", to).Str("msg_id", m.MsgID).Logger()
	line := strings.TrimSpace(string(out))
	switch {
	case err == nil:
		log.Debug().Str("notify", line).Msg("terminal delivery")
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		log.Warn().Str("cmd", argv[0]).Msg("terminal delivery timed out; the message is still in the inbox")
	case errors.As(err, &ee) && poked(ee.ExitCode()):
		log.Debug().Int("rc", ee.ExitCode()).Str("notify", line).Msg("terminal delivery: pane left alone")
	default:
		log.Warn().Err(err).Str("cmd", argv[0]).Str("notify", line).
			Msg("terminal delivery failed; the message is still in the inbox")
	}
}

// withAttachments is the body the pane is shown: one "[image attached: ...]"
// line per file, in front of the text. Owner topic 3eb98913 (msg 9ef7aac9,
// 2026-10-10): a pasted screenshot sent with no text reached every agent pane
// as an EMPTY post while the hub row held the image, so the agents read "the
// owner sent nothing". In front, not after: the poke line cuts a long body.
func withAttachments(m *msg.Message) string {
	var b strings.Builder
	for _, a := range m.Files {
		b.WriteString(AttachmentNote(a))
		b.WriteByte('\n')
	}
	if b.Len() == 0 {
		return m.Body
	}
	return b.String() + m.Body
}

// AttachmentNote is one attachment as a line an agent can act on:
// "[image attached: image.png, 337 KB, file_id <sha256>]".
func AttachmentNote(a msg.Attachment) string {
	what := "file"
	switch {
	case a.Kind == "dir":
		what = "dir"
	case isImageName(a.Name):
		what = "image"
	}
	parts := []string{what + " attached: " + a.Name}
	if a.Bytes > 0 {
		parts = append(parts, humanBytes(a.Bytes))
	}
	switch {
	case a.FileID != "":
		parts = append(parts, "file_id "+a.FileID)
	case a.Path != "":
		parts = append(parts, "path "+a.Path)
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

func isImageName(name string) bool {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg", ".heic", ".avif", ".tif", ".tiff":
		return true
	}
	return false
}

// humanBytes: decimal units, as a file manager shows them (336983 -> "337 KB").
func humanBytes(n int64) string {
	switch {
	case n < 1000:
		return strconv.FormatInt(n, 10) + " B"
	case n < 1000*1000:
		return strconv.FormatInt((n+500)/1000, 10) + " KB"
	default:
		return strconv.FormatFloat(float64(n)/1e6, 'f', 1, 64) + " MB"
	}
}
