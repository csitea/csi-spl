package action

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 183 (SPL-2398, row P3): an agent exports any topic it can read to a
// PDF file on its machine. The hub renders it for the person the box works
// for (7.1.1); this verb only asks, writes the file and says where it is.
// `spool topic-pdf` and the MCP tool spool_topic_pdf both call TopicPDF, so
// they print the same JSON.

// TopicPDFTimeout is how long an export waits by default: the hub's own
// render bound (cnf hub.pdf.timeout, 120 s, spec 183 1.2 R2), which covers a
// cold start of the renderer.
const TopicPDFTimeout = 120 * time.Second

// Exit codes of spool topic-pdf (spec 183 7.1.2); 1 is a usage error.
const (
	ExitTopicPDFNotFound = 3 // 404 not_found: no such topic, or not this operator's to read
	ExitTopicPDFOperator = 4 // 400 operator_ambiguous, 403 typed_by_not_bound or 403 no_operator
	ExitTopicPDFRender   = 5 // 413 too_large, 503 render_unavailable or 504 render_timeout
)

// ErrTopicPDFTimeout: no whole PDF within the export's timeout (exit 5, as
// the hub's own 504 render_timeout).
var ErrTopicPDFTimeout = errors.New("render_timeout: no PDF within the timeout")

// TopicPDFArgs is one export.
type TopicPDFArgs struct {
	Task    string        // the topic: its uuid or a WUI link (ParseLink)
	Out     string        // the file to write, replaced when it exists; "" = the default dir and the hub's name
	TypedBy string        // HUM-<n>: the operator to export as; "" = the box's one operator
	Agent   string        // names the default dir; "" = $SPOOL_AGENT_ID, else the box id
	Timeout time.Duration // 0 = TopicPDFTimeout
}

// TopicPDFResult is the one JSON line the verb prints (spec 183 7.1.2).
type TopicPDFResult struct {
	TaskID   string `json:"task_id"`
	Path     string `json:"path"`
	Bytes    int64  `json:"bytes"`
	Rows     int    `json:"rows"`
	Pictures int    `json:"pictures"`
	SHA256   string `json:"sha256"`
}

// TopicPDFExitCode maps an export error to the verb's exit code.
func TopicPDFExitCode(err error) int {
	if errors.Is(err, ErrTopicPDFTimeout) {
		return ExitTopicPDFRender
	}
	var he *hubclient.HubError
	if errors.As(err, &he) {
		switch {
		case he.Token == "not_found" || he.Status == http.StatusNotFound:
			return ExitTopicPDFNotFound
		case he.Token == "operator_ambiguous" || he.Token == "typed_by_not_bound" || he.Token == "no_operator":
			return ExitTopicPDFOperator
		case he.Status == http.StatusRequestEntityTooLarge || he.Status == http.StatusServiceUnavailable ||
			he.Status == http.StatusGatewayTimeout:
			return ExitTopicPDFRender
		}
	}
	return ExitCode(err)
}

// TopicPDF exports the topic in.Task names through this box's desks, in the
// order a link is read (the link's workspace first): a desk whose hub answers
// 404, or that cannot be reached, hands over to the next one. The PDF is
// written to a temp file next to its target and renamed into place only when
// whole, so a failed export leaves no file and no partial one.
func TopicPDF(ctx context.Context, d Desks, in TopicPDFArgs) (TopicPDFResult, error) {
	l, err := ParseLink(in.Task)
	if err != nil {
		return TopicPDFResult{}, err
	}
	if in.TypedBy != "" && (!strings.HasPrefix(in.TypedBy, "HUM-") || !msg.ValidID(in.TypedBy)) {
		return TopicPDFResult{}, fmt.Errorf("typed_by %q is not a person id (HUM-<n>)", in.TypedBy)
	}
	desks := d.ordered(l)
	if len(desks) == 0 {
		return TopicPDFResult{}, fmt.Errorf("topic %s: no live hub desk on this box to export it through (%s)", l.TaskID, d.where())
	}
	dir, path, err := topicPDFTarget(d.Base, in)
	if err != nil {
		return TopicPDFResult{}, err
	}
	timeout := in.Timeout
	if timeout <= 0 {
		timeout = TopicPDFTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	tmp, err := os.CreateTemp(dir, ".topic-pdf-*.part")
	if err != nil {
		return TopicPDFResult{}, err
	}
	defer os.Remove(tmp.Name()) // a no-op once renamed
	defer tmp.Close()
	info, sum, err := topicPDFFromDesks(ctx, desks, l.TaskID, in.TypedBy, tmp)
	if err != nil && errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return TopicPDFResult{}, fmt.Errorf("%w (%s): %w", ErrTopicPDFTimeout, timeout, err)
	}
	if err != nil {
		return TopicPDFResult{}, err
	}
	return topicPDFKeep(tmp, path, filepath.Join(dir, topicPDFName(info.Name, l.TaskID)), l.TaskID, info, sum)
}

// topicPDFFromDesks writes the PDF into f from the first desk that serves it;
// f is emptied before each try. The error, when none does: a refusal other
// than not_found or no_operator at once; else an unreachable desk, then a
// workspace where this box has no operator (a missing grant), then a 404.
func topicPDFFromDesks(ctx context.Context, desks []desk, taskID, typedBy string, f *os.File) (hubclient.TopicPDFInfo, hash.Hash, error) {
	var notFound, noOperator, unreachable error
	for _, k := range desks {
		if err := truncate(f); err != nil {
			return hubclient.TopicPDFInfo{}, nil, err
		}
		h := sha256.New()
		info, err := topicPDFExport(ctx, k.cfg, taskID, typedBy, io.MultiWriter(f, h))
		var he *hubclient.HubError
		switch {
		case err == nil:
			return info, h, nil
		case errors.As(err, &he) && TopicPDFExitCode(err) == ExitTopicPDFNotFound:
			notFound = err
		case errors.As(err, &he) && he.Token == "no_operator":
			noOperator = fmt.Errorf("desk %s in %s: %w", k.cfg.BoxID, k.tenant, err)
		case errors.Is(err, hubclient.ErrUnreachable) && ctx.Err() == nil:
			unreachable = fmt.Errorf("desk %s in %s: %w", k.cfg.BoxID, k.tenant, err)
		default:
			return hubclient.TopicPDFInfo{}, nil, err
		}
	}
	if unreachable != nil {
		return hubclient.TopicPDFInfo{}, nil, unreachable
	}
	if noOperator != nil {
		return hubclient.TopicPDFInfo{}, nil, noOperator
	}
	return hubclient.TopicPDFInfo{}, nil, notFound
}

// topicPDFExport is one export through one desk (tests replace it).
var topicPDFExport = topicPDFVia

// topicPDFVia is one export as cfg's box: a CLI session, then the REST call.
func topicPDFVia(ctx context.Context, cfg *config.Config, taskID, typedBy string, w io.Writer) (hubclient.TopicPDFInfo, error) {
	sess, err := hubclient.New(cfg).Dial(ctx, wire.RoleCLI)
	if err != nil {
		return hubclient.TopicPDFInfo{}, err
	}
	defer sess.Close()
	return sess.TopicPDF(ctx, taskID, typedBy, w)
}

// topicPDFKeep syncs the whole temp file and renames it to out (or, with no
// out, to named) and answers the result line.
func topicPDFKeep(tmp *os.File, out, named, taskID string, info hubclient.TopicPDFInfo, sum hash.Hash) (TopicPDFResult, error) {
	if err := tmp.Sync(); err != nil {
		return TopicPDFResult{}, err
	}
	fi, err := tmp.Stat()
	if err != nil {
		return TopicPDFResult{}, err
	}
	if err := tmp.Close(); err != nil {
		return TopicPDFResult{}, err
	}
	if out == "" {
		out = named
	}
	if err := os.Rename(tmp.Name(), out); err != nil {
		return TopicPDFResult{}, err
	}
	return TopicPDFResult{TaskID: taskID, Path: out, Bytes: fi.Size(), Rows: info.Rows, Pictures: info.Pictures,
		SHA256: hex.EncodeToString(sum.Sum(nil))}, nil
}

// topicPDFTarget is the directory the temp file goes in and the absolute
// --out path ("" = the default dir, $SPOOL_ROOT/<agent>/exports, made 0700;
// the hub's name is the file's).
func topicPDFTarget(base *config.Config, in TopicPDFArgs) (dir, path string, err error) {
	if in.Out != "" {
		p, err := filepath.Abs(in.Out)
		if err != nil {
			return "", "", err
		}
		if fi, err := os.Stat(p); err == nil && fi.IsDir() {
			return "", "", fmt.Errorf("out %s is a directory: it names the file itself", p)
		}
		return filepath.Dir(p), p, nil
	}
	if base == nil || base.SpoolRoot == "" {
		return "", "", errors.New("no spool root to put the export in: give out")
	}
	agent := in.Agent
	if agent == "" {
		agent = os.Getenv("SPOOL_AGENT_ID")
	}
	if agent == "" {
		agent = base.BoxID
	}
	if !msg.ValidID(agent) && !msg.ValidBoxID(agent) {
		return "", "", fmt.Errorf("agent id %q cannot name an exports dir: set $SPOOL_AGENT_ID or give out", agent)
	}
	dir = filepath.Join(base.SpoolRoot, agent, "exports")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", "", err
	}
	return dir, "", os.Chmod(dir, 0o700)
}

// topicPDFName is the hub's file name (7.1.4), or when it sent none,
// topic-<task8>-<UTC stamp>.pdf.
func topicPDFName(hubName, taskID string) string {
	if hubName != "" {
		return hubName
	}
	task8 := taskID
	if len(task8) > 8 {
		task8 = task8[:8]
	}
	return "topic-" + task8 + "-" + time.Now().UTC().Format("20060102T150405Z") + ".pdf"
}

func truncate(f *os.File) error {
	if err := f.Truncate(0); err != nil {
		return err
	}
	_, err := f.Seek(0, io.SeekStart)
	return err
}
