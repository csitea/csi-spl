// Package spool implements the on-box message store: the $SPOOL_ROOT layout,
// unsigned send, recv with an at-most-once ack, and a task tail. It is the
// local, no-hub realisation of the box API (spec 002); in hub mode 003 carries
// the same inner v:1 object inside a box-signed envelope.
package spool

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
)

// Store binds the spool operations to a resolved config.
type Store struct{ cfg *config.Config }

// New returns a Store over cfg.
func New(cfg *config.Config) *Store { return &Store{cfg: cfg} }

// ensureAgent creates <id>/{inbox,outbox,archive}.
func (s *Store) ensureAgent(id string) error {
	for _, d := range []string{"inbox", "outbox", "archive"} {
		if err := os.MkdirAll(filepath.Join(s.cfg.SpoolRoot, id, d), 0o775); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) dir(id, box string) string { return filepath.Join(s.cfg.SpoolRoot, id, box) }

// Send builds an unsigned v:1 message and writes it to the recipient's inbox
// and the sender's outbox. Local mode trusts POSIX permissions on SpoolRoot: no
// key, no pin, no sig (contracts/trust-modes.md section 2).
func (s *Store) Send(from, to, taskID, kind, body string, atts []msg.Attachment) (*msg.Message, error) {
	if !msg.ValidID(from) || !msg.ValidID(to) {
		return nil, fmt.Errorf("from/to must be valid agent ids")
	}
	if taskID == "" {
		taskID = newUUID()
	}
	m := &msg.Message{
		V: msg.Version, MsgID: newUUID(), TaskID: taskID,
		TS: msg.Now(time.Now()), From: from, To: to, Kind: kind, Body: body,
		Files: atts,
	}
	if m.Files == nil {
		m.Files = []msg.Attachment{}
	}
	if err := m.Validate(); err != nil {
		return nil, err
	}

	blob, err := msg.Marshal(m)
	if err != nil {
		return nil, err
	}
	name := msg.Filename(m)
	if err := s.ensureAgent(to); err != nil {
		return nil, err
	}
	if err := s.ensureAgent(from); err != nil {
		return nil, err
	}
	if err := writeFileAtomic(filepath.Join(s.dir(to, "inbox"), name), blob, 0o664); err != nil {
		return nil, err
	}
	if err := writeFileAtomic(filepath.Join(s.dir(from, "outbox"), name), blob, 0o664); err != nil {
		return nil, err
	}
	return m, nil
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
	inbox := s.dir(as, "inbox")
	entries, err := os.ReadDir(inbox)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		ext := filepath.Ext(e.Name())
		if ext != ".json" && ext != ".md" {
			continue
		}
		names = append(names, e.Name())
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
			res.Failed++
			continue
		}
		res.Messages = append(res.Messages, m)
		if ack {
			if err := atomicMove(p, filepath.Join(s.dir(as, "archive"), name)); err != nil {
				return res, err
			}
		}
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
	if err := m.Validate(); err != nil {
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
	seen := map[string]*msg.Message{}
	for _, a := range agents {
		if !a.IsDir() || !msg.ValidID(a.Name()) {
			continue
		}
		for _, box := range []string{"inbox", "outbox", "archive"} {
			d := s.dir(a.Name(), box)
			entries, err := os.ReadDir(d)
			if err != nil {
				continue
			}
			for _, e := range entries {
				if e.IsDir() {
					continue
				}
				ext := filepath.Ext(e.Name())
				if ext != ".json" && ext != ".md" {
					continue
				}
				var m *msg.Message
				var err error
				if ext == ".md" {
					m, err = s.readLegacyMD(filepath.Join(d, e.Name()), a.Name())
				} else {
					var raw []byte
					raw, err = os.ReadFile(filepath.Join(d, e.Name()))
					if err == nil {
						m, err = msg.Parse(raw)
					}
				}
				if err != nil || m.TaskID != taskID {
					continue
				}
				seen[m.MsgID] = m // dedupe: same msg exists in inbox+outbox
			}
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
// copy+remove across filesystems.
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

func newUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant 10
	h := hex.EncodeToString(b[:])
	return fmt.Sprintf("%s-%s-%s-%s-%s", h[0:8], h[8:12], h[12:16], h[16:20], h[20:32])
}

// ExitCode maps an error to the CLI convention: 0 ok, 78 verify/refuse, 1 other.
// Local mode raises neither sign error; they are kept for hub mode (003).
func ExitCode(err error) int {
	switch {
	case err == nil:
		return 0
	case errors.Is(err, sign.ErrUnpinned), errors.Is(err, sign.ErrVerify):
		return 78
	default:
		return 1
	}
}

// readLegacyMD ingests a legacy .md message file (e.g. from ysg-box inbox-send.sh)
// wrapping it into a synthetic unsigned v:1 message with kind="note".
func (s *Store) readLegacyMD(path string, as string) (*msg.Message, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	base := filepath.Base(path)
	from := ""
	to := as
	ts := ""
	taskID := ""
	subject := ""
	body := string(raw)

	// Filename parse: <timestamp>--<from>--<subject>.md
	parts := strings.Split(strings.TrimSuffix(base, ".md"), "--")
	if len(parts) >= 2 {
		if t, err := time.Parse("20060102T150405Z", parts[0]); err == nil {
			ts = t.UTC().Format(time.RFC3339)
		} else if t, err := time.Parse("20060102-150405", parts[0]); err == nil {
			ts = t.UTC().Format(time.RFC3339)
		}
		if msg.ValidID(parts[1]) {
			from = parts[1]
		}
		if len(parts) >= 3 {
			subject = parts[2]
		}
	}

	// Frontmatter parse:
	content := string(raw)
	if strings.HasPrefix(content, "---\n") || strings.HasPrefix(content, "---\r\n") {
		delim := "\n---\n"
		idx := strings.Index(content[4:], delim)
		if idx == -1 {
			delim = "\r\n---\r\n"
			idx = strings.Index(content[4:], delim)
		}
		if idx != -1 {
			fm := content[4 : 4+idx]
			body = strings.TrimPrefix(content[4+idx+len(delim):], "\n")
			body = strings.TrimPrefix(body, "\r\n")
			for _, line := range strings.Split(fm, "\n") {
				line = strings.TrimSpace(line)
				colon := strings.Index(line, ":")
				if colon == -1 {
					continue
				}
				key := strings.ToLower(strings.TrimSpace(line[:colon]))
				val := strings.TrimSpace(line[colon+1:])
				val = strings.Trim(val, "\"'")
				switch key {
				case "from":
					if msg.ValidID(val) {
						from = val
					}
				case "to":
					if val != "" {
						to = val
					}
				case "sent":
					if t, err := time.Parse("20060102T150405Z", val); err == nil {
						ts = t.UTC().Format(time.RFC3339)
					} else if t, err := time.Parse(time.RFC3339, val); err == nil {
						ts = t.UTC().Format(time.RFC3339)
					}
				case "task_id", "task":
					if val != "" {
						taskID = val
					}
				case "subject":
					if val != "" {
						subject = val
					}
				}
			}
		}
	}

	if from == "" {
		from = "LEGACY"
	}
	if ts == "" {
		if fi, err := os.Stat(path); err == nil {
			ts = fi.ModTime().UTC().Format(time.RFC3339)
		} else {
			ts = time.Now().UTC().Format(time.RFC3339)
		}
	}
	msgID := deterministicUUID("msg:" + base + ":" + string(raw))
	if taskID == "" {
		if subject != "" {
			taskID = deterministicUUID("task:" + subject)
		} else {
			taskID = deterministicUUID("task:" + base)
		}
	}

	return &msg.Message{
		V:      msg.Version,
		MsgID:  msgID,
		TaskID: taskID,
		TS:     ts,
		From:   from,
		To:     to,
		Kind:   "note",
		Body:   body,
		Files:  []msg.Attachment{},
	}, nil
}

func deterministicUUID(data string) string {
	sum := sha256.Sum256([]byte(data))
	sum[6] = (sum[6] & 0x0f) | 0x40 // version 4
	sum[8] = (sum[8] & 0x3f) | 0x80 // variant 10
	h := hex.EncodeToString(sum[:16])
	return fmt.Sprintf("%s-%s-%s-%s-%s", h[0:8], h[8:12], h[12:16], h[16:20], h[20:32])
}
