// SPDX-License-Identifier: AGPL-3.0-only

// Package evlog groups and redacts backend errors for the System event log
// (spec 162 section 10.4.1, SPL-5882). It is pure: no store, no HTTP, so the
// hub (source a) and the box reader (source b) group and redact one way.
//
// Redact removes secrets and personal strings (10.6). Normalize redacts,
// then folds the parts that vary between two sightings of one error (ids,
// numbers, quoted values), so Fingerprint is equal for both. TopFrame takes
// the first frame of this module from a Go stack. Groups is a bounded map
// of sightings with the caps of 10.4.5.
package evlog

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Kinds and levels this package writes itself (10.3).
const (
	KindOverflow = "evlog.overflow"
	LevelError   = "error"
	LevelWarn    = "warn"
)

// The caps of 10.4.5.
const (
	CapInProcess = 1000 // open groups between two hub flushes
	CapReader    = 500  // groups in one reader frame
)

// MaxMessageRunes is rdb 0240's `message` cap; Normalize cuts to it.
const MaxMessageRunes = 800

// ModulePrefix marks this module's frames in a Go stack (TopFrame).
const ModulePrefix = "github.com/csitea/csi-spl/"

// rule is one replacement of Redact or Normalize, applied in order.
type rule struct {
	re  *regexp.Regexp
	rep string
}

// redactRules are the rules of 10.6, most specific first: a PEM block or a
// DSN before the URL and key rules that would cut it in parts, a URL's
// query before its userinfo (the userinfo placeholder holds `<`, which ends
// the query rule's URL), the userinfo of a URL before the email rule. A key
// or its value may sit in escaped quotes (\" of a Go %q of a JSON body);
// a quoted value keeps its own escaped quotes, and an unquoted value its
// backslashes, so a secret with either is redacted whole. The long-run rule (blobRe) runs last, so
// the placeholders here (they hold `<` and `>`) end every run they replaced.
var redactRules = []rule{
	{regexp.MustCompile(`-----BEGIN [A-Z0-9 ]+-----(?s:.*?)(?:-----END [A-Z0-9 ]+-----|\z)`), "<pem>"},
	{regexp.MustCompile(`(?i)\bpostgres(?:ql)?://[^\s"'<>]+`), "<dsn>"},
	{regexp.MustCompile(`(?i)\b(?:host|hostaddr)=\S+(?:\s+(?:port|user|password|dbname|sslmode|connect_timeout|application_name)=\S+)+`), "<dsn>"},
	{regexp.MustCompile(`(?i)\b([a-z][a-z0-9+.-]*://[^\s?#"'<>]*)\?[^\s#"'<>]+`), "$1?<q>"},
	{regexp.MustCompile(`//[^\s/?#@"'<>]+@`), "//<redacted>@"},
	{regexp.MustCompile(`\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*`), "<jwt>"},
	{regexp.MustCompile(`[\p{L}\p{N}._%+-]+@[\p{L}\p{N}-]+(?:\.[\p{L}\p{N}-]+)*\.\p{L}{2,}`), "<email>"},
	{regexp.MustCompile(`(?i)\b(bearer)\s+[^\s"',;<>]+`), "$1 <redacted>"},
	{regexp.MustCompile(`(?i)\b((?:set-)?cookie\s*:\s*)[^"'\s][^\r\n]*`), "$1<redacted>"},
	{regexp.MustCompile(`(?i)([A-Za-z0-9_-]*(?:token|key|secret|password|passwd|pwd|credential|sig|signature|authorization|cookie|dsn)(?:\\?["'])?\s*[:=]\s*)(?:(?:bearer|basic|digest|token)\s+)?(?:\\"(?:[^"\\]|\\[^"])*?\\"|\\'(?:[^'\\]|\\[^'])*?\\'|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|(?:[^\s"',;&}<>\\]|\\[^"'\s])+)`), "$1<redacted>"},
}

// blobRe is the last rule of 10.6: a run of 24+ token characters. A run
// that is exactly a UUID is kept: it is an id, not a secret, and Normalize
// folds it to <uuid>.
var (
	blobRe = regexp.MustCompile(`[A-Za-z0-9+/_=-]{24,}`)
	uuidRe = regexp.MustCompile(`(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b`)
)

// Redact removes from s every secret and personal string of spec 162
// section 10.6. It runs on every text that reaches a row and on the box's
// frame before it leaves the box.
func Redact(s string) string {
	for _, r := range redactRules {
		s = r.re.ReplaceAllString(s, r.rep)
	}
	return blobRe.ReplaceAllStringFunc(s, func(m string) string {
		if uuidRe.FindString(m) == m {
			return m
		}
		return "<blob>"
	})
}

// normalizeRules fold what varies between two sightings of one error, in
// the order of 10.4.1. A single quote opens a value only after a non-word
// character, so an apostrophe (can't) is not a quote; a doubled quote
// inside a value (SQL's escape of a quote) stays in the value, so
// Normalize is idempotent: Normalize(Normalize(s)) == Normalize(s).
var normalizeRules = []rule{
	{uuidRe, "<uuid>"},
	{regexp.MustCompile(`\bHUM-[0-9]+\b`), "HUM-<n>"},
	{regexp.MustCompile(`\b[acgmoqu]-[0-9]{3}\b`), "<agent>"},
	{regexp.MustCompile(`\b[0-9a-fA-F]{8,}\b`), "<hex>"},
	{regexp.MustCompile(`[0-9]+`), "<n>"},
	{regexp.MustCompile(`"(?:[^"\\]|\\.|"")*"`), "<s>"},
	{regexp.MustCompile(`(^|[^A-Za-z0-9_])'(?:[^'\n]|'')*'`), "$1<s>"},
	{regexp.MustCompile(`\s+`), " "},
}

// Normalize redacts s, then replaces each UUID with <uuid>, HUM-<digits>
// with HUM-<n>, an agent id with <agent>, a run of 8+ hex digits with
// <hex>, every other number with <n> and each quoted string with <s>;
// collapses blanks and cuts to MaxMessageRunes runes. A placeholder can
// open a word boundary a rule then matches (X0AAAAAAAA -> X<n>AAAAAAAA ->
// X<n><hex>), so the pass repeats until the text holds still, at most
// normalizePasses times: Normalize(Normalize(s)) == Normalize(s), and a
// group's stored Message hashes to its Fingerprint.
func Normalize(s string) string {
	for i := 0; i < normalizePasses; i++ {
		n := normalizeOnce(s)
		if n == s {
			break
		}
		s = n
	}
	return s
}

// normalizePasses bounds Normalize's repeat; two or three passes are the
// most any input of the fuzz seeds needed.
const normalizePasses = 8

func normalizeOnce(s string) string {
	s = Redact(s)
	for _, r := range normalizeRules {
		s = r.re.ReplaceAllString(s, r.rep)
	}
	s = strings.TrimSpace(s)
	if r := []rune(s); len(r) > MaxMessageRunes {
		s = strings.TrimSpace(string(r[:MaxMessageRunes]))
	}
	return s
}

// frameArgs is the argument list Go prints after a function in a stack.
var frameArgs = regexp.MustCompile(`\([^()]*\)$`)

// TopFrame is the first function of this module in a Go stack (the text of
// debug.Stack or a panic dump), without its arguments, file or line, so a
// release that moves lines keeps one group. Frames above the last panic(
// line are the recovery's own (the deferred func that took the stack), so
// the search starts below it. "" when no frame of this module is there.
func TopFrame(stack string) string {
	lines := strings.Split(stack, "\n")
	start := 0
	for i, l := range lines {
		if strings.HasPrefix(l, "panic(") {
			start = i + 1
		}
	}
	for _, l := range lines[start:] {
		l = strings.TrimRight(l, "\r")
		if strings.HasPrefix(l, ModulePrefix) {
			return frameArgs.ReplaceAllString(l, "")
		}
	}
	return ""
}

// Fingerprint is the first 16 hex of sha256(kind NUL Normalize(msg) NUL
// anchor). The anchor is the route and token of a 5xx, TopFrame of a
// panic, the loop name of a loop panic, the calling function of an
// error.log line and the class name of a Cloud Run kind (10.4.1).
func Fingerprint(kind, msg, anchor string) string {
	sum := sha256.Sum256([]byte(kind + "\x00" + Normalize(msg) + "\x00" + anchor))
	return hex.EncodeToString(sum[:])[:16]
}

// Group is one error group: one row of the System log for life (10.5).
// Message is already through Normalize; N counts the sightings.
type Group struct {
	Kind, Level, Message, Fingerprint string
	FirstAt, LastAt                   time.Time
	N                                 int
}

// Sighting is one occurrence of an error, before grouping.
type Sighting struct {
	Kind, Level, Message, Anchor string
	At                           time.Time
}

// Groups is a bounded map of groups, safe for concurrent use: Add opens a
// group or adds a sighting to one; past the cap a new fingerprint is
// counted, not kept, and Take reports the count as one evlog.overflow
// group (10.4.5).
type Groups struct {
	mu      sync.Mutex
	limit   int
	byFP    map[string]*Group
	order   []string
	dropped map[string]bool
	extra   int // sightings of new fingerprints once dropped is full itself
}

// NewGroups returns an empty Groups that keeps at most limit groups
// (CapInProcess in the hub, CapReader in the box reader).
func NewGroups(limit int) *Groups {
	return &Groups{limit: limit, byFP: map[string]*Group{}, dropped: map[string]bool{}}
}

// Add records one sighting and returns its group's fingerprint and whether
// the group is kept (false: past the cap, counted into the overflow).
func (g *Groups) Add(s Sighting) (string, bool) {
	msg := Normalize(s.Message)
	fp := Fingerprint(s.Kind, s.Message, s.Anchor)
	g.mu.Lock()
	defer g.mu.Unlock()
	if gr, ok := g.byFP[fp]; ok {
		gr.N++
		gr.FirstAt, gr.LastAt = minTime(gr.FirstAt, s.At), maxTime(gr.LastAt, s.At)
		return fp, true
	}
	if len(g.byFP) >= g.limit {
		g.drop(fp)
		return fp, false
	}
	g.byFP[fp] = &Group{Kind: s.Kind, Level: s.Level, Message: msg, Fingerprint: fp, FirstAt: s.At, LastAt: s.At, N: 1}
	g.order = append(g.order, fp)
	return fp, true
}

// drop counts fp as one group not kept. The set of dropped fingerprints is
// bounded by the cap too; past it each further sighting counts once.
func (g *Groups) drop(fp string) {
	if g.dropped[fp] {
		return
	}
	if len(g.dropped) < g.limit {
		g.dropped[fp] = true
		return
	}
	g.extra++
}

// Len is the number of groups kept now.
func (g *Groups) Len() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.byFP)
}

// Take returns the groups in the order they were opened, plus one
// evlog.overflow group when any were dropped, and empties g.
func (g *Groups) Take(at time.Time) []Group {
	g.mu.Lock()
	defer g.mu.Unlock()
	out := make([]Group, 0, len(g.order)+1)
	for _, fp := range g.order {
		out = append(out, *g.byFP[fp])
	}
	if n := len(g.dropped) + g.extra; n > 0 {
		out = append(out, OverflowGroup(n, g.limit, at))
	}
	g.byFP, g.order, g.dropped, g.extra = map[string]*Group{}, nil, map[string]bool{}, 0
	return out
}

// OverflowGroup is the evlog.overflow row of 10.4.5: n groups not kept
// under limit. Its fingerprint is fixed per limit, so every overflow of
// one source is one row whose N adds up the groups dropped.
func OverflowGroup(n, limit int, at time.Time) Group {
	return Group{
		Kind: KindOverflow, Level: LevelWarn,
		Message:     fmt.Sprintf("%d error groups not kept (cap %d)", n, limit),
		Fingerprint: Fingerprint(KindOverflow, "", fmt.Sprintf("cap %d", limit)),
		FirstAt:     at, LastAt: at, N: n,
	}
}

func minTime(a, b time.Time) time.Time {
	if b.Before(a) {
		return b
	}
	return a
}

func maxTime(a, b time.Time) time.Time {
	if b.After(a) {
		return b
	}
	return a
}
