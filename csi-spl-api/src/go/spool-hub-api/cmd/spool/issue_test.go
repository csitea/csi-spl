package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// TestParseIssueArgs pins what `spool issue` sends the hub for each op and
// flag shape: the IssueArgs as JSON, or the error.
func TestParseIssueArgs(t *testing.T) {
	dir := t.TempDir()
	desc := filepath.Join(dir, "desc.md")
	if err := os.WriteFile(desc, []byte("## from a file\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		op   string
		args []string
		want string
	}{
		{"list", []string{"--as", "CLE-1"}, `{"op":"list","as":"CLE-1"}`},
		{"list", []string{"--as", "CLE-1", "--status", "wip,qas", "--priority", "1,2", "--level", "2", "--assignee", "me", "--label", "bug",
			"--deadline-before", "2026-10-01T00:00:00Z", "--deadline-after", "2026-09-01T00:00:00Z", "--sort", "deadline",
			"--epic", "SPL-1", "--kind", "epic", "--parent", "SPL-3"},
			`{"op":"list","as":"CLE-1","query":"assignee=me\u0026deadline_after=2026-09-01T00%3A00%3A00Z\u0026deadline_before=2026-10-01T00%3A00%3A00Z\u0026epic=SPL-1\u0026kind=epic\u0026label=bug\u0026level=2\u0026parent=SPL-3\u0026priority=1%2C2\u0026sort=deadline\u0026status=wip%2Cqas"}`},
		{"list", []string{"--as", "CLE-1", "--labels", "x", "--title", "ignored"}, `{"op":"list","as":"CLE-1"}`},
		{"get", []string{"--as", "CLE-1", "--ref", "SPL-3"}, `{"op":"get","as":"CLE-1","ref":"SPL-3"}`},
		{"create", []string{"--as", "CLE-1", "--title", "T", "--epic", "SPL-1"}, `{"op":"create","as":"CLE-1","issue":{"epic":"SPL-1","title":"T"}}`},
		{"create", []string{"--as", "CLE-1", "--title", "T", "--parent", "SPL-3", "--description", "D", "--status", "wip",
			"--priority", "2", "--level", "3", "--assignee", "HUM-1", "--labels", " a, ,b ", "--deadline", "2026-10-01T15:00:00Z", "--kind", "issue"},
			`{"op":"create","as":"CLE-1","issue":{"assignee":"HUM-1","deadline":"2026-10-01T15:00:00Z","description":"D","kind":"issue","labels":["a","b"],"level":3,"parent":"SPL-3","priority":2,"status":"wip","title":"T"}}`},
		{"create", []string{"--as", "CLE-1", "--title", "T", "--kind", "epic", "--description-file", desc},
			`{"op":"create","as":"CLE-1","issue":{"description":"## from a file\n","kind":"epic","title":"T"}}`},
		{"update", []string{"--as", "CLE-1", "--ref", "SPL-3", "--deadline", "", "--labels", ""},
			`{"op":"update","as":"CLE-1","ref":"SPL-3","issue":{"deadline":"","labels":[]}}`},
		{"update", []string{"--as", "CLE-1", "--ref", "SPL-3"}, `{"op":"update","as":"CLE-1","ref":"SPL-3","issue":{}}`},
		{"update", []string{"--as", "CLE-1", "--ref", "SPL-3", "--priority", "high"}, `error: --priority must be a number`},
		{"update", []string{"--as", "CLE-1", "--ref", "SPL-3", "--level", "x"}, `error: --level must be a number`},
		{"create", []string{"--as", "CLE-1", "--description-file", filepath.Join(dir, "missing")}, `error: open ` + filepath.Join(dir, "missing") + `: no such file or directory`},
		{"comment", []string{"--as", "CLE-1", "--ref", "SPL-3", "--body", "hi"}, `{"op":"comment","as":"CLE-1","ref":"SPL-3","body":"hi"}`},
		{"comment", []string{"--as", "CLE-1", "--ref", "SPL-3", "--body", "hi", "--body-file", desc}, `{"op":"comment","as":"CLE-1","ref":"SPL-3","body":"## from a file\n"}`},
		{"comment", []string{"--as", "CLE-1", "--body-file", filepath.Join(dir, "missing")}, `error: open ` + filepath.Join(dir, "missing") + `: no such file or directory`},
		{"label", []string{"--as", "CLE-1", "--name", "perf", "--color", "#ff0000"}, `{"op":"label","as":"CLE-1","issue":{"color":"#ff0000","name":"perf"}}`},
		{"label", []string{"--as", "CLE-1"}, `{"op":"label","as":"CLE-1","issue":{"color":"","name":""}}`},
		{"frobnicate", []string{"--as", "CLE-1", "--ref", "SPL-3"}, `{"op":"frobnicate","as":"CLE-1","ref":"SPL-3"}`},
		{"list", []string{"--nope"}, `error: bad flags`},
	}
	for _, c := range cases {
		in, err := parseIssueArgs(c.op, c.args)
		got := ""
		if err != nil {
			got = "error: " + err.Error()
		} else {
			b, jerr := json.Marshal(in)
			if jerr != nil {
				t.Fatal(jerr)
			}
			got = string(b)
		}
		if got != c.want {
			t.Errorf("%s %q:\n got %s\nwant %s", c.op, c.args, got, c.want)
		}
	}
}
