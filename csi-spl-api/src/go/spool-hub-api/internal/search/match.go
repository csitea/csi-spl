package search

import (
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

// In-process evaluation of a parsed query (search-v1 §3.2). The memory store
// uses Match{Msg,File,Topic}; the hub uses MatchEntity for robots, users,
// channels and boxes. The Postgres store compiles the same leaves to SQL
// (store/search_postgres.go); the contract suite runs both.

// Msg is one stored message as search sees it.
type Msg struct {
	MsgID, TaskID, Parent string
	Channel               string // normalized; "" = a DM
	Kind, Body            string
	FromID, FromBox       string
	ToID, ToBox           string
	ReceivedAt            time.Time
	Files                 int // attachments carried
}

// File is one attachment of a stored message.
type File struct {
	Msg      Msg
	Name     string
	Kind     string // file | dir
	Bytes    int64
	HasBytes bool
}

// Topic is one task's aggregate: its title and every live message.
type Topic struct {
	TaskID, Parent, Channel, Title string
	LastAt                         time.Time
	Msgs                           []Msg
}

// Entity is a robot, user, channel or box.
type Entity struct {
	Type    Type
	Name    string   // what name: matches, and the label shown
	Text    []string // what free text matches (substring)
	Box     string   // robot: its box; box: its id
	Online  bool
	Revoked bool
}

// Eval evaluates n with leaf deciding each term; a nil n matches.
func Eval(n *Node, leaf func(*Term) bool) bool {
	if n == nil {
		return true
	}
	switch n.Kind {
	case Leaf:
		return leaf(n.Term)
	case Not:
		return !Eval(n.Kids[0], leaf)
	case Or:
		for _, k := range n.Kids {
			if Eval(k, leaf) {
				return true
			}
		}
		return false
	}
	for _, k := range n.Kids {
		if !Eval(k, leaf) {
			return false
		}
	}
	return true
}

// MatchMsg reports whether m matches n.
func MatchMsg(n *Node, m Msg) bool {
	return Eval(n, func(t *Term) bool {
		switch t.Op {
		case OpText:
			return FTS(m.Body, t)
		case OpFrom:
			return party(m.FromID, m.FromBox, t)
		case OpTo:
			return party(m.ToID, m.ToBox, t)
		case OpBox:
			return m.FromBox == t.Box || m.ToBox == t.Box
		case OpIn:
			return inChannel(m.Channel, t)
		case OpIs:
			return m.Kind == t.Enum
		case OpHas:
			if t.Enum == "code" {
				return HasCode(m.Body)
			}
			return m.Files > 0
		case OpTopic:
			return m.TaskID == t.Value
		case OpBefore, OpAfter, OpOn:
			return inRange(m.ReceivedAt, t)
		}
		return false
	})
}

// MatchFile reports whether f matches n.
func MatchFile(n *Node, f File) bool {
	return Eval(n, func(t *Term) bool {
		switch t.Op {
		case OpText, OpName, OpFilename:
			return contains(f.Name, t.Value)
		case OpExt:
			return strings.HasSuffix(strings.ToLower(f.Name), "."+t.Value)
		case OpLarger:
			return f.Kind == "file" && f.HasBytes && f.Bytes > t.Size
		case OpSmaller:
			return f.Kind == "file" && f.HasBytes && f.Bytes < t.Size
		case OpFrom:
			return party(f.Msg.FromID, f.Msg.FromBox, t)
		case OpTo:
			return party(f.Msg.ToID, f.Msg.ToBox, t)
		case OpBox:
			return f.Msg.FromBox == t.Box || f.Msg.ToBox == t.Box
		case OpIn:
			return inChannel(f.Msg.Channel, t)
		case OpTopic:
			return f.Msg.TaskID == t.Value
		case OpBefore, OpAfter, OpOn:
			return inRange(f.Msg.ReceivedAt, t)
		}
		return false
	})
}

// MatchTopic reports whether th matches n.
func MatchTopic(n *Node, th Topic) bool {
	return Eval(n, func(t *Term) bool {
		switch t.Op {
		case OpText, OpTitle:
			return FTS(th.Title, t)
		case OpFrom, OpTo, OpBox:
			for _, m := range th.Msgs {
				if (t.Op == OpFrom && party(m.FromID, m.FromBox, t)) || (t.Op == OpTo && party(m.ToID, m.ToBox, t)) ||
					(t.Op == OpBox && (m.FromBox == t.Box || m.ToBox == t.Box)) {
					return true
				}
			}
			return false
		case OpIn:
			return inChannel(th.Channel, t)
		case OpIs:
			return t.Enum == "root" && th.Parent == ""
		case OpTopic:
			return th.TaskID == t.Value
		case OpBefore, OpAfter, OpOn:
			return inRange(th.LastAt, t)
		}
		return false
	})
}

// MatchEntity reports whether e matches n.
func MatchEntity(n *Node, e Entity) bool {
	return Eval(n, func(t *Term) bool {
		switch t.Op {
		case OpText:
			for _, s := range e.Text {
				if contains(s, t.Value) {
					return true
				}
			}
			return false
		case OpName:
			return contains(e.Name, t.Value)
		case OpBox:
			return e.Box == t.Box
		case OpIs:
			switch t.Enum {
			case "online":
				return e.Online
			case "offline":
				return !e.Online
			case "revoked":
				return e.Revoked
			}
		}
		return false
	})
}

// party: <id>@<box> needs both; a bare value is the id or the box.
func party(id, box string, t *Term) bool {
	if t.Box != "" {
		return id == t.ID && box == t.Box
	}
	return id == t.ID || box == t.ID
}

func inChannel(ch string, t *Term) bool {
	if t.DM {
		return ch == ""
	}
	return ch == t.Channel
}

func inRange(at time.Time, t *Term) bool {
	return (t.From.IsZero() || !at.Before(t.From)) && (t.Until.IsZero() || at.Before(t.Until))
}

// HasCode: a fenced code block, a line starting with ``` (CLE-3407).
func HasCode(body string) bool {
	return strings.HasPrefix(body, "```") || strings.Contains(body, "\n```")
}

// FTS approximates Postgres plainto_tsquery / phraseto_tsquery with the
// 'simple' configuration: every word of a term present, or (phrase) its
// words adjacent and in order.
func FTS(text string, t *Term) bool {
	lex := t.Lexemes
	if len(lex) == 0 {
		return false
	}
	words := Words(text)
	if t.Phrase {
		for i := 0; i+len(lex) <= len(words); i++ {
			ok := true
			for j, l := range lex {
				if words[i+j] != l {
					ok = false
					break
				}
			}
			if ok {
				return true
			}
		}
		return false
	}
	have := map[string]bool{}
	for _, w := range words {
		have[w] = true
	}
	for _, l := range lex {
		if !have[l] {
			return false
		}
	}
	return true
}

// Rank is the memory store's relevance: how many positive lexemes body has.
func (q *Query) Rank(body string) int {
	words := Words(body)
	n := 0
	for _, l := range q.lexemes() {
		for _, w := range words {
			if w == l {
				n++
			}
		}
	}
	return n
}

// lexemes of the positive FTS terms (text, title:).
func (q *Query) lexemes() []string {
	var out []string
	for _, t := range q.Positive {
		if t.Op == OpText || t.Op == OpTitle {
			out = append(out, t.Lexemes...)
		}
	}
	return out
}

// substrs of the positive substring terms for an entity label.
func (q *Query) substrs() []string {
	var out []string
	for _, t := range q.Positive {
		if t.Value != "" {
			out = append(out, t.Value)
		}
	}
	return out
}

func contains(s, sub string) bool {
	return strings.Contains(strings.ToLower(s), strings.ToLower(sub))
}

// ---- highlights -------------------------------------------------------------

// Span is one [start, end) highlight in UTF-16 code units (search-v1 §4).
type Span [2]int

// HighlightWords marks every word of text that is a positive lexeme (the
// FTS types: message snippets, topic titles).
func (q *Query) HighlightWords(text string) []Span {
	set := map[string]bool{}
	for _, l := range q.lexemes() {
		set[l] = true
	}
	var out []Span
	for _, sp := range wordSpans(text) {
		if set[strings.ToLower(text[sp[0]:sp[1]])] {
			out = append(out, Span{u16len(text[:sp[0]]), u16len(text[:sp[1]])})
		}
	}
	return merge(out)
}

// HighlightSubstrings marks every case-insensitive occurrence of a positive
// term value (the substring types: files, robots, users, channels, boxes).
func (q *Query) HighlightSubstrings(text string) []Span {
	var out []Span
	rs := []rune(text)
	for _, sub := range q.substrs() {
		sr := []rune(sub)
		if len(sr) == 0 {
			continue
		}
		for i := 0; i+len(sr) <= len(rs); i++ {
			if strings.EqualFold(string(rs[i:i+len(sr)]), sub) {
				a := u16len(string(rs[:i]))
				out = append(out, Span{a, a + u16len(string(rs[i:i+len(sr)]))})
			}
		}
	}
	return merge(out)
}

func merge(in []Span) []Span {
	if len(in) == 0 {
		return []Span{}
	}
	sort.Slice(in, func(i, j int) bool { return in[i][0] < in[j][0] })
	out := []Span{in[0]}
	for _, s := range in[1:] {
		last := &out[len(out)-1]
		if s[0] <= last[1] {
			if s[1] > last[1] {
				last[1] = s[1]
			}
			continue
		}
		out = append(out, s)
	}
	return out
}

// SnippetMax is the snippet length in characters (search-v1 §4.1).
const SnippetMax = 200

// Snippet is at most SnippetMax characters of body around its first
// highlighted word, newlines as spaces, "…" marking a cut, with highlights.
func (q *Query) Snippet(body string) (string, []Span) {
	flat := strings.Join(strings.Fields(body), " ")
	if utf8.RuneCountInString(flat) <= SnippetMax {
		return flat, q.HighlightWords(flat)
	}
	rs := []rune(flat)
	first := 0
	if hs := q.HighlightWords(flat); len(hs) > 0 {
		first = len([]rune(string(utf16Prefix(flat, hs[0][0]))))
	}
	start := first - 60
	if start < 0 {
		start = 0
	}
	if start > 0 { // never cut a word in half
		for start < first && rs[start-1] != ' ' {
			start++
		}
	}
	end := start + SnippetMax - 4
	if end > len(rs) {
		end = len(rs)
	}
	if end < len(rs) {
		e := end
		for e > first && rs[e] != ' ' {
			e--
		}
		if e > first {
			end = e
		}
	}
	text := string(rs[start:end])
	if start > 0 {
		text = "… " + text
	}
	if end < len(rs) {
		text += " …"
	}
	return text, q.HighlightWords(text)
}

// utf16Prefix is the prefix of s spanning n UTF-16 code units.
func utf16Prefix(s string, n int) string {
	u := 0
	for i, r := range s {
		if u >= n {
			return s[:i]
		}
		u++
		if r >= 0x10000 {
			u++
		}
	}
	return s
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
