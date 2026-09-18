// Package wire is the hub transport vocabulary shared by the hub (internal/hub)
// and the box-side client (internal/hubclient): the WS frame shape, the
// box-signed envelope around the unchanged inner v:1 object, and the exact
// bytes each signature covers (specs/003 contracts/http-v1.md §2).
//
// Signing payloads are canonical JSON: keys sorted, compact, numbers exact,
// no HTML escaping — byte-identical to `jq -cS`.
package wire

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"fmt"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
)

// Frame types (http-v1.md §2.1).
const (
	TChallenge = "challenge"
	THello     = "hello"
	TWelcome   = "welcome"
	TAnnounce  = "announce"
	TRoster    = "roster"
	TSend      = "send"
	TSent      = "sent"
	TRecv      = "recv"
	TQueueEnd  = "queue_end"
	TTail      = "tail"
	TTailMsg   = "tail_msg"
	TTailEnd   = "tail_end"
	TToken     = "token"
	TError     = "error"
)

// Hello roles (http-v1.md §2.2).
const (
	RoleBox = "box" // the session socket: recv frames, roster, last hello wins
	RoleCLI = "cli" // a one-shot sender: never receives, never evicts
)

// Delivery values of a send result (trust-modes §8 + OQ-09).
const (
	DeliveryLocal   = "local"
	DeliverySent    = "sent"
	DeliveryQueued  = "queued"
	DeliveryPending = "pending"
)

// WS close codes (http-v1.md §2.5).
const (
	CloseBadFrame     = 4400
	CloseUnauthorized = 4401
	CloseHelloTimeout = 4408
	CloseSuperseded   = 4409
)

// Frame is every WS frame: a type discriminator plus the fields that type uses.
type Frame struct {
	Type string `json:"type"`

	// challenge / hello
	Nonce  string   `json:"nonce,omitempty"`
	BoxID  string   `json:"box_id,omitempty"`
	TS     string   `json:"ts,omitempty"`
	Sig    string   `json:"sig,omitempty"`
	Role   string   `json:"role,omitempty"`
	Agents []string `json:"agents,omitempty"`

	// welcome / roster / token
	Roster               map[string][]string `json:"roster,omitempty"`
	UploadToken          string              `json:"upload_token,omitempty"`
	UploadTokenExpiresAt string              `json:"upload_token_expires_at,omitempty"`

	// send / recv / tail_msg
	Env json.RawMessage `json:"env,omitempty"`

	// sent
	MsgID    string `json:"msg_id,omitempty"`
	TaskID   string `json:"task_id,omitempty"`
	ToBox    string `json:"to_box,omitempty"`
	Delivery string `json:"delivery,omitempty"`

	// tail / tail_end / queue_end
	Follow bool `json:"follow,omitempty"`
	Count  int  `json:"count,omitempty"`

	// error
	Error  string `json:"error,omitempty"`
	Status int    `json:"status,omitempty"`
	Detail string `json:"detail,omitempty"`
}

// Envelope is the box-signed hub envelope (trust-modes §5). Msg is kept as the
// raw inner v:1 bytes so nothing between the signer and the verifier re-encodes
// a signed field.
type Envelope struct {
	FromBox string          `json:"from_box"`
	ToBox   string          `json:"to_box"`
	Msg     json.RawMessage `json:"msg"`
	Sig     string          `json:"sig"`
}

// Canonical re-encodes any JSON value with sorted keys, compact, exact numbers
// and no HTML escaping (== jq -cS).
func Canonical(v any) ([]byte, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	var any interface{}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&any); err != nil {
		return nil, err
	}
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(any); err != nil {
		return nil, err
	}
	return bytes.TrimRight(b.Bytes(), "\n"), nil
}

// HelloPayload is the byte string a hello sig covers: jq -cS '{box_id,nonce,ts}'.
func HelloPayload(boxID, nonce, ts string) ([]byte, error) {
	return Canonical(map[string]string{"box_id": boxID, "nonce": nonce, "ts": ts})
}

// SigningPayload is the byte string an envelope sig covers:
// jq -cS '{from_box,to_box,msg}' (OQ-03a: to_box is always present).
func (e *Envelope) SigningPayload() ([]byte, error) {
	return Canonical(map[string]any{"from_box": e.FromBox, "to_box": e.ToBox, "msg": e.Msg})
}

// NewEnvelope marshals m and signs the envelope with the sending box key.
func NewEnvelope(priv ed25519.PrivateKey, fromBox, toBox string, m *msg.Message) (*Envelope, error) {
	inner, err := msg.Canonical(m) // inner v:1 without sig (both modes omit it)
	if err != nil {
		return nil, err
	}
	e := &Envelope{FromBox: fromBox, ToBox: toBox, Msg: inner}
	p, err := e.SigningPayload()
	if err != nil {
		return nil, err
	}
	e.Sig = sign.Sign(priv, p)
	return e, nil
}

// Verify checks the envelope sig against the sending box's pubkey.
func (e *Envelope) Verify(pub ed25519.PublicKey) error {
	p, err := e.SigningPayload()
	if err != nil {
		return err
	}
	return sign.Verify(pub, p, e.Sig)
}

// Marshal returns the canonical envelope bytes (what the hub stores and forwards).
func (e *Envelope) Marshal() ([]byte, error) { return Canonical(e) }

// ParseEnvelope decodes an envelope, rejecting unknown keys.
func ParseEnvelope(raw []byte) (*Envelope, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var e Envelope
	if err := dec.Decode(&e); err != nil {
		return nil, fmt.Errorf("decode envelope: %w", err)
	}
	if len(e.Msg) == 0 {
		return nil, fmt.Errorf("envelope has no msg")
	}
	return &e, nil
}

// Inner parses and validates the inner v:1 object.
func (e *Envelope) Inner() (*msg.Message, error) {
	m, err := msg.Parse(e.Msg)
	if err != nil {
		return nil, err
	}
	if err := m.Validate(); err != nil {
		return nil, err
	}
	return m, nil
}

// PinPayload is what a tenant-root pin sig covers: jq -cS '{box_id,force,pubkey,ts}'.
func PinPayload(boxID, pubkey, ts string, force bool) ([]byte, error) {
	return Canonical(map[string]any{"box_id": boxID, "force": force, "pubkey": pubkey, "ts": ts})
}

// RevokePayload is what a tenant-root revoke sig covers: jq -cS '{box_id,op:"revoke",ts}'.
func RevokePayload(boxID, ts string) ([]byte, error) {
	return Canonical(map[string]string{"box_id": boxID, "op": "revoke", "ts": ts})
}

// PinRequest is the body of POST /v1/pins.
type PinRequest struct {
	BoxID  string `json:"box_id"`
	PubKey string `json:"pubkey"`
	TS     string `json:"ts"`
	Force  bool   `json:"force"`
	Sig    string `json:"sig"`
}

// RevokeRequest is the body of DELETE /v1/pins/{box_id}.
type RevokeRequest struct {
	BoxID string `json:"box_id"`
	TS    string `json:"ts"`
	Sig   string `json:"sig"`
}

// PinEntry is one row of GET /v1/pins.
type PinEntry struct {
	BoxID  string `json:"box_id"`
	PubKey string `json:"pubkey"`
}

// PinList is the body of GET /v1/pins.
type PinList struct {
	Pins []PinEntry `json:"pins"`
}

// FileResult is the body of POST /v1/files.
type FileResult struct {
	FileID string `json:"file_id"`
	SHA256 string `json:"sha256"`
	Bytes  int64  `json:"bytes"`
}

// ErrorBody is every REST error body (error-envelope.md).
type ErrorBody struct {
	Error  string `json:"error"`
	Detail string `json:"detail,omitempty"`
}

// VerifyTokens are the hub error tokens the CLI maps to exit 78.
var VerifyTokens = map[string]bool{
	"bad_sig": true, "unpinned_box": true, "bad_nonce": true,
	"stale_hello": true, "pin_conflict": true, "stale_pin_op": true,
}
