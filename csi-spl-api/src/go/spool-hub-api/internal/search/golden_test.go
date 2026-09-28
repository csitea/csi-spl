package search

import (
	"encoding/json"
	"flag"
	"os"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "rewrite testdata/parse.golden from the current parser")

// goldenQueries walk every operator's accept and reject branches and every
// finish() rule (type: placement, implied types, applicability). The golden
// file was recorded from the parser BEFORE the SPL-1029 round-2 splits of
// operator() and finish(), so those refactors are pinned byte for byte.
var goldenQueries = []string{
	"", "deploy", "deplo*", `"dry run"`, "deploy hub", "deploy OR hub", "-deploy hub", "(deploy OR hub) -dry",
	// type:
	"type:robot", "type:robot,user", "type:robot,robot", "kind:tickets", "type:", "type:nope", "-type:robot",
	"type:robot type:user", "deploy OR type:robot", "(type:robot)", "type:issue deploy", "type:robot is:task",
	// from: / to: / box:
	"from:CLE-07", "from:CLE-07@box-a", "from:CLE-07@Box_A", "from:-bad", "to:HUM-3", "to:@box", "box:box-a", "box:BOX-A", "box:bad_box",
	// in:
	"in:#lobby", "in:general", "in:#general", "in:dm", "in:DM", "channel:tasks", "in:#Bad_Chan", "in:#",
	// is: / has:
	"is:task", "is:TASK", "is:root", "is:online", "is:revoked", "is:nope", "has:file", "has:attachment", "has:code", "has:nope",
	// topic:
	"topic:6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b", "topic:6F1C2A3B-4D5E-4F60-8A7B-9C0D1E2F3A4B", "topic:nope",
	// before: / after: / on:
	"before:2026-09-01", "after:7d", "after:24h", "after:2w", "on:2026-09-19", "on:7d", "after:0d", "after:3651d", "after:3650d", "before:yesterday",
	// title: / name: / filename: / ext:
	"title:migration", "subject:migra*", `title:"the hub"`, "title:*", "title:---", "name:ops", `filename:"q3 report"`, "ext:pdf", "ext:.PDF", "ext:toolongextension12", "ext:p-f",
	// larger: / smaller:
	"larger:1M", "smaller:10K", "larger:2G", "larger:12345", "larger:1T", "larger:999999999999999G", "larger:4294967296G", "smaller:x",
	// the issue fields
	"status:wip", "status:in_progress", "status:nope", "prio:1", "prio=1", "priority:9", "prio:x", "assignee:me", "assignee:none",
	"assignee:CLE-07", "assignee:-x", "label:Bug", "type:issue status:done prio:2", "status:done deploy",
	// applicability
	"type:robot ext:pdf", "type:file ext:pdf", "ext:pdf is:online", "status:done is:task", "type:issue from:CLE-07",
	// empty values
	"from:", `title:""`, "in: x",
}

func TestParseGolden(t *testing.T) {
	issueFixture(t)
	var b strings.Builder
	for _, q := range goldenQueries {
		b.WriteString("## " + q + "\n")
		p, err := Parse(q, now)
		if err != nil {
			b.WriteString("error: " + err.Error() + "\n")
			continue
		}
		j, err := json.Marshal(p)
		if err != nil {
			t.Fatal(err)
		}
		b.Write(j)
		b.WriteString("\n")
	}
	const path = "testdata/parse.golden"
	if *update {
		if err := os.MkdirAll("testdata", 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := b.String(); got != string(want) {
		gl, wl := strings.Split(got, "\n"), strings.Split(string(want), "\n")
		for i := 0; i < len(gl) && i < len(wl); i++ {
			if gl[i] != wl[i] {
				t.Fatalf("parse output differs from %s at line %d:\n got %s\nwant %s", path, i+1, gl[i], wl[i])
			}
		}
		t.Fatalf("parse output differs from %s in length: %d vs %d lines", path, len(gl), len(wl))
	}
}
