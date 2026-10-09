// Package agentid is the one place the Go module knows what an agent id looks
// like (spec 061 FR-001): the new grammar c-004, the letter-to-kind map, the
// legacy grammar CLE-77952, and the instant legacy ids stop being accepted on
// a write path. Every validation site calls it; no other file carries an id
// regex.
//
//	agent id          ^[acgmq]-[0-9]{3}$       c-004 (000 is never an id)
//	legacy agent id   ^(CLE|AGY|GRK|QWN)-[0-9]+$ until LegacyUntil
//	participant       an agent id, or ^[A-Z]{2,4}-[0-9]+$ (HUM-, GST-, BOX-,
//	                  and every stored legacy id: history keeps them, FR-006)
package agentid

import (
	"fmt"
	"regexp"
	"strings"
	"testing"
	"time"
)

// LegacyUntilText is the deadline (spec 061 section 0; the owner moved it a
// day, to 2026-10-03, on 2026-10-02 ~06:50Z): after it a legacy
// agent id is refused on every write path (FR-003). The bash
// SPOOL_LEGACY_ID_UNTIL and the WUI LEGACY_ID_UNTIL copy this value (FR-005).
const LegacyUntilText = "2026-10-03T20:59:59Z"

// Responder is the non-AI responder's agent id, the same on every box-rsp /
// sat-rsp desk. It was RSP-01 until the legacy cutoff refused that id; the
// bash SPL_RSP_AGENT (csi-spl-orc/lib/bash/funcs/spl-desk-agents.func.sh) is
// its copy, and desk-agent-ids.tst.sh fails when the two differ.
const Responder = "c-684"

// IsResponder reports whether id is the responder: Responder, or the legacy
// RSP-* form history keeps (FR-006).
func IsResponder(id string) bool { return id == Responder || strings.HasPrefix(id, "RSP-") }

// LegacyUntil is LegacyUntilText as an instant.
var LegacyUntil = time.Date(2026, 10, 3, 20, 59, 59, 0, time.UTC)

// Now is the clock the deadline reads (FR-004). Under `go test` it stands one
// hour before LegacyUntil, so a fixture that still carries a legacy literal
// never turns red at the deadline on its own; a test of the cutoff sets Now.
var Now = defaultNow

func defaultNow() time.Time {
	if testing.Testing() {
		return LegacyUntil.Add(-time.Hour)
	}
	return time.Now()
}

var (
	newRe         = regexp.MustCompile(`^[acgmq]-[0-9]{3}$`)
	newAnyCaseRe  = regexp.MustCompile(`^[ACGMQacgmq]-[0-9]{3}$`)
	legacyRe      = regexp.MustCompile(`^(CLE|AGY|GRK|QWN)-[0-9]+$`)
	participantRe = regexp.MustCompile(`^[A-Z]{2,4}-[0-9]+$`)
	boxRe         = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)
)

// kinds is the one letter-to-kind map; legacyKinds is its legacy twin. 'm'
// (spec 110) has no legacy twin: legacy ids ended before mistral joined.
var (
	kinds       = map[byte]string{'a': "agy", 'c': "claude", 'g': "grok", 'm': "mistral", 'q': "qwen"}
	legacyKinds = map[string]string{"AGY": "agy", "CLE": "claude", "GRK": "grok", "QWN": "qwen"}
)

// IsNew reports whether s is an agent id in the new grammar (c-004).
func IsNew(s string) bool { return newRe.MatchString(s) && !strings.HasSuffix(s, "-000") }

// IsLegacy reports whether s is a legacy agent id (CLE-77952).
func IsLegacy(s string) bool { return legacyRe.MatchString(s) }

// IsAgent reports whether s is an agent id in either grammar.
func IsAgent(s string) bool { return IsNew(s) || IsLegacy(s) }

// IsParticipant reports whether s may stand in from / to / a roster: an agent
// id in either grammar, or any other participant (HUM-17, GST-3, LGC-0).
func IsParticipant(s string) bool { return IsNew(s) || participantRe.MatchString(s) }

// Number is the digits of a participant id ("" when s has no dash).
func Number(s string) string {
	if i := strings.LastIndexByte(s, '-'); i >= 0 {
		return s[i+1:]
	}
	return ""
}

// SplitAtBox splits "<id>@<box>" (spec 058); box is "" without an @.
func SplitAtBox(s string) (id, box string) {
	id, box, _ = strings.Cut(s, "@")
	return id, box
}

// IsAtBox reports whether s is "<participant>@<box>" (a lease holder).
func IsAtBox(s string) bool {
	id, box := SplitAtBox(s)
	return strings.Contains(s, "@") && IsParticipant(id) && boxRe.MatchString(box)
}

// Kind is the agent kind of an id in either grammar: agy, claude, grok,
// qwen; "" for anything else.
func Kind(s string) string {
	id, _ := SplitAtBox(s)
	if IsNew(id) {
		return kinds[id[0]]
	}
	if IsLegacy(id) {
		return legacyKinds[id[:3]]
	}
	return ""
}

// Normalize is the one edge normalisation (spec 061 section 2): a new-form
// id in any case becomes lower case (C-004 -> c-004), a box suffix is kept.
// Everything else comes back unchanged.
func Normalize(s string) string {
	s = strings.TrimSpace(s)
	id, box := SplitAtBox(s)
	if newAnyCaseRe.MatchString(id) {
		id = strings.ToLower(id)
	}
	if strings.Contains(s, "@") {
		return id + "@" + box
	}
	return id
}

// Expired reports whether legacy ids are past LegacyUntil on clock Now.
func Expired() bool { return Now().After(LegacyUntil) }

// RetiredError is the FR-003 refusal of a legacy id after the deadline.
type RetiredError struct {
	ID  string // the legacy id refused
	New string // its alias, "" when the table has none
}

func (e *RetiredError) Error() string {
	use := e.New
	if use == "" {
		use = string(Letter(e.ID)) + "-NNN"
	}
	return fmt.Sprintf("%s is retired as an id; use %s", e.ID, use)
}

// Letter is the new-grammar letter of a legacy id's kind ('c' for CLE-).
func Letter(legacy string) byte {
	for l, k := range kinds {
		if legacyKinds[strings.SplitN(legacy, "-", 2)[0]] == k {
			return l
		}
	}
	return 'c'
}

// Lookup reads one alias, keyed (legacy id, box) -> new id on that same box
// (owner 2026-10-02: no bands, c-NNN@<box> is the unique name). box "" means
// the caller does not know it: the table answers only when the legacy id has
// one row. ok false when it has none. A nil Lookup is an empty table.
type Lookup func(legacy, box string) (newID string, ok bool)

// Table is an alias table in memory, keyed (legacy id, box).
type Table map[[2]string]string

// Lookup answers for (old, box); with box "" only a legacy id that has one
// row answers.
func (t Table) Lookup(old, box string) (string, bool) {
	if box != "" {
		n, ok := t[[2]string{old, box}]
		return n, ok
	}
	found, n := "", 0
	for k, v := range t {
		if k[0] == old {
			found, n = v, n+1
		}
	}
	return found, n == 1
}

// Resolve is the edge rule (FR-002 / FR-003) for one id or "<id>@<box>":
// normalised; a legacy agent id becomes its alias, or stays itself when the
// table has none, until LegacyUntil; after it a legacy agent id is a
// *RetiredError naming the alias. Anything that is not a legacy agent id
// passes through normalised.
func Resolve(s string, lookup Lookup) (string, error) { return ResolveOn(s, "", lookup) }

// ResolveOn is Resolve for a bare id whose box the caller knows from
// elsewhere (a lane row's agent_box): the alias is looked up on onBox.
func ResolveOn(s, onBox string, lookup Lookup) (string, error) {
	s = Normalize(s)
	id, box := SplitAtBox(s)
	if !IsLegacy(id) {
		return s, nil
	}
	if box == "" {
		box = onBox
	}
	newID, ok := "", false
	if lookup != nil {
		newID, ok = lookup(id, box)
	}
	if Expired() {
		return "", &RetiredError{ID: id, New: newID}
	}
	if !ok || !IsNew(newID) {
		return s, nil
	}
	if strings.Contains(s, "@") {
		return newID + "@" + box, nil
	}
	return newID, nil // the box stays the caller's
}

// Check is Resolve's refusal alone, for an id the caller may not rewrite (a
// signed envelope's from / to): nil before the deadline, or when s is not a
// legacy agent id.
func Check(s string, lookup Lookup) error {
	if !Expired() || !IsLegacy(Normalize(strings.SplitN(s, "@", 2)[0])) {
		return nil // no table read on the hot path before the deadline
	}
	_, err := Resolve(s, lookup)
	return err
}
