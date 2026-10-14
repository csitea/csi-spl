package main

import (
	"encoding/json"
	"net/url"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The read-only inspect verbs (r9-02): topics, flow, lane and box-beat, each
// against a scripted hub. What each sends, how it prints the hub's answer, and
// the refusals made before anything is sent or when the hub refuses.

// inspectAnswer answers topic_list and flow_read with the pages given, and a
// lane frame with lane = lanes[op]; anything else gets a hub error, so a
// refusal case only has to leave its page empty.
func inspectAnswer(topics, flow string, lanes map[string]string) func(wire.Frame) []wire.Frame {
	refuse := func(f wire.Frame) []wire.Frame {
		return []wire.Frame{{Type: wire.TError, MsgID: f.MsgID, Error: "not_seated", Status: 403}}
	}
	return func(f wire.Frame) []wire.Frame {
		switch f.Type {
		case wire.TTopicList:
			if topics == "" {
				return refuse(f)
			}
			return []wire.Frame{{Type: wire.TTopicList, MsgID: f.MsgID, TopicList: json.RawMessage(topics)}}
		case wire.TFlowRead:
			if flow == "" {
				return refuse(f)
			}
			return []wire.Frame{{Type: wire.TFlowRead, MsgID: f.MsgID, Flow: json.RawMessage(flow)}}
		}
		return laneAnswer(lanes)(f)
	}
}

const inspectTopics = `{"channel":"refactoring","topics":[` +
	`{"task_id":"0b9e4c1a-1111-4aaa-8bbb-000000000001","subject":"split the store","last_ts":"2026-10-12T06:01:02Z"}],"next":"CUR"}`

const inspectFlow = `{"lines":[` +
	`{"kind":"blocked","count":4,"at":"2026-10-12T16:40:00Z","unread":true,"link":"/t/x#m","title":"Flow v2","ids":["c-002"],"ids_more":2},` +
	`{"kind":"mention","count":1,"at":"not a time","link":"/t/y","title":"Plain","ids":["c-003"]},` +
	`{"kind":"release","day":"2026-10-12","link":"/r/1","version_from":"1.3.0","version_to":"1.3.4","versions":5},` +
	`{"kind":"release","day":"2026-10-13","unread":true,"link":"/r/2","version_from":"1.3.5","version_to":"1.3.5","versions":1}],` +
	`"next":"N2"}`

// TestTopicsVerb: the page prints one line per topic, --json prints it raw,
// and the frame carries --as and the channel without its '#'.
func TestTopicsVerb(t *testing.T) {
	h := newScriptHub(t, inspectAnswer(inspectTopics, "", nil), nil)
	cfg := hubCfg(t, h.URL)
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"--as", "c-007", "--channel", "#refactoring", "--limit", "5", "--before", "B1"},
			"0b9e4c1a-1111-4aaa-8bbb-000000000001  2026-10-12 06:01Z  split the store\nnext: CUR\n"},
		{[]string{"--as", "c-007", "--channel", "refactoring", "--json"}, inspectTopics + "\n"},
	} {
		rc, out, errOut := capture(t, "", func() int { return cmdTopics(cfg, c.args) })
		if rc != 0 || out != c.want {
			t.Errorf("%v: rc %d out %q err %q, want 0 %q", c.args, rc, out, errOut, c.want)
		}
	}
	fr := h.Frames()
	if len(fr) != 2 || fr[0].Type != wire.TTopicList || fr[0].As != "c-007" {
		t.Fatalf("frames = %+v", fr)
	}
	q, err := url.ParseQuery(fr[0].Query)
	if err != nil || q.Get("channel") != "refactoring" || q.Get("limit") != "5" || q.Get("before") != "B1" {
		t.Errorf("query = %q (%v)", fr[0].Query, err)
	}
}

// TestFlowVerb: topic lines, folded who, a release span and a single-version
// release, then the cursor; --json prints the page raw.
func TestFlowVerb(t *testing.T) {
	h := newScriptHub(t, inspectAnswer("", inspectFlow, nil), nil)
	cfg := hubCfg(t, h.URL)
	want := "* blocked 4 in \"Flow v2\" · c-002 +2 · 2026-10-12 16:40Z  /t/x#m\n" +
		"  mention 1 in \"Plain\" · c-003 · not a time  /t/y\n" +
		"  release 1.3.0 .. 1.3.4 (5 versions) · 2026-10-12  /r/1\n" +
		"* release 1.3.5 (1 versions) · 2026-10-13  /r/2\n" +
		"next: N2\n"
	rc, out, errOut := capture(t, "", func() int {
		return cmdFlow(cfg, []string{"--as", "c-007", "--kind", "blocked", "--limit", "3", "--before", "B"})
	})
	if rc != 0 || out != want {
		t.Errorf("flow: rc %d err %q\ngot  %q\nwant %q", rc, errOut, out, want)
	}
	rc, out, _ = capture(t, "", func() int { return cmdFlow(cfg, []string{"--as", "c-007", "--json"}) })
	if rc != 0 || out != inspectFlow+"\n" {
		t.Errorf("flow --json: rc %d %q", rc, out)
	}
	fr := h.Frames()
	if len(fr) != 2 || fr[0].Type != wire.TFlowRead || fr[0].As != "c-007" {
		t.Fatalf("frames = %+v", fr)
	}
	q, err := url.ParseQuery(fr[0].Query)
	if err != nil || q.Get("kind") != "blocked" || q.Get("limit") != "3" || q.Get("before") != "B" {
		t.Errorf("query = %q (%v)", fr[0].Query, err)
	}
	if fr[1].Query != "" {
		t.Errorf("bare flow query = %q, want empty", fr[1].Query)
	}
}

// TestTopicsFlowRefusals: flag errors, local mode, a missing --as or channel,
// a hub refusal and a reply that is not a page each exit 1 naming why.
func TestTopicsFlowRefusals(t *testing.T) {
	refusing := newScriptHub(t, inspectAnswer("", "", nil), nil)
	cfg := hubCfg(t, refusing.URL)
	garbled := newScriptHub(t, inspectAnswer(`"not a page"`, `"not a page"`, nil), nil)
	gcfg := hubCfg(t, garbled.URL)
	local := testkit.NewConfig(t)
	for _, c := range []struct {
		name string
		run  func() int
		want string
	}{
		{"topics bad flag", func() int { return cmdTopics(cfg, []string{"--x"}) }, "flag provided but not defined"},
		{"topics local mode", func() int { return cmdTopics(local, []string{"--as", "c-007", "--channel", "a"}) }, "needs hub mode"},
		{"topics no --as", func() int { return cmdTopics(cfg, []string{"--channel", "a"}) }, "--as"},
		{"topics no channel", func() int { return cmdTopics(cfg, []string{"--as", "c-007", "--channel", "#"}) }, "--channel is required"},
		{"topics hub refuses", func() int { return cmdTopics(cfg, []string{"--as", "c-007", "--channel", "a"}) }, "not_seated"},
		{"topics bad reply", func() int { return cmdTopics(gcfg, []string{"--as", "c-007", "--channel", "a"}) }, "topics reply"},
		{"flow bad flag", func() int { return cmdFlow(cfg, []string{"--x"}) }, "flag provided but not defined"},
		{"flow local mode", func() int { return cmdFlow(local, []string{"--as", "c-007"}) }, "needs hub mode"},
		{"flow no --as", func() int { return cmdFlow(cfg, nil) }, "--as"},
		{"flow hub refuses", func() int { return cmdFlow(cfg, []string{"--as", "c-007"}) }, "not_seated"},
		{"flow bad reply", func() int { return cmdFlow(gcfg, []string{"--as", "c-007"}) }, "flow reply"},
	} {
		rc, _, errOut := capture(t, "", c.run)
		if rc != 1 || !strings.Contains(errOut, c.want) {
			t.Errorf("%s: rc %d %q, want 1 naming %q", c.name, rc, errOut, c.want)
		}
	}
}

// TestLaneVerb: no --agent lists the fleet; --agent writes the row with the
// files split and trimmed, state live by default.
func TestLaneVerb(t *testing.T) {
	list := `{"fleet":"csi","lanes":[]}`
	put := `{"fleet":"csi","lanes":[{"agent_id":"c-104"}]}`
	h := newScriptHub(t, inspectAnswer("", "", map[string]string{"list": list, "put": put}), nil)
	cfg := hubCfg(t, h.URL)
	rc, out, errOut := capture(t, "", func() int { return cmdLane(cfg, []string{"--fleet", "csi"}) })
	if rc != 0 || out != list+"\n" {
		t.Errorf("list: rc %d %q err %q", rc, out, errOut)
	}
	rc, out, errOut = capture(t, "", func() int {
		return cmdLane(cfg, []string{"--fleet", "csi", "--agent", "c-104", "--box", "box-a", "--repo", "csi-spl",
			"--branch", "c-104-x", "--scope", "tests", "--files", " a.go, ,b.go ", "--topic", "t-1"})
	})
	if rc != 0 || out != put+"\n" {
		t.Errorf("put: rc %d %q err %q", rc, out, errOut)
	}
	fr := h.Frames()
	if len(fr) != 2 || fr[0].LaneOp != "list" || fr[0].Fleet != "csi" || len(fr[0].Lane) != 0 || fr[1].LaneOp != "put" {
		t.Fatalf("frames = %+v", fr)
	}
	var row struct {
		AgentID string   `json:"agent_id"`
		Files   []string `json:"files"`
		State   string   `json:"state"`
	}
	if err := json.Unmarshal(fr[1].Lane, &row); err != nil || row.AgentID != "c-104" || row.State != "live" ||
		strings.Join(row.Files, "|") != "a.go|b.go" {
		t.Errorf("put row = %s (%v)", fr[1].Lane, err)
	}
}

func TestLaneRefusals(t *testing.T) {
	h := newScriptHub(t, inspectAnswer("", "", nil), nil)
	cfg := hubCfg(t, h.URL)
	for _, c := range []struct {
		name string
		hub  bool
		args []string
		want string
	}{
		{"bad flag", true, []string{"--x"}, "flag provided but not defined"},
		{"bad agent id", true, []string{"--fleet", "csi", "--agent", "not an id!"}, "agent must be an agent id"},
		{"local mode", false, []string{"--fleet", "csi"}, "needs hub mode"},
		{"bad fleet", true, []string{"--fleet", "Csi Fleet"}, "--fleet must be"},
		{"bad row", true, []string{"--fleet", "csi", "--agent", "c-104", "--box", "box-a", "--repo", "r",
			"--branch", "b", "--topic", "t", "--state", "gone"}, "state must be live or done"},
		{"hub refuses", true, []string{"--fleet", "csi"}, "bad_lane_op"},
	} {
		c2 := cfg
		if !c.hub {
			c2 = testkit.NewConfig(t)
		}
		rc, _, errOut := capture(t, "", func() int { return cmdLane(c2, c.args) })
		if rc != 1 || !strings.Contains(errOut, c.want) {
			t.Errorf("%s: rc %d %q, want 1 naming %q", c.name, rc, errOut, c.want)
		}
	}
}

// TestBoxBeatVerb: put sends {pid}, list sends {box, since} with 10m default.
func TestBoxBeatVerb(t *testing.T) {
	h := newScriptHub(t, laneAnswer(map[string]string{
		"box_beat_put":  `{"ok":true}`,
		"box_beat_list": `{"box":"","since":"10m","rows":[]}`,
	}), nil)
	cfg := hubCfg(t, h.URL)
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"put", "--pid", "42"}, "{\"ok\":true}\n"},
		{[]string{"list", "--box", "box-a", "--since", "2h"}, "{\"box\":\"\",\"since\":\"10m\",\"rows\":[]}\n"},
		{[]string{"list"}, "{\"box\":\"\",\"since\":\"10m\",\"rows\":[]}\n"},
	} {
		rc, out, errOut := capture(t, "", func() int { return cmdBoxBeat(cfg, c.args) })
		if rc != 0 || out != c.want {
			t.Errorf("%v: rc %d %q err %q, want %q", c.args, rc, out, errOut, c.want)
		}
	}
	fr := h.Frames()
	if len(fr) != 3 || fr[0].LaneOp != "box_beat_put" || string(fr[0].Lane) != `{"pid":42}` {
		t.Fatalf("frames = %+v", fr)
	}
	var q map[string]string
	if err := json.Unmarshal(fr[1].Lane, &q); err != nil || q["box"] != "box-a" || q["since"] != "2h" {
		t.Errorf("list query = %s (%v)", fr[1].Lane, err)
	}
	if err := json.Unmarshal(fr[2].Lane, &q); err != nil || q["box"] != "" || q["since"] != "10m" {
		t.Errorf("list default query = %s (%v)", fr[2].Lane, err)
	}
}

func TestBoxBeatRefusals(t *testing.T) {
	h := newScriptHub(t, laneAnswer(nil), nil)
	cfg := hubCfg(t, h.URL)
	for _, c := range []struct {
		name string
		hub  bool
		args []string
		want string
	}{
		{"no sub-verb", true, nil, "usage: spool box-beat"},
		{"local mode", false, []string{"list"}, "need hub mode"},
		{"unknown sub-verb", true, []string{"drop"}, `unknown sub-verb "drop"`},
		{"put bad flag", true, []string{"put", "--x"}, "flag provided but not defined"},
		{"put no --pid", true, []string{"put"}, "--pid <n> (1 or more) is required"},
		{"put hub refuses", true, []string{"put", "--pid", "7"}, "bad_lane_op"},
		{"list bad flag", true, []string{"list", "--x"}, "flag provided but not defined"},
		{"list bad box", true, []string{"list", "--box", "Box A"}, "--box must be a box id"},
		{"list hub refuses", true, []string{"list"}, "bad_lane_op"},
	} {
		c2 := cfg
		if !c.hub {
			c2 = testkit.NewConfig(t)
		}
		rc, _, errOut := capture(t, "", func() int { return cmdBoxBeat(c2, c.args) })
		if rc != 1 || !strings.Contains(errOut, c.want) {
			t.Errorf("%s: rc %d %q, want 1 naming %q", c.name, rc, errOut, c.want)
		}
	}
}
