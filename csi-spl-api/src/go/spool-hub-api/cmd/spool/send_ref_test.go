package main

import (
	"io"
	"os"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit/fakehub"
)

// Spec 067 row L5: `spool send --ref <task>` claims the topic a DM is about.
// The claim rides the SEND FRAME as ref_task_id, never the signed envelope:
// a box older than 31053328 refuses an inner msg with a key it does not know
// (internal/hub/dm_ref.go).
func TestSendRefRidesTheFrameNotTheEnvelope(t *testing.T) {
	const topic = "0b6f0c55-8a1f-4d5e-9a4c-2f0d4c6e7a10"
	h := fakehub.New(t)
	cfg := testkit.NewConfig(t)
	testkit.Agents(t, cfg, "c-001")
	h.Wire(t, cfg, "box-a")
	quiet := func(fn func() int) int {
		old := os.Stdout
		os.Stdout, _ = os.Open(os.DevNull)
		defer func() { os.Stdout = old }()
		return fn()
	}
	base := []string{"--from", "c-001", "--to", "HUM-3", "--to-box", "box-wui", "--kind", "msg", "--body", "about the topic"}
	if code := quiet(func() int { return cmdSend(cfg, append(append([]string{}, base...), "--ref", topic)) }); code != 0 {
		t.Fatalf("send --ref: exit %d", code)
	}
	// CONTROL: the same send without --ref carries no claim.
	if code := quiet(func() int { return cmdSend(cfg, base) }); code != 0 {
		t.Fatalf("plain send: exit %d", code)
	}
	sends := h.Sends()
	if len(sends) != 2 {
		t.Fatalf("hub got %d sends, want 2", len(sends))
	}
	if got := sends[0].RefTaskID; got != topic {
		t.Errorf("--ref frame ref_task_id = %q, want %q", got, topic)
	}
	if got := sends[1].RefTaskID; got != "" {
		t.Errorf("plain frame ref_task_id = %q, want none", got)
	}
	for i, f := range sends {
		if strings.Contains(string(f.Env), "ref_task_id") || strings.Contains(string(f.Env), topic) {
			t.Errorf("send %d: the claim leaked into the envelope: %s", i, f.Env)
		}
	}
}

// --ref is refused where the hub could not store it, before anything is sent.
func TestSendRefRefusals(t *testing.T) {
	const topic = "0b6f0c55-8a1f-4d5e-9a4c-2f0d4c6e7a10"
	h := fakehub.New(t)
	stderr := func(fn func() int) (int, string) {
		r, w, _ := os.Pipe()
		old := os.Stderr
		os.Stderr = w
		code := fn()
		w.Close()
		os.Stderr = old
		b, _ := io.ReadAll(r)
		return code, string(b)
	}
	for _, c := range []struct {
		hub  bool
		args []string
		want string
	}{
		{false, []string{"--to", "c-002", "--ref", topic}, "--ref needs hub mode"},
		{true, []string{"--to", "HUM-3", "--to-box", "box-wui", "--ref", "not-a-uuid"}, "--ref must be a topic uuid"},
		{true, []string{"--channel", "ops", "--ref", topic}, "drop --channel"},
	} {
		cfg := testkit.NewConfig(t)
		testkit.Agents(t, cfg, "c-001", "c-002")
		if c.hub {
			h.Wire(t, cfg, "box-a")
		}
		args := append([]string{"--from", "c-001", "--kind", "msg", "--body", "x"}, c.args...)
		code, out := stderr(func() int { return cmdSend(cfg, args) })
		if code != 1 || !strings.Contains(out, c.want) {
			t.Errorf("%v: exit %d %q, want 1 naming %q", c.args, code, out, c.want)
		}
	}
	if n := len(h.Sends()); n != 0 {
		t.Fatalf("a refused --ref still reached the hub (%d sends)", n)
	}
}
