package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The client half of the verbs that ride one lane frame (memory, lifecycle,
// box-stats): what each sends, how it prints the hub's answer, and the
// refusals made before anything is sent (r7-10).

// TestMemoryVerbs: add (new and merged), show and index against a scripted
// hub; the frames carry the op and the row.
func TestMemoryVerbs(t *testing.T) {
	added := `{"lesson":{"title":"Tmux wraps"},"merged":false}`
	h := newScriptHub(t, func(f wire.Frame) []wire.Frame {
		if f.LaneOp == "memory_add" && strings.Contains(string(f.Lane), "again") {
			return laneAnswer(map[string]string{"memory_add": `{"lesson":{"title":"Tmux wraps","merges":2},"merged":true}`})(f)
		}
		return laneAnswer(map[string]string{
			"memory_add":   added,
			"memory_show":  `{"lesson":{"title":"Tmux wraps","body":"capture-pane splits words"}}`,
			"memory_index": `{"lessons":[{"title":"Tmux wraps","line":"split words","body":"never printed"},{"title":"Bare"}]}`,
		})(f)
	}, nil)
	cfg := hubCfg(t, h.URL)
	for _, c := range []struct {
		name, in string
		args     []string
		want     string
	}{
		{"add", "", []string{"add", "--title", "Tmux wraps", "--text", "capture-pane splits words"}, "added \"Tmux wraps\"\n"},
		{"add merged from stdin", "said again\n", []string{"add", "--title", "Tmux wraps", "--text", "-"}, "merged into \"Tmux wraps\" (2 merges)\n"},
		{"show", "", []string{"show", "Tmux", "wraps"}, "# Tmux wraps\n\ncapture-pane splits words\n"},
		{"index", "", []string{"index"}, "- Tmux wraps: split words\n- Bare\n"},
	} {
		rc, out, errOut := capture(t, c.in, func() int { return cmdMemory(cfg, c.args) })
		if rc != 0 || out != c.want {
			t.Errorf("%s: rc %d out %q err %q, want 0 %q", c.name, rc, out, errOut, c.want)
		}
	}
	fr := h.Frames()
	if len(fr) != 4 {
		t.Fatalf("hub read %d frames, want 4", len(fr))
	}
	var row map[string]string
	if err := json.Unmarshal(fr[1].Lane, &row); err != nil || row["title"] != "Tmux wraps" || row["text"] != "said again\n" {
		t.Errorf("stdin add row = %s (%v)", fr[1].Lane, err)
	}
	if fr[3].LaneOp != "memory_index" || len(fr[3].Lane) != 0 {
		t.Errorf("index frame = %s %s, want memory_index with no row", fr[3].LaneOp, fr[3].Lane)
	}
}

// TestMemoryRefusals: every usage error and bad answer exits 1 and names why.
func TestMemoryRefusals(t *testing.T) {
	h := newScriptHub(t, laneAnswer(map[string]string{"memory_show": `[]`}), nil)
	cfg := hubCfg(t, h.URL)
	local := testkit.NewConfig(t)
	for _, c := range []struct {
		name string
		hub  bool
		args []string
		want string
	}{
		{"no sub-verb", true, nil, "usage: spool memory"},
		{"local mode", false, []string{"index"}, "needs hub mode"},
		{"unknown sub-verb", true, []string{"forget"}, `unknown sub-verb "forget"`},
		{"add bad flag", true, []string{"add", "--nope"}, "flag provided but not defined"},
		{"add no title", true, []string{"add", "--text", "x"}, "title must name the lesson"},
		{"show no title", true, []string{"show", " "}, "usage: spool memory show"},
		{"index with args", true, []string{"index", "x"}, "usage: spool memory index"},
		{"answer does not parse", true, []string{"show", "t"}, "does not parse"},
		{"hub refuses the op", true, []string{"index"}, "bad_lane_op"},
	} {
		c2 := cfg
		if !c.hub {
			c2 = local
		}
		rc, _, errOut := capture(t, "", func() int { return cmdMemory(c2, c.args) })
		if rc != 1 || !strings.Contains(errOut, c.want) {
			t.Errorf("%s: rc %d %q, want 1 naming %q", c.name, rc, errOut, c.want)
		}
	}
}

// TestLifecycleConfigPrintsKeyOrder: KEY=VALUE in the key table's order, an
// enum unquoted, a key this build does not know after them.
func TestLifecycleConfigPrintsKeyOrder(t *testing.T) {
	h := newScriptHub(t, laneAnswer(map[string]string{
		"lifecycle_config": `{"config":{"seat_fail_action":"respawn","lane_restart_ctx_k":400,"zz_new_key":7}}`,
	}), nil)
	cfg := hubCfg(t, h.URL)
	rc, out, errOut := capture(t, "", func() int { return cmdLifecycle(cfg, []string{"config"}) })
	want := "LANE_RESTART_CTX_K=400\nSEAT_FAIL_ACTION=respawn\nZZ_NEW_KEY=7\n"
	if rc != 0 || out != want {
		t.Fatalf("config: rc %d %q err %q, want %q", rc, out, errOut, want)
	}
}

// TestLifecycleEvent: a valid event from a file and from stdin is sent as
// is, with --fleet on the frame; the hub's answer is printed.
func TestLifecycleEvent(t *testing.T) {
	h := newScriptHub(t, laneAnswer(map[string]string{"lifecycle_event": `{"ok":true}`}), nil)
	cfg := hubCfg(t, h.URL)
	ev := `{"agent_id":"c-001","role":"lane","event":"restart","reason":"size","outcome":"ok"}`
	file := filepath.Join(t.TempDir(), "ev.json")
	if err := os.WriteFile(file, []byte(ev), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"event", "--json", file, "--fleet", "f1"}, {"event", "--json", "-"}} {
		rc, out, errOut := capture(t, ev, func() int { return cmdLifecycle(cfg, args) })
		if rc != 0 || out != "{\"ok\":true}\n" {
			t.Errorf("%v: rc %d %q err %q", args, rc, out, errOut)
		}
	}
	fr := h.Frames()
	if len(fr) != 2 || fr[0].Fleet != "f1" || fr[1].Fleet != "" || string(fr[0].Lane) != ev {
		t.Fatalf("frames = %+v", fr)
	}
}

func TestLifecycleRefusals(t *testing.T) {
	h := newScriptHub(t, laneAnswer(map[string]string{"lifecycle_config": `[]`}), nil)
	cfg := hubCfg(t, h.URL)
	for _, c := range []struct {
		name, in string
		hub      bool
		args     []string
		want     string
	}{
		{"no sub-verb", "", true, nil, "usage: spool lifecycle"},
		{"local mode", "", false, []string{"config"}, "needs hub mode"},
		{"unknown sub-verb", "", true, []string{"reset"}, `unknown sub-verb "reset"`},
		{"config bad flag", "", true, []string{"config", "--x"}, "flag provided but not defined"},
		{"config answer does not parse", "", true, []string{"config"}, "does not parse"},
		{"event bad flag", "", true, []string{"event", "--x"}, "flag provided but not defined"},
		{"event no --json", "", true, []string{"event"}, "--json <file|-> is required"},
		{"event missing file", "", true, []string{"event", "--json", "/nonexistent/ev.json"}, "no such file"},
		{"event unknown field", `{"role":"lane","event":"restart","x":1}`, true, []string{"event", "--json", "-"}, "not one event object"},
		{"event bad role", `{"role":"boss","event":"restart"}`, true, []string{"event", "--json", "-"}, "role must be"},
		{"event hub refuses", `{"role":"lane","event":"restart"}`, true, []string{"event", "--json", "-"}, "bad_lane_op"},
	} {
		c2 := cfg
		if !c.hub {
			c2 = testkit.NewConfig(t)
		}
		rc, _, errOut := capture(t, c.in, func() int { return cmdLifecycle(c2, c.args) })
		if rc != 1 || !strings.Contains(errOut, c.want) {
			t.Errorf("%s: rc %d %q, want 1 naming %q", c.name, rc, errOut, c.want)
		}
	}
}

// TestBoxStatsVerbs: put sends the sample as is, list sends {box, since}.
func TestBoxStatsVerbs(t *testing.T) {
	h := newScriptHub(t, laneAnswer(map[string]string{
		"box_stats_put":  `{"ok":true}`,
		"box_stats_list": `{"since":"x","rows":[],"hours":[]}`,
	}), nil)
	cfg := hubCfg(t, h.URL)
	sample := `{"box":"box-a","load1":0.5,"load5":0.4,"load15":0.3,"cpus":8,"mem_total_kb":1,"mem_avail_kb":1,"swap_used_kb":0,"agents_live":2}`
	file := filepath.Join(t.TempDir(), "s.json")
	if err := os.WriteFile(file, []byte(sample), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		in   string
		args []string
		want string
	}{
		{"", []string{"put", "--json", file}, "{\"ok\":true}\n"},
		{sample, []string{"put", "--json", "-"}, "{\"ok\":true}\n"},
		{"", []string{"list", "--box", "box-a", "--since", "7d"}, "{\"since\":\"x\",\"rows\":[],\"hours\":[]}\n"},
		{"", []string{"list"}, "{\"since\":\"x\",\"rows\":[],\"hours\":[]}\n"},
	} {
		rc, out, errOut := capture(t, c.in, func() int { return cmdBoxStats(cfg, c.args) })
		if rc != 0 || out != c.want {
			t.Errorf("%v: rc %d %q err %q, want %q", c.args, rc, out, errOut, c.want)
		}
	}
	fr := h.Frames()
	if len(fr) != 4 || string(fr[0].Lane) != sample {
		t.Fatalf("frames = %d, first row %s", len(fr), fr[0].Lane)
	}
	var q map[string]string
	if err := json.Unmarshal(fr[2].Lane, &q); err != nil || q["box"] != "box-a" || q["since"] != "7d" {
		t.Errorf("list query = %s (%v)", fr[2].Lane, err)
	}
	if err := json.Unmarshal(fr[3].Lane, &q); err != nil || q["box"] != "" || q["since"] != "24h" {
		t.Errorf("list default query = %s (%v)", fr[3].Lane, err)
	}
}

func TestBoxStatsRefusals(t *testing.T) {
	h := newScriptHub(t, laneAnswer(nil), nil)
	cfg := hubCfg(t, h.URL)
	for _, c := range []struct {
		name, in string
		hub      bool
		args     []string
		want     string
	}{
		{"no sub-verb", "", true, nil, "usage: spool box-stats"},
		{"local mode", "", false, []string{"list"}, "need hub mode"},
		{"unknown sub-verb", "", true, []string{"drop"}, `unknown sub-verb "drop"`},
		{"put bad flag", "", true, []string{"put", "--x"}, "flag provided but not defined"},
		{"put no --json", "", true, []string{"put"}, "--json <file|-> is required"},
		{"put missing file", "", true, []string{"put", "--json", "/nonexistent/s.json"}, "no such file"},
		{"put unknown field", `{"box":"box-a","x":1}`, true, []string{"put", "--json", "-"}, "not one sample object"},
		{"put bad sample", `{"box":"box-a","cpus":0}`, true, []string{"put", "--json", "-"}, "cpus must be"},
		{"put hub refuses", `{"box":"box-a","cpus":1}`, true, []string{"put", "--json", "-"}, "bad_lane_op"},
		{"list bad flag", "", true, []string{"list", "--x"}, "flag provided but not defined"},
		{"list bad box", "", true, []string{"list", "--box", "Box A"}, "--box must be a box id"},
		{"list hub refuses", "", true, []string{"list"}, "bad_lane_op"},
	} {
		c2 := cfg
		if !c.hub {
			c2 = testkit.NewConfig(t)
		}
		rc, _, errOut := capture(t, c.in, func() int { return cmdBoxStats(c2, c.args) })
		if rc != 1 || !strings.Contains(errOut, c.want) {
			t.Errorf("%s: rc %d %q, want 1 naming %q", c.name, rc, errOut, c.want)
		}
	}
}
