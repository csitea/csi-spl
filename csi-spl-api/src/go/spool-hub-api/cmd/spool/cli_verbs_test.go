package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The client half of issue, ask, lease, fleet-load and attach-rename (r10-01):
// what each sends to a scripted hub, what it prints, and the refusals made
// before anything is sent. No Postgres, no network.

// verbCase is one command line of a verb: its exit code and a piece of the
// stdout (rc 0) or stderr (rc != 0) it prints.
type verbCase struct {
	name string
	args []string
	rc   int
	want string
}

// runVerbCases runs each case through verb and checks rc and output.
func runVerbCases(t *testing.T, verb func([]string) int, cases []verbCase) {
	t.Helper()
	for _, c := range cases {
		rc, out, errOut := capture(t, "", func() int { return verb(c.args) })
		got := out
		if c.rc != 0 {
			got = errOut
		}
		if rc != c.rc || !strings.Contains(got, c.want) {
			t.Errorf("%s: rc %d out %q err %q, want rc %d with %q", c.name, rc, out, errOut, c.rc, c.want)
		}
	}
}

// echoAnswer answers frames of type typ with set(reply, f): the reply pairs
// on the request's msg_id. Any other frame gets a hub error.
func echoAnswer(typ string, set func(r *wire.Frame, f wire.Frame)) func(wire.Frame) []wire.Frame {
	return func(f wire.Frame) []wire.Frame {
		if f.Type != typ {
			return []wire.Frame{{Type: wire.TError, MsgID: f.MsgID, Error: "bad_frame", Status: 400}}
		}
		r := wire.Frame{Type: typ, MsgID: f.MsgID}
		set(&r, f)
		return []wire.Frame{r}
	}
}

// pastLegacyDeadline stands the agent id clock after LegacyUntil, so a
// legacy id flag is refused at the edge (spec 061 FR-003).
func pastLegacyDeadline(t *testing.T) {
	t.Helper()
	old := agentid.Now
	t.Cleanup(func() { agentid.Now = old })
	agentid.Now = func() time.Time { return agentid.LegacyUntil.Add(time.Hour) }
}

// refuseAll answers every frame with a 403 hub error.
func refuseAll(f wire.Frame) []wire.Frame {
	return []wire.Frame{{Type: wire.TError, MsgID: f.MsgID, Error: "forbidden", Status: 403, Detail: "not yours"}}
}

func TestIssueVerb(t *testing.T) {
	h := newScriptHub(t, echoAnswer(wire.TIssue, func(r *wire.Frame, f wire.Frame) {
		r.Issue, _ = json.Marshal(map[string]any{"op": f.IssueOp, "ref": f.IssueRef, "as": f.As})
	}), nil)
	cfg := hubCfg(t, h.URL)
	desc := filepath.Join(t.TempDir(), "desc.md")
	if err := os.WriteFile(desc, []byte("from a file\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	issue := func(args []string) int { return cmdIssue(cfg, args) }
	runVerbCases(t, issue, []verbCase{
		{"list", []string{"list", "--as", "c-007", "--status", "wip,todo", "--limit", "5"}, 0, `"op":"list"`},
		{"show", []string{"get", "--as", "c-007", "--ref", "SPL-3"}, 0, `"ref":"SPL-3"`},
		{"new", []string{"create", "--as", "c-007", "--title", "T", "--epic", "SPL-1", "--discussions", "t1, ,t2",
			"--description-file", desc, "--priority", "2", "--labels", "a, b,"}, 0, `"op":"create"`},
		{"edit", []string{"update", "--as", "c-007", "--ref", "SPL-3", "--status", "", "--level", "2"}, 0, `"op":"update"`},
		{"close", []string{"update", "--as", "c-007", "--ref", "SPL-1", "--status", "done", "--cascade"}, 0, `"ref":"SPL-1"`},
		{"comment", []string{"comment", "--as", "c-007", "--ref", "SPL-3", "--body", "hi"}, 0, `"op":"comment"`},
		{"archive", []string{"archive", "--as", "c-007", "--ref", "SPL-3", "--cascade"}, 0, `"op":"archive"`},
		{"link", []string{"link", "--as", "c-007", "--ref", "SPL-3", "--discussion", "t3"}, 0, `"op":"link"`},
	})
	fr := h.Frames()
	if len(fr) != 8 {
		t.Fatalf("hub read %d frames, want 8", len(fr))
	}
	if fr[0].IssueOp != "list" || fr[0].Query != "limit=5&status=wip%2Ctodo" {
		t.Errorf("list frame op %q query %q", fr[0].IssueOp, fr[0].Query)
	}
	var created map[string]any
	if err := json.Unmarshal(fr[2].Issue, &created); err != nil {
		t.Fatal(err)
	}
	if created["description"] != "from a file\n" || created["priority"] != float64(2) ||
		len(created["labels"].([]any)) != 2 || len(created["discussions"].([]any)) != 2 {
		t.Errorf("create object = %s", fr[2].Issue)
	}
	if string(fr[3].Issue) != `{"level":2,"status":""}` {
		t.Errorf("update object = %s, want only the flags given", fr[3].Issue)
	}
	if string(fr[4].Issue) != `{"cascade":true,"status":"done"}` {
		t.Errorf("close object = %s, want the cascade confirmation", fr[4].Issue)
	}
	if fr[5].Body != "hi" || fr[6].Query != "cascade=1" || fr[7].Body != "t3" {
		t.Errorf("comment body %q, archive query %q, link body %q", fr[5].Body, fr[6].Query, fr[7].Body)
	}
}

// TestIssueVerbRefusals: usage errors exit 1 before the hub; a hub refusal
// exits non-zero and names its token.
func TestIssueVerbRefusals(t *testing.T) {
	h := newScriptHub(t, refuseAll, nil)
	cfg := hubCfg(t, h.URL)
	local := testkit.NewConfig(t)
	runVerbCases(t, func(a []string) int { return cmdIssue(cfg, a) }, []verbCase{
		{"no op", nil, 1, "usage: spool issue"},
		{"flag first", []string{"--as", "c-007"}, 1, "usage: spool issue"},
		{"bad flag", []string{"list", "--nope"}, 1, "flag provided but not defined"},
		{"bad priority", []string{"create", "--as", "c-007", "--priority", "high"}, 1, "--priority must be a number"},
		{"missing description file", []string{"create", "--as", "c-007", "--description-file", "/nonexistent/d.md"}, 1, "no such file"},
		{"missing body file", []string{"comment", "--as", "c-007", "--ref", "SPL-3", "--body-file", "/nonexistent/b.md"}, 1, "no such file"},
		{"archive without ref", []string{"archive", "--as", "c-007"}, 1, "--ref is required"},
		{"unknown op", []string{"close", "--as", "c-007"}, 1, "op must be"},
		{"no --as", []string{"list"}, 1, "--as (the acting agent id) is required"},
	})
	if fr := h.Frames(); len(fr) != 0 {
		t.Fatalf("bad input reached the hub: %+v", fr)
	}
	runVerbCases(t, func(a []string) int { return cmdIssue(local, a) }, []verbCase{
		{"local mode", []string{"list", "--as", "c-007"}, 1, "issues need hub mode"},
	})
	rc, _, errOut := capture(t, "", func() int { return cmdIssue(cfg, []string{"get", "--as", "c-007", "--ref", "SPL-3"}) })
	if rc == 0 || !strings.Contains(errOut, "forbidden") {
		t.Errorf("hub refusal: rc %d err %q", rc, errOut)
	}
}

func TestAskVerb(t *testing.T) {
	h := newScriptHub(t, echoAnswer(wire.TAsk, func(r *wire.Frame, f wire.Frame) {
		r.Ask, _ = json.Marshal(map[string]any{"fleet": f.Fleet, "op": f.AskOp, "asks": []any{}})
	}), nil)
	cfg := hubCfg(t, h.URL)
	const id = "0b6f3c1e-3333-4a2b-8c3d-000000000003"
	runVerbCases(t, func(a []string) int { return cmdAsk(cfg, a) }, []verbCase{
		{"list is the default op", []string{"--fleet", "csi"}, 0, `"op":"list"`},
		{"ack", []string{"ack", "--fleet", "csi", "--id", id, "--by", "c-007@box-a"}, 0, `"op":"ack"`},
		{"pool --set", []string{"pool", "--fleet", "csi", "--set", "--by", "c-007@box-a", "--claude-n", "3", "--grok-n", "1",
			"--min-boxes", "2", "--vendor-out", "grok", "--out-until", "2026-10-15T09:00:00Z", "--kinds", "spawn, box_op,"}, 0, `"op":"pool"`},
		{"lock-next", []string{"lock-next", "--fleet", "csi", "--seat", "c-007@box-a", "--vendor", "claude", "--caps", "prd,"}, 0, `"op":"lock-next"`},
	})
	fr := h.Frames()
	if len(fr) != 4 {
		t.Fatalf("hub read %d frames, want 4", len(fr))
	}
	var ack map[string]any
	if err := json.Unmarshal(fr[1].Ask, &ack); err != nil || ack["ask_id"] != id || ack["by"] != "c-007@box-a" {
		t.Errorf("ack body = %s (%v)", fr[1].Ask, err)
	}
	var pool map[string]any
	if err := json.Unmarshal(fr[2].Ask, &pool); err != nil {
		t.Fatal(err)
	}
	if pool["set"] != true || pool["claude_n"] != float64(3) || pool["grok_n"] != float64(1) || pool["min_boxes"] != float64(2) ||
		pool["vendor_out"] != "grok" || pool["out_until"] != "2026-10-15T09:00:00Z" || len(pool["kinds"].([]any)) != 2 {
		t.Errorf("pool body = %s", fr[2].Ask)
	}
	var lock map[string]any
	if err := json.Unmarshal(fr[3].Ask, &lock); err != nil || len(lock["caps"].([]any)) != 1 {
		t.Errorf("lock-next body = %s (%v)", fr[3].Ask, err)
	}
}

// TestAskVerbRefusals: usage errors exit 1 before the hub.
func TestAskVerbRefusals(t *testing.T) {
	pastLegacyDeadline(t)
	h := newScriptHub(t, refuseAll, nil)
	cfg := hubCfg(t, h.URL)
	local := testkit.NewConfig(t)
	runVerbCases(t, func(a []string) int { return cmdAsk(cfg, a) }, []verbCase{
		{"bad flag", []string{"list", "--nope"}, 1, "flag provided but not defined"},
		{"stray argument", []string{"list", "--fleet", "csi", "extra"}, 1, `unexpected argument "extra"`},
		{"retired --by", []string{"ack", "--fleet", "csi", "--by", "CLE-77952@box-a"}, 1, "--by: "},
		{"bad fleet", []string{"list", "--fleet", "CSI"}, 1, "--fleet must be a lowercase slug"},
		{"bad ask id", []string{"ack", "--fleet", "csi", "--id", "nope", "--by", "c-007@box-a"}, 1, "--id must be"},
	})
	if fr := h.Frames(); len(fr) != 0 {
		t.Fatalf("bad input reached the hub: %+v", fr)
	}
	runVerbCases(t, func(a []string) int { return cmdAsk(local, a) }, []verbCase{
		{"local mode", []string{"list", "--fleet", "csi"}, 1, "asks need hub mode"},
	})
	rc, _, errOut := capture(t, "", func() int { return cmdAsk(cfg, []string{"--fleet", "csi"}) })
	if rc == 0 || !strings.Contains(errOut, "forbidden") {
		t.Errorf("hub refusal: rc %d err %q", rc, errOut)
	}
}

func TestSplitList(t *testing.T) {
	for in, want := range map[string]int{"": 0, " , ,": 0, "a": 1, " a , b ,": 2} {
		got := splitList(in)
		if got == nil || len(got) != want {
			t.Errorf("splitList(%q) = %#v, want %d items, never nil", in, got, want)
		}
	}
}

func TestLeaseVerb(t *testing.T) {
	h := newScriptHub(t, echoAnswer(wire.TLease, func(r *wire.Frame, f wire.Frame) {
		r.Lease, _ = json.Marshal(map[string]any{"fleet": f.Fleet, "role": f.LeaseRole, "holder": f.Holder,
			"gen": f.IfGen + 1, "won": f.LeaseOp == "cas"})
	}), nil)
	cfg := hubCfg(t, h.URL)
	runVerbCases(t, func(a []string) int { return cmdLease(cfg, a) }, []verbCase{
		{"get", []string{"--fleet", "csi", "--role", "dispatch"}, 0, `"won":false`},
		{"cas", []string{"--fleet", "csi", "--role", "dispatch", "--holder", "c-007@box-a", "--if-gen", "4"}, 0, `"gen":5`},
		{"cas reason", []string{"--fleet", "csi", "--role", "dispatch", "--holder", "c-007@box-a", "--if-gen", "5", "--reason", "rotation"}, 0, `"gen":6`},
	})
	fr := h.Frames()
	if len(fr) != 3 || fr[0].LeaseOp != "get" || fr[1].LeaseOp != "cas" || fr[1].Holder != "c-007@box-a" || fr[1].IfGen != 4 {
		t.Fatalf("lease frames = %+v", fr)
	}
	// spec 162 C19: --reason rides as lease_reason; without it the frame has none
	if fr[1].LeaseReason != "" || fr[2].LeaseReason != "rotation" {
		t.Fatalf("lease_reason = %q, %q; want \"\", rotation", fr[1].LeaseReason, fr[2].LeaseReason)
	}
}

// TestLeaseVerbRefusals: usage errors exit 1 before the hub.
func TestLeaseVerbRefusals(t *testing.T) {
	pastLegacyDeadline(t)
	h := newScriptHub(t, refuseAll, nil)
	cfg := hubCfg(t, h.URL)
	local := testkit.NewConfig(t)
	runVerbCases(t, func(a []string) int { return cmdLease(cfg, a) }, []verbCase{
		{"bad flag", []string{"--nope"}, 1, "flag provided but not defined"},
		{"retired holder id", []string{"--fleet", "csi", "--role", "orch", "--holder", "CLE-77952@box-a"}, 1, "--holder: "},
		{"bad role", []string{"--fleet", "csi", "--role", "Orch"}, 1, "lowercase slugs"},
		{"holder without box", []string{"--fleet", "csi", "--role", "orch", "--holder", "c-007"}, 1, "<agent id>@<box>"},
		{"cas without gen", []string{"--fleet", "csi", "--role", "orch", "--holder", "c-007@box-a"}, 1, "--if-gen"},
		{"bogus reason", []string{"--fleet", "csi", "--role", "orch", "--holder", "c-007@box-a", "--if-gen", "1", "--reason", "bogus"}, 1,
			"--reason must be one of claim, rotation, seat_move, failover, handback, vendor, limit"},
	})
	if fr := h.Frames(); len(fr) != 0 {
		t.Fatalf("bad input reached the hub: %+v", fr)
	}
	runVerbCases(t, func(a []string) int { return cmdLease(local, a) }, []verbCase{
		{"local mode", []string{"--fleet", "csi", "--role", "orch"}, 1, "needs hub mode"},
	})
	rc, _, errOut := capture(t, "", func() int { return cmdLease(cfg, []string{"--fleet", "csi", "--role", "orch"}) })
	if rc == 0 || !strings.Contains(errOut, "forbidden") {
		t.Errorf("hub refusal: rc %d err %q", rc, errOut)
	}
}

func TestFleetLoadVerb(t *testing.T) {
	h := newScriptHub(t, laneAnswer(map[string]string{
		"fleet_load_get":   `{"low":2,"high":6}`,
		"fleet_load_pause": `{"agent_kinds_paused":{"claude":{}}}`,
	}), nil)
	cfg := hubCfg(t, h.URL)
	runVerbCases(t, func(a []string) int { return cmdFleetLoad(cfg, a) }, []verbCase{
		{"get", []string{"get"}, 0, `{"low":2,"high":6}`},
		{"pause", []string{"pause", "claude", "2026-10-15T09:00:00Z", "weekly", "limit"}, 0, `"agent_kinds_paused"`},
	})
	fr := h.Frames()
	if len(fr) != 2 || len(fr[0].Lane) != 0 {
		t.Fatalf("fleet-load frames = %+v", fr)
	}
	var row map[string]string
	if err := json.Unmarshal(fr[1].Lane, &row); err != nil || row["kind"] != "claude" || row["reason"] != "weekly limit" {
		t.Errorf("pause row = %s (%v)", fr[1].Lane, err)
	}
}

// TestFleetLoadVerbRefusals: usage errors exit 1 before the hub.
func TestFleetLoadVerbRefusals(t *testing.T) {
	h := newScriptHub(t, refuseAll, nil)
	cfg := hubCfg(t, h.URL)
	local := testkit.NewConfig(t)
	runVerbCases(t, func(a []string) int { return cmdFleetLoad(cfg, a) }, []verbCase{
		{"no op", nil, 1, "usage: spool fleet-load"},
		{"get with args", []string{"get", "x"}, 1, "usage: spool fleet-load"},
		{"pause without until", []string{"pause", "claude"}, 1, "usage: spool fleet-load"},
	})
	if fr := h.Frames(); len(fr) != 0 {
		t.Fatalf("bad input reached the hub: %+v", fr)
	}
	runVerbCases(t, func(a []string) int { return cmdFleetLoad(local, a) }, []verbCase{
		{"local mode", []string{"get"}, 1, "needs hub mode"},
	})
	rc, _, errOut := capture(t, "", func() int { return cmdFleetLoad(cfg, []string{"get"}) })
	if rc == 0 || !strings.Contains(errOut, "forbidden") {
		t.Errorf("hub refusal: rc %d err %q", rc, errOut)
	}
}

// TestAttachRenameVerb: the hub hands back a stored message with no
// hash-named file, so nothing is renamed and only the fetch is sent.
func TestAttachRenameVerb(t *testing.T) {
	const task, id = "0b6f3c1e-1111-4a2b-8c3d-0000000000a1", "0b6f3c1e-2222-4a2b-8c3d-0000000000a2"
	var stored []byte
	h := newScriptHub(t, echoAnswer(wire.TEdit, func(r *wire.Frame, f wire.Frame) { r.Env = stored }), nil)
	cfg := hubCfg(t, h.URL)
	priv, err := sign.LoadPrivate(cfg.KeysDir, "box-a")
	if err != nil {
		t.Fatal(err)
	}
	m := &msg.Message{V: msg.V1, MsgID: id, TaskID: task, TS: time.Now().UTC().Format(time.RFC3339),
		From: "c-007", To: "c-008", Kind: "note", Body: "body"}
	e, err := wire.NewEnvelopeIn(priv, "box-a", "box-b", "ops", "", m)
	if err != nil {
		t.Fatal(err)
	}
	if stored, err = e.Marshal(); err != nil {
		t.Fatal(err)
	}
	rename := func(a []string) int { return cmdAttachRename(cfg, a) }
	runVerbCases(t, rename, []verbCase{
		{"nothing to rename", []string{"--msg-id", strings.ToUpper(id), "--as", "c-007"}, 0, `"task_id":"` + task + `"`},
		{"dry run", []string{"--msg-id", id, "--dry-run"}, 0, `"renamed":0`},
		{"another agent's message", []string{"--msg-id", id, "--as", "c-009"}, 1, "not c-009"},
	})
	fr := h.Frames()
	if len(fr) != 3 || fr[0].MsgID != id || len(fr[0].Env) != 0 {
		t.Fatalf("attach-rename frames = %+v, want 3 fetches", fr)
	}
}

// TestAttachRenameVerbRefusals: usage errors exit 1 before the hub.
func TestAttachRenameVerbRefusals(t *testing.T) {
	h := newScriptHub(t, refuseAll, nil)
	cfg := hubCfg(t, h.URL)
	local := testkit.NewConfig(t)
	const id = "0b6f3c1e-2222-4a2b-8c3d-0000000000a2"
	runVerbCases(t, func(a []string) int { return cmdAttachRename(cfg, a) }, []verbCase{
		{"bad flag", []string{"--nope"}, 1, "flag provided but not defined"},
		{"bad msg id", []string{"--msg-id", "nope"}, 1, "--msg-id must be"},
		{"bad --as", []string{"--msg-id", id, "--as", "Not An Id"}, 1, "--as must be an agent id"},
	})
	if fr := h.Frames(); len(fr) != 0 {
		t.Fatalf("bad input reached the hub: %+v", fr)
	}
	runVerbCases(t, func(a []string) int { return cmdAttachRename(local, a) }, []verbCase{
		{"local mode", []string{"--msg-id", id}, 1, "needs hub mode"},
	})
	rc, _, errOut := capture(t, "", func() int { return cmdAttachRename(cfg, []string{"--msg-id", id}) })
	if rc == 0 || !strings.Contains(errOut, "forbidden") {
		t.Errorf("hub refusal: rc %d err %q", rc, errOut)
	}
}

// TestFleetTokensVerb: the collector's frame goes to the hub as {samples}
// only (the hub refuses unknown fields), and the ack is printed.
func TestFleetTokensVerb(t *testing.T) {
	h := newScriptHub(t, laneAnswer(map[string]string{
		wire.FleetBurnPushOp: `{"type":"ack","lane_op":"fleet_tokens_push","inserted":1,"at":"x"}`,
	}), nil)
	cfg := hubCfg(t, h.URL)
	minute := time.Now().UTC().Truncate(time.Minute).Format(time.RFC3339)
	frame := `{"type":"lane","lane_op":"fleet_tokens_push","samples":[{"agent_id":"g-001","vendor":"grok","model":null,` +
		`"minute":"` + minute + `","tokens_in":5,"tokens_out":2,"cache_read":0,"cache_write":0,"is_metered":true}]}`
	rc, out, errOut := capture(t, frame, func() int { return cmdFleetTokens(cfg, []string{"push", "--json", "-"}) })
	if rc != 0 || !strings.Contains(out, `"inserted":1`) {
		t.Fatalf("push: rc %d out %q err %q", rc, out, errOut)
	}
	fr := h.Frames()
	if len(fr) != 1 || fr[0].LaneOp != wire.FleetBurnPushOp {
		t.Fatalf("frames = %+v", fr)
	}
	if _, err := wire.DecodeFleetTokensPush(fr[0].Lane); err != nil {
		t.Errorf("sent lane %s is not a valid push: %v", fr[0].Lane, err)
	}
}

// TestFleetTokensVerbRefusals: usage errors and bad samples exit 1 before
// the hub.
func TestFleetTokensVerbRefusals(t *testing.T) {
	h := newScriptHub(t, refuseAll, nil)
	cfg := hubCfg(t, h.URL)
	runVerbCases(t, func(a []string) int { return cmdFleetTokens(cfg, a) }, []verbCase{
		{"no op", nil, 1, "usage: spool fleet-tokens"},
		{"no --json", []string{"push", "-"}, 1, "usage: spool fleet-tokens"},
	})
	for name, in := range map[string]string{
		"not json":   `nope`,
		"no samples": `{"type":"lane"}`,
		"bad vendor": `{"samples":[{"agent_id":"c-001","vendor":"gpt","minute":"2026-10-16T00:00:00Z"}]}`,
	} {
		rc, _, errOut := capture(t, in, func() int { return cmdFleetTokens(cfg, []string{"push", "--json", "-"}) })
		if rc != 1 || !strings.Contains(errOut, "fleet-tokens push") {
			t.Errorf("%s: rc %d err %q", name, rc, errOut)
		}
	}
	if fr := h.Frames(); len(fr) != 0 {
		t.Fatalf("bad input reached the hub: %+v", fr)
	}
}
