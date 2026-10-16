package action

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-2112 (owner HUM-10, csitea topic e055195c): an agent handed a WUI
// discussion link reads it, and a seated one replies in it. The workspace
// comes from the LINK, not from the agent's one seat: the box's desks are
// tried in turn, the link's own workspace first, and the hub serves a topic
// only to a desk box that may read it, so no desk prints more than it
// already could.

// Link is one WUI discussion link, parsed.
type Link struct {
	Host   string // the link's host, lower case
	Label  string // its first label: the workspace of a tenant host (csitea.<base>)
	TaskID string // the topic uuid
	MsgID  string // the message the link points at, when it names one
	Form   string // which form it was: t, m, query, id
}

// ParseLink reads the link forms the WUI emits (csi-spl-wui src/pages and
// utils): /t/<task>[#<msg>], /m/<id> (a message or a topic id), and a page
// carrying ?topic=<task> (/, /channel/<name>, /dm/<peer>, /lobby), each with
// an optional locale prefix (/fi/t/<task>). A bare topic uuid is taken too.
func ParseLink(raw string) (Link, error) {
	raw = strings.TrimSpace(raw)
	if refRe.MatchString(raw) {
		return Link{TaskID: strings.ToLower(raw), Form: "id"}, nil
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Hostname() == "" {
		return Link{}, fmt.Errorf("%q is not a discussion link: want https://<host>/t/<topic uuid> (or /m/<id>, or a page with ?topic=<uuid>)", raw)
	}
	l := Link{Host: strings.ToLower(u.Hostname())}
	if label, rest, ok := strings.Cut(l.Host, "."); ok && strings.Contains(rest, ".") && msg.ValidTenantID(label) {
		l.Label = label
	}
	if l.TaskID, l.MsgID, l.Form = linkTopic(u); l.TaskID == "" {
		return Link{}, fmt.Errorf("%q names no topic: want /t/<topic uuid>, /m/<id> or ?topic=<topic uuid>", raw)
	}
	return l, nil
}

// linkTopic is the topic (and message) a parsed WUI URL names.
func linkTopic(u *url.URL) (task, msgID, form string) {
	segs := strings.Split(strings.Trim(u.EscapedPath(), "/"), "/")
	if len(segs) == 3 && isLocale(segs[0]) {
		segs = segs[1:]
	}
	if len(segs) == 2 && (segs[0] == "t" || segs[0] == "m") {
		id, _ := url.PathUnescape(segs[1])
		if refRe.MatchString(id) {
			id = strings.ToLower(id)
			if segs[0] == "m" {
				return id, id, "m"
			}
			if refRe.MatchString(u.Fragment) {
				msgID = strings.ToLower(u.Fragment)
			}
			return id, msgID, "t"
		}
	}
	if q := u.Query().Get("topic"); refRe.MatchString(q) {
		return strings.ToLower(q), "", "query"
	}
	return "", "", ""
}

// isLocale is a WUI locale prefix segment (prefix_except_default): fi, pt-br.
func isLocale(s string) bool {
	if len(s) == 2 {
		return s[0] >= 'a' && s[0] <= 'z' && s[1] >= 'a' && s[1] <= 'z'
	}
	return len(s) == 5 && s[2] == '-' && isLocale(s[:2]) && isLocale(s[3:])
}

// Desks are the hub desks of this box a link is read through: one desk per
// workspace, <Dir>/<tenant>/<Box>, each run by a live `spool hub-run`
// sidecar whose own settings (SPOOL_ROOT, keys, box, hub, tenant) the read
// takes, the path spool-mcp.sh and topic-text.sh use. With no Dir the Base
// config is the one desk.
type Desks struct {
	Dir  string
	Box  string
	Base *config.Config
	// ProcRoot is /proc (tests point it at a fake one).
	ProcRoot string
	// Tail reads a topic as the desk box; nil = the hub (HubTail).
	Tail func(ctx context.Context, cfg *config.Config, taskID string) ([]TailRow, error)
	// Send posts as the desk box; nil = SendCtx.
	Send func(ctx context.Context, cfg *config.Config, in SendArgs) (SendResult, error)
	// Seat seats an agent on the desk of a workspace (spool-mcp.sh --seat:
	// do_spl_desk_up); nil = this server seats nobody.
	Seat func(ctx context.Context, tenant, agent string) error
}

// TailRow is one message of a hub tail, with the boxes it went between.
type TailRow struct {
	Msg     *msg.Message
	FromBox string
	ToBox   string
}

// desk is one workspace's desk: its tenant and the config of its sidecar.
type desk struct {
	tenant string
	cfg    *config.Config
}

// HubTail reads a topic from the hub as cfg's box (== spool hub-tail): what
// the hub serves that box, nothing more.
func HubTail(ctx context.Context, cfg *config.Config, taskID string) ([]TailRow, error) {
	if cfg.HubURL == "" {
		return nil, fmt.Errorf("reading a topic from the hub needs hub mode ($SPOOL_HUB_URL)")
	}
	sess, err := hubclient.New(cfg).Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, err
	}
	defer sess.Close() //nolint:errcheck
	var rows []TailRow
	_, err = sess.Tail(ctx, taskID, false, func(e *wire.Envelope) {
		if m, err := e.Inner(); err == nil {
			rows = append(rows, TailRow{Msg: m, FromBox: e.FromBox, ToBox: e.ToBox})
		}
	})
	return rows, err
}

// ordered is the desks to try for link l, best first: the link's own
// workspace, then the base config's, then every other live one by name.
func (d Desks) ordered(l Link) []desk {
	if d.Dir == "" {
		if d.Base == nil || d.Base.HubURL == "" {
			return nil
		}
		return []desk{{tenant: d.Base.TenantID(), cfg: d.Base}}
	}
	entries, _ := os.ReadDir(d.Dir)
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() && msg.ValidTenantID(e.Name()) {
			names = append(names, e.Name())
		}
	}
	sort.SliceStable(names, func(i, j int) bool { return d.rank(l, names[i]) < d.rank(l, names[j]) })
	var out []desk
	for _, t := range names {
		if cfg, err := d.deskConfig(t); err == nil {
			out = append(out, desk{tenant: t, cfg: cfg})
		}
	}
	return out
}

func (d Desks) rank(l Link, tenant string) int {
	switch {
	case tenant == l.Label:
		return 0
	case d.Base != nil && tenant == d.Base.TenantID():
		return 1
	}
	return 2
}

// deskConfig is the config of tenant's desk sidecar: Base with the sidecar's
// own spool settings, or an error when no live hub-run serves that desk.
func (d Desks) deskConfig(tenant string) (*config.Config, error) {
	dir := filepath.Join(d.Dir, tenant, d.Box)
	raw, err := os.ReadFile(filepath.Join(dir, "spool", ".hub", "hub-run.pid"))
	if err != nil {
		return nil, fmt.Errorf("no desk %s in %s", d.Box, tenant)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 0 {
		return nil, fmt.Errorf("desk %s in %s: bad hub-run.pid", d.Box, tenant)
	}
	proc := d.ProcRoot
	if proc == "" {
		proc = "/proc"
	}
	cmd, err := os.ReadFile(filepath.Join(proc, strconv.Itoa(pid), "cmdline"))
	if err != nil || !bytes.Contains(cmd, []byte("\x00hub-run")) {
		return nil, fmt.Errorf("desk %s in %s: no live hub-run sidecar", d.Box, tenant)
	}
	envb, err := os.ReadFile(filepath.Join(proc, strconv.Itoa(pid), "environ"))
	if err != nil {
		return nil, fmt.Errorf("desk %s in %s: cannot read the sidecar's settings: %w", d.Box, tenant, err)
	}
	return sidecarConfig(d.Base, envb)
}

// sidecarConfig is base with the spool settings of one sidecar environ.
func sidecarConfig(base *config.Config, environ []byte) (*config.Config, error) {
	c := config.Config{MsgVersion: 1, LogLevel: "error"}
	if base != nil {
		c = *base
	}
	c.PinsDir, c.SubmitSocket = "", ""
	for _, kv := range bytes.Split(environ, []byte{0}) {
		k, v, _ := strings.Cut(string(kv), "=")
		switch k {
		case "SPOOL_ROOT":
			c.SpoolRoot = v
		case "SPOOL_KEYS_DIR":
			c.KeysDir = v
		case "SPOOL_PINS_DIR":
			c.PinsDir = v
		case "SPOOL_BOX_ID":
			c.BoxID = v
		case "SPOOL_HUB_URL":
			c.HubURL = v
		case "SPOOL_TENANT":
			c.Tenant = v
		}
	}
	if c.SpoolRoot == "" || c.KeysDir == "" || c.HubURL == "" || !msg.ValidBoxID(c.BoxID) {
		return nil, errors.New("the sidecar's settings lack SPOOL_ROOT, SPOOL_KEYS_DIR, SPOOL_HUB_URL or SPOOL_BOX_ID")
	}
	if c.PinsDir == "" {
		c.PinsDir = filepath.Join(c.SpoolRoot, "pins")
	}
	return &c, nil
}

// read is the first desk that holds a message of l's topic, its rows, and
// the workspaces tried; an error only when no desk could be asked at all.
func (d Desks) read(ctx context.Context, l Link) (desk, []TailRow, []string, error) {
	tail := d.Tail
	if tail == nil {
		tail = HubTail
	}
	var tried []string
	var lastErr error
	for _, k := range d.ordered(l) {
		tried = append(tried, k.tenant)
		rows, err := tail(ctx, k.cfg, l.TaskID)
		if err != nil {
			lastErr = fmt.Errorf("desk %s in %s: %w", k.cfg.BoxID, k.tenant, err)
			continue
		}
		if len(rows) > 0 {
			return k, rows, tried, nil
		}
	}
	if len(tried) == 0 {
		return desk{}, nil, nil, fmt.Errorf("topic %s: no live hub desk on this box to read it through (%s)", l.TaskID, d.where())
	}
	if lastErr != nil && len(tried) == 1 {
		return desk{}, nil, tried, lastErr
	}
	return desk{}, nil, tried, nil
}

func (d Desks) where() string {
	if d.Dir == "" {
		return "this spool is not in hub mode and no desks dir was given"
	}
	return "desk " + d.Box + " under " + d.Dir
}

// errLinkUnseen says why a link reads nothing (row A's wording, SPL-2105)
// and names what would grant it.
func errLinkUnseen(who string, l Link, tried []string) error {
	ws := l.Label
	if ws == "" {
		ws = "the link's workspace"
	}
	return fmt.Errorf("topic %s: no messages visible to %s in workspace %s; if the link is from another workspace, "+
		"this box cannot read it: a seat in %s: ask the orchestrator", l.TaskID, who, strings.Join(tried, ", "), ws)
}

// ReadLink reads the discussion a WUI link names, through this box's desks:
// a header line naming the workspace and the count, then one line per
// message (or, with asJSON, the v:1 objects as NDJSON and no header). who
// names the asker in the refusal.
func ReadLink(ctx context.Context, d Desks, who, raw string, asJSON bool) (string, error) {
	l, err := ParseLink(raw)
	if err != nil {
		return "", err
	}
	k, rows, tried, err := d.read(ctx, l)
	if err != nil {
		return "", err
	}
	if len(rows) == 0 {
		return "", errLinkUnseen(d.who(who), l, tried)
	}
	var b strings.Builder
	if !asJSON {
		fmt.Fprintf(&b, "topic %s in workspace %s, read through desk %s: %d message(s), oldest first\n",
			l.TaskID, k.tenant, k.cfg.BoxID, len(rows))
	}
	for _, r := range rows {
		m := r.Msg
		if !asJSON {
			fmt.Fprintf(&b, "%s  %s  %s@%s -> %s@%s  [%s]  %s\n", m.TS, m.MsgID, m.From, r.FromBox, m.To, r.ToBox, m.Kind, m.Body)
			continue
		}
		raw, err := msg.Marshal(m)
		if err != nil {
			return "", err
		}
		b.Write(raw)
		b.WriteByte('\n')
	}
	return b.String(), nil
}

func (d Desks) who(who string) string {
	switch {
	case who != "":
		return who
	case d.Box != "":
		return "box " + d.Box
	case d.Base != nil && d.Base.BoxID != "":
		return "box " + d.Base.BoxID
	}
	return "this box"
}

// ReplyArgs is one reply into a linked discussion.
type ReplyArgs struct {
	Seat string // the posting agent: the seated server's id
	URL  string
	Body string
	Kind string // default msg
}

// ReplyLink posts Body into the discussion URL names, as Seat, through the
// desk of the link's workspace on this box. A Seat with no seat there is
// seated first (Desks.Seat, the existing desk action): this call is the
// request. The post goes to the topic's newest human (on box-wui), else to
// its first other sender, in the same topic (spec 067 rule 2's shape).
func ReplyLink(ctx context.Context, d Desks, in ReplyArgs) (SendResult, error) {
	if in.Seat == "" {
		return SendResult{}, fmt.Errorf("a reply needs a seated server (spool mcp --as <id>): it posts as that agent, never as a person")
	}
	if strings.TrimSpace(in.Body) == "" {
		return SendResult{}, fmt.Errorf("body is required")
	}
	l, err := ParseLink(in.URL)
	if err != nil {
		return SendResult{}, err
	}
	k, rows, tried, err := d.read(ctx, l)
	if err != nil {
		return SendResult{}, err
	}
	if len(rows) == 0 {
		return SendResult{}, errLinkUnseen(in.Seat, l, tried)
	}
	if err := d.ensureSeat(ctx, k, in.Seat); err != nil {
		return SendResult{}, err
	}
	to, toBox := replyTarget(rows, in.Seat)
	send := d.Send
	if send == nil {
		send = SendCtx
	}
	kind := in.Kind
	if kind == "" {
		kind = "msg"
	}
	return send(ctx, k.cfg, SendArgs{From: in.Seat, To: to, ToBox: toBox, TaskID: l.TaskID, Kind: kind, Body: in.Body})
}

// ensureSeat seats agent on k's desk unless its seat dir is already there.
func (d Desks) ensureSeat(ctx context.Context, k desk, agent string) error {
	if _, err := os.Stat(filepath.Join(k.cfg.SpoolRoot, agent)); err == nil {
		return nil
	}
	if d.Seat == nil {
		return fmt.Errorf("%s has no seat on desk %s in workspace %s and this server seats nobody: a seat in %s: ask the orchestrator",
			agent, k.cfg.BoxID, k.tenant, k.tenant)
	}
	if err := d.Seat(ctx, k.tenant, agent); err != nil {
		return fmt.Errorf("seat %s on desk %s in workspace %s: %w", agent, k.cfg.BoxID, k.tenant, err)
	}
	return nil
}

// replyTarget is who a reply in the topic goes to: its newest human post's
// author (on box-wui, where every human lives), else its first sender that
// is not the replier, on that sender's box.
func replyTarget(rows []TailRow, self string) (to, toBox string) {
	for i := len(rows) - 1; i >= 0; i-- {
		if strings.HasPrefix(rows[i].Msg.From, "HUM-") {
			return rows[i].Msg.From, "box-wui"
		}
	}
	for _, r := range rows {
		if r.Msg.From != self {
			return r.Msg.From, r.FromBox
		}
	}
	return rows[0].Msg.To, rows[0].ToBox
}
