package mcp

import (
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit/fakehub"
)

// Spec 067 row L5: spool_send's ref_task_id is `spool send --ref`. It rides
// the SEND FRAME, never the signed envelope (internal/hub/dm_ref.go).
func TestSendRefTaskIDRidesTheFrameNotTheEnvelope(t *testing.T) {
	const topic = "0b6f0c55-8a1f-4d5e-9a4c-2f0d4c6e7a10"
	h := fakehub.New(t)
	cs, cfg := seated(t, "c-001")
	testkit.Agents(t, cfg, "c-001")
	h.Wire(t, cfg, "box-a")

	dm := map[string]any{"to": "HUM-3", "kind": "msg", "body": "about the topic"}
	withRef := map[string]any{"ref_task_id": topic}
	for k, v := range dm {
		withRef[k] = v
	}
	if out, isErr := callText(t, cs, "spool_send", withRef); isErr {
		t.Fatalf("send with ref_task_id: %s", out)
	}
	// CONTROL: the same send without the field carries no claim.
	if out, isErr := callText(t, cs, "spool_send", dm); isErr {
		t.Fatalf("plain send: %s", out)
	}
	sends := h.Sends()
	if len(sends) != 2 {
		t.Fatalf("hub got %d sends, want 2", len(sends))
	}
	if got := sends[0].RefTaskID; got != topic {
		t.Errorf("frame ref_task_id = %q, want %q", got, topic)
	}
	if got := sends[1].RefTaskID; got != "" {
		t.Errorf("plain frame ref_task_id = %q, want none", got)
	}
	for i, f := range sends {
		if f.ToBox != "" && f.ToBox != "box-wui" {
			t.Errorf("send %d: to_box %q", i, f.ToBox)
		}
		if strings.Contains(string(f.Env), "ref_task_id") || strings.Contains(string(f.Env), topic) {
			t.Errorf("send %d: the claim leaked into the envelope: %s", i, f.Env)
		}
	}
	// A malformed claim is a tool error, and nothing more reaches the hub.
	withRef["ref_task_id"] = "not-a-uuid"
	if out, isErr := callText(t, cs, "spool_send", withRef); !isErr || !strings.Contains(out, "--ref must be a topic uuid") {
		t.Fatalf("bad ref_task_id: isErr=%v %q", isErr, out)
	}
	if n := len(h.Sends()); n != 2 {
		t.Fatalf("a refused ref_task_id reached the hub (%d sends)", n)
	}
}
