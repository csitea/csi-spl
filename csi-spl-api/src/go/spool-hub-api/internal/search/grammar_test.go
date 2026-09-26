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
	all := []Type{TypeMessage, TypeTopic, TypeFile, TypeRobot, TypeUser, TypeChannel, TypeBox}
	mtf := []Type{TypeMessage, TypeTopic, TypeFile}
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
		{"after:7d", mtf, want{tMsg: true, pdf: true, dir: true, thr: true}},
		{"before:7d", mtf, want{dm: true, thrCh: true}},
		{"after:2026-09-19", mtf, want{tMsg: true, pdf: true, dir: true, thr: true}},
		{"before:2026-09-19", mtf, want{dm: true, thrCh: true}},
		{"on:2026-09-09", mtf, want{dm: true}},
		{"after:3h", mtf, want{tMsg: true, pdf: true, dir: true, thr: true}},
		{"after:1h", mtf, want{thr: true}},
		{"after:2w", mtf, want{tMsg: true, dm: true, pdf: true, dir: true, thr: true}},
		// title: / subject:
		{"title:migrate", []Type{TypeTopic}, want{thr: true}},
		{`subject:"disk full"`, []Type{TypeTopic}, want{thrCh: true}},
		// name: / filename: / ext: / larger: / smaller:
		{"name:box", []Type{TypeTopic, TypeFile, TypeRobot, TypeUser, TypeChannel, TypeBox}, want{robot: true, boxE: true}},
		{"name:hum-3", []Type{TypeTopic, TypeFile, TypeRobot, TypeUser, TypeChannel, TypeBox}, want{user: true}},
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
		{"a -", 2, "-"},
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

// TestOperatorTable: every operator is documented and reachable by name.
func TestOperatorTable(t *testing.T) {
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
	// as you type (1.1, CLE-34992): the query's last bare word is a prefix
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
