// Package msg defines the canonical spool message object (v:1, and v:2 =
// v:1 as shipped, specs/020) and its serialisation, signing payload,
// validation, and on-disk filename rules.
//
// The on-disk JSON here is byte-for-byte the object that 003 (the cloud hub)
// will put on the wire, so nothing needs migrating when a hub is added.
package msg

import (
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"
)

// Schema versions. v:2 is v:1 as shipped (files[] mode/kind/path written
// down, specs/020 contracts/message-schema-v2.md): same keys, same rules.
const (
	V1 = 1
	V2 = 2
)

// Version is the default version a writer emits until the 020 migration
// flips it (contracts/migration.md P3). Writers read SPOOL_MSG_VERSION /
// SPOOL_HUB_MSG_VERSION; readers accept every Supported version.
const Version = V1

// Supported lists the versions a reader accepts; boxes advertise it in hello
// (msg_versions) so the hub never pushes them a version they would refuse.
var Supported = []int{V1, V2}

// IsSupported reports whether v is a version this reader accepts.
func IsSupported(v int) bool { return v == V1 || v == V2 }

// Schema limits (message-schema.md → 003 limits.md). Kept as named constants so
// they track the contract in one place.
const (
	MaxBodyBytes = 64 * 1024        // 64 KiB
	MaxFiles     = 16               // attachments per message
	MaxFileBytes = 32 * 1024 * 1024 // 32 MiB per file
)

// Kind enumerates the allowed message kinds. blocker and msg arrived with
// SPL-952: a blocker is a sender that cannot proceed without input, msg a
// plain message. A reader that predates them still validates the old four.
var validKinds = map[string]bool{
	"task": true, "result": true, "note": true, "reject": true,
	"blocker": true, "msg": true,
}

// KindList is validKinds for help text and error messages.
const KindList = "task|result|note|reject|blocker|msg"

// idRe matches an agent id: a 2-4 letter kind prefix and a number, e.g. CLE-07.
var idRe = regexp.MustCompile(`^[A-Z]{2,4}-\d+$`)

// LegacySender is the `from` of a legacy .md message whose sender is not an
// agent id (e.g. the orchestrator's `--ORC--` files): a valid id, so the
// synthesized object validates like any other (message-schema.md, Legacy
// bridge; spec 002 Clarifications 2026-09-19).
const LegacySender = "LGC-0"

// boxRe matches a box id ($SPOOL_BOX_ID), e.g. box-a.
var boxRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)

// Attachment is one file or directory carried by a message. Two modes:
//
//   - mode "blob": bytes were copied into $SPOOL_ROOT/files/<file_id>
//     (content-addressed). For a dir the blob is a deterministic tar and
//     file_id is the sha256 of that tar. Transferable off-box (003).
//   - mode "path": a reference to an absolute on-box path; nothing is copied.
//     Only meaningful on the same box / shared filesystem. sha256/bytes (for a
//     file) are captured at send time so a receiver can detect drift.
type Attachment struct {
	Mode   string `json:"mode"`              // "blob" | "path"
	Kind   string `json:"kind"`              // "file" | "dir"
	FileID string `json:"file_id,omitempty"` // blob only: sha256 of bytes (file) or tar (dir)
	Path   string `json:"path,omitempty"`    // path only: absolute on-box path
	Name   string `json:"name"`
	Bytes  int64  `json:"bytes,omitempty"`
	SHA256 string `json:"sha256,omitempty"` // blob: == file_id; path-file: content hash at send
}

// Message is the canonical v:1 / v:2 object (one shape, specs/020).
type Message struct {
	V      int          `json:"v"`
	MsgID  string       `json:"msg_id"`
	TaskID string       `json:"task_id"`
	TS     string       `json:"ts"`
	From   string       `json:"from"`
	To     string       `json:"to"`
	Kind   string       `json:"kind"`
	Body   string       `json:"body"`
	Files  []Attachment `json:"files"`
	Sig    string       `json:"sig,omitempty"`
}

// Canonical returns the signing payload: the object with sig removed, keys
// sorted, compact — byte-identical to `jq -cS 'del(.sig)'`. Numbers are kept
// exact via json.Number.
func Canonical(m *Message) ([]byte, error) {
	c := *m
	c.Sig = "" // omitempty tag drops it from the marshalled form
	if c.Files == nil {
		c.Files = []Attachment{} // ensure "files":[] not "files":null
	}
	raw, err := json.Marshal(&c)
	if err != nil {
		return nil, err
	}
	return sortedCompact(raw)
}

// Marshal returns the full object (including sig) in sorted-key compact form,
// which is what is written to disk.
func Marshal(m *Message) ([]byte, error) {
	c := *m
	if c.Files == nil {
		c.Files = []Attachment{}
	}
	raw, err := json.Marshal(&c)
	if err != nil {
		return nil, err
	}
	return sortedCompact(raw)
}

// sortedCompact re-encodes JSON with recursively sorted map keys, compact,
// numbers preserved exactly and no HTML escaping (== jq -cS; <>& stay literal,
// as in wire.Canonical). Files written before this held \u003c-style escapes;
// Parse reads both, and no signature covers these bytes directly (local mail
// is unsigned, and the hub envelope sig is over wire.Canonical's re-encoding).
func sortedCompact(raw []byte) ([]byte, error) {
	var any interface{}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&any); err != nil {
		return nil, err
	}
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(any); err != nil { // sorts map[string]interface{} keys
		return nil, err
	}
	return bytes.TrimRight(b.Bytes(), "\n"), nil
}

// Parse decodes a stored message, rejecting unknown top-level keys.
func Parse(raw []byte) (*Message, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var m Message
	if err := dec.Decode(&m); err != nil {
		return nil, fmt.Errorf("decode message: %w", err)
	}
	return &m, nil
}

// Validate enforces the schema rules (independent of signature).
func (m *Message) Validate() error {
	if !IsSupported(m.V) {
		return fmt.Errorf("unsupported version %d (want %d or %d)", m.V, V1, V2)
	}
	if m.MsgID == "" || m.TaskID == "" || m.TS == "" {
		return fmt.Errorf("msg_id, task_id and ts are required")
	}
	if !ValidID(m.From) {
		return fmt.Errorf("from %q is not a valid agent id", m.From)
	}
	if !ValidID(m.To) {
		return fmt.Errorf("to %q is not a valid agent id", m.To)
	}
	if !validKinds[m.Kind] {
		return fmt.Errorf("kind %q is not one of "+KindList, m.Kind)
	}
	if len(m.Body) > MaxBodyBytes {
		return fmt.Errorf("body %d bytes exceeds limit %d", len(m.Body), MaxBodyBytes)
	}
	if len(m.Files) > MaxFiles {
		return fmt.Errorf("%d files exceeds limit %d", len(m.Files), MaxFiles)
	}
	for i, f := range m.Files {
		if err := f.validate(); err != nil {
			return fmt.Errorf("files[%d]: %w", i, err)
		}
	}
	return nil
}

func (a Attachment) validate() error {
	if a.Kind != "file" && a.Kind != "dir" {
		return fmt.Errorf("kind %q is not file|dir", a.Kind)
	}
	switch a.Mode {
	case "blob":
		if a.FileID == "" {
			return fmt.Errorf("blob attachment needs file_id")
		}
		if a.SHA256 != "" && a.SHA256 != a.FileID {
			return fmt.Errorf("blob sha256 must equal file_id")
		}
	case "path":
		if a.Path == "" {
			return fmt.Errorf("path attachment needs path")
		}
	default:
		return fmt.Errorf("mode %q is not blob|path", a.Mode)
	}
	if a.Bytes > MaxFileBytes {
		return fmt.Errorf("file %q is %d bytes, exceeds limit %d", a.Name, a.Bytes, MaxFileBytes)
	}
	return nil
}

// ValidID reports whether s is a well-formed agent id.
// BOX is forbidden as a prefix: the box id lives in env, not in from/to.
func ValidID(s string) bool {
	return idRe.MatchString(s) && !strings.HasPrefix(s, "BOX-")
}

// ValidBoxID reports whether s is a well-formed box id.
func ValidBoxID(s string) bool { return boxRe.MatchString(s) }

// reservedTenants are labels a tenant may not take (006 FR-016): env labels
// that own a sub-zone of the product domain (*.dev.<domain>) and hosts the
// estate may serve itself. Not hostnames — the domain is cnf-only.
var reservedTenants = map[string]bool{
	"dev": true, "prd": true, "lde": true, "stg": true, "tst": true,
	"www": true, "api": true, "app": true, "hub": true, "wui": true,
	"admin": true, "auth": true, "login": true, "mail": true,
	"status": true, "docs": true, "help": true, "support": true,
}

// ValidTenantID reports whether s is a usable tenant DNS slug: the box-id
// alphabet (^[a-z0-9][a-z0-9-]{0,31}$) and not a reserved label. The tenant
// is the Host label, not an agent id.
func ValidTenantID(s string) bool { return boxRe.MatchString(s) && !reservedTenants[s] }

// Now returns an RFC3339 UTC timestamp with second precision.
func Now(t time.Time) string { return t.UTC().Format(time.RFC3339) }

var slugRe = regexp.MustCompile(`[^a-z0-9]+`)

// Filename builds the on-disk name <yyyymmddThhmmssZ>--<from>--<slug>.json,
// tie-breaking a same-second collision with a short msg_id fragment.
func Filename(m *Message) string {
	t, err := time.Parse(time.RFC3339, m.TS)
	if err != nil {
		t = time.Now().UTC()
	}
	stamp := t.UTC().Format("20060102T150405Z")
	slug := slugRe.ReplaceAllString(strings.ToLower(m.Body), "-")
	slug = strings.Trim(slug, "-")
	if len(slug) > 32 {
		slug = slug[:32]
	}
	if slug == "" {
		slug = m.Kind
	}
	frag := m.MsgID
	if len(frag) > 8 {
		frag = frag[:8]
	}
	return fmt.Sprintf("%s--%s--%s-%s.json", stamp, m.From, slug, frag)
}
