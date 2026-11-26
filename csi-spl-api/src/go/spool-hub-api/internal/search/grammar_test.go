package search

import (
	"reflect"
	"strings"
	"testing"
	"time"
)

var now = time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)

const task1 = "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b"

// the fixture every per-operator row is evaluated against
var (
	mTask = Msg{MsgID: "m1", TaskID: task1, Channel: "tasks", Kind: "task", Body: "Please deploy the hub\n```sh\nmake do-provision\n```",
		FromID: "CLE-07", FromBox: "box-a", ToID: "GRK-03", ToBox: "box-b", ReceivedAt: now.Add(-2 * time.Hour), Files: 1}
	mDM = Msg{MsgID: "m2", TaskID: "11111111-2222-4333-8444-555555555555", Kind: "note", Body: "dry run finished, report attached",
		FromID: "HUM-3", FromBox: "box-wui", ToID: "CLE-07", ToBox: "box-a", ReceivedAt: now.Add(-10 * 24 * time.Hour)}
	fPDF  = File{Msg: mTask, Name: "Q3 Report.pdf", Kind: "file", Bytes: 2 << 20, HasBytes: true}
	fDir  = File{Msg: mTask, Name: "logs", Kind: "dir"}
	thr   = Topic{TaskID: task1, Channel: "tasks", Title: "Migrate the hub to 0018", LastAt: now.Add(-time.Hour), Msgs: []Msg{mTask}}
	thrCh = Topic{TaskID: "22222222-2222-4333-8444-555555555555", Parent: task1, Channel: "alerts", Title: "disk full", LastAt: now.Add(-40 * 24 * time.Hour), Msgs: []Msg{mDM}}
	robot = Entity{Type: TypeRobot, Name: "CLE-07@box-a", Text: []string{"CLE-07", "box-a"}, Box: "box-a", Online: true}
	user  = Entity{Type: TypeUser, Name: "Ops Person (HUM-3)", Text: []string{"HUM-3", "Ops Person"}}
	chanE = Entity{Type: TypeChannel, Name: "tasks", Text: []string{"tasks"}}
	boxE  = Entity{Type: TypeBox, Name: "box-b", Text: []string{"box-b"}, Box: "box-b", Revoked: true}
)

type want struct{ tMsg, dm, pdf, dir, thr, thrCh, robot, user, chanE, boxE bool }

func eval(q *Query) want {
	return want{MatchMsg(q.Root, mTask), MatchMsg(q.Root, mDM), MatchFile(q.Root, fPDF), MatchFile(q.Root, fDir),
		MatchTopic(q.Root, thr), MatchTopic(q.Root, thrCh), MatchEntity(q.Root, robot), MatchEntity(q.Root, user),
		MatchEntity(q.Root, chanE), MatchEntity(q.Root, boxE)}
}

// TestOperators is the table-driven suite of search-v1 §3.2: one row (at
// least) per operator, with the sections it selects and what it matches.
func TestOperators(t *testing.T) {
	all := []Type{TypeMessage, TypeTopic, TypeFile, TypeRobot, TypeUser, TypeChannel, TypeBox, TypeDoc, TypeContact}
	mtf := []Type{TypeMessage, TypeTopic, TypeFile}
	dated := []Type{TypeMessage, TypeTopic, TypeFile, TypeDoc} // before: / after: / on: (a doc section: last edited)
	cases := []struct {
		q     string
		types []Type
		w     want // only the fields of the selected types are meaningful
	}{
		// free text: FTS on messages / topic titles, substring elsewhere
		{"deploy", all, want{tMsg: true}},
		{"DEPLOY hub", all, want{tMsg: true}},
		{"hub", all, want{tMsg: true, thr: true}},
		{`"deploy the hub"`, all, want{tMsg: true}},
		{`"the deploy"`, all, want{}},
		{"report", all, want{dm: true, pdf: true}},
		{"cle", all, want{robot: true}},
		{"ops", all, want{user: true}},
		{"task", all, want{chanE: true}}, // substring of "tasks"; FTS does not stem
		{"box-b", all, want{boxE: true, tMsg: false}},
		// type:
		{"type:robot", []Type{TypeRobot}, want{robot: true}},
		{"type:bot,human", []Type{TypeRobot, TypeUser}, want{robot: true, user: true}},
		{"type:attachment report", []Type{TypeFile}, want{pdf: true}},
		// from: / to: / box:
		{"from:CLE-07", mtf, want{tMsg: true, pdf: true, dir: true, thr: true}},
		{"from:CLE-07@box-a", mtf, want{tMsg: true, pdf: true, dir: true, thr: true}},
		{"from:CLE-07@box-z", mtf, want{}},
		{"from:box-wui", mtf, want{dm: true, thrCh: true}},
		{"to:CLE-07", mtf, want{dm: true, thrCh: true}},
		{"box:box-b", []Type{TypeMessage, TypeTopic, TypeFile, TypeRobot, TypeBox}, want{tMsg: true, pdf: true, dir: true, thr: true, boxE: true}},
		// in:
		{"in:#tasks", mtf, want{tMsg: true, pdf: true, dir: true, thr: true}},
		{"in:dm", mtf, want{dm: true}},
		{"-in:#tasks", mtf, want{dm: true, thrCh: true}},
		{"in:general", mtf, want{}},
		// is:
		{"is:task", []Type{TypeMessage}, want{tMsg: true}},
		{"is:note", []Type{TypeMessage}, want{dm: true}},
		{"is:root", []Type{TypeTopic}, want{thr: true}},
		{"is:online", []Type{TypeRobot, TypeUser, TypeBox}, want{robot: true}},
		{"is:offline", []Type{TypeRobot, TypeUser, TypeBox}, want{user: true, boxE: true}},
		{"is:revoked", []Type{TypeRobot, TypeBox}, want{boxE: true}},
		// has:
		{"has:file", []Type{TypeMessage}, want{tMsg: true}},
		{"has:attachment", []Type{TypeMessage}, want{tMsg: true}},
		{"has:code", []Type{TypeMessage}, want{tMsg: true}},
		// topic:
		{"topic:" + task1, mtf, want{tMsg: true, pdf: true, dir: true, thr: true}},
		{"topic:" + strings.ToUpper(task1), mtf, want{tMsg: true, pdf: true, dir: true, thr: true}},
		// dates
		{"after:7d", dated, want{tMsg: true, pdf: true, dir: true, thr: true}},
		{"before:7d", dated, want{dm: true, thrCh: true}},
		{"after:2026-09-19", dated, want{tMsg: true, pdf: true, dir: true, thr: true}},
		{"before:2026-09-19", dated, want{dm: true, thrCh: true}},
		{"on:2026-09-09", dated, want{dm: true}},
		{"after:3h", dated, want{tMsg: true, pdf: true, dir: true, thr: true}},
		{"after:1h", dated, want{thr: true}},
		{"after:2w", dated, want{tMsg: true, dm: true, pdf: true, dir: true, thr: true}},
		// title: / subject:
		{"title:migrate", []Type{TypeTopic, TypeDoc}, want{thr: true}},
		{`subject:"disk full"`, []Type{TypeTopic, TypeDoc}, want{thrCh: true}},
		// name: / filename: / ext: / larger: / smaller:
		{"name:box", []Type{TypeTopic, TypeFile, TypeRobot, TypeUser, TypeChannel, TypeBox, TypeDoc}, want{robot: true, boxE: true}},
		{"name:hum-3", []Type{TypeTopic, TypeFile, TypeRobot, TypeUser, TypeChannel, TypeBox, TypeDoc}, want{user: true}},
		{`filename:"q3 report"`, []Type{TypeFile}, want{pdf: true}},
		{"ext:PDF", []Type{TypeFile}, want{pdf: true}},
		{"ext:.pdf", []Type{TypeFile}, want{pdf: true}},
		{"larger:1M", []Type{TypeFile}, want{pdf: true}},
		{"larger:2M", []Type{TypeFile}, want{}},
		{"smaller:10K", []Type{TypeFile}, want{}},
		{"smaller:3m", []Type{TypeFile}, want{pdf: true}},
		// boolean structure, Gmail precedence
		{"from:HUM-3 OR from:GRK-03 report", mtf, want{dm: true}},
		{"(deploy OR report) -from:HUM-3", mtf, want{tMsg: true, pdf: true}},
		{"deploy AND hub", all, want{tMsg: true}},
		{"-(is:task OR is:note)", []Type{TypeMessage}, want{}},
		{"deploy or hub", all, want{}}, // lower-case or is text
		// SQL-shaped text is text
		{"'; DROP TABLE messages; --", all, want{}},
	}
	for _, c := range cases {
		q, err := Parse(c.q, now)
		if err != nil {
			t.Errorf("%q: %v", c.q, err)
			continue
		}
		if !reflect.DeepEqual(q.Types, c.types) {
			t.Errorf("%q: types %v, want %v", c.q, q.Types, c.types)
		}
		got, w := eval(q), c.w
		sel := map[Type]bool{}
		for _, ty := range q.Types {
			sel[ty] = true
		}
		mask := func(ty Type, g, x bool, name string) {
			if sel[ty] && g != x {
				t.Errorf("%q: %s = %v, want %v", c.q, name, g, x)
			}
		}
		mask(TypeMessage, got.tMsg, w.tMsg, "task message")
		mask(TypeMessage, got.dm, w.dm, "dm message")
		mask(TypeFile, got.pdf, w.pdf, "pdf file")
		mask(TypeFile, got.dir, w.dir, "dir file")
		mask(TypeTopic, got.thr, w.thr, "topic")
		mask(TypeTopic, got.thrCh, w.thrCh, "child topic")
		mask(TypeRobot, got.robot, w.robot, "robot")
		mask(TypeUser, got.user, w.user, "user")
		mask(TypeChannel, got.chanE, w.chanE, "channel")
		mask(TypeBox, got.boxE, w.boxE, "box")
	}
}

// TestParseErrors: malformed → *Error with the UTF-16 offset of the bad token.
func TestParseErrors(t *testing.T) {
	cases := []struct {
		q     string
		pos   int
		token string
	}{
		{"", 0, ""},
		{"   ", 0, ""},
		{"(a", 0, "("},
		{"a)", 1, ")"},
		{"()", 0, "()"},
		{`a "b c`, 2, `"b c`},
		{"a OR", 2, "OR"},
		{"OR a", 0, "OR"},
		{"a AND", 2, "AND"},
		{"AND a", 0, "AND"},
		{"from:", 0, "from:"},
		{"x from:a@B!", 2, "from:a@B!"},
		{"is:urgent", 0, "is:urgent"},
		{"has:pic", 0, "has:pic"},
		{"before:yesterday", 0, "before:yesterday"},
		{"on:7d", 0, "on:7d"},
		{"after:0d", 0, "after:0d"},
		{"topic:xyz", 0, "topic:xyz"},
		{"larger:big", 0, "larger:big"},
		{"larger:99999999999999G", 0, "larger:99999999999999G"},
		{"ext:p.df", 0, "ext:p.df"},
		{"in:#Bad_Slug", 0, "in:#Bad_Slug"},
		{"box:Box_A", 0, "box:Box_A"},
		{"type:robot type:user", 11, "type:user"},
		{"a OR type:robot", 5, "type:robot"},
		{"-type:robot", 1, "type:robot"},
		{"type:nope", 0, "type:nope"},
		{"filename:plan is:online", 14, "is:online"},
		{"type:robot filename:x", 11, "filename:x"},
		{"title:!!!", 0, "title:!!!"},
		{"héllo 😀 (x", 9, "("}, // offsets are UTF-16: é=1, 😀=2
		{strings.Repeat("((", 5) + "a" + strings.Repeat("))", 5), 8, "("},
		{strings.Repeat("a ", 33), 64, "a"},
		{strings.Repeat("a", 513), 512, ""},
	}
	for _, c := range cases {
		_, err := Parse(c.q, now)
		e, ok := err.(*Error)
		if !ok {
			t.Errorf("%q: err = %v, want *Error", c.q, err)
			continue
		}
		if e.Pos != c.pos || e.Token != c.token {
			t.Errorf("%q: pos %d token %q (%s), want pos %d token %q", c.q, e.Pos, e.Token, e.Detail, c.pos, c.token)
		}
	}
}

// TestWarnings: unknown operators are text plus a warning; URLs are not;
// punctuation-only words are dropped with a warning.
func TestWarnings(t *testing.T) {
	q, err := Parse("foo:bar https://x.example/a !!! deploy", now)
	if err != nil {
		t.Fatal(err)
	}
	if len(q.Warnings) != 2 || q.Warnings[0].Token != "foo:bar" || q.Warnings[0].Pos != 0 || q.Warnings[1].Token != "!!!" || q.Warnings[1].Pos != 28 {
		t.Fatalf("warnings: %+v", q.Warnings)
	}
	if !MatchMsg(q.Root, Msg{Body: "foo:bar at https://x.example/a — deploy"}) || MatchMsg(q.Root, Msg{Body: "deploy only"}) {
		t.Fatal("unknown operator and URL must be searched as text")
	}
	if q, err = Parse("!!!", now); err != nil || q.Root != nil || len(q.Warnings) != 1 {
		t.Fatalf("punctuation only: %v %+v", err, q)
	}
}

// TestHighlights: UTF-16 offsets, whole words for FTS, substrings for names,
// negated terms never highlighted, snippets cut at word boundaries.
func TestHighlights(t *testing.T) {
	q, _ := Parse(`deploy -hub "dry run"`, now)
	if got := q.HighlightWords("😀 Deploy the hub; redeploy"); !reflect.DeepEqual(got, []Span{{3, 9}}) {
		t.Fatalf("words: %v", got)
	}
	if got := q.HighlightWords("a dry run"); !reflect.DeepEqual(got, []Span{{2, 5}, {6, 9}}) {
		t.Fatalf("phrase words: %v", got)
	}
	q, _ = Parse("box name:A", now)
	if got := q.HighlightSubstrings("CLE-07@box-a"); !reflect.DeepEqual(got, []Span{{7, 10}, {11, 12}}) {
		t.Fatalf("substrings: %v", got)
	}
	q, _ = Parse("hub ub", now)
	if got := q.HighlightSubstrings("the hub"); !reflect.DeepEqual(got, []Span{{4, 7}}) {
		t.Fatalf("overlaps merged: %v", got)
	}
	q, _ = Parse("needle", now)
	body := strings.Repeat("word ", 100) + "the needle\nis here " + strings.Repeat("tail ", 100)
	text, hs := q.Snippet(body)
	if len([]rune(text)) > SnippetMax || !strings.HasPrefix(text, "… ") || !strings.HasSuffix(text, " …") || len(hs) != 1 {
		t.Fatalf("snippet %q %v", text, hs)
	}
	if got := text[len(string(utf16Prefix(text, hs[0][0]))):]; !strings.HasPrefix(got, "needle") {
		t.Fatalf("highlight lands on %q", got)
	}
	if strings.Contains(text, "\n") {
		t.Fatal("snippet keeps newlines")
	}
	short, hs := q.Snippet("a needle")
	if short != "a needle" || !reflect.DeepEqual(hs, []Span{{2, 8}}) {
		t.Fatalf("short snippet %q %v", short, hs)
	}
}

// TestSnippetEdges: a first hit near the start is not cut before the body, and
// one near the end is not cut past it.
func TestSnippetEdges(t *testing.T) {
	q, _ := Parse("needle", now)
	head, _ := q.Snippet("the needle " + strings.Repeat("word ", 100))
	if !strings.HasPrefix(head, "the needle ") || !strings.HasSuffix(head, " …") || len([]rune(head)) > SnippetMax {
		t.Fatalf("head snippet %q", head)
	}
	tail, _ := q.Snippet(strings.Repeat("word ", 100) + "the needle")
	if !strings.HasPrefix(tail, "… ") || !strings.HasSuffix(tail, "the needle") || len([]rune(tail)) > SnippetMax {
		t.Fatalf("tail snippet %q", tail)
	}
}

// TestOperatorTable: every operator is documented and reachable by name.
func TestOperatorTable(t *testing.T) {
	issueFixture(t)
	for _, o := range Operators {
		if o.Doc == "" || o.Example == "" || len(o.Applies) == 0 {
			t.Errorf("%s: incomplete row", o.Name)
		}
		if _, err := Parse(strings.Replace(o.Example, "<task_id>", task1, 1), now); err != nil {
			t.Errorf("%s: example %q does not parse: %v", o.Name, o.Example, err)
		}
	}
}

// search-v1 §2.2 prefix (owner, 2026-09-26).
func TestParsePrefix(t *testing.T) {
	now := time.Now()
	leafOf := func(q string) *Term {
		t.Helper()
		p, err := Parse(q, now)
		if err != nil || p.Root == nil || p.Root.Kind != Leaf {
			t.Fatalf("%q: %v %+v", q, err, p)
		}
		return p.Root.Term
	}
	if tm := leafOf("deplo*"); !tm.Prefix || tm.Value != "deplo" {
		t.Fatalf("deplo*: %+v", tm)
	}
	if tm := leafOf("title:mig*"); !tm.Prefix || tm.Lexemes[0] != "mig" {
		t.Fatalf("title:mig*: %+v", tm)
	}
	// as you type (1.1): the query's last bare word is a prefix
	if tm := leafOf("deplo"); !tm.Prefix {
		t.Fatalf("last bare word: %+v", tm)
	}
	// CONTROL: a quoted phrase, and a word with a space typed after it, are
	// never a prefix
	if tm := leafOf(`"deplo*"`); tm.Prefix {
		t.Fatalf("phrase must not be a prefix: %+v", tm)
	}
	if tm := leafOf("deploy "); tm.Prefix {
		t.Fatalf("finished word: %+v", tm)
	}
	// FTS (memory store) agrees with Postgres: the last lexeme only
	if !FTS("the hub is green", &Term{Lexemes: []string{"hub", "gre"}, Prefix: true}) {
		t.Fatal("hub gre* must match 'hub is green'")
	}
	if FTS("the hub is green", &Term{Lexemes: []string{"hu", "green"}, Prefix: true}) {
		t.Fatal("CONTROL: only the LAST word is a prefix")
	}
}

// Grammar 1.8 (spec 187 row S2): idle: / changed: on topics and issues, key:
// / epic: on issues. CONTROLS: a topic with a message 29 days ago is not
// idle:30d, the one silent 31 days is (and changed:7d is the inverse);
// key:SPL-7 is not SPL-70; epic:SPL-17 is its issues, never SPL-17 itself;
// each operator is refused on a type it does not apply to.
func TestIdleChangedKeyEpic(t *testing.T) {
	old := Topic{TaskID: task1, Title: "old", LastAt: now.Add(-31 * 24 * time.Hour)}
	recent := Topic{TaskID: task1, Title: "recent", LastAt: now.Add(-29 * 24 * time.Hour)}
	fresh := Topic{TaskID: task1, Title: "fresh", LastAt: now.Add(-2 * 24 * time.Hour)}
	topics := []struct {
		q              string
		old, rec, frsh bool
	}{
		{"idle:30d", true, false, false},
		{"changed:30d", false, true, true},
		{"changed:7d", false, false, true},
		{"idle:7d", true, true, false},
		{"-idle:30d", false, true, true},
		{"idle:4w", true, true, false}, // 28 days: the 29-day topic too
		{"idle:720h", true, false, false},
	}
	for _, c := range topics {
		q, err := Parse(c.q, now)
		if err != nil {
			t.Fatalf("%q: %v", c.q, err)
		}
		if !reflect.DeepEqual(q.Types, []Type{TypeTopic}) {
			t.Errorf("%q: types %v, want [topic]", c.q, q.Types)
		}
		if got := [3]bool{MatchTopic(q.Root, old), MatchTopic(q.Root, recent), MatchTopic(q.Root, fresh)}; got != [3]bool{c.old, c.rec, c.frsh} {
			t.Errorf("%q: old/29d/2d = %v, want %v", c.q, got, [3]bool{c.old, c.rec, c.frsh})
		}
	}

	ep := Entity{Type: TypeIssue, Key: "SPL-17", Changed: now.Add(-40 * 24 * time.Hour)}
	i7 := Entity{Type: TypeIssue, Key: "SPL-7", Epic: "SPL-17", Changed: now.Add(-31 * 24 * time.Hour)}
	i70 := Entity{Type: TypeIssue, Key: "SPL-70", Epic: "SPL-1", Changed: now.Add(-3 * 24 * time.Hour)}
	sub := Entity{Type: TypeIssue, Key: "SPL-71", Epic: "SPL-17", Changed: now.Add(-time.Hour)} // a subtask: its level-1 row
	never := Entity{Type: TypeIssue, Key: "SPL-72", Epic: "SPL-17"}                             // no change time: neither idle nor changed
	issues := []struct {
		q    string
		want [5]bool // ep, i7, i70, sub, never
	}{
		{"key:SPL-7", [5]bool{false, true, false, false, false}},
		{"key:spl-7", [5]bool{false, true, false, false, false}},
		{"key:SPL-70", [5]bool{false, false, true, false, false}},
		{"epic:SPL-17", [5]bool{false, true, false, true, true}},
		{"epic:SPL-17 OR key:SPL-17", [5]bool{true, true, false, true, true}},
		{"type:issue idle:30d", [5]bool{true, true, false, false, false}},
		{"type:issue changed:30d", [5]bool{false, false, true, true, false}},
		{"type:issue changed:7d", [5]bool{false, false, true, true, false}},
		{"epic:SPL-17 idle:7d", [5]bool{false, true, false, false, false}},
	}
	for _, c := range issues {
		q, err := Parse(c.q, now)
		if err != nil {
			t.Fatalf("%q: %v", c.q, err)
		}
		if !reflect.DeepEqual(q.Types, []Type{TypeIssue}) {
			t.Errorf("%q: types %v, want [issue]", c.q, q.Types)
		}
		got := [5]bool{MatchEntity(q.Root, ep), MatchEntity(q.Root, i7), MatchEntity(q.Root, i70), MatchEntity(q.Root, sub), MatchEntity(q.Root, never)}
		if got != c.want {
			t.Errorf("%q: %v, want %v", c.q, got, c.want)
		}
	}
	// idle: on issues alone, without type:, searches topics (a default type)
	if q, _ := Parse("idle:30d", now); !reflect.DeepEqual(q.Types, []Type{TypeTopic}) {
		t.Errorf("idle:30d: types %v", q.Types)
	}

	// CONTROLS: refused where they do not apply, and bad values
	for _, bad := range []string{"type:topic key:SPL-7", "type:message epic:SPL-17", "type:robot key:SPL-7",
		"type:message idle:30d", "type:file changed:7d", "in:#lobby key:SPL-7", "key:SPL", "key:7", "epic:SPL-x",
		"key:SPL-7-1", "idle:30", "idle:0d", "idle:2026-01-01", "changed:month"} {
		if _, err := Parse(bad, now); err == nil {
			t.Errorf("%q: want a bad query", bad)
		}
	}
}
