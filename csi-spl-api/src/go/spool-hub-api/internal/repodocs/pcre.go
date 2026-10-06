package repodocs

import (
	"errors"
	"regexp"
	"strings"
	"unicode/utf8"
)

// The sweep's patterns are grep -P (PCRE); Go's regexp (RE2) has no
// lookaround. compilePCRE accepts what the sweep uses: an optional leading
// inline-flag group, top-level alternatives, and at most ONE negative
// lookahead (?!...) per alternative at its top level. Any other lookaround
// is an error, so a new sweep pattern this cannot honour fails the package
// tests instead of being judged differently from the sweep.

var flagsRe = regexp.MustCompile(`^\(\?[a-zA-Z]+\)`)

// matcher is one compiled pattern: a line matches when any alternative does.
type matcher struct{ alts []alt }

// alt is one alternative "P(?!LA)Q". Without a lookahead only any is set.
type alt struct {
	any       *regexp.Regexp // P Q anywhere: the cheap first test
	head, mid *regexp.Regexp // ^(P)Q at offset 0 / ^.(P)Q one rune after the context rune
	laHead    *regexp.Regexp // ^LA at offset 0
	laMid     *regexp.Regexp // ^.LA one rune after the context rune
}

func compilePCRE(p string) (*matcher, error) {
	flags := flagsRe.FindString(p)
	branches, err := splitTop(p[len(flags):])
	if err != nil {
		return nil, err
	}
	m := &matcher{}
	for _, b := range branches {
		a, err := compileAlt(flags, b)
		if err != nil {
			return nil, err
		}
		m.alts = append(m.alts, a)
	}
	return m, nil
}

func compileAlt(flags, b string) (alt, error) {
	pre, la, post, err := cutLookahead(b)
	if err != nil {
		return alt{}, err
	}
	if la == "" {
		re, err := regexp.Compile(flags + b)
		return alt{any: re}, err
	}
	var a alt
	for _, c := range []struct {
		dst **regexp.Regexp
		src string
	}{
		{&a.any, flags + "(?:" + pre + ")(?:" + post + ")"},
		{&a.head, flags + "^(" + pre + ")(?:" + post + ")"},
		{&a.mid, flags + "^(?s:.)(" + pre + ")(?:" + post + ")"},
		{&a.laHead, flags + "^(?:" + la + ")"},
		{&a.laMid, flags + "^(?s:.)(?:" + la + ")"},
	} {
		if *c.dst, err = regexp.Compile(c.src); err != nil {
			return alt{}, err
		}
	}
	return a, nil
}

func (m *matcher) match(s string) bool {
	for _, a := range m.alts {
		if a.match(s) {
			return true
		}
	}
	return false
}

// match tries every start offset like PCRE does, so a start whose lookahead
// refuses never hides a later start. The rune before the offset rides along
// as context, so \b at the start of P or LA reads as it would in grep.
func (a alt) match(s string) bool {
	if ok := a.any.MatchString(s); !ok || a.head == nil {
		return ok
	}
	for i := 0; i <= len(s); {
		if e := a.preEnd(s, i); e >= 0 && !a.laAt(s, e) {
			return true
		}
		if i == len(s) {
			break
		}
		_, n := utf8.DecodeRuneInString(s[i:])
		i += n
	}
	return false
}

// preEnd is where P ends for a match of P Q starting at i, -1 for none.
func (a alt) preEnd(s string, i int) int {
	if i == 0 {
		if loc := a.head.FindStringSubmatchIndex(s); loc != nil {
			return loc[3]
		}
		return -1
	}
	_, n := utf8.DecodeLastRuneInString(s[:i])
	if loc := a.mid.FindStringSubmatchIndex(s[i-n:]); loc != nil {
		return i - n + loc[3]
	}
	return -1
}

func (a alt) laAt(s string, e int) bool {
	if e == 0 {
		return a.laHead.MatchString(s)
	}
	_, n := utf8.DecodeLastRuneInString(s[:e])
	return a.laMid.MatchString(s[e-n:])
}

// scan walks a pattern and calls at(i, depth) for every character that is
// neither escaped nor inside a [...] class.
func scan(p string, at func(i, depth int) error) error {
	depth, class := 0, false
	for i := 0; i < len(p); i++ {
		switch c := p[i]; {
		case c == '\\':
			i++
		case class:
			class = c != ']'
		case c == '[':
			class = true
			if strings.HasPrefix(p[i+1:], "]") || strings.HasPrefix(p[i+1:], "^]") {
				i += strings.Index(p[i:], "]")
			}
		default:
			if c == ')' {
				depth--
			}
			if err := at(i, depth); err != nil {
				return err
			}
			if c == '(' {
				depth++
			}
		}
	}
	if depth != 0 || class {
		return errors.New("unbalanced pattern")
	}
	return nil
}

// splitTop splits p at its top-level "|".
func splitTop(p string) ([]string, error) {
	var out []string
	last := 0
	err := scan(p, func(i, depth int) error {
		if p[i] == '|' && depth == 0 {
			out = append(out, p[last:i])
			last = i + 1
		}
		return nil
	})
	return append(out, p[last:]), err
}

// cutLookahead splits "P(?!LA)Q"; la is "" when the branch has none.
func cutLookahead(b string) (pre, la, post string, err error) {
	open, closeAt := -1, -1
	err = scan(b, func(i, depth int) error {
		switch {
		case strings.HasPrefix(b[i:], "(?=") || strings.HasPrefix(b[i:], "(?<=") || strings.HasPrefix(b[i:], "(?<!"):
			return errors.New("only a negative lookahead (?!...) is supported")
		case strings.HasPrefix(b[i:], "(?!") && (depth != 0 || open >= 0):
			return errors.New("one top-level (?!...) per alternative at most")
		case strings.HasPrefix(b[i:], "(?!"):
			open = i
		case b[i] == ')' && depth == 0 && open >= 0 && closeAt < 0:
			closeAt = i
		}
		return nil
	})
	if err != nil || open < 0 {
		return b, "", "", err
	}
	return b[:open], b[open+3 : closeAt], b[closeAt+1:], nil
}
