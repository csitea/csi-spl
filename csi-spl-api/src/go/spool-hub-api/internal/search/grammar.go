// Package search is the one grammar of GET /v1/view/search (specs/003
// contracts/search-v1.md): a Gmail-style query parsed server-side into an AST
// that the stores compile (Postgres: bind parameters only) or evaluate
// (memory, and the hub for robots / users / channels / boxes). The browser
// never parses a query.
package search

import (
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf16"
)

// Version is the grammar version published by the operators endpoint.
const Version = "1.0"

// Limits (search-v1 §1, §2.1).
const (
	MaxQueryUnits = 512 // UTF-16 code units of q
	MaxTerms      = 32
	MaxDepth      = 8
)

// Type is an entity type (search-v1 §0).
type Type string

const (
	TypeMessage Type = "message"
	TypeThread  Type = "thread"
	TypeFile    Type = "file"
	TypeRobot   Type = "robot"
	TypeUser    Type = "user"
	TypeChannel Type = "channel"
	TypeBox     Type = "box"
)

// Types is every type in response order (search-v1 §4).
var Types = []Type{TypeMessage, TypeThread, TypeFile, TypeRobot, TypeUser, TypeChannel, TypeBox}

// Group is the plural response key of t.
func (t Type) Group() string {
	if t == TypeBox {
		return "boxes"
	}
	return string(t) + "s"
}

var typeAliases = map[string]Type{
	"message": TypeMessage, "msg": TypeMessage, "messages": TypeMessage,
	"thread": TypeThread, "threads": TypeThread,
	"file": TypeFile, "files": TypeFile, "attachment": TypeFile,
	"robot": TypeRobot, "robots": TypeRobot, "agent": TypeRobot, "bot": TypeRobot,
	"user": TypeUser, "users": TypeUser, "human": TypeUser,
	"channel": TypeChannel, "channels": TypeChannel,
	"box": TypeBox, "boxes": TypeBox,
}

// Op names (the canonical name of each operator; "" is free text).
const (
	OpText     = ""
	OpType     = "type"
	OpFrom     = "from"
	OpTo       = "to"
	OpBox      = "box"
	OpIn       = "in"
	OpIs       = "is"
	OpHas      = "has"
	OpThread   = "thread"
	OpBefore   = "before"
	OpAfter    = "after"
	OpOn       = "on"
	OpTitle    = "title"
	OpName     = "name"
	OpFilename = "filename"
	OpExt      = "ext"
	OpLarger   = "larger"
	OpSmaller  = "smaller"
)

// Operator is one row of the operator table (search-v1 §3.2, §6).
type Operator struct {
	Name    string            `json:"name"`
	Aliases []string          `json:"aliases"`
	Values  string            `json:"values"`
	Enum    map[string][]Type `json:"enum,omitempty"`
	Applies []Type            `json:"applies_to"`
	Example string            `json:"example"`
	Doc     string            `json:"doc"`
}

var (
	msgThreadFile = []Type{TypeMessage, TypeThread, TypeFile}
	presence      = []Type{TypeRobot, TypeUser, TypeBox}
)

// Operators is the table; the parser, the applicability check and the
// operators endpoint all read it.
var Operators = []Operator{
	{Name: OpType, Values: "type", Applies: Types, Example: "type:robot", Doc: "the sections to search: message, thread, file, robot, user, channel, box (comma list)"},
	{Name: OpFrom, Values: "id", Applies: msgThreadFile, Example: "from:CLE-07", Doc: "sender: agent, agent@box, HUM-n or box"},
	{Name: OpTo, Values: "id", Applies: msgThreadFile, Example: "to:HUM-3", Doc: "recipient: agent, agent@box, HUM-n or box"},
	{Name: OpBox, Values: "box", Applies: []Type{TypeMessage, TypeThread, TypeFile, TypeRobot, TypeBox}, Example: "box:box-a", Doc: "sent from or to this box; a robot on it; the box itself"},
	{Name: OpIn, Values: "channel", Applies: msgThreadFile, Example: "in:#tasks", Doc: "a channel (#name or name), or dm for direct messages"},
	{Name: OpIs, Values: "enum", Enum: map[string][]Type{
		"task": {TypeMessage}, "note": {TypeMessage}, "result": {TypeMessage}, "reject": {TypeMessage},
		"root": {TypeThread}, "online": presence, "offline": presence, "revoked": {TypeRobot, TypeBox},
	}, Applies: []Type{TypeMessage, TypeThread, TypeRobot, TypeUser, TypeBox}, Example: "is:task", Doc: "message kind, root thread, presence or revoked pin"},
	{Name: OpHas, Values: "enum", Enum: map[string][]Type{
		"file": {TypeMessage}, "attachment": {TypeMessage}, "code": {TypeMessage},
	}, Applies: []Type{TypeMessage}, Example: "has:file", Doc: "messages with attachments or a fenced code block"},
	{Name: OpThread, Values: "uuid", Applies: msgThreadFile, Example: "thread:<task_id>", Doc: "one thread (task id)"},
	{Name: OpBefore, Values: "date", Applies: msgThreadFile, Example: "before:2026-09-01", Doc: "received before a UTC day, or before an age (24h, 7d, 2w)"},
	{Name: OpAfter, Values: "date", Applies: msgThreadFile, Example: "after:7d", Doc: "received on or after a UTC day, or within an age"},
	{Name: OpOn, Values: "date", Applies: msgThreadFile, Example: "on:2026-09-19", Doc: "received on a UTC day"},
	{Name: OpTitle, Aliases: []string{"subject"}, Values: "text", Applies: []Type{TypeThread}, Example: "title:migration", Doc: "thread title words"},
	{Name: OpName, Values: "text", Applies: []Type{TypeFile, TypeRobot, TypeUser, TypeChannel, TypeBox}, Example: "name:ops", Doc: "the entity's name contains this"},
	{Name: OpFilename, Values: "text", Applies: []Type{TypeFile}, Example: `filename:"q3 report"`, Doc: "attachment name contains this"},
	{Name: OpExt, Values: "ext", Applies: []Type{TypeFile}, Example: "ext:pdf", Doc: "attachment extension"},
	{Name: OpLarger, Values: "size", Applies: []Type{TypeFile}, Example: "larger:1M", Doc: "attachment larger than (bytes, K, M, G)"},
	{Name: OpSmaller, Values: "size", Applies: []Type{TypeFile}, Example: "smaller:10K", Doc: "attachment smaller than (bytes, K, M, G)"},
}

var opByName = func() map[string]*Operator {
	m := map[string]*Operator{}
	for i := range Operators {
		o := &Operators[i]
		m[o.Name] = o
		for _, a := range o.Aliases {
			m[a] = o
		}
	}
	return m
}()

// Term is one leaf: free text or an operator with its parsed value.
type Term struct {
	Op     string // canonical operator name; OpText for free text
	Value  string // the value as typed (phrase quotes removed)
	Phrase bool   // the value was "quoted"
	Pos    int    // UTF-16 offset of the term in q
	Raw    string // the term as typed

	Enum    string    // is: / has: canonical value
	ID, Box string    // from: / to: (<id>@<box> sets both; a bare value sets ID)
	Channel string    // in: normalized slug; "" with DM
	DM      bool      // in:dm
	From    time.Time // before / after / on lower bound (zero = none)
	Until   time.Time // exclusive upper bound (zero = none)
	Size    int64     // larger / smaller
	Types   []Type    // type:
	Lexemes []string  // text / title: lowercase words (Words of Value)
}

// NodeKind is the AST node kind.
type NodeKind int

const (
	Leaf NodeKind = iota
	And
	Or
	Not
)

// Node is one AST node.
type Node struct {
	Kind NodeKind
	Kids []*Node
	Term *Term
}

// Warning is a non-fatal note on a term (search-v1 §5.2).
type Warning struct {
	Token  string `json:"token"`
	Pos    int    `json:"pos"`
	Detail string `json:"detail"`
}

// Error is a malformed query: 400 bad_query with a pointer (search-v1 §5.1).
type Error struct {
	Pos    int
	Token  string
	Detail string
}

func (e *Error) Error() string {
	return fmt.Sprintf("bad query at %d (%q): %s", e.Pos, e.Token, e.Detail)
}

// Query is a parsed query.
type Query struct {
	Raw      string
	Root     *Node  // nil = no condition (type: alone): everything of the types
	Types    []Type // the sections to search, response order
	Explicit bool   // type: was given
	Warnings []Warning
	Positive []*Term // text-bearing terms not under a Not (highlights, rank)
}

// ---- tokenizer ------------------------------------------------------------------

type tokKind int

const (
	tWord tokKind = iota
	tPhrase
	tOpPhrase // name:"value"
	tLParen
	tRParen
	tNeg
)

type token struct {
	kind tokKind
	text string // word text; phrase content; op name for tOpPhrase
	val  string // tOpPhrase value
	pos  int    // UTF-16 offset
	raw  string
}

func u16len(s string) int { return len(utf16.Encode([]rune(s))) }

// Units is the length of s in UTF-16 code units (the offset unit of the API).
func Units(s string) int { return u16len(s) }

func tokenize(q string) ([]token, error) {
	rs := []rune(q)
	var out []token
	pos := 0 // UTF-16 offset of rs[i]
	adv := func(r rune) int {
		if r >= 0x10000 {
			return 2
		}
		return 1
	}
	i := 0
	for i < len(rs) {
		r := rs[i]
		switch {
		case unicode.IsSpace(r):
			pos += adv(r)
			i++
		case r == '(':
			out = append(out, token{kind: tLParen, text: "(", pos: pos, raw: "("})
			pos++
			i++
		case r == ')':
			out = append(out, token{kind: tRParen, text: ")", pos: pos, raw: ")"})
			pos++
			i++
		case r == '-' && startOfToken(rs, i):
			if i+1 >= len(rs) || unicode.IsSpace(rs[i+1]) || rs[i+1] == ')' {
				return nil, &Error{Pos: pos, Token: "-", Detail: "'-' must be followed by a term"}
			}
			out = append(out, token{kind: tNeg, text: "-", pos: pos, raw: "-"})
			pos++
			i++
		case r == '"':
			start, sp := i, pos
			pos++
			i++
			for i < len(rs) && rs[i] != '"' {
				pos += adv(rs[i])
				i++
			}
			if i >= len(rs) {
				return nil, &Error{Pos: sp, Token: string(rs[start:]), Detail: "unterminated \""}
			}
			out = append(out, token{kind: tPhrase, text: string(rs[start+1 : i]), pos: sp, raw: string(rs[start : i+1])})
			pos++
			i++
		default:
			start, sp := i, pos
			for i < len(rs) && !unicode.IsSpace(rs[i]) && rs[i] != '(' && rs[i] != ')' && rs[i] != '"' {
				pos += adv(rs[i])
				i++
			}
			w := string(rs[start:i])
			// name:"value" is one operator term.
			if strings.HasSuffix(w, ":") && i < len(rs) && rs[i] == '"' && opNameRe.MatchString(strings.TrimSuffix(w, ":")) {
				vs := i
				pos++
				i++
				for i < len(rs) && rs[i] != '"' {
					pos += adv(rs[i])
					i++
				}
				if i >= len(rs) {
					return nil, &Error{Pos: sp, Token: string(rs[start:]), Detail: "unterminated \""}
				}
				out = append(out, token{kind: tOpPhrase, text: strings.TrimSuffix(w, ":"), val: string(rs[vs+1 : i]), pos: sp, raw: string(rs[start : i+1])})
				pos++
				i++
				continue
			}
			out = append(out, token{kind: tWord, text: w, pos: sp, raw: w})
		}
	}
	return out, nil
}

// startOfToken: '-' negates only at the start of a token (search-v1 §2.1).
func startOfToken(rs []rune, i int) bool {
	return i == 0 || unicode.IsSpace(rs[i-1]) || rs[i-1] == '('
}

var opNameRe = regexp.MustCompile(`^[A-Za-z]+$`)

// ---- parser ---------------------------------------------------------------------

type parser struct {
	toks  []token
	i     int
	q     *Query
	terms int
	now   time.Time
	end   int // UTF-16 length of q
}

// Parse parses q at time now (relative dates). A malformed query is *Error.
func Parse(q string, now time.Time) (*Query, error) {
	if strings.TrimSpace(q) == "" {
		return nil, &Error{Pos: 0, Token: "", Detail: "q is required"}
	}
	if n := u16len(q); n > MaxQueryUnits {
		return nil, &Error{Pos: MaxQueryUnits, Token: "", Detail: fmt.Sprintf("q is %d characters; the limit is %d", n, MaxQueryUnits)}
	}
	toks, err := tokenize(q)
	if err != nil {
		return nil, err
	}
	p := &parser{toks: toks, q: &Query{Raw: q}, now: now.UTC(), end: u16len(q)}
	root, err := p.conj(0)
	if err != nil {
		return nil, err
	}
	if p.i < len(p.toks) { // only a stray ')' stops conj at depth 0
		t := p.toks[p.i]
		return nil, &Error{Pos: t.pos, Token: t.raw, Detail: "unbalanced ')'"}
	}
	if err := p.q.finish(root); err != nil {
		return nil, err
	}
	return p.q, nil
}

func (p *parser) peek() *token {
	if p.i < len(p.toks) {
		return &p.toks[p.i]
	}
	return nil
}

func isWord(t *token, w string) bool { return t != nil && t.kind == tWord && t.text == w }

// conj = disj { [AND] disj }
func (p *parser) conj(depth int) (*Node, error) {
	var kids []*Node
	var lastAnd *token
	for {
		t := p.peek()
		if t == nil || t.kind == tRParen {
			break
		}
		if isWord(t, "AND") {
			if len(kids) == 0 && lastAnd == nil {
				return nil, &Error{Pos: t.pos, Token: "AND", Detail: "AND with nothing on its left"}
			}
			if lastAnd != nil {
				return nil, &Error{Pos: t.pos, Token: "AND", Detail: "AND AND"}
			}
			lastAnd = t
			p.i++
			continue
		}
		if isWord(t, "OR") {
			return nil, &Error{Pos: t.pos, Token: "OR", Detail: "OR with nothing on its left"}
		}
		n, err := p.disj(depth)
		if err != nil {
			return nil, err
		}
		lastAnd = nil
		if n != nil {
			kids = append(kids, n)
		}
	}
	if lastAnd != nil {
		return nil, &Error{Pos: lastAnd.pos, Token: "AND", Detail: "AND with nothing on its right"}
	}
	return mk(And, kids), nil
}

// disj = unary { OR unary }
func (p *parser) disj(depth int) (*Node, error) {
	first, err := p.unary(depth)
	if err != nil {
		return nil, err
	}
	kids := []*Node{first}
	for isWord(p.peek(), "OR") {
		or := p.peek()
		p.i++
		t := p.peek()
		if t == nil || t.kind == tRParen || isWord(t, "OR") || isWord(t, "AND") {
			return nil, &Error{Pos: or.pos, Token: "OR", Detail: "OR with nothing on its right"}
		}
		n, err := p.unary(depth)
		if err != nil {
			return nil, err
		}
		kids = append(kids, n)
	}
	var keep []*Node
	for _, k := range kids {
		if k != nil {
			keep = append(keep, k)
		}
	}
	return mk(Or, keep), nil
}

func (p *parser) unary(depth int) (*Node, error) {
	t := p.peek()
	if t != nil && t.kind == tNeg {
		p.i++
		if nt := p.peek(); nt == nil || nt.kind == tRParen || nt.kind == tNeg || isWord(nt, "OR") || isWord(nt, "AND") {
			return nil, &Error{Pos: t.pos, Token: "-", Detail: "'-' must be followed by a term"}
		}
		n, err := p.atom(depth, true)
		if err != nil || n == nil {
			return n, err
		}
		return &Node{Kind: Not, Kids: []*Node{n}}, nil
	}
	return p.atom(depth, false)
}

func (p *parser) atom(depth int, neg bool) (*Node, error) {
	t := p.peek()
	p.i++
	switch t.kind {
	case tLParen:
		if depth+1 > MaxDepth {
			return nil, &Error{Pos: t.pos, Token: "(", Detail: fmt.Sprintf("parentheses nest deeper than %d", MaxDepth)}
		}
		if nt := p.peek(); nt != nil && nt.kind == tRParen {
			return nil, &Error{Pos: t.pos, Token: "()", Detail: "empty parentheses"}
		}
		n, err := p.conj(depth + 1)
		if err != nil {
			return nil, err
		}
		if c := p.peek(); c == nil || c.kind != tRParen {
			return nil, &Error{Pos: t.pos, Token: "(", Detail: "unbalanced '('"}
		}
		p.i++
		return n, nil
	case tPhrase:
		return p.leaf(&Term{Op: OpText, Value: t.text, Phrase: true, Pos: t.pos, Raw: t.raw}, neg)
	case tOpPhrase:
		return p.operator(t, strings.ToLower(t.text), t.val, true, neg)
	case tWord:
		if name, val, ok := strings.Cut(t.text, ":"); ok && opNameRe.MatchString(name) {
			if _, known := opByName[strings.ToLower(name)]; known {
				return p.operator(t, strings.ToLower(name), val, false, neg)
			}
			if !strings.HasPrefix(val, "//") && val != "" {
				p.q.Warnings = append(p.q.Warnings, Warning{Token: t.raw, Pos: t.pos, Detail: "unknown operator " + name + ": searched as text"})
			}
		}
		return p.leaf(&Term{Op: OpText, Value: t.text, Pos: t.pos, Raw: t.raw}, neg)
	}
	return nil, &Error{Pos: t.pos, Token: t.raw, Detail: "unexpected token"}
}

func (p *parser) leaf(t *Term, neg bool) (*Node, error) {
	p.terms++
	if p.terms > MaxTerms {
		return nil, &Error{Pos: t.Pos, Token: t.Raw, Detail: fmt.Sprintf("more than %d terms", MaxTerms)}
	}
	if t.Op == OpText {
		t.Lexemes = Words(t.Value)
		if len(t.Lexemes) == 0 {
			p.q.Warnings = append(p.q.Warnings, Warning{Token: t.Raw, Pos: t.Pos, Detail: "no letter or digit: ignored"})
			p.terms--
			return nil, nil
		}
	}
	return &Node{Kind: Leaf, Term: t}, nil
}

func mk(k NodeKind, kids []*Node) *Node {
	switch len(kids) {
	case 0:
		return nil
	case 1:
		return kids[0]
	}
	return &Node{Kind: k, Kids: kids}
}

// finish checks type: placement, applies it, and computes the sections.
func (q *Query) finish(root *Node) error {
	var typeTerm *Term
	// type: only as a top-level conjunct (search-v1 §3.1).
	top := []*Node{root}
	if root != nil && root.Kind == And {
		top = root.Kids
	}
	var rest []*Node
	for _, n := range top {
		if n != nil && n.Kind == Leaf && n.Term.Op == OpType {
			if typeTerm != nil {
				return &Error{Pos: n.Term.Pos, Token: n.Term.Raw, Detail: "at most one type:"}
			}
			typeTerm = n.Term
			continue
		}
		if n != nil {
			rest = append(rest, n)
		}
	}
	var bad *Term
	walk(mk(And, rest), func(n *Node) {
		if bad == nil && n.Kind == Leaf && n.Term.Op == OpType {
			bad = n.Term
		}
	})
	if bad != nil {
		return &Error{Pos: bad.Pos, Token: bad.Raw, Detail: "type: must be a top-level term (not negated, not inside OR or parentheses)"}
	}
	q.Root = mk(And, rest)
	cand := map[Type]bool{}
	if typeTerm != nil {
		q.Explicit = true
		for _, t := range typeTerm.Types {
			cand[t] = true
		}
	} else {
		for _, t := range Types {
			cand[t] = true
		}
	}
	var fail *Term
	walk(q.Root, func(n *Node) {
		if n.Kind != Leaf || fail != nil {
			return
		}
		ap := applies(n.Term)
		if ap == nil { // text: every type
			return
		}
		next := map[Type]bool{}
		for _, t := range ap {
			if cand[t] {
				next[t] = true
			}
		}
		if len(next) == 0 {
			fail = n.Term
			return
		}
		cand = next
	})
	if fail != nil {
		d := fail.Raw + " does not apply to any type the rest of the query searches"
		if typeTerm != nil {
			d = fail.Raw + " does not apply to " + typeTerm.Raw
		}
		return &Error{Pos: fail.Pos, Token: fail.Raw, Detail: d}
	}
	for _, t := range Types {
		if cand[t] {
			q.Types = append(q.Types, t)
		}
	}
	q.Positive = positives(q.Root, false, nil)
	return nil
}

// applies is the set of types a term applies to; nil = every type (text).
func applies(t *Term) []Type {
	if t.Op == OpText {
		return nil
	}
	o := opByName[t.Op]
	if o.Enum != nil {
		return o.Enum[t.Enum]
	}
	return o.Applies
}

func walk(n *Node, f func(*Node)) {
	if n == nil {
		return
	}
	f(n)
	for _, k := range n.Kids {
		walk(k, f)
	}
}

// positives are the text-bearing terms (text, title:, name:, filename:) not
// under a Not: what highlights mark and relevance ranks.
func positives(n *Node, neg bool, out []*Term) []*Term {
	if n == nil {
		return out
	}
	switch n.Kind {
	case Leaf:
		switch n.Term.Op {
		case OpText, OpTitle, OpName, OpFilename:
			if !neg {
				out = append(out, n.Term)
			}
		}
	case Not:
		return positives(n.Kids[0], !neg, out)
	default:
		for _, k := range n.Kids {
			out = positives(k, neg, out)
		}
	}
	return out
}

// Words splits s the way the Postgres 'simple' configuration roughly does:
// runs of letters and digits, lower-cased.
func Words(s string) []string {
	var out []string
	for _, sp := range wordSpans(s) {
		out = append(out, strings.ToLower(s[sp[0]:sp[1]]))
	}
	return out
}

// wordSpans are the byte ranges of the letter/digit runs of s.
func wordSpans(s string) [][2]int {
	var out [][2]int
	start := -1
	for i, r := range s {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			if start < 0 {
				start = i
			}
			continue
		}
		if start >= 0 {
			out = append(out, [2]int{start, i})
			start = -1
		}
	}
	if start >= 0 {
		out = append(out, [2]int{start, len(s)})
	}
	return out
}
