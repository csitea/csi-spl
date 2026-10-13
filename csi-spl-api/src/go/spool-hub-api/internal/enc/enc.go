// Package enc seals a spool message of an `enc` workspace into its v:3 form
// and opens it again (spec 136 section 3.1): age X25519 recipients inside the
// binary, no external process, no keyring. Sealing needs public recipients
// only; opening needs an identity named in `for`, and binds the clear header
// to its sealed copy: a rewritten header or a `ct` replayed under another
// msg_id is refused (FR13).
package enc

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"

	"filippo.io/age"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// ErrNotRecipient: none of the given identities opens the message.
var ErrNotRecipient = errors.New("not a recipient of this sealed message")

// ErrHeaderMismatch: the clear header differs from its sealed copy. The
// caller exits 6 with `HEADER MISMATCH <msg_id>` and shows nothing.
var ErrHeaderMismatch = errors.New("HEADER MISMATCH")

// Recipient is one identity a message is sealed for: its participant id (the
// `for` entry) and its age public key.
type Recipient struct {
	ID  string
	Key age.Recipient
}

// ParseRecipient reads an X25519 recipient (`age1…`) for participant id.
func ParseRecipient(id, pub string) (Recipient, error) {
	if !msg.ValidID(id) {
		return Recipient{}, fmt.Errorf("recipient id %q is not a valid participant id", id)
	}
	k, err := age.ParseX25519Recipient(pub)
	if err != nil {
		return Recipient{}, fmt.Errorf("recipient %s: %w", id, err)
	}
	return Recipient{ID: id, Key: k}, nil
}

// inner is the sealed plaintext: the six header fields, the body and the
// attachment metadata (spec 136 3.1). ref_task_id and accepts ride inside
// too, omitted while empty, so opening gives back the message that was sealed.
type inner struct {
	MsgID     string           `json:"msg_id"`
	TaskID    string           `json:"task_id"`
	TS        string           `json:"ts"`
	From      string           `json:"from"`
	To        string           `json:"to"`
	Kind      string           `json:"kind"`
	Body      string           `json:"body"`
	Files     []msg.Attachment `json:"files"`
	RefTaskID string           `json:"ref_task_id,omitempty"`
	Accepts   string           `json:"accepts,omitempty"`
}

// Seal validates m (MaxBodyBytes is checked on the clear body) and returns its
// v:3 form, openable by every recipient and listing them, in order, in `for`.
func Seal(m *msg.Message, rcpts []Recipient) (*msg.Sealed, error) {
	if err := m.Validate(); err != nil {
		return nil, err
	}
	if len(rcpts) == 0 {
		return nil, errors.New("seal: no recipient")
	}
	plain, err := json.Marshal(innerOf(m))
	if err != nil {
		return nil, err
	}
	keys := make([]age.Recipient, 0, len(rcpts))
	ids := make([]string, 0, len(rcpts))
	for _, r := range rcpts {
		keys = append(keys, r.Key)
		ids = append(ids, r.ID)
	}
	var ct bytes.Buffer
	w, err := age.Encrypt(&ct, keys...)
	if err != nil {
		return nil, fmt.Errorf("seal: %w", err)
	}
	if _, err := w.Write(plain); err != nil {
		return nil, fmt.Errorf("seal: %w", err)
	}
	if err := w.Close(); err != nil {
		return nil, fmt.Errorf("seal: %w", err)
	}
	s := &msg.Sealed{
		V: msg.V3, MsgID: m.MsgID, TaskID: m.TaskID, TS: m.TS, From: m.From,
		To: m.To, Kind: m.Kind, Enc: msg.SealScheme, For: ids,
		CT: base64.StdEncoding.EncodeToString(ct.Bytes()), Files: []msg.Attachment{},
	}
	return s, s.Validate()
}

// Open decrypts s with the first identity that fits and returns the message,
// built from the sealed (inner) values only. It refuses a header that differs
// from its sealed copy (ErrHeaderMismatch) and an identity set that opens
// nothing (ErrNotRecipient).
func Open(s *msg.Sealed, ids ...age.Identity) (*msg.Message, error) {
	if err := s.Validate(); err != nil {
		return nil, err
	}
	ct, err := base64.StdEncoding.DecodeString(s.CT)
	if err != nil {
		return nil, fmt.Errorf("open %s: ct: %w", s.MsgID, err)
	}
	r, err := age.Decrypt(bytes.NewReader(ct), ids...)
	if err != nil {
		var none *age.NoIdentityMatchError
		if errors.As(err, &none) {
			return nil, ErrNotRecipient
		}
		return nil, fmt.Errorf("open %s: %w", s.MsgID, err)
	}
	plain, err := io.ReadAll(io.LimitReader(r, msg.MaxSealedCTBytes))
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", s.MsgID, err)
	}
	in, err := parseInner(plain)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", s.MsgID, err)
	}
	if !sameHeader(s, in) {
		return nil, fmt.Errorf("%w %s", ErrHeaderMismatch, s.MsgID)
	}
	m := in.message()
	return m, m.Validate()
}

func innerOf(m *msg.Message) inner {
	files := m.Files
	if files == nil {
		files = []msg.Attachment{}
	}
	return inner{
		MsgID: m.MsgID, TaskID: m.TaskID, TS: m.TS, From: m.From, To: m.To,
		Kind: m.Kind, Body: m.Body, Files: files, RefTaskID: m.RefTaskID, Accepts: m.Accepts,
	}
}

func parseInner(plain []byte) (*inner, error) {
	dec := json.NewDecoder(bytes.NewReader(plain))
	dec.DisallowUnknownFields()
	var in inner
	if err := dec.Decode(&in); err != nil {
		return nil, fmt.Errorf("sealed body: %w", err)
	}
	return &in, nil
}

func sameHeader(s *msg.Sealed, in *inner) bool {
	return s.MsgID == in.MsgID && s.TaskID == in.TaskID && s.TS == in.TS &&
		s.From == in.From && s.To == in.To && s.Kind == in.Kind
}

func (in *inner) message() *msg.Message {
	return &msg.Message{
		V: msg.Version, MsgID: in.MsgID, TaskID: in.TaskID, TS: in.TS, From: in.From,
		To: in.To, Kind: in.Kind, Body: in.Body, Files: in.Files,
		RefTaskID: in.RefTaskID, Accepts: in.Accepts,
	}
}
