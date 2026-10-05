// Package spool implements the on-box message store: the $SPOOL_ROOT layout,
// unsigned send, recv with an at-most-once ack, and a task tail. It is the
// local, no-hub realisation of the box API (spec 002); in hub mode 003 carries
// the same inner v:1 object inside a box-signed envelope.
package spool

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/notify"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/trace"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Store binds the spool operations to a resolved config. clock is the wall
// clock BounceRetired measures the quarantine against; nil = time.Now (tests
// set it to cross the quarantine's end without back-dating registry rows).
type Store struct {
	cfg   *config.Config
	clock func() time.Time
}

// now reads s.clock, or time.Now when no clock is set.
func (s *Store) now() time.Time {
	if s.clock != nil {
		return s.clock()
	}
	return time.Now()
}

// New returns a Store over cfg.
func New(cfg *config.Config) *Store { return &Store{cfg: cfg} }

// ensureAgent creates <id>/{inbox,outbox,archive}. Under the qualified layout
// (specs/058 6, SPOOL_DIR_LAYOUT=qualified + SPOOL_DESK_BOX) a NEW mailbox is
// the dir <id>@<box> plus the compat symlink <id> -> <id>@<box>, so every
// path built from the bare id keeps resolving; an existing <id> (dir or link)
// is used as it is.
// The three mailbox dirs under <root>/<id>/.
const (
	boxInbox   = "inbox"
	boxOutbox  = "outbox"
	boxArchive = "archive"
)

var allBoxes = []string{boxInbox, boxOutbox, boxArchive}

func (s *Store) ensureAgent(id string) error {
	if q := s.qualifiedDir(id); q != "" {
		base := filepath.Join(s.cfg.SpoolRoot, id)
		if _, err := os.Lstat(base); errors.Is(err, fs.ErrNotExist) {
			if err := os.MkdirAll(filepath.Join(s.cfg.SpoolRoot, q), 0o775); err != nil {
				return err
			}
			if err := os.Symlink(q, base); err != nil && !errors.Is(err, fs.ErrExist) {
				return err
			}
		}
	}
	for _, d := range allBoxes {
		if err := os.MkdirAll(filepath.Join(s.cfg.SpoolRoot, id, d), 0o775); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) dir(id, box string) string { return filepath.Join(s.cfg.SpoolRoot, id, box) }

// qualifiedDir is "<id>@<box>" when this root uses the qualified layout, else "".
func (s *Store) qualifiedDir(id string) string {
	if s.cfg.DirLayout != "qualified" || !msg.ValidBoxID(s.cfg.DeskBox) {
		return ""
	}
	return id + "@" + s.cfg.DeskBox
}

// AgentDirID maps a $SPOOL_ROOT entry name to the agent id it holds: "<ID>"
// (the bare layout) or "<ID>@<box>" (the qualified layout, specs/058 6).
func AgentDirID(name string) (string, bool) {
	id, box, qualified := strings.Cut(name, "@")
	if !msg.ValidID(id) || (qualified && !msg.ValidBoxID(box)) {
		return "", false
	}
	return id, true
}

// ScanAgents lists, sorted and each once, the agent ids that have a mailbox
// DIR under root: "<ID>" or "<ID>@<box>". A symlink is never counted, so the
// compat link <ID> -> <ID>@<box> does not list an agent twice. A missing root
// is an empty list. This is the $SPOOL_ROOT/*/ scan of the hub-run roster.
func ScanAgents(root string) ([]string, error) {
	ents, err := os.ReadDir(root)
	if errors.Is(err, fs.ErrNotExist) {
		return []string{}, nil
	}
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	out := []string{}
	for _, e := range ents {
		if id, ok := AgentDirID(e.Name()); ok && e.IsDir() && !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	sort.Strings(out)
	return out, nil
}

// ErrUnknownRecipient: a local-mode send to an id this root does not know
// (specs/058 N1, O3). Before it, the send minted an orphan inbox for an agent
// that lives on another machine and reported "local": the message was lost
// and the id was burnt on the sender's machine.
var ErrUnknownRecipient = errors.New("unknown_local_agent")

// KnownLocal reports whether id is an agent of this spool root: its dir
// exists, or registry.tsv (the spawn record) lists it in its first column (a
// "<box tag>: " prefix or an "@<box>" suffix there is ignored, as the
// harness's name parsers do).
func (s *Store) KnownLocal(id string) bool {
	if fi, err := os.Stat(filepath.Join(s.cfg.SpoolRoot, id)); err == nil && fi.IsDir() {
		return true
	}
	b, err := os.ReadFile(filepath.Join(s.cfg.SpoolRoot, "registry.tsv"))
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(b), "\n") {
		first, _, _ := strings.Cut(line, "\t")
		if i := strings.LastIndex(first, ": "); i >= 0 {
			first = first[i+2:]
		}
		first, _, _ = strings.Cut(first, "@")
		if strings.TrimSpace(first) == id {
			return true
		}
	}
	return false
}

// SendKnown is Send to an id KnownLocal accepts; any other id is refused with
// ErrUnknownRecipient before anything is written - or, when this machine
// retired it inside the quarantine, bounced (BounceRetired: a reject in the
// sender's inbox, ErrRetiredRecipient).
func (s *Store) SendKnown(from, to, taskID, kind, body string, atts []msg.Attachment) (*msg.Message, error) {
	if msg.ValidID(to) && !s.KnownLocal(to) {
		if _, ok := s.RetiredInQuarantine(to, time.Now().UTC()); ok {
			m, err := s.Compose(from, to, taskID, kind, body, atts)
			if err != nil {
				return nil, err
			}
			return nil, s.BounceRetired(m)
		}
		return nil, fmt.Errorf("%w: %s has no inbox under %s and is not in its registry.tsv; "+
			"it lives on another machine (spool-send.sh relays it through the hub) or does not exist; nothing was written",
			ErrUnknownRecipient, to, s.cfg.SpoolRoot)
	}
	return s.Send(from, to, taskID, kind, body, atts)
}

// Send builds an unsigned message (v = cfg.WriteVersion(), specs/020) and writes it to the recipient's inbox
// and the sender's outbox. Local mode trusts POSIX permissions on SpoolRoot: no
// key, no pin, no sig (contracts/trust-modes.md section 2).
func (s *Store) Send(from, to, taskID, kind, body string, atts []msg.Attachment) (*msg.Message, error) {
	m, err := s.Compose(from, to, taskID, kind, body, atts)
	if err != nil {
		return nil, err
	}
	if _, err := s.writeBox(m, m.To, boxInbox); err != nil {
		return nil, err
	}
	if err := s.WriteOutbox(m); err != nil {
		return nil, err
	}
	return m, nil
}

// Compose builds and validates an unsigned message without writing it.
// Hub mode (003) composes first, then decides where the message goes.
func (s *Store) Compose(from, to, taskID, kind, body string, atts []msg.Attachment) (*msg.Message, error) {
	if !msg.ValidID(from) || !msg.ValidTo(to) {
		return nil, fmt.Errorf("from/to must be valid agent ids (to may be %s)", msg.PeersID)
	}
	if taskID == "" {
		taskID = uid.New()
	}
	m := &msg.Message{
		V: s.cfg.WriteVersion(), MsgID: uid.New(), TaskID: taskID,
		TS: msg.Now(time.Now()), From: from, To: to, Kind: kind, Body: body,
		Files: atts,
	}
	if m.Files == nil {
		m.Files = []msg.Attachment{}
	}
	if err := m.Validate(); err != nil {
		return nil, err
	}
	return m, nil
}

// WriteOutbox records m in the sender's outbox.
func (s *Store) WriteOutbox(m *msg.Message) error {
	_, err := s.writeBox(m, m.From, boxOutbox)
	return err
}

// Deliver writes a message that arrived from the hub into the recipient's
// inbox, unless the same file is already in that inbox or its archive (a hub
// redelivery is shown once). It reports whether it wrote.
func (s *Store) Deliver(m *msg.Message) (bool, error) {
	return s.DeliverTo(m, m.To)
}

// DeliverTo is Deliver into agent id's inbox: a mention-routed channel
// message (specs/003 channels-v1 §4) lands with its v:1 object unchanged in
// every addressed local agent's inbox, whatever its `to` says.
func (s *Store) DeliverTo(m *msg.Message, id string) (bool, error) {
	return s.deliverTo(m, id, true)
}

// DeliverQuiet is DeliverTo without the terminal leg: a channel back-fill
// (SPL-987) writes each earlier post into the new member's inbox and then
// rings the pane ONCE with a summary, instead of once per post.
func (s *Store) DeliverQuiet(m *msg.Message, id string) (bool, error) {
	return s.deliverTo(m, id, false)
}

func (s *Store) deliverTo(m *msg.Message, id string, ring bool) (bool, error) {
	if !msg.ValidID(id) {
		return false, fmt.Errorf("to must be a valid agent id")
	}
	name := msg.Filename(m)
	for _, box := range []string{boxInbox, boxArchive} {
		if _, err := os.Stat(filepath.Join(s.dir(id, box), name)); err == nil {
			// a redelivery: the fleet copy may be the half that failed
			return false, s.bridgeFleet(m, id)
		}
	}
	wrote, err := s.writeBoxRing(m, id, boxInbox, ring)
	if err != nil {
		return wrote, err
	}
	return wrote, s.bridgeFleet(m, id)
}

// bridgeFleet writes an agent-to-agent DM the hub delivered into the same
// agent's inbox under cfg.FleetRoot (specs/058 N1): the inbox a harness agent
// reads with `spool recv`, so a peer message or a report sent from another
// machine reaches it. Only when that inbox already exists (never an orphan),
// only for a DM (id is the message's to, not a channel mention) from an
// agent (not a human or a broadcast), shown once (inbox or archive), and
// without a ring: the desk delivery above already rang the pane. An error is
// returned, not swallowed, so the hub redelivers and this half is retried.
func (s *Store) bridgeFleet(m *msg.Message, id string) error {
	root := s.cfg.FleetRoot
	if root == "" || id != m.To || !agentSender(m.From) ||
		filepath.Clean(root) == filepath.Clean(s.cfg.SpoolRoot) {
		return nil
	}
	inbox := filepath.Join(root, id, boxInbox)
	if fi, err := os.Stat(inbox); err != nil || !fi.IsDir() {
		return nil
	}
	name := msg.Filename(m)
	for _, box := range []string{boxInbox, boxArchive} {
		if _, err := os.Stat(filepath.Join(root, id, box, name)); err == nil {
			return nil
		}
	}
	blob, err := msg.Marshal(m)
	if err != nil {
		return err
	}
	if err := writeFileAtomic(filepath.Join(inbox, name), blob, 0o664); err != nil {
		return fmt.Errorf("fleet copy into %s: %w", inbox, err)
	}
	return nil
}

// agentSender: an agent id, not a human (HUM-) or the broadcast (ALL-); a
// relayed "<ID>@<box>" (WithFromAgent) is its ID's.
func agentSender(id string) bool {
	if i := strings.IndexByte(id, '@'); i >= 0 && msg.ValidBoxID(id[i+1:]) {
		id = id[:i]
	}
	return msg.ValidID(id) && !strings.HasPrefix(id, "HUM-") && !strings.HasPrefix(id, "ALL-")
}

// writeBox writes m as <id>/<box>/<filename>.
func (s *Store) writeBox(m *msg.Message, id, box string) (bool, error) {
	return s.writeBoxRing(m, id, box, true)
}

// writeBoxRing is writeBox; ring=false skips the inbox's terminal leg.
func (s *Store) writeBoxRing(m *msg.Message, id, box string, ring bool) (bool, error) {
	blob, err := msg.Marshal(m)
	if err != nil {
		return false, err
	}
	if err := s.ensureAgent(id); err != nil {
		return false, err
	}
	if err := writeFileAtomic(filepath.Join(s.dir(id, box), msg.Filename(m)), blob, 0o664); err != nil {
		return false, err
	}
	if box == boxInbox {
		// The delivery itself: from here the message survives a crash, a
		// restart and a closed socket (002). The hop table subtracts this
		// from ws_recv to price the file mailbox - the part of the design
		// the owner asked about.
		trace.Mark(trace.Event{Stage: trace.StageInboxWritten, MsgID: m.MsgID, To: id})
	}
	// specs/028 FR-001: this is the ONE place a message enters a local agent's
	// inbox, whichever hop brought it here - a same-box `spool send` (CLI or
	// the spool_send MCP tool), or the hub sidecar's Deliver/DeliverTo
	// (cross-box mail, a channel mention, a signed-in human's box-wui task).
	// Hooking it here is also what gives FR-003 for free: a redelivery that
	// DeliverTo already short-circuited never reaches this line, so a
	// reconnecting sidecar does not ring an old message a second time.
	if box == boxInbox && ring {
		// Deliver, not Run: a long-running box daemon installs a per-recipient
		// queue (notify.Start) so the terminal leg does not hold up the read
		// loop behind it; every other caller is short-lived and still runs it
		// synchronously, which is what keeps a CLI's poke alive past its exit.
		notify.Deliver(s.cfg, m, id)
	}
	return true, nil
}

// RecvResult is the outcome of a Recv: the valid messages plus how many files
// were malformed (so the caller can fail while still returning the good ones).
type RecvResult struct {
	Messages []*msg.Message
	Failed   int
}

// Recv reads as's inbox and returns the well-formed messages. Local mode trusts
// the filesystem, so no signature is checked. With ack, returned messages are
// atomically moved to archive/. A malformed file increments Failed and stays in
// place (surfaced, not silently dropped).
func (s *Store) Recv(as string, ack bool) (*RecvResult, error) {
	if !msg.ValidID(as) {
		return nil, fmt.Errorf("as must be a valid agent id")
	}
	if err := s.ensureAgent(as); err != nil {
		return nil, err
	}
	inbox := s.dir(as, boxInbox)
	entries, err := os.ReadDir(inbox)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if isMessageFile(e) {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)

	res := &RecvResult{}
	for _, name := range names {
		p := filepath.Join(inbox, name)
		var m *msg.Message
		var verr error
		if filepath.Ext(name) == ".md" {
			m, verr = s.readLegacyMD(p, as)
		} else {
			m, verr = readMessage(p)
		}
		if verr != nil {
			if errors.Is(verr, fs.ErrNotExist) {
				continue // a concurrent ack claimed it first
			}
			res.Failed++
			continue
		}
		if ack {
			// FR-006: the rename is the claim. Only the process whose rename
			// succeeded returns the message; a racing loser (ENOENT) drops it
			// silently and does not fail.
			if err := atomicMove(p, filepath.Join(s.dir(as, boxArchive), name)); err != nil {
				if errors.Is(err, fs.ErrNotExist) {
					continue
				}
				return res, err
			}
		}
		res.Messages = append(res.Messages, m)
	}
	if res.Failed > 0 {
		return res, fmt.Errorf("%d malformed message file(s) left in %s", res.Failed, inbox)
	}
	return res, nil
}

// readMessage loads and validates one stored message file.
func readMessage(path string) (*msg.Message, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	m, err := msg.Parse(raw)
	if err != nil {
		return nil, err
	}
	if err := validStored(m); err != nil {
		return nil, err
	}
	return m, nil
}

// Tail returns every message on taskID across all agents' boxes, oldest-first.
func (s *Store) Tail(taskID string) ([]*msg.Message, error) {
	agents, err := os.ReadDir(s.cfg.SpoolRoot)
	if err != nil {
		return nil, err
	}
	seen := map[string]*msg.Message{} // dedupe: same msg exists in inbox+outbox
	for _, a := range agents {
		id, ok := AgentDirID(a.Name())
		if !ok || !a.IsDir() {
			continue
		}
		for _, box := range allBoxes {
			s.tailBox(filepath.Join(s.cfg.SpoolRoot, a.Name(), box), id, taskID, seen)
		}
	}
	out := make([]*msg.Message, 0, len(seen))
	for _, m := range seen {
		out = append(out, m)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].TS != out[j].TS {
			return out[i].TS < out[j].TS
		}
		return out[i].MsgID < out[j].MsgID
	})
	return out, nil
}

// tailBox adds every readable message on taskID in one box dir of owner to
// seen, keyed by msg id. An unreadable dir or file is skipped.
func (s *Store) tailBox(dir, owner, taskID string, seen map[string]*msg.Message) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		if !isMessageFile(e) {
			continue
		}
		m, err := s.parseMessageFile(filepath.Join(dir, e.Name()), owner)
		if err == nil && m.TaskID == taskID {
			seen[m.MsgID] = m
		}
	}
}

// isMessageFile: a box holds messages as .json files and legacy .md files.
func isMessageFile(e fs.DirEntry) bool {
	ext := filepath.Ext(e.Name())
	return !e.IsDir() && (ext == ".json" || ext == ".md")
}

// parseMessageFile reads one box file: a legacy .md through the bridge, a
// .json parsed as is (Tail shows it without the Validate that Recv applies).
func (s *Store) parseMessageFile(path, owner string) (*msg.Message, error) {
	if filepath.Ext(path) == ".md" {
		return s.readLegacyMD(path, owner)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return msg.Parse(raw)
}

func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o775); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	if err := os.Chmod(tmpName, mode); err != nil {
		os.Remove(tmpName)
		return err
	}
	return os.Rename(tmpName, path)
}

// atomicMove renames within the spool (same filesystem); falls back to
// copy+remove across filesystems. Either way exactly one caller can succeed:
// rename(2), or the final remove, is the claim. The caller that loses a race
// gets an error wrapping fs.ErrNotExist (ENOENT).
func atomicMove(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o775); err != nil {
		return err
	}
	if err := os.Rename(src, dst); err == nil {
		return nil
	}
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if err := writeFileAtomic(dst, data, 0o664); err != nil {
		return err
	}
	return os.Remove(src)
}

// ExitCode maps an error to the CLI convention: 0 ok, 78 verify/refuse,
// 3 unknown local recipient (specs/058 N1), 4 a retired recipient inside its
// quarantine (specs/061 3.6), 1 other.
// Local mode raises neither sign error; they are kept for hub mode (003).
func ExitCode(err error) int {
	switch {
	case err == nil:
		return 0
	case errors.Is(err, sign.ErrUnpinned), errors.Is(err, sign.ErrVerify):
		return 78
	case errors.Is(err, ErrUnknownRecipient):
		return 3
	case errors.Is(err, ErrRetiredRecipient):
		return 4
	default:
		return 1
	}
}

// readLegacyMD ingests a legacy .md message file (e.g. from ysg-box inbox-send.sh)
// wrapping it into a synthetic unsigned v:1 message with kind="note". A sender
// that is not an agent id becomes msg.LegacySender; `to` is always the inbox
// owner; the result must pass Validate or the file is malformed.
func (s *Store) readLegacyMD(path string, as string) (*msg.Message, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	base := filepath.Base(path)
	h := parseLegacyName(base)
	body := string(raw)
	if fm, rest, ok := splitFrontmatter(body); ok {
		body = rest
		h.applyFrontmatter(fm)
	}
	if h.from == "" {
		h.from = msg.LegacySender
	}
	if h.ts == "" {
		h.ts = fileTimeOrNow(path)
	}
	if h.taskID == "" {
		h.taskID = uid.FromSeed("task:" + firstNonEmpty(h.subject, base))
	}

	m := &msg.Message{
		V:      msg.V1, // the .md bridge contract is v:1 and never leaves the box (020 FR-005)
		MsgID:  uid.FromSeed("msg:" + base + ":" + string(raw)),
		TaskID: h.taskID,
		TS:     h.ts,
		From:   h.from,
		To:     as, // the contract: the recipient whose inbox holds the file
		Kind:   "note",
		Body:   body,
		Files:  []msg.Attachment{},
	}
	// FR-015: the synthesized object is validated like any other v:1 message.
	if err := m.Validate(); err != nil {
		return nil, fmt.Errorf("legacy %s: %w", base, err)
	}
	return m, nil
}

// legacyHeader is what a legacy .md file says about itself: the file name
// first, then the frontmatter keys that override it (SPL-1032).
type legacyHeader struct {
	from, ts, taskID, subject string
}

// parseLegacyName reads <timestamp>--<from>--<subject>.md; a part that does
// not parse is left empty.
func parseLegacyName(base string) legacyHeader {
	var h legacyHeader
	parts := strings.Split(strings.TrimSuffix(base, ".md"), "--")
	if len(parts) < 2 {
		return h
	}
	h.ts = parseLegacyTime(parts[0], "20060102T150405Z", "20060102-150405")
	if msg.ValidID(parts[1]) {
		h.from = parts[1]
	}
	if len(parts) >= 3 {
		h.subject = parts[2]
	}
	return h
}

// splitFrontmatter splits a leading "---" block (LF or CRLF) off content. ok
// is false when there is no complete block: the whole content is the body.
func splitFrontmatter(content string) (fm, body string, ok bool) {
	if !strings.HasPrefix(content, "---\n") && !strings.HasPrefix(content, "---\r\n") {
		return "", content, false
	}
	delim := "\n---\n"
	idx := strings.Index(content[4:], delim)
	if idx == -1 {
		delim = "\r\n---\r\n"
		idx = strings.Index(content[4:], delim)
	}
	if idx == -1 {
		return "", content, false
	}
	body = strings.TrimPrefix(content[4+idx+len(delim):], "\n")
	return content[4 : 4+idx], strings.TrimPrefix(body, "\r\n"), true
}

// applyFrontmatter overrides h with every "key: value" line it recognises.
func (h *legacyHeader) applyFrontmatter(fm string) {
	for _, line := range strings.Split(fm, "\n") {
		key, val, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok {
			continue
		}
		h.apply(strings.ToLower(strings.TrimSpace(key)), strings.Trim(strings.TrimSpace(val), "\"'"))
	}
}

// apply sets one frontmatter key; an invalid or empty value keeps what the
// file name said.
func (h *legacyHeader) apply(key, val string) {
	switch key {
	case "from":
		if msg.ValidID(val) {
			h.from = val
		}
	case "sent":
		if ts := parseLegacyTime(val, "20060102T150405Z", time.RFC3339); ts != "" {
			h.ts = ts
		}
	case "task_id", "task":
		h.taskID = firstNonEmpty(val, h.taskID)
	case "subject":
		h.subject = firstNonEmpty(val, h.subject)
	}
}

// parseLegacyTime returns v as RFC 3339 UTC under the first layout that
// parses it, or "".
func parseLegacyTime(v string, layouts ...string) string {
	for _, l := range layouts {
		if t, err := time.Parse(l, v); err == nil {
			return t.UTC().Format(time.RFC3339)
		}
	}
	return ""
}

// fileTimeOrNow is the fallback timestamp of a file with none in its name or
// frontmatter: its mtime, or now when it cannot be stat'ed.
func fileTimeOrNow(path string) string {
	if fi, err := os.Stat(path); err == nil {
		return fi.ModTime().UTC().Format(time.RFC3339)
	}
	return time.Now().UTC().Format(time.RFC3339)
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}
