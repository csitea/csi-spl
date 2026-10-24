// Package pollform is the hub's half of the "is this ```poll fence a form"
// rule (SPL-3203, spec 038): a port of readPoll and pollProblems in
// csi-spl-wui/src/utils/poll.mjs, ONLY the yes/no and its reason, no
// renderer. The send check of the desk actions (spl_desk_poll_check,
// SPL-3062) runs only when the sender's tree has it; MCP sends and `spool
// send` skip it. The hub sees every box send, so onSend refuses a body whose
// fence would render as a code block (poll_not_a_form).
//
// The two sides are held equal by one fixture, testdata/poll-form-cases.json:
// each case is a body and the exact problem lines pollProblems prints for it.
// The writers' rule: csi-spl-doc/doc/help/how-to-post.md section 7.
package pollform

import (
	"fmt"
	"regexp"
	"strings"
	"unicode"
)

// key is an option key: 1-8 letters or digits (SPL-3202, the WUI's KEY).
const key = `[A-Za-z0-9]{1,8}`

var (
	openRE  = regexp.MustCompile("^(`{3,})poll[ \t]*$")
	fenceRE = regexp.MustCompile("^(`{3,})")
	closeRE = regexp.MustCompile("^(`{3,})[ \t]*$")
	// optionRE is OPTION_RE; RE2 has no lookahead, so the task-list marker
	// `[ ]` / `[x]` (SPL-3062) is the taskRE try first: it is dropped only
	// when an option follows it, else `[x] text` is checkbox X.
	optionRE = regexp.MustCompile(`^(?:[-*][ \t]+)?([([])[ \t]*(` + key + `)[ \t]*([)\]])[ \t]+(\S.*)$`)
	taskRE   = regexp.MustCompile(`^(?:[-*][ \t]+)?\[[ xX]?\][ \t]+([([])[ \t]*(` + key + `)[ \t]*([)\]])[ \t]+(\S.*)$`)
	nearRE   = regexp.MustCompile(`^(?:[-*][ \t]+)?(?:\[[ xX]?\][ \t]+)?[([]?[ \t]*` + key + `[ \t]*[)\].:][ \t]+\S`)
	chatRE   = regexp.MustCompile(`(?i)^chat about this\.?$`)
)

type question struct {
	text string
	keys []string
	near []string
}

// option is OPTION_RE's match with matching brackets: kind "(" or "[".
func option(line string) (kind, k, text string, ok bool) {
	m := taskRE.FindStringSubmatch(line)
	if m == nil {
		m = optionRE.FindStringSubmatch(line)
	}
	if m == nil || (m[1] == "(") != (m[3] == ")") {
		return "", "", "", false
	}
	return m[1], strings.ToUpper(m[2]), trim(m[4]), true
}

// Why is readPoll's reason a fence's inner text is no form, "" when it is one.
func Why(text string) string {
	var qs []*question
	var q *question
	shape := ""
	for _, raw := range strings.Split(text, "\n") {
		line := trim(raw)
		if line == "" {
			continue
		}
		kind, k, otext, ok := option(line)
		if !ok {
			q, qs = textLine(q, qs, line)
			continue
		}
		if shape != "" && shape != kind {
			return fmt.Sprintf("radios `(A)` and checkboxes `[A]` are mixed (%s)", jsQuote(line))
		}
		shape = kind
		if q == nil {
			q = &question{}
			qs = append(qs, q)
		}
		if chatRE.MatchString(otext) {
			continue
		}
		for _, have := range q.keys {
			if have == k {
				return fmt.Sprintf("key %s twice in question %s", k, jsQuote(q.text))
			}
		}
		q.keys = append(q.keys, k)
	}
	return bareWhy(qs)
}

// textLine is a line that is no option: it continues a question that has no
// option yet, else it starts the next one.
func textLine(q *question, qs []*question, line string) (*question, []*question) {
	if q != nil && len(q.keys) == 0 {
		q.text += " " + line
	} else {
		q = &question{text: line}
		qs = append(qs, q)
	}
	if nearRE.MatchString(line) {
		q.near = append(q.near, line)
	}
	return q, qs
}

// bareWhy names the first question with no option line, or an empty fence.
func bareWhy(qs []*question) string {
	for _, q := range qs {
		if len(q.keys) > 0 {
			continue
		}
		near := ""
		if len(q.near) > 0 {
			near = "; not an option line: " + jsQuote(q.near[0])
		}
		return fmt.Sprintf("question %s has no option line%s", jsQuote(q.text), near)
	}
	if len(qs) == 0 {
		return "the fence is empty"
	}
	return ""
}

// Problems is pollProblems: why body's ```poll fences would not render as a
// form, one line per problem; nil when they would, or when there is none. A
// ```poll inside another fence is that fence's content.
func Problems(body string) []string {
	lines := strings.Split(strings.ReplaceAll(strings.ReplaceAll(body, "\r\n", "\n"), "\r", "\n"), "\n")
	var out []string
	forms := 0
	for i := 0; i < len(lines); i++ {
		open := openRE.FindStringSubmatch(lines[i])
		fence := open
		if fence == nil {
			fence = fenceRE.FindStringSubmatch(lines[i])
		}
		if fence == nil {
			continue
		}
		end := closer(lines, i, len(fence[1]))
		if open != nil {
			forms++
			if p := formProblem(lines, i, end, forms); p != "" {
				out = append(out, p)
			}
		}
		if end < 0 {
			break
		}
		i = end
	}
	return out
}

// formProblem is the problem of the forms-th ```poll fence opened on line i
// and closed on end (-1: never), "" when it is a form.
func formProblem(lines []string, i, end, forms int) string {
	switch {
	case forms > 1:
		return fmt.Sprintf("a second ```poll fence (line %d): one form per message", i+1)
	case end < 0:
		return fmt.Sprintf("the ```poll fence of line %d is never closed", i+1)
	}
	if why := Why(strings.Join(lines[i+1:end], "\n")); why != "" {
		return fmt.Sprintf("the ```poll fence of line %d is no form: %s", i+1, why)
	}
	return ""
}

// closer is the line that closes a fence of n backticks opened on line i, -1 when none.
func closer(lines []string, i, n int) int {
	for j := i + 1; j < len(lines); j++ {
		if c := closeRE.FindStringSubmatch(lines[j]); c != nil && len(c[1]) >= n {
			return j
		}
	}
	return -1
}

// jsQuote is the JS template's "${s}": the text between plain double quotes,
// nothing escaped (Go's %q would escape and differ from the WUI's reason).
func jsQuote(s string) string { return `"` + s + `"` }

// trim is String.prototype.trim: unicode white space and the BOM.
func trim(s string) string {
	return strings.TrimFunc(s, func(r rune) bool { return unicode.IsSpace(r) || r == 0xFEFF })
}
