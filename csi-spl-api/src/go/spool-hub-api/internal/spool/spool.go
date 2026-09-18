// Package spool implements the on-box message store: the $SPOOL_ROOT layout,
// signed send, verified recv with an at-most-once ack, and a task tail. It is
// the local, no-hub realisation of the box API (spec 002); 003 puts the same
// v:1 object behind an HTTP hub without changing any of this.
package spool

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
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

// Send builds a v:1 message, signs it with from's private key, and writes it to
// the recipient's inbox and the sender's outbox. It refuses (sign.ErrUnpinned)
// when from is unpinned or its key is missing.
func (s *Store) Send(from, to, taskID, kind, body string, atts []msg.Attachment) (*msg.Message, error) {
	if !msg.ValidID(from) || !msg.ValidID(to) {
		return nil, fmt.Errorf("from/to must be valid agent ids")
	}
	// from must be pinned (its author identity is publishable) AND hold a key.
	if _, err := sign.LoadPin(s.cfg.PinsDir, from); err != nil {
		return nil, err
	}
	priv, err := sign.LoadPrivate(s.cfg.KeysDir, from)
	if err != nil {
		return nil, err
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
	payload, err := msg.Canonical(m)
	if err != nil {
		return nil, err
	}
	m.Sig = sign.Sign(priv, payload)

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

// RecvResult is the outcome of a Recv: the verified messages plus how many
// files failed verification (so the caller can exit 78 while still returning
// the good ones).
type RecvResult struct {
	Messages []*msg.Message
	Failed   int
}

// Recv reads as's inbox, verifies each message against the sender's pin, and
// returns the valid ones. With ack, verified messages are atomically moved to
// archive/. A verification failure increments Failed and leaves that file in
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
		if e.IsDir() || filepath.Ext(e.Name()) != ".json" {
			continue
		}
		names = append(names, e.Name())
	}
	sort.Strings(names)

	res := &RecvResult{}
	for _, name := range names {
		p := filepath.Join(inbox, name)
		m, verr := s.readVerify(p)
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
		return res, fmt.Errorf("%d message(s) failed verification: %w", res.Failed, sign.ErrVerify)
	}
	return res, nil
}

// readVerify loads and verifies one stored message file.
func (s *Store) readVerify(path string) (*msg.Message, error) {
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
	pub, err := sign.LoadPin(s.cfg.PinsDir, m.From)
	if err != nil {
		return nil, err
	}
	payload, err := msg.Canonical(m)
	if err != nil {
		return nil, err
	}
	if err := sign.Verify(pub, payload, m.Sig); err != nil {
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
				if e.IsDir() || filepath.Ext(e.Name()) != ".json" {
					continue
				}
				raw, err := os.ReadFile(filepath.Join(d, e.Name()))
				if err != nil {
					continue
				}
				m, err := msg.Parse(raw)
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
