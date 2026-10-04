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
	"slices"
	"unicode"
	"unicode/utf16"
	"unicode/utf8"

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
	// TReact is a box agent adding or removing an emoji reaction on a
	// message of a topic, and the hub's answer (CLE-77895): the box twin of
	// the browser's PUT/DELETE /v1/messages/{msg_id}/reactions. Request and
	// reply pair on MsgID, a request id the box picks.
	TReact = "react"
	// TLease is a box reading or compare-and-setting one role's fleet-wide
	// lease, and the hub's answer (CLE-77911, rdb 0094). Request and reply
	// pair on MsgID, a request id the box picks.
	TLease = "lease"
	// TLane is a box writing (lane_op put) or reading (lane_op list) the
	// fleet-wide lane map, and the hub's answer (CLE-77920, rdb 0096).
	// Request and reply pair on MsgID, a request id the box picks.
	TLane = "lane"
	// TAsk is a box recording (ask_op put), working (ack | done | decline |
	// raise | escalate | release | dead) or reading (ask_op list) an ask to the orchestrator,
	// and the hub's answer (CLE-77929, rdb 0097). Request and reply pair on
	// MsgID, a request id the box picks.
	TAsk = "ask"
	// TClaim is a peer seat locking (claim_op poll), keeping (renew), giving
	// back (release) or closing (done) messages, and the hub's answer (spec
	// 068 4.1, rdb 0110). Request and reply pair on MsgID, a request id the
	// box picks.
	TClaim = "claim"
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

// FeatureCommit is the hello feature of a box client that sends a TCommit
// frame (MsgID) once a recv frame's inbox copy is written (spec 059 §11 S2).
// The hub then keeps the delivery unacked until that frame, and sends an
// unacked row again at the next hello or after its acquisition lock. Without
// the feature a delivery counts as acked the moment its frame is written.
const FeatureCommit = "commit"

// TCommit is the box's commit of one delivery (spec 059 §11 S2): MsgID names
// it. Fire and forget: the hub sends no reply.
const TCommit = "commit"

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

// Answer-once refusals (spec 068 4.2), both 409 on a send frame that carries
// answers=<msg_id>: another post already answered that message, or the
// sender's seat is not its responsible on if_gen. `spool send --answers`
// exits with a distinct code for each.
const (
	TokenAnswered       = "answered"
	TokenNotResponsible = "not_responsible"
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

	// hello (t1 f77c9f87): what the box runs on, its OS and run-times. Not
	// signed, static per hello; absent = an older box, and the roster view
	// then omits them. The hub cuts it to size (hub/box_facts.go).
	Host *BoxHost `json:"host,omitempty"`

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

	// send (spec 068 4.2): this post answers msg Answers, sent by the seat
	// that holds it on IfGen (its responsible_gen). The hub stores it only
	// from that seat on that gen, and only once; outside the signed envelope
	// like TypedBy, and never on a frame to a box.
	Answers string `json:"answers,omitempty"`

	// send (spec 067 3.3): the channel topic this DM is about. Outside the
	// signed envelope like TypedBy: the inner msg carries it only once every
	// box reader knows the key (msg.Parse refuses unknown keys), so a box
	// claims it here. The hub keeps it only when the sender may read the
	// topic, and never puts it on a frame to a box.
	RefTaskID string `json:"ref_task_id,omitempty"`

	// sent
	MsgID    string `json:"msg_id,omitempty"`
	TaskID   string `json:"task_id,omitempty"`
	ToBox    string `json:"to_box,omitempty"`
	Delivery string `json:"delivery,omitempty"`

	// tail / tail_end / queue_end / backfill_end
	Follow bool `json:"follow,omitempty"`
	Count  int  `json:"count,omitempty"`

	// tail / tail_end (c-082): RSPCount on a tail asks only HOW MANY of the
	// task's messages a responder (an RSP-* id) sent, from ANY box, so a
	// second machine's responder sees the first one's "Seen" after a lease
	// failover. No envelope is streamed; tail_end echoes RSPCount with the
	// number in Count. A task the box holds nothing of reads 0 (the tail
	// door). An older hub ignores the flag and its tail_end lacks it.
	RSPCount bool `json:"rsp_count,omitempty"`

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

	// react (CLE-77895): ReactOp add | remove | list (read-only), Emoji the glyph, ReactMsg the
	// target message ("" = the topic's opening card) on the request (TaskID
	// the topic, As the acting agent); Reaction the answer object on the
	// reply - the browser route's body {msg_id, task_id, reactions}.
	ReactOp  string          `json:"react_op,omitempty"`
	ReactMsg string          `json:"react_msg,omitempty"`
	Emoji    string          `json:"emoji,omitempty"`
	Reaction json.RawMessage `json:"reaction,omitempty"`

	// lease (CLE-77911): LeaseOp get | cas, Fleet + LeaseRole name the lease;
	// cas also carries Holder ("<agent id>@<box>") and IfGen (the gen it
	// read, 0 = no row yet). Lease is the answer object on the reply
	// {fleet, role, holder, box, gen, age_s, won}.
	LeaseOp   string          `json:"lease_op,omitempty"`
	Fleet     string          `json:"fleet,omitempty"`
	LeaseRole string          `json:"lease_role,omitempty"`
	Holder    string          `json:"holder,omitempty"`
	IfGen     int64           `json:"if_gen,omitempty"`
	Lease     json.RawMessage `json:"lease,omitempty"`

	// lane (CLE-77920): LaneOp put | list, Fleet names the map. A put carries
	// the row in Lane {agent_id, agent_box, repo, branch, scope, files, topic,
	// state}; the reply's Lane is {fleet, lanes: [row + writer_box, updated_at, age_s]}.
	LaneOp string          `json:"lane_op,omitempty"`
	Lane   json.RawMessage `json:"lane,omitempty"`

	// ask (CLE-77929): AskOp put | list | ack | done | decline | raise |
	// escalate | release | dead (CLE-77942), Fleet names the ask book. The request's Ask is the new ask
	// (put), {ask_id, by, reason} (an update) or {all} (list); the reply's Ask
	// is {fleet, created, asks: [row + writer_box, times, age_s, quiet_s]}.
	AskOp string          `json:"ask_op,omitempty"`
	Ask   json.RawMessage `json:"ask,omitempty"`

	// claim (spec 068 4.1): ClaimOp poll | renew | release | done. The
	// request's Claim is {seat, max, ttl_s, msg_id, gen, how, reason}; the
	// reply's is {seat, msgs: [row + lock, gen, claim_n, close, not_by, msg on
	// poll], dead: [rows a poll closed dead]}.
	ClaimOp string          `json:"claim_op,omitempty"`
	Claim   json.RawMessage `json:"claim,omitempty"`

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
// and no HTML escaping (== jq -cS). It marshals v once and rewrites those bytes
// in one pass (perf round 4, G9): no decode into any and no second encode. The
// output is byte-identical to canonicalDecode, which stays as the fallback for
// anything the one pass does not recognise.
func Canonical(v any) ([]byte, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	c := canonBuf{src: raw, out: make([]byte, 0, len(raw))}
	if n, ok := c.value(0); ok && skipWS(raw, n) == len(raw) {
		return c.out, nil
	}
	return canonicalDecode(raw)
}

// canonicalDecode is the reference re-encode: decode into any (exact numbers),
// encode with sorted map keys and without HTML escaping.
func canonicalDecode(raw []byte) ([]byte, error) {
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

// canonBuf rewrites marshalled JSON (src) into its canonical form (out). mem
// is one stack of object members shared by every nesting level, tmp the
// scratch an escaped string is unescaped into.
type canonBuf struct {
	src, out, tmp []byte
	mem           []canonMember
}

// canonMember is one object member: its decoded key and where its value starts.
type canonMember struct {
	key []byte
	at  int
}

// value appends the canonical form of the value at src[i:] and returns the
// index just past it; false means src is not JSON this pass understands.
func (c *canonBuf) value(i int) (int, bool) {
	i = skipWS(c.src, i)
	if i >= len(c.src) {
		return i, false
	}
	switch c.src[i] {
	case '{':
		return c.object(i)
	case '[':
		c.out = append(c.out, '[')
		i = skipWS(c.src, i+1)
		if i < len(c.src) && c.src[i] == ']' {
			c.out = append(c.out, ']')
			return i + 1, true
		}
		for {
			var ok bool
			if i, ok = c.value(i); !ok {
				return i, false
			}
			i = skipWS(c.src, i)
			if i >= len(c.src) {
				return i, false
			}
			switch c.src[i] {
			case ',':
				c.out = append(c.out, ',')
				i++
			case ']':
				c.out = append(c.out, ']')
				return i + 1, true
			default:
				return i, false
			}
		}
	case '"':
		end, ok := scanString(c.src, i)
		if !ok {
			return end, false
		}
		if plainString(c.src[i+1 : end-1]) {
			c.out = append(c.out, c.src[i:end]...) // already canonical
			return end, true
		}
		s, ok := c.unquote(c.src[i:end])
		if !ok {
			return end, false
		}
		c.out = appendStringNoHTML(c.out, s)
		return end, true
	default:
		// numbers stay exactly as written (UseNumber), true/false/null as is
		end := i
		for end < len(c.src) && !isDelim(c.src[end]) {
			end++
		}
		if end == i {
			return i, false
		}
		c.out = append(c.out, c.src[i:end]...)
		return end, true
	}
}

// object collects the members of the object at src[i], sorts them by key
// (stable, so of two equal keys the later one wins, as in a decoded map) and
// appends them canonically.
func (c *canonBuf) object(i int) (int, bool) {
	base := len(c.mem)
	defer func() { c.mem = c.mem[:base] }()
	i = skipWS(c.src, i+1)
	if i < len(c.src) && c.src[i] == '}' {
		c.out = append(c.out, '{', '}')
		return i + 1, true
	}
	for {
		i = skipWS(c.src, i)
		if i >= len(c.src) || c.src[i] != '"' {
			return i, false
		}
		end, ok := scanString(c.src, i)
		if !ok {
			return end, false
		}
		key := c.src[i+1 : end-1]
		if !plainString(key) {
			s, ok := c.unquote(c.src[i:end])
			if !ok {
				return end, false
			}
			key = bytes.Clone(s)
		}
		i = skipWS(c.src, end)
		if i >= len(c.src) || c.src[i] != ':' {
			return i, false
		}
		at := skipWS(c.src, i+1)
		if i = skipValue(c.src, at); i < 0 {
			return at, false
		}
		c.mem = append(c.mem, canonMember{key: key, at: at})
		i = skipWS(c.src, i)
		if i >= len(c.src) {
			return i, false
		}
		if c.src[i] == '}' {
			i++
			break
		}
		if c.src[i] != ',' {
			return i, false
		}
		i++
	}
	top := len(c.mem)
	slices.SortStableFunc(c.mem[base:top], func(a, b canonMember) int { return bytes.Compare(a.key, b.key) })
	c.out = append(c.out, '{')
	first := true
	for k := base; k < top; k++ {
		if k+1 < top && bytes.Equal(c.mem[k].key, c.mem[k+1].key) {
			continue
		}
		if !first {
			c.out = append(c.out, ',')
		}
		first = false
		c.out = appendStringNoHTML(c.out, c.mem[k].key)
		c.out = append(c.out, ':')
		if _, ok := c.value(c.mem[k].at); !ok {
			return i, false
		}
	}
	c.out = append(c.out, '}')
	return i, true
}

// unquote returns the decoded bytes of the string literal lit (quotes
// included) as encoding/json decodes it: escapes resolved, invalid UTF-8 and
// lone surrogates turned into U+FFFD. A plain literal is returned in place.
func (c *canonBuf) unquote(lit []byte) ([]byte, bool) {
	s := lit[1 : len(lit)-1]
	if plainString(s) {
		return s, true
	}
	c.tmp = c.tmp[:0]
	for r := 0; r < len(s); {
		switch b := s[r]; {
		case b == '\\':
			var ok bool
			if r, ok = c.unescape(s, r); !ok {
				return nil, false
			}
		case b < utf8.RuneSelf:
			c.tmp = append(c.tmp, b)
			r++
		default:
			rr, size := utf8.DecodeRune(s[r:])
			c.tmp = utf8.AppendRune(c.tmp, rr)
			r += size
		}
	}
	return c.tmp, true
}

// unescape appends the character the escape at s[r] ('\\') stands for and
// returns the index past it; a \u surrogate pair is one character, and a
// lone surrogate is U+FFFD (as encoding/json decodes it).
func (c *canonBuf) unescape(s []byte, r int) (int, bool) {
	if r+1 >= len(s) {
		return r, false
	}
	switch e := s[r+1]; e {
	case '"', '\\', '/':
		c.tmp = append(c.tmp, e)
	case 'b':
		c.tmp = append(c.tmp, '\b')
	case 'f':
		c.tmp = append(c.tmp, '\f')
	case 'n':
		c.tmp = append(c.tmp, '\n')
	case 'r':
		c.tmp = append(c.tmp, '\r')
	case 't':
		c.tmp = append(c.tmp, '\t')
	case 'u':
		rr := getU4(s[r:])
		if rr < 0 {
			return r, false
		}
		r += 6
		if utf16.IsSurrogate(rr) {
			if dec := utf16.DecodeRune(rr, getU4(s[r:])); dec != unicode.ReplacementChar {
				c.tmp = utf8.AppendRune(c.tmp, dec)
				return r + 6, true
			}
			rr = unicode.ReplacementChar
		}
		c.tmp = utf8.AppendRune(c.tmp, rr)
		return r, true
	default:
		return r, false
	}
	return r + 2, true
}

// plainString: s holds no escape and only printable ASCII, so it decodes to
// itself and re-encodes (without HTML escaping) to itself.
func plainString(s []byte) bool {
	for _, b := range s {
		if b == '\\' || b >= utf8.RuneSelf || b < 0x20 || b == '"' {
			return false
		}
	}
	return true
}

// appendStringNoHTML is encoding/json's string encoding with SetEscapeHTML
// (false), for s that is valid UTF-8 (unquote guarantees it).
func appendStringNoHTML(dst, s []byte) []byte {
	const hex = "0123456789abcdef"
	dst = append(dst, '"')
	start := 0
	for i := 0; i < len(s); {
		b := s[i]
		if b >= utf8.RuneSelf {
			if b == 0xE2 && i+2 < len(s) && s[i+1] == 0x80 && s[i+2]&^1 == 0xA8 {
				dst = append(dst, s[start:i]...)
				dst = append(dst, '\\', 'u', '2', '0', '2', hex[s[i+2]&0xF])
				i += 3
				start = i
				continue
			}
			i++
			continue
		}
		if b >= 0x20 && b != '"' && b != '\\' {
			i++
			continue
		}
		dst = append(dst, s[start:i]...)
		switch b {
		case '\\', '"':
			dst = append(dst, '\\', b)
		case '\b':
			dst = append(dst, '\\', 'b')
		case '\f':
			dst = append(dst, '\\', 'f')
		case '\n':
			dst = append(dst, '\\', 'n')
		case '\r':
			dst = append(dst, '\\', 'r')
		case '\t':
			dst = append(dst, '\\', 't')
		default:
			dst = append(dst, '\\', 'u', '0', '0', hex[b>>4], hex[b&0xF])
		}
		i++
		start = i
	}
	dst = append(dst, s[start:]...)
	return append(dst, '"')
}

// getU4 decodes the \uXXXX at the start of s, or returns -1.
func getU4(s []byte) rune {
	if len(s) < 6 || s[0] != '\\' || s[1] != 'u' {
		return -1
	}
	var r rune
	for _, c := range s[2:6] {
		switch {
		case '0' <= c && c <= '9':
			c -= '0'
		case 'a' <= c && c <= 'f':
			c = c - 'a' + 10
		case 'A' <= c && c <= 'F':
			c = c - 'A' + 10
		default:
			return -1
		}
		r = r*16 + rune(c)
	}
	return r
}

// scanString returns the index just past the string literal at s[i] ('"').
func scanString(s []byte, i int) (int, bool) {
	for j := i + 1; j < len(s); j++ {
		switch s[j] {
		case '\\':
			j++
		case '"':
			return j + 1, true
		}
	}
	return len(s), false
}

// skipValue returns the index just past the JSON value at s[i], or -1.
func skipValue(s []byte, i int) int {
	if i >= len(s) {
		return -1
	}
	switch s[i] {
	case '"':
		end, ok := scanString(s, i)
		if !ok {
			return -1
		}
		return end
	case '{', '[':
		depth := 0
		for j := i; j < len(s); j++ {
			switch s[j] {
			case '"':
				end, ok := scanString(s, j)
				if !ok {
					return -1
				}
				j = end - 1
			case '{', '[':
				depth++
			case '}', ']':
				if depth--; depth == 0 {
					return j + 1
				}
			}
		}
		return -1
	default:
		j := i
		for j < len(s) && !isDelim(s[j]) {
			j++
		}
		if j == i {
			return -1
		}
		return j
	}
}

func skipWS(s []byte, i int) int {
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') {
		i++
	}
	return i
}

func isDelim(b byte) bool {
	return b == ',' || b == '}' || b == ']' || b == ':' || b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

// BoxHost is a box's own report of what it runs on, sent on its hello.
// Runtimes maps a run-time or CLI name (go, node, docker, claude, ...) to its
// version; one the box does not have is absent, never "unknown".
type BoxHost struct {
	OS       *HostOS           `json:"os,omitempty"`
	Runtimes map[string]string `json:"runtimes,omitempty"`
}

// HostOS is the box's operating system; an empty field is one it could not read.
type HostOS struct {
	Name    string `json:"name,omitempty"`
	Version string `json:"version,omitempty"`
	Kernel  string `json:"kernel,omitempty"`
	Arch    string `json:"arch,omitempty"`
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
