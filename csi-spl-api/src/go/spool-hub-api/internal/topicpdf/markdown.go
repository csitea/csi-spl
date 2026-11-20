// SPDX-License-Identifier: AGPL-3.0-only

package topicpdf

import (
	"html"
	"html/template"
	"regexp"
	"strings"
)

// Markdown renders a message body for print: the subset agents and people
// post (spec 183 7.1.3; csi-spl-doc/doc/help/how-to-post.md): fenced code,
// headings, lists, quotes, pipe tables and paragraphs, with inline code,
// bold, italic and http(s)/mailto links. Every character of the body is
// HTML-escaped before any tag is added, so a body can never inject markup.
func Markdown(src string) template.HTML {
	lines := strings.Split(strings.ReplaceAll(src, "\r\n", "\n"), "\n")
	var out strings.Builder
	for i := 0; i < len(lines); {
		i = block(lines, i, &out)
	}
	return template.HTML(out.String()) //nolint:gosec // G203: built only from escaped text
}

var (
	fenceRe   = regexp.MustCompile("^\\s*(```|~~~)")
	headingRe = regexp.MustCompile(`^(#{1,6})\s+(.*?)\s*#*\s*$`)
	ulRe      = regexp.MustCompile(`^\s*[-*+]\s+(.*)$`)
	olRe      = regexp.MustCompile(`^\s*\d+[.)]\s+(.*)$`)
	quoteRe   = regexp.MustCompile(`^\s*>\s?(.*)$`)
	tableSep  = regexp.MustCompile(`^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$`)
)

// block writes the block that starts at line i and answers the next line.
func block(lines []string, i int, out *strings.Builder) int {
	l := lines[i]
	switch {
	case strings.TrimSpace(l) == "":
		return i + 1
	case fenceRe.MatchString(l):
		return fenced(lines, i, out)
	case headingRe.MatchString(l):
		m := headingRe.FindStringSubmatch(l)
		n := string(rune('0' + len(m[1])))
		out.WriteString("<h" + n + ">" + inline(m[2]) + "</h" + n + ">\n")
		return i + 1
	case ulRe.MatchString(l):
		return list(lines, i, out, ulRe, "ul")
	case olRe.MatchString(l):
		return list(lines, i, out, olRe, "ol")
	case quoteRe.MatchString(l):
		return run(lines, i, out, quoteRe, "blockquote")
	case strings.HasPrefix(strings.TrimSpace(l), "|"):
		return table(lines, i, out)
	}
	return paragraph(lines, i, out)
}

func fenced(lines []string, i int, out *strings.Builder) int {
	mark := fenceRe.FindStringSubmatch(lines[i])[1]
	j := i + 1
	for j < len(lines) && !strings.HasPrefix(strings.TrimSpace(lines[j]), mark) {
		j++
	}
	out.WriteString("<pre><code>" + html.EscapeString(strings.Join(lines[i+1:j], "\n")) + "</code></pre>\n")
	return min(j+1, len(lines))
}

func list(lines []string, i int, out *strings.Builder, re *regexp.Regexp, tag string) int {
	out.WriteString("<" + tag + ">")
	for ; i < len(lines) && re.MatchString(lines[i]); i++ {
		out.WriteString("<li>" + inline(re.FindStringSubmatch(lines[i])[1]) + "</li>")
	}
	out.WriteString("</" + tag + ">\n")
	return i
}

// run is consecutive lines of one kind (a quote) as one block, a <br> between.
func run(lines []string, i int, out *strings.Builder, re *regexp.Regexp, tag string) int {
	var parts []string
	for ; i < len(lines) && re.MatchString(lines[i]); i++ {
		parts = append(parts, inline(re.FindStringSubmatch(lines[i])[1]))
	}
	out.WriteString("<" + tag + ">" + strings.Join(parts, "<br>") + "</" + tag + ">\n")
	return i
}

func table(lines []string, i int, out *strings.Builder) int {
	out.WriteString("<table>")
	head := i+1 < len(lines) && tableSep.MatchString(lines[i+1])
	for row := 0; i < len(lines) && strings.HasPrefix(strings.TrimSpace(lines[i]), "|"); i, row = i+1, row+1 {
		if head && row == 1 {
			continue
		}
		cell := "td"
		if head && row == 0 {
			cell = "th"
		}
		out.WriteString("<tr>")
		for _, c := range strings.Split(strings.Trim(strings.TrimSpace(lines[i]), "|"), "|") {
			out.WriteString("<" + cell + ">" + inline(strings.TrimSpace(c)) + "</" + cell + ">")
		}
		out.WriteString("</tr>")
	}
	out.WriteString("</table>\n")
	return i
}

// paragraph runs to a blank line or the start of another block; its lines
// keep their breaks, as a chat card shows them.
func paragraph(lines []string, i int, out *strings.Builder) int {
	parts := []string{inline(lines[i])}
	for i++; i < len(lines) && !startsBlock(lines[i]); i++ {
		parts = append(parts, inline(lines[i]))
	}
	out.WriteString("<p>" + strings.Join(parts, "<br>") + "</p>\n")
	return i
}

func startsBlock(l string) bool {
	return strings.TrimSpace(l) == "" || fenceRe.MatchString(l) || headingRe.MatchString(l) ||
		ulRe.MatchString(l) || olRe.MatchString(l) || quoteRe.MatchString(l) ||
		strings.HasPrefix(strings.TrimSpace(l), "|")
}

var (
	codeSpan = regexp.MustCompile("`[^`]+`")
	linkRe   = regexp.MustCompile(`\[([^\]]+)\]\(((?:https?://|mailto:)[^)\s]+)\)`)
	boldRe   = regexp.MustCompile(`\*\*([^*]+)\*\*`)
	italRe   = regexp.MustCompile(`(^|[^\w*])\*([^*\s][^*]*)\*`)
)

// inline escapes s and marks its code spans, links, bold and italic. Code
// spans are cut out first so nothing inside them is touched.
func inline(s string) string {
	var out strings.Builder
	last := 0
	for _, m := range codeSpan.FindAllStringIndex(s, -1) {
		out.WriteString(emphasis(s[last:m[0]]))
		out.WriteString("<code>" + html.EscapeString(s[m[0]+1:m[1]-1]) + "</code>")
		last = m[1]
	}
	out.WriteString(emphasis(s[last:]))
	return out.String()
}

func emphasis(s string) string {
	e := html.EscapeString(s)
	e = linkRe.ReplaceAllString(e, `<a href="$2">$1</a>`)
	e = boldRe.ReplaceAllString(e, `<strong>$1</strong>`)
	return italRe.ReplaceAllString(e, `$1<em>$2</em>`)
}
