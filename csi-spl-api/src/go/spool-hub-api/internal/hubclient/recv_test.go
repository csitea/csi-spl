package hubclient

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// r7-04: what a role=box session does with the frames the hub pushes after
// welcome - a DM, a channel copy, a back-fill and its summary, a WUI
// fallback, a roster - driven end to end through Sync.

// pokeLog points the terminal leg at a script that appends its argv to a
// file, and returns that file.
func pokeLog(t *testing.T, c *Client) string {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "pokes")
	script := filepath.Join(dir, "poke.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\necho \"$@\" >> "+log+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	c.Cfg.NotifyCmd = script
	return log
}

func readPokes(t *testing.T, log string) string {
	t.Helper()
	raw, err := os.ReadFile(log)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return string(raw)
}

// inbox counts the files in agent's inbox.
func inbox(t *testing.T, c *Client, agent string) int {
	t.Helper()
	ents, err := os.ReadDir(filepath.Join(c.Cfg.SpoolRoot, agent, "inbox"))
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, e := range ents {
		if strings.HasSuffix(e.Name(), ".json") {
			n++
		}
	}
	return n
}

func TestSyncDeliversPushedFrames(t *testing.T) {
	b, wui := newPeer(t, "box-b"), newPeer(t, wuiBox)
	h := &opsHub{pins: []wire.PinEntry{b.pin, wui.pin}, roster: map[string][]string{"box-b": {"c-009"}}}
	c := opsClient(t, h)
	pokes := pokeLog(t, c)

	dm := note("c-009", "c-007", "task", "a DM with a file")
	fileID := h.putFile([]byte("blob riding the DM"))
	dm.Files = []msg.Attachment{{Mode: "blob", Kind: "file", FileID: fileID, SHA256: fileID, Name: "f.txt", Bytes: 18}}
	ch := note("c-009", "ALL-0", "note", "a channel post")
	bf := note("c-009", "ALL-0", "note", "an earlier post")
	fb := note("HUM-1", "c-008", "task", "  nobody\n answered   this ")
	h.push = []wire.Frame{
		{Type: wire.TRecv, Env: envRaw(t, b, "box-a", "", dm)},
		{Type: wire.TRecv, Env: envRaw(t, b, wuiBox, "ops", ch), Agents: []string{"c-007", "c-008", "c-099"}},
		{Type: wire.TRecv, Env: envRaw(t, b, wuiBox, "lobby", bf), Agents: []string{"c-007"}, Backfill: "general"},
		{Type: wire.TBackfillEnd, Backfill: "lobby", Agents: []string{"c-007", "c-008"}, Count: 1, Topics: 1, From: "c-009",
			MsgID: bf.MsgID, TaskID: bf.TaskID},
		{Type: wire.TRecv, Env: envRaw(t, wui, wuiBox, "", fb), Agents: []string{"c-008"}, Fallback: "DM to c-008"},
		{Type: wire.TRoster, Roster: map[string][]string{"box-b": {"c-009"}, "box-c": {"c-010"}}},
	}
	r, err := c.Sync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	// dm -> c-007; channel -> c-007, c-008 (c-099 is not here); back-fill ->
	// c-007; fallback -> c-008
	if r.Delivered != 5 || r.Refused != 0 || r.Flushed != 0 || r.Pending != 0 {
		t.Errorf("report %+v", r)
	}
	if n7, n8 := inbox(t, c, "c-007"), inbox(t, c, "c-008"); n7 != 3 || n8 != 2 {
		t.Errorf("inboxes c-007 %d c-008 %d, want 3 and 2", n7, n8)
	}
	if raw, err := os.ReadFile(filepath.Join(c.Cfg.FilesDir(), fileID)); err != nil || string(raw) != "blob riding the DM" {
		t.Errorf("attachment %q %v", raw, err)
	}
	// only the plain recv frames are committed, each by its msg_id
	var commits []string
	for _, f := range h.frames(wire.TCommit) {
		commits = append(commits, f.MsgID)
	}
	if strings.Join(commits, ",") != dm.MsgID+","+ch.MsgID {
		t.Errorf("commits %v, want the DM and the channel post", commits)
	}
	p := readPokes(t, pokes)
	if !strings.Contains(p, "--to c-007") || strings.Count(p, "--msg-id "+bf.MsgID) != 1 {
		t.Errorf("back-fill summary pokes:\n%s", p)
	}
	if !strings.Contains(p, "--to c-008") || !strings.Contains(p, "--msg-id "+fb.MsgID) {
		t.Errorf("fallback pokes:\n%s", p)
	}
	// the roster frame replaced the welcome's: c-010 now resolves to box-c
	if box, err := c.ResolveToBox("c-010", ""); err != nil || box != "box-c" {
		t.Errorf("c-010 -> %q %v", box, err)
	}
}

func TestSyncReportsRefusedFrames(t *testing.T) {
	b, wui := newPeer(t, "box-b"), newPeer(t, wuiBox)
	stranger := newPeer(t, "box-z") // never pinned
	h := &opsHub{pins: []wire.PinEntry{b.pin, wui.pin}}
	c := opsClient(t, h)
	m := func() *msg.Message { return note("c-009", "c-007", "task", "x") }
	h.push = []wire.Frame{
		{Type: wire.TRecv, Env: envRaw(t, stranger, "box-a", "", m())},                                        // unpinned sender
		{Type: wire.TRecv, Env: envRaw(t, b, "box-q", "", m())},                                               // another box's DM
		{Type: wire.TRecv, Env: envRaw(t, b, wuiBox, "ops", m()), Agents: []string{"c-099"}},                  // hosts none
		{Type: wire.TRecv, Env: envRaw(t, wui, "box-a", "", note("HUM-1", "c-007", "result", "x"))},           // wui kind
		{Type: wire.TRecv, Env: envRaw(t, b, wuiBox, "ops", m()), Agents: []string{"c-007"}, Backfill: "dev"}, // wrong channel
		{Type: wire.TRecv, Env: envRaw(t, b, wuiBox, "dev", m()), Agents: []string{"c-099"}, Backfill: "dev"}, // back-fill hosts none
		{Type: wire.TRecv, Env: envRaw(t, b, wuiBox, "", m()), Agents: []string{"c-007"}, Fallback: "#ops"},   // fallback not from wui
		{Type: wire.TRecv, Env: envRaw(t, wui, wuiBox, "", m()), Agents: []string{"c-099"}, Fallback: "#ops"}, // fallback hosts none
		{Type: wire.TRecv, Env: []byte(`{"broken":true}`)},
	}
	r, err := c.Sync(context.Background())
	if err == nil || !strings.Contains(err.Error(), "box-z") {
		t.Fatalf("Sync returned %v, want the first refusal (unpinned box-z)", err)
	}
	if r.Refused != len(h.push) || r.Delivered != 0 {
		t.Errorf("report %+v, want %d refused and none delivered", r, len(h.push))
	}
	if n := inbox(t, c, "c-007"); n != 0 {
		t.Errorf("c-007 got %d files from refused frames", n)
	}

	// each frame is refused for its own reason, in order
	s, err := c.Dial(context.Background(), wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if n, err := s.WaitQueueEnd(context.Background()); err != nil || n != len(h.push) {
		t.Fatalf("queue_end %d %v", n, err)
	}
	want := []string{"box-z", `to_box "box-q"`, "hosts none", "kind \"result\"", "back-fill frame for #dev carries",
		"back-fill frame for agents", "not box-wui", "fallback frame for agents", ""}
	errs := s.RecvErrors()
	if len(errs) != len(want) {
		t.Fatalf("%d refusals, want %d: %v", len(errs), len(want), errs)
	}
	for i, w := range want {
		if !strings.Contains(errs[i].Error(), w) {
			t.Errorf("frame %d refused with %q, want it to name %q", i, errs[i], w)
		}
	}
	if s.Delivered() != 0 {
		t.Errorf("delivered %d", s.Delivered())
	}
}

// A pin the hub rotated keeps the session up, and Sync still reports it.
func TestSyncReportsPinConflict(t *testing.T) {
	b, x := newPeer(t, "box-b"), newPeer(t, "box-x")
	h := &opsHub{pins: []wire.PinEntry{b.pin}}
	c := opsClient(t, h)
	if _, err := c.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	h.setPins(wire.PinEntry{BoxID: "box-b", PubKey: x.pin.PubKey})
	_, err := c.Sync(context.Background())
	var he *HubError
	if !asHubError(err, &he) || he.Token != "pin_conflict" {
		t.Fatalf("got %v", err)
	}
}

// A refused pin list fails the role=box dial; an unreadable pending dir
// reads as pending -1, never 0.
func TestSyncDialAndOutboxFailures(t *testing.T) {
	h := &opsHub{restStatus: 403, restToken: "forbidden"}
	c := opsClient(t, h)
	if _, err := c.Sync(context.Background()); err == nil || !strings.Contains(err.Error(), "forbidden") {
		t.Fatalf("got %v", err)
	}
	h.setREST(0, "")
	if err := os.MkdirAll(c.Cfg.HubDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(c.pendingDir(), []byte("a file, not a dir"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := c.pendingCount(); got != -1 {
		t.Errorf("pendingCount with an unreadable outbox = %d, want -1", got)
	}
}
