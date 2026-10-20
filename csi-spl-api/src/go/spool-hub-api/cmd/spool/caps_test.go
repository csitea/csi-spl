package main

import (
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
)

// Spec 147 5.2: the desk pre-check refuses at the cap, admits under it and
// for an uncapped vendor, and names agent, vendor, workspace, cap and count.
func TestCapsVerdict(t *testing.T) {
	one, two := 1, 2
	a := capsAnswer{WorkspaceID: "example-ws",
		Caps: map[string]*int{"claude": &one, "agy": &two, "qwen": nil},
		Live: map[string]int{"claude": 1, "agy": 1, "qwen": 5}}
	if got, want := capsVerdict(a, "c-005"), "agent c-005 (claude) exceeds workspace example-ws cap of 1 (currently 1 live); seating refused"; got != want {
		t.Fatalf("claude at cap: %q, want %q", got, want)
	}
	for _, id := range []string{"a-005", "q-006", "m-004", "g-004"} {
		if got := capsVerdict(a, id); got != "" {
			t.Errorf("%s: refused %q", id, got)
		}
	}
	a.Live["agy"] = 2
	if capsVerdict(a, "a-006") == "" {
		t.Fatal("3rd agy at cap 2 admitted")
	}
}

const capsReply = `{"workspace_id":"example-ws","caps":{"claude":1,"agy":2,"qwen":null},"live":{"claude":1,"agy":1},"can_edit":true}`

// TestCapsList: a bare `spool caps` sends agent_caps_get with no row and
// prints the hub's answer as is.
func TestCapsList(t *testing.T) {
	h := newScriptHub(t, laneAnswer(map[string]string{"agent_caps_get": capsReply}), nil)
	cfg := hubCfg(t, h.URL)
	rc, out, errOut := capture(t, "", func() int { return cmdCaps(cfg, nil) })
	if rc != 0 || out != capsReply+"\n" {
		t.Fatalf("caps: rc %d %q err %q, want 0 %q", rc, out, errOut, capsReply)
	}
	fr := h.Frames()
	if len(fr) != 1 || fr[0].LaneOp != "agent_caps_get" || len(fr[0].Lane) != 0 {
		t.Fatalf("frames = %d %+v, want one agent_caps_get with no row", len(fr), fr)
	}
}

// TestCapsCheck: exit 0 under the cap and for an uncapped vendor, exit 3
// with the one-line refusal at the cap; each line names count and cap.
func TestCapsCheck(t *testing.T) {
	h := newScriptHub(t, laneAnswer(map[string]string{"agent_caps_get": capsReply}), nil)
	cfg := hubCfg(t, h.URL)
	for _, c := range []struct {
		agent string
		rc    int
		want  string
	}{
		{"a-005", 0, "ok a-005 (agy): 1 of 2 live in example-ws\n"},
		{"q-006", 0, "ok q-006 (qwen): uncapped in example-ws\n"},
		{"g-004", 0, "ok g-004 (grok): uncapped in example-ws\n"},
		{"c-005", 3, "agent c-005 (claude) exceeds workspace example-ws cap of 1 (currently 1 live); seating refused\n"},
	} {
		rc, out, errOut := capture(t, "", func() int { return cmdCaps(cfg, []string{"check", c.agent}) })
		if rc != c.rc || out != c.want {
			t.Errorf("check %s: rc %d %q err %q, want %d %q", c.agent, rc, out, errOut, c.rc, c.want)
		}
	}
}

// TestCapsRefusals: every usage error and bad answer exits 1 and names why;
// a usage error or a bad agent id is refused before anything is sent.
func TestCapsRefusals(t *testing.T) {
	bad := newScriptHub(t, laneAnswer(map[string]string{"agent_caps_get": `[1,2]`}), nil)
	none := newScriptHub(t, laneAnswer(nil), nil)
	for _, c := range []struct {
		name string
		hub  *scriptHub
		args []string
		want string
	}{
		{"local mode", nil, nil, "need hub mode"},
		{"unknown sub-verb", none, []string{"show"}, "usage: spool caps"},
		{"check no agent", none, []string{"check"}, "usage: spool caps"},
		{"check two agents", none, []string{"check", "c-001", "c-002"}, "usage: spool caps"},
		{"check not an agent id", none, []string{"check", "box-a"}, `"box-a" is not an agent id`},
		{"list hub refuses", none, nil, "bad_lane_op"},
		{"check hub refuses", none, []string{"check", "c-001"}, "bad_lane_op"},
		{"check answer not caps", bad, []string{"check", "c-001"}, "not caps JSON"},
	} {
		cfg := testkit.NewConfig(t)
		if c.hub != nil {
			cfg = hubCfg(t, c.hub.URL)
		}
		rc, out, errOut := capture(t, "", func() int { return cmdCaps(cfg, c.args) })
		if rc != 1 || out != "" || !strings.Contains(errOut, c.want) {
			t.Errorf("%s: rc %d out %q err %q, want 1 naming %q", c.name, rc, out, errOut, c.want)
		}
	}
	if n := len(none.Frames()); n != 2 {
		t.Errorf("refusing hub read %d frames, want 2 (the two hub-refused cases only)", n)
	}
}

// TestDocWriteArgs: --file in every spelling moves ahead of the path, and a
// `--` keeps everything after it positional.
func TestDocWriteArgs(t *testing.T) {
	for _, c := range []struct{ in, want []string }{
		{[]string{"p.md", "--file", "f"}, []string{"--file", "f", "p.md"}},
		{[]string{"p.md", "-file", "f"}, []string{"-file", "f", "p.md"}},
		{[]string{"p.md", "--file=f"}, []string{"--file=f", "p.md"}},
		{[]string{"-file=f", "p.md"}, []string{"-file=f", "p.md"}},
		{[]string{"p.md", "--file"}, []string{"--file", "p.md"}},
		{[]string{"--file", "f", "--", "--file", "x"}, []string{"--file", "f", "--file", "x"}},
		{[]string{"--", "p.md"}, []string{"p.md"}},
	} {
		if got := docWriteArgs(c.in); !reflect.DeepEqual(got, c.want) {
			t.Errorf("docWriteArgs(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// TestDocFlagParsing: a bad flag prints the verb's usage and maps to
// errDocFlags; oneDocPath exits 1 on a bad flag and a wrong path count,
// and returns the path otherwise.
func TestDocFlagParsing(t *testing.T) {
	const usage = "usage: spool doc-read <path>"
	var fsErr error
	_, _, errOut := capture(t, "", func() int {
		_, fsErr = docFlagSet("doc-read", usage, []string{"--nope"})
		return 0
	})
	if !errors.Is(fsErr, errDocFlags) || !strings.Contains(errOut, usage) {
		t.Fatalf("bad flag: err %v stderr %q, want errDocFlags and the usage", fsErr, errOut)
	}
	for _, c := range []struct {
		name string
		args []string
		want string
	}{
		{"bad flag", []string{"--nope", "a.md"}, usage},
		{"no path", nil, "spool: " + usage},
		{"two paths", []string{"a.md", "b.md"}, "spool: " + usage},
	} {
		var ok bool
		var rc int
		_, _, errOut := capture(t, "", func() int {
			_, _, rc, ok = oneDocPath("doc-read", usage, c.args)
			return rc
		})
		if ok || rc != 1 || !strings.Contains(errOut, c.want) {
			t.Errorf("%s: rc %d ok %v %q, want 1 false naming %q", c.name, rc, ok, errOut, c.want)
		}
	}
	raw, rel, rc, ok := oneDocPath("doc-read", usage, []string{"notes/a.md"})
	if !ok || rc != 0 || raw != "notes/a.md" || rel == "" {
		t.Errorf("one path: raw %q rel %q rc %d ok %v", raw, rel, rc, ok)
	}
}
