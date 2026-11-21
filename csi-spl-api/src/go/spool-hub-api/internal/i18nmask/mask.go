// Package i18nmask is the Go port of spec 115's mask (T9, the bash action
// do_spl_i18n_mask, csi-spl-orc/src/bash/run/spl-i18n-mask.func.sh) for the
// hub: before a cost label leaves the hub, for Google Cloud Translation or
// for agy, its emails, phone numbers and the names of a term list become
// tokens (spec 123 section 16.6.5; owner HUM-10, csitea 720fa031, msg
// baae5fb7, follow-up answer 2: "M — The hub masks them, as it does for
// agy").
//
// The rules are the bash action's, match for match:
//
//   - one pass, left to right; at each place an email first, then a phone
//     number, then a term;
//   - a term matches case-insensitively at a word start (no letter, digit or
//     _ before it), with any letters after it (inflected forms); the longer
//     term is tried first;
//   - each distinct match (exact text) becomes [EMAIL_n], [PHONE_n],
//     [NAME_n], [WORKSPACE_n] or [OTHER_n], n counted per class in order of
//     first appearance.
//
// The mask is deterministic for one text and one term list, so the hub
// rebuilds the token map instead of storing it. The shared fixture
// csi-spl-orc/src/bash/tests/fixtures/i18n-mask keeps the two in step.
package i18nmask

import (
	"bufio"
	"fmt"
	"io"
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"
)

// The term classes of the list, as the bash action's.
const (
	Name      = "NAME"
	Workspace = "WORKSPACE"
	Other     = "OTHER"
)

// Term is one entry of the term list: its class and its text.
type Term struct {
	Class, Text string
}

// Pair is one token and the original text it stands for.
type Pair struct {
	Token, Value string
}

// Map is a mask's tokens in order of first appearance.
type Map []Pair

// The bash action's patterns, anchored: an email; a phone number (its
// lookbehind and lookahead are checked by hand, RE2 has none, so the
// lookahead is one consumed non-digit rune or the end).
var (
	emailRe = regexp.MustCompile(`^[\p{L}\p{N}._%+-]+@[\p{L}\p{N}-]+(?:\.[\p{L}\p{N}-]+)+`)
	phoneRe = regexp.MustCompile(`^(?:\+[0-9][0-9 ().-]{6,18}[0-9]|0[0-9]{1,4}[ -][0-9]{2,4}(?:[ -]?[0-9]{2,4}){1,2})(?:[^\p{N}]|$)`)
	// TokenRe is any mask token.
	TokenRe = regexp.MustCompile(`\[(?:EMAIL|PHONE|NAME|WORKSPACE|OTHER)_[0-9]+\]`)
)

// termLineRe is the bash action's term line; skipLineRe a comment or blank.
var (
	termLineRe = regexp.MustCompile(`^\s*(name|workspace|other)\s+(\S.*?)\s*$`)
	skipLineRe = regexp.MustCompile(`^\s*(?:#|$)`)
)

// ParseTerms reads the bash action's term list: one `<name|workspace|other>
// <term>` per line, # comments and blank lines skipped.
func ParseTerms(r io.Reader) ([]Term, error) {
	var out []Term
	sc := bufio.NewScanner(r)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSuffix(sc.Text(), "\r")
		if skipLineRe.MatchString(line) {
			continue
		}
		m := termLineRe.FindStringSubmatch(line)
		if m == nil {
			return nil, fmt.Errorf("term list line %d: want <name|workspace|other> <term>", n)
		}
		out = append(out, Term{Class: strings.ToUpper(m[1]), Text: m[2]})
	}
	return out, sc.Err()
}

// Masker masks texts against one term list.
type Masker struct {
	terms  []Term
	termRe *regexp.Regexp // nil = no term
}

// New is a Masker for terms: longest first, ties in list order (Perl's
// stable sort), empty terms dropped.
func New(terms []Term) *Masker {
	t := make([]Term, 0, len(terms))
	for _, x := range terms {
		if x.Text != "" {
			t = append(t, x)
		}
	}
	sort.SliceStable(t, func(i, j int) bool { return len(t[i].Text) > len(t[j].Text) })
	m := &Masker{terms: t}
	if len(t) > 0 {
		alt := make([]string, len(t))
		for i, x := range t {
			alt[i] = regexp.QuoteMeta(x.Text)
		}
		m.termRe = regexp.MustCompile(`^(?i:` + strings.Join(alt, "|") + `)\p{L}*`)
	}
	return m
}

// wordRune is the bash action's $L: a letter, a digit or _.
func wordRune(r rune) bool { return r == '_' || unicode.IsLetter(r) || unicode.IsNumber(r) }

// Mask is s with every match a token, and the map of its tokens.
func (m *Masker) Mask(s string) (string, Map) {
	var b strings.Builder
	tok, count, out := map[string]string{}, map[string]int{}, Map{}
	take := func(class, v string) string {
		if t, ok := tok[v]; ok {
			return t
		}
		count[class]++
		t := fmt.Sprintf("[%s_%d]", class, count[class])
		tok[v] = t
		out = append(out, Pair{Token: t, Value: v})
		return t
	}
	prev := rune(-1)
	for i := 0; i < len(s); {
		class, n := m.matchAt(s, i, prev)
		if n > 0 {
			b.WriteString(take(class, s[i:i+n]))
			prev, _ = utf8.DecodeLastRuneInString(s[:i+n])
			i += n
			continue
		}
		r, size := utf8.DecodeRuneInString(s[i:])
		b.WriteString(s[i : i+size])
		prev = r
		i += size
	}
	return b.String(), out
}

// matchAt is the class and byte length of the match at s[i:] (0 = none);
// prev is the rune before i (-1 at the start).
func (m *Masker) matchAt(s string, i int, prev rune) (string, int) {
	rest := s[i:]
	if loc := emailRe.FindStringIndex(rest); loc != nil {
		return "EMAIL", loc[1]
	}
	if prev != '+' && (prev < 0 || !unicode.IsNumber(prev)) {
		if loc := phoneRe.FindStringIndex(rest); loc != nil {
			// the number ends on a digit: a last rune that is not one is the
			// consumed lookahead
			n := loc[1]
			if r, size := utf8.DecodeLastRuneInString(rest[:n]); !unicode.IsNumber(r) {
				n -= size
			}
			return "PHONE", n
		}
	}
	if m.termRe != nil && (prev < 0 || !wordRune(prev)) {
		if loc := m.termRe.FindStringIndex(rest); loc != nil {
			return m.class(rest[:loc[1]]), loc[1]
		}
	}
	return "", 0
}

// class is the bash action's $class: the first term (longest first) that the
// match starts with, case-insensitively; OTHER when none does.
func (m *Masker) class(match string) string {
	lm := strings.ToLower(match)
	for _, t := range m.terms {
		if strings.HasPrefix(lm, strings.ToLower(t.Text)) {
			return t.Class
		}
	}
	return Other
}

// Unmask is s with each of m's tokens its value, and the tokens of m that s
// did not carry.
func (m Map) Unmask(s string) (string, []string) {
	val := make(map[string]string, len(m))
	for _, p := range m {
		val[p.Token] = p.Value
	}
	seen := map[string]bool{}
	out := TokenRe.ReplaceAllStringFunc(s, func(t string) string {
		if v, ok := val[t]; ok {
			seen[t] = true
			return v
		}
		return t
	})
	var miss []string
	for _, p := range m {
		if !seen[p.Token] {
			miss = append(miss, p.Token)
		}
	}
	return out, miss
}

// Remask is s (a text made from the original, such as a translation of
// it) masked by the same rules, each value of have keeping its token; a
// match have does not hold (an inflected form) gets a new token numbered
// after have's, so no name of the list is left. The returned map is have
// plus those new tokens.
func (m *Masker) Remask(s string, have Map) (string, Map) {
	count := map[string]int{}
	for _, p := range have {
		count[tokenClass(p.Token)]++
	}
	out := append(Map{}, have...)
	return m.maskOn(s, &out, count), out
}

// maskOn masks seg with numbering after count, adding new tokens to out.
func (m *Masker) maskOn(seg string, out *Map, count map[string]int) string {
	masked, mm := m.Mask(seg)
	if len(mm) == 0 {
		return masked
	}
	re := map[string]string{}
	for _, p := range mm {
		if t, ok := out.tokenOf(p.Value); ok {
			re[p.Token] = t
			continue
		}
		c := tokenClass(p.Token)
		count[c]++
		t := fmt.Sprintf("[%s_%d]", c, count[c])
		*out = append(*out, Pair{Token: t, Value: p.Value})
		re[p.Token] = t
	}
	return TokenRe.ReplaceAllStringFunc(masked, func(t string) string {
		if n, ok := re[t]; ok {
			return n
		}
		return t // a token the text already carried
	})
}

// tokenOf is v's token in m.
func (m Map) tokenOf(v string) (string, bool) {
	for _, p := range m {
		if p.Value == v {
			return p.Token, true
		}
	}
	return "", false
}

// tokenClass is EMAIL of [EMAIL_3].
func tokenClass(t string) string {
	c, _, _ := strings.Cut(strings.TrimPrefix(t, "["), "_")
	return c
}
