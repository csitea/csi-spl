package action

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// r44-06: every refusal of Lane, Move, MoveMsg and Pin, each with its error
// text and no frame on the hub, and their success paths against newOpHub.

const (
	hvTask = "aaaaaaaa-1111-4222-8333-444444444444"
	hvMsg  = "bbbbbbbb-1111-4222-8333-444444444444"
)

// hvHub answers a lane frame with {"ok":true} in Lane and a move frame with
// {"moved":true} in Move; anything else is an error frame.
func hvHub(t *testing.T) *opHub {
	t.Helper()
	return newOpHub(t, func(f wire.Frame) wire.Frame {
		switch f.Type {
		case wire.TLane:
			return wire.Frame{Type: wire.TLane, MsgID: f.MsgID, Lane: []byte(`{"ok":true}`)}
		case wire.TMove:
			return wire.Frame{Type: wire.TMove, MsgID: f.MsgID, Move: []byte(`{"moved":true}`)}
		}
		return wire.Frame{Type: wire.TError, Error: "unexpected_frame"}
	})
}

// hvRefused fails unless err carries want and the hub saw no frame.
func hvRefused(t *testing.T, h *opHub, err error, want string) {
	t.Helper()
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("err = %v, want %q", err, want)
	}
	if n := len(h.of("")); n != 0 {
		t.Fatalf("a refusal sent %d frame(s) to the hub", n)
	}
}

func TestLaneRefusals(t *testing.T) {
	h := hvHub(t)
	cfg := opCfg(t, h.url)
	ctx := context.Background()
	good := LaneArgs{Fleet: "csi", Agent: "CLE-07", Box: "box-a", Repo: "csi-spl", Branch: "b", Topic: "t1", Issue: "SPL-1"}
	bad := func(mod func(*LaneArgs)) LaneArgs { a := good; mod(&a); return a }
	cases := []struct {
		name  string
		noHub bool
		in    LaneArgs
		want  string
	}{
		{"no hub", true, good, "the lane map needs hub mode ($SPOOL_HUB_URL is not set)"},
		{"empty fleet", false, bad(func(a *LaneArgs) { a.Fleet = "" }), "--fleet must be a lowercase slug ([a-z0-9-], up to 32)"},
		{"upper-case fleet", false, bad(func(a *LaneArgs) { a.Fleet = "CSI" }), "--fleet must be a lowercase slug"},
		{"fleet too long", false, bad(func(a *LaneArgs) { a.Fleet = strings.Repeat("a", 33) }), "--fleet must be a lowercase slug"},
		{"bad agent", false, bad(func(a *LaneArgs) { a.Agent = "not an id" }), "lane: agent must be an agent id like CLE-07"},
		{"bad box", false, bad(func(a *LaneArgs) { a.Box = "Box A" }), "lane: box must be the agent's desk box id"},
		{"bad state", false, bad(func(a *LaneArgs) { a.State = "gone" }), "lane: state must be live or done"},
		{"bad issue", false, bad(func(a *LaneArgs) { a.Issue = "spl one" }), "lane: issue_key must be an issue key like SPL-12"},
		{"empty file", false, bad(func(a *LaneArgs) { a.Files = []string{""} }), "lane: each file must be a path of up to 300 bytes"},
		{"bad list state", false, LaneArgs{Fleet: "csi", ListState: "gone"}, "lane: --state must be live or done"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfg := *cfg
			if c.noHub {
				cfg.HubURL = ""
			}
			out, err := Lane(ctx, &cfg, c.in)
			if out != nil {
				t.Errorf("a refusal answered %s", out)
			}
			hvRefused(t, h, err, c.want)
		})
	}
}

// TestLaneOps: list, archived and put each send one lane frame; a put
// defaults State to live and Files to [], and the hub's answer comes back.
func TestLaneOps(t *testing.T) {
	ctx := context.Background()
	cases := []struct {
		name, op string
		in       LaneArgs
		row      map[string]any // nil = no row on the frame
	}{
		{"list", "list", LaneArgs{Fleet: "csi"}, nil},
		{"list live", "list", LaneArgs{Fleet: "csi", ListState: "live"}, map[string]any{"state": "live"}}, // SPL-4630
		{"archived", "archived", LaneArgs{Fleet: "csi", Box: "box-b", Archived: true}, map[string]any{"agent_box": "box-b"}},
		{"put", "put", LaneArgs{Fleet: "csi", Agent: "CLE-07", Box: "box-a", Repo: "csi-spl", Branch: "b", Topic: "t1", Issue: "SPL-1"},
			map[string]any{"agent_id": "CLE-07", "agent_box": "box-a", "state": "live", "files": []any{}, "issue_key": "SPL-1"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := hvHub(t)
			out, err := Lane(ctx, opCfg(t, h.url), c.in)
			if err != nil || string(out) != `{"ok":true}` {
				t.Fatalf("Lane = %s, %v", out, err)
			}
			fs := h.of(wire.TLane)
			if len(fs) != 1 || fs[0].LaneOp != c.op || fs[0].Fleet != "csi" {
				t.Fatalf("frames %+v, want one %s on csi", fs, c.op)
			}
			if c.row == nil {
				if len(fs[0].Lane) != 0 {
					t.Errorf("a list carried a row %s", fs[0].Lane)
				}
				return
			}
			var row map[string]any
			if err := json.Unmarshal(fs[0].Lane, &row); err != nil {
				t.Fatal(err)
			}
			for k, v := range c.row {
				got, _ := json.Marshal(row[k])
				want, _ := json.Marshal(v)
				if string(got) != string(want) {
					t.Errorf("row[%s] = %s, want %s", k, got, want)
				}
			}
		})
	}
}

func TestMoveRefusals(t *testing.T) {
	h := hvHub(t)
	cfg := opCfg(t, h.url)
	ctx := context.Background()
	good := MoveArgs{TaskID: hvTask, Channel: "ops", As: "CLE-1"}
	bad := func(mod func(*MoveArgs)) MoveArgs { a := good; mod(&a); return a }
	cases := []struct {
		name  string
		noHub bool
		in    MoveArgs
		want  string
	}{
		{"no hub", true, good, "moving a topic needs hub mode ($SPOOL_HUB_URL is not set)"},
		{"empty task", false, bad(func(a *MoveArgs) { a.TaskID = "" }), "--task must be the topic's task UUID"},
		{"task not a uuid", false, bad(func(a *MoveArgs) { a.TaskID = "dispatch-r44" }), "--task must be the topic's task UUID"},
		{"empty channel", false, bad(func(a *MoveArgs) { a.Channel = "" }), "--channel (the target channel id) is required"},
		{"blank channel", false, bad(func(a *MoveArgs) { a.Channel = "  " }), "--channel (the target channel id) is required"},
		{"bare hash", false, bad(func(a *MoveArgs) { a.Channel = " #" }), "--channel (the target channel id) is required"},
		{"empty as", false, bad(func(a *MoveArgs) { a.As = "" }), "--as (the acting agent id) is required"},
		{"box as", false, bad(func(a *MoveArgs) { a.As = "BOX-1" }), "--as (the acting agent id) is required"},
		{"agent acting-for", false, bad(func(a *MoveArgs) { a.ActingFor = "CLE-2" }), "--acting-for must be a HUM-* id"},
		{"hum prefix only", false, bad(func(a *MoveArgs) { a.ActingFor = "HUM-" }), "--acting-for must be a HUM-* id"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfg := *cfg
			if c.noHub {
				cfg.HubURL = ""
			}
			out, err := Move(ctx, &cfg, c.in)
			if out != nil {
				t.Errorf("a refusal answered %s", out)
			}
			hvRefused(t, h, err, c.want)
		})
	}
}

// TestMoveSends: Move lower-cases the task, strips "#" and case from the
// channel and carries --as and --acting-for on the frame.
func TestMoveSends(t *testing.T) {
	h := hvHub(t)
	out, err := Move(context.Background(), opCfg(t, h.url),
		MoveArgs{TaskID: strings.ToUpper(hvTask), Channel: " #Ops ", As: "CLE-1", ActingFor: "HUM-3"})
	if err != nil || string(out) != `{"moved":true}` {
		t.Fatalf("Move = %s, %v", out, err)
	}
	fs := h.of(wire.TMove)
	if len(fs) != 1 {
		t.Fatalf("frames %+v, want one move", fs)
	}
	if f := fs[0]; f.TaskID != hvTask || f.MoveTo != "ops" || f.As != "CLE-1" || f.TypedBy != "HUM-3" || f.MoveMsg != "" {
		t.Errorf("frame task %q to %q as %q for %q msg %q", f.TaskID, f.MoveTo, f.As, f.TypedBy, f.MoveMsg)
	}
}

func TestMoveMsgRefusals(t *testing.T) {
	h := hvHub(t)
	cfg := opCfg(t, h.url)
	ctx := context.Background()
	good := MoveMsgArgs{MsgID: hvMsg, ToTask: hvTask, As: "CLE-1"}
	bad := func(mod func(*MoveMsgArgs)) MoveMsgArgs { a := good; mod(&a); return a }
	cases := []struct {
		name  string
		noHub bool
		in    MoveMsgArgs
		want  string
	}{
		{"no hub", true, good, "moving a message needs hub mode ($SPOOL_HUB_URL is not set)"},
		{"empty msg", false, bad(func(a *MoveMsgArgs) { a.MsgID = "" }), "--msg must be the message's UUID"},
		{"msg not a uuid", false, bad(func(a *MoveMsgArgs) { a.MsgID = "bbbbbbbb" }), "--msg must be the message's UUID"},
		{"empty to-task", false, bad(func(a *MoveMsgArgs) { a.ToTask = "" }), "--to-task must be the target topic's task UUID"},
		{"to-task not a uuid", false, bad(func(a *MoveMsgArgs) { a.ToTask = "dispatch-r44" }), "--to-task must be the target topic's task UUID"},
		{"empty as", false, bad(func(a *MoveMsgArgs) { a.As = "" }), "--as (the acting agent id) is required"},
		{"box as", false, bad(func(a *MoveMsgArgs) { a.As = "BOX-1" }), "--as (the acting agent id) is required"},
		{"agent acting-for", false, bad(func(a *MoveMsgArgs) { a.ActingFor = "CLE-2" }), "--acting-for must be a HUM-* id"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfg := *cfg
			if c.noHub {
				cfg.HubURL = ""
			}
			out, err := MoveMsg(ctx, &cfg, c.in)
			if out != nil {
				t.Errorf("a refusal answered %s", out)
			}
			hvRefused(t, h, err, c.want)
		})
	}
}

// TestMoveMsgSends: MoveMsg lower-cases both ids and sends them as
// MoveMsg / MoveToTask, never as TaskID / MoveTo.
func TestMoveMsgSends(t *testing.T) {
	h := hvHub(t)
	out, err := MoveMsg(context.Background(), opCfg(t, h.url),
		MoveMsgArgs{MsgID: strings.ToUpper(hvMsg), ToTask: strings.ToUpper(hvTask), As: "CLE-1"})
	if err != nil || string(out) != `{"moved":true}` {
		t.Fatalf("MoveMsg = %s, %v", out, err)
	}
	fs := h.of(wire.TMove)
	if len(fs) != 1 {
		t.Fatalf("frames %+v, want one move", fs)
	}
	if f := fs[0]; f.MoveMsg != hvMsg || f.MoveToTask != hvTask || f.As != "CLE-1" || f.TypedBy != "" || f.TaskID != "" || f.MoveTo != "" {
		t.Errorf("frame msg %q to-task %q as %q for %q task %q to %q", f.MoveMsg, f.MoveToTask, f.As, f.TypedBy, f.TaskID, f.MoveTo)
	}
}

// TestPinRefusals: Pin refuses a bad box, both or neither of --pubkey and
// --revoke, a key that is not base64 and a changed key without --force, and
// a root key without hub mode only after the local pin is written.
func TestPinRefusals(t *testing.T) {
	pk := base64.StdEncoding.EncodeToString(make([]byte, 32))
	other := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("k", 32)))
	cases := []struct {
		name   string
		hubURL string
		in     PinArgs
		want   string
		pinned string // the pin of box-a after the call ("" = none)
	}{
		{"empty box", "", PinArgs{PubKey: pk}, "--box (valid box id) is required", ""},
		{"bad box", "", PinArgs{Box: "Box A", PubKey: pk}, "--box (valid box id) is required", ""},
		{"neither", "", PinArgs{Box: "box-a"}, "exactly one of --pubkey or --revoke is required", ""},
		{"both", "", PinArgs{Box: "box-a", PubKey: pk, Revoke: true}, "exactly one of --pubkey or --revoke is required", ""},
		{"not base64", "", PinArgs{Box: "box-a", PubKey: "%%%"}, "pubkey is not valid base64", ""},
		{"root key, no hub", "", PinArgs{Box: "box-a", PubKey: pk, RootKey: "unused"},
			"--root-key / $SPOOL_TENANT_ROOT_KEY needs hub mode ($SPOOL_HUB_URL)", pk},
		{"root key not a key", "http://127.0.0.1:1", PinArgs{Box: "box-a", PubKey: pk, RootKey: "bm90LWEta2V5"},
			"is not a base64 ed25519 private key", pk},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfg := &config.Config{PinsDir: t.TempDir(), HubURL: c.hubURL}
			err := Pin(cfg, c.in)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want %q", err, c.want)
			}
			if got := pinB64(cfg.PinsDir, "box-a"); got != c.pinned {
				t.Errorf("pin after the refusal = %q, want %q", got, c.pinned)
			}
		})
	}
	t.Run("changed key without force", func(t *testing.T) {
		cfg := &config.Config{PinsDir: t.TempDir()}
		if err := Pin(cfg, PinArgs{Box: "box-a", PubKey: pk}); err != nil {
			t.Fatal(err)
		}
		err := Pin(cfg, PinArgs{Box: "box-a", PubKey: other})
		if err == nil || !strings.Contains(err.Error(), "already set to a different key (use --force to change)") {
			t.Fatalf("err = %v, want the --force refusal", err)
		}
		if got := pinB64(cfg.PinsDir, "box-a"); got != pk {
			t.Errorf("pin = %q, want the first key kept", got)
		}
	})
}

// TestPinLocal: with no root key Pin writes, forces and revokes the local
// pin only, and never needs a hub.
func TestPinLocal(t *testing.T) {
	pk := base64.StdEncoding.EncodeToString(make([]byte, 32))
	other := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("k", 32)))
	cfg := &config.Config{PinsDir: t.TempDir()}
	steps := []struct {
		name string
		in   PinArgs
		want string // the pin after the step, "" = no pin
	}{
		{"pin", PinArgs{Box: "box-a", PubKey: pk}, pk},
		{"same key again", PinArgs{Box: "box-a", PubKey: pk}, pk},
		{"force a new key", PinArgs{Box: "box-a", PubKey: other, Force: true}, other},
		{"revoke", PinArgs{Box: "box-a", Revoke: true}, ""},
		{"revoke again", PinArgs{Box: "box-a", Revoke: true}, ""},
	}
	for _, s := range steps {
		if err := Pin(cfg, s.in); err != nil {
			t.Fatalf("%s: %v", s.name, err)
		}
		if got := pinB64(cfg.PinsDir, "box-a"); got != s.want {
			t.Fatalf("%s: pin = %q, want %q", s.name, got, s.want)
		}
	}
	if ents, err := os.ReadDir(cfg.PinsDir); err != nil || len(ents) != 0 {
		t.Errorf("pins dir after revoke = %v, %v; want empty", ents, err)
	}
}
