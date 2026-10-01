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
	// TIssue is an agent's issue request and the hub's answer (specs/039
	// contracts/issues-v1.md §6); request and reply pair on MsgID.
	TIssue = "issue"
	// TEdit is a box editing a message it sent, and the hub's answer
	// (specs/032 contracts/message-edit-v1.md §10). Without env it fetches the
	// stored envelope to re-sign; with env it applies the edit. TDelete
	// removes one. Request and reply pair on MsgID, the edited message's id.
	TEdit   = "edit"
	TDelete = "delete"
	// TArchive is a box agent archiving or unarchiving a topic by its task
	// id, and the hub's answer (CLE-77869): the box twin of the browser's
	// PUT/DELETE /v1/messages/{card}/archive. Request and reply pair on
	// MsgID, a request id the box picks.
	TArchive = "archive"
	// TBackfillEnd closes one back-fill run (SPL-987): Count messages in
	// Topics topics of channel Backfill were sent for Agents, the newest by
	// From (TaskID / MsgID name it). Sent only to a box whose hello carried
	// FeatureBackfill.
	TBackfillEnd = "backfill_end"
)

// FeatureBackfill is the hello feature of a box client that takes back-fill
// recv frames and backfill_end (SPL-987).
const FeatureBackfill = "backfill"

// FeatureFallback is the hello feature of a box client that takes recv
// frames carrying Fallback (SPL-997, specs/038 FR-033).
const FeatureFallback = "fallback"

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

// TokenFromNotAnnounced is the error token for a send whose msg.from is not
// an agent the sending box announced. A box client that hosts
// that agent re-announces and resends; any other sender cannot post as it.
const TokenFromNotAnnounced = "from_not_announced"

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
	Agents []string `json:"agents,omitempty"` // hello/announce roster; on recv: the addressed local agents (channels-v1 §4)

	// hello / announce (M3): channel subscriptions of every agent in Agents
	// (channels-v1 §3). Absent = lobby only.
	Channels []string `json:"channels,omitempty"`

	// hello (specs/020 migration.md §3): the inner msg versions this box's
	// reader accepts. Not signed (HelloPayload is unchanged); absent = [1],
	// i.e. every pre-020 box, and the hub then never pushes it a v:2.
	MsgVersions []int `json:"msg_versions,omitempty"`

	// hello (SPL-987): what this box's client understands beyond the base
	// protocol. Not signed; absent = none, and the hub then sends it no frame
	// that needs one. FeatureBackfill = recv frames carrying Backfill, and
	// the backfill_end frame.
	Features []string `json:"features,omitempty"`

	// welcome / roster / token
	Roster               map[string][]string `json:"roster,omitempty"`
	UploadToken          string              `json:"upload_token,omitempty"`
	UploadTokenExpiresAt string              `json:"upload_token_expires_at,omitempty"`

	// send / recv / tail_msg
	Env json.RawMessage `json:"env,omitempty"`

	// send (specs/036 FR-009): the HUM-* who typed this line at the sending
	// agent's terminal. A claim the hub verifies (FR-010), deliberately
	// OUTSIDE the box-signed envelope and the inner msg, which boxes decode
	// strictly; a frame is decoded leniently, so an older hub ignores it.
	// The hub never puts it on a frame to a box.
	TypedBy string `json:"typed_by,omitempty"`

	// sent
	MsgID    string `json:"msg_id,omitempty"`
	TaskID   string `json:"task_id,omitempty"`
	ToBox    string `json:"to_box,omitempty"`
	Delivery string `json:"delivery,omitempty"`

	// tail / tail_end / queue_end / backfill_end
	Follow bool `json:"follow,omitempty"`
	Count  int  `json:"count,omitempty"`

	// recv / backfill_end (SPL-987, specs/038 FR-020..): the channel whose
	// earlier posts a newly seated agent is being back-filled with. On recv
	// it marks the frame as a back-fill copy for exactly Agents (msg.to is
	// NOT added, and no per-message poke runs); backfill_end then closes the
	// run with Count messages in Topics topics, the newest From.
	Backfill string `json:"backfill,omitempty"`
	Topics   int    `json:"topics,omitempty"`
	From     string `json:"from,omitempty"`

	// recv (SPL-997, specs/038 FR-033): a human post that no agent it was
	// meant for could hear, handed to ONE fallback agent (Agents). The value
	// says where it was posted: "#<channel>" or "DM to <agent>". msg.to is
	// NOT added, and the box rings one "unanswered post in ..." poke instead
	// of the ordinary one. Sent only to a box whose hello carried
	// FeatureFallback.
	Fallback string `json:"fallback,omitempty"`

	// issue (specs/039 §6): IssueOp create | update | get | list | label |
	// comment, As the acting agent (one this box announced), IssueRef the
	// issue key, Issue the request body (issues-v1 §3) on a request and the
	// answer object on the reply, Query the list filters (§4, URL query
	// form), Body a comment's text.
	IssueOp  string          `json:"issue_op,omitempty"`
	As       string          `json:"as,omitempty"`
	IssueRef string          `json:"issue_ref,omitempty"`
	Issue    json.RawMessage `json:"issue,omitempty"`
	Query    string          `json:"query,omitempty"`
	Body     string          `json:"body,omitempty"`

	// edit reply (specs/032 §10): the register revision the edit wrote.
	Revision int `json:"revision,omitempty"`

	// archive (CLE-77869): ArchiveOp archive | unarchive on the request
	// (TaskID the topic, As the acting agent); Archive the answer object on
	// the reply - the browser route's body {msg_id, task_id, archived,
	// archived_at, archived_by}.
	ArchiveOp string          `json:"archive_op,omitempty"`
	Archive   json.RawMessage `json:"archive,omitempty"`

	// error
	Error  string `json:"error,omitempty"`
	Status int    `json:"status,omitempty"`
	Detail string `json:"detail,omitempty"`
}

// Envelope is the box-signed hub envelope (trust-modes §5). Msg is kept as the
// raw inner v:1 bytes so nothing between the signer and the verifier re-encodes
// a signed field.
//
// Channel and ParentTaskID are the optional M3 hub-envelope fields (specs/003
// contracts/channels-v1.md §2): never v:1 fields, signed only when present, so
// an envelope without them is byte-identical to a pre-M3 one.
type Envelope struct {
	FromBox      string          `json:"from_box"`
	ToBox        string          `json:"to_box"`
	Channel      string          `json:"channel,omitempty"`
	ParentTaskID string          `json:"parent_task_id,omitempty"`
	Msg          json.RawMessage `json:"msg"`
	Sig          string          `json:"sig"`
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
// jq -cS '{from_box,to_box,msg}' (OQ-03a: to_box is always present), plus
// channel and parent_task_id only when present (channels-v1 §2).
func (e *Envelope) SigningPayload() ([]byte, error) {
	p := map[string]any{"from_box": e.FromBox, "to_box": e.ToBox, "msg": e.Msg}
	if e.Channel != "" {
		p["channel"] = e.Channel
	}
	if e.ParentTaskID != "" {
		p["parent_task_id"] = e.ParentTaskID
	}
	return Canonical(p)
}

// NewEnvelope marshals m and signs the envelope with the sending box key.
func NewEnvelope(priv ed25519.PrivateKey, fromBox, toBox string, m *msg.Message) (*Envelope, error) {
	return NewEnvelopeIn(priv, fromBox, toBox, "", "", m)
}

// NewEnvelopeIn is NewEnvelope with the optional M3 channel / parent_task_id
// tags ("" = absent), both covered by the sig when present.
func NewEnvelopeIn(priv ed25519.PrivateKey, fromBox, toBox, channel, parentTaskID string, m *msg.Message) (*Envelope, error) {
	inner, err := msg.Canonical(m) // inner v:1 without sig (both modes omit it)
	if err != nil {
		return nil, err
	}
	e := &Envelope{FromBox: fromBox, ToBox: toBox, Channel: channel, ParentTaskID: parentTaskID, Msg: inner}
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

// InnerVersion is the inner msg's v without validating the rest; 0 when the
// envelope or its msg does not parse. The hub's push guard reads it
// (specs/020 migration.md §3).
func InnerVersion(raw []byte) int {
	var e struct {
		Msg struct {
			V int `json:"v"`
		} `json:"msg"`
	}
	if json.Unmarshal(raw, &e) != nil {
		return 0
	}
	return e.Msg.V
}

// InnerMsgID is the inner msg's msg_id without validating the rest; "" when
// the envelope or its msg does not parse. Cheaper than a full Inner() when the
// caller only needs to name the message it is holding (e.g. to match a reply).
func InnerMsgID(raw []byte) string {
	var e struct {
		Msg struct {
			MsgID string `json:"msg_id"`
		} `json:"msg"`
	}
	if json.Unmarshal(raw, &e) != nil {
		return ""
	}
	return e.Msg.MsgID
}

// Inner parses and validates the inner v:1 / v:2 object.
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
