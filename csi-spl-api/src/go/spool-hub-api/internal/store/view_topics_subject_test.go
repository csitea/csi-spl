package store

import (
	"context"
	"encoding/json"
	"slices"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

// CLE-77960 (payload audit 2026-10-02 cut 2): the topic walk returns the
// subject's source, not the whole first message, and distinct parties. What
// the hub makes of them must not change: topicSubject and topicParties are
// hub view.go's subject() and its participant dedup + sort, copied (the
// store cannot import hub).

func topicSubject(firstMsg []byte) string {
	var first struct {
		Body string `json:"body"`
	}
	if json.Unmarshal(firstMsg, &first) != nil {
		return ""
	}
	line, _, _ := strings.Cut(first.Body, "\n")
	line = strings.TrimSpace(line)
	if utf8.RuneCountInString(line) > 140 {
		line = string([]rune(line)[:140])
	}
	return line
}

func topicParties(p []string) []string {
	out := slices.Clone(p)
	slices.Sort(out)
	return slices.Compact(out)
}

// Every space rune Go's TrimSpace trims, built from code points so no
// editor or tool turns an escape into the raw rune.
var goSpaces = func() string {
	var b strings.Builder
	for _, r := range []rune{'\t', '\v', '\f', '\r', ' ', 0x85, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003,
		0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000} {
		b.WriteRune(r)
	}
	return b.String()
}()

func TestViewTopicsSubjectCut(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	tn := newTenant(t, pg)
	x := func(s string, n int) string { return strings.Repeat(s, n) }
	nbsp, ideo := string(rune(0xA0)), string(rune(0x3000))
	bodies := map[string]any{
		"short":              "hello world",
		"empty":              "",
		"multiline":          "first line\nsecond line\nthird",
		"crlf":               "first line\r\nsecond",
		"lead and trail":     "  \t hello \t ",
		"unicode lead":       goSpaces + "subject" + goSpaces + "\nrest",
		"only spaces":        goSpaces,
		"exactly 140":        x("a", 140),
		"141":                x("a", 141),
		"long":               x("word ", 400),
		"space at 140":       x("a", 139) + " " + x("b", 50),
		"space run over 140": x("a", 130) + x(" ", 30) + "tail",
		"nbsp run over 140":  x("a", 130) + x(nbsp, 30) + "tail",
		"space run to end":   x("a", 130) + x(" ", 30),
		"space run to nl":    x("a", 130) + x(ideo, 30) + "\nnext",
		"multibyte long":     x("ж€😀", 100),
		"lead then long":     x(" ", 50) + x("é", 300),
		"not a string":       42,
		"null":               nil,
		"no body":            "<none>",
		"unicode only line2": "\n" + x("z", 300),
	}
	want := map[string][]byte{}
	for name, b := range bodies {
		inner := map[string]any{"v": 1, "body": b}
		if b == "<none>" {
			delete(inner, "body")
		}
		raw, err := json.Marshal(inner)
		if err != nil {
			t.Fatal(err)
		}
		task := uuid4()
		m := msgFor(tn, task, "box-b", now, now.Add(-time.Minute), "e")
		m.Msg = raw
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		want[task] = raw
	}
	rows, err := pg.ViewTopics(ctx, tn, TopicQuery{Limit: 50, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != len(bodies) {
		t.Fatalf("%d rows, seeded %d", len(rows), len(bodies))
	}
	for _, r := range rows {
		full := want[r.TaskID]
		if got, exp := topicSubject(r.FirstMsg), topicSubject(full); got != exp {
			t.Errorf("subject differs for %s:\n got %q\nwant %q", full, got, exp)
		}
		if len(r.FirstMsg) > 600 {
			t.Errorf("first_msg not cut: %d bytes", len(r.FirstMsg))
		}
		if !slices.Equal(r.Parties, []string{"CLE-07@box-b", "GRK-03@box-a"}) {
			t.Errorf("parties %v", r.Parties)
		}
	}
	// CONTROL: the comparison is not vacuous - the long bodies were cut.
	var cut int
	for _, r := range rows {
		if len(r.FirstMsg) < len(want[r.TaskID])-100 {
			cut++
		}
	}
	if cut < 4 {
		t.Fatalf("only %d first_msg values were shorter than the stored message", cut)
	}
}
