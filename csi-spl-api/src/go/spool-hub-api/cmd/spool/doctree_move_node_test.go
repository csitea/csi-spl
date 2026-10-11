package main

import (
	"testing"
)

// TestDocTreeMoveNode: move-node posts {parent} to the node's move route
// (spec 120 section 7; gap topic t1 b67d5dc7), and wants exactly one node id.
func TestDocTreeMoveNode(t *testing.T) {
	h := newDTHub(t)
	got := dtOK(t, "move-node", "n1", "--parent", "f1")
	in, _ := got["in"].(map[string]any)
	if got["route"] != "nodes" || in["parent"] != "f1" {
		t.Fatalf("move-node answer: %v", got)
	}
	if last := h.calls[len(h.calls)-1]; last != "POST /v1/workspace/doctree/nodes/n1/move" {
		t.Fatalf("move-node called %q", last)
	}
	dtOK(t, "move-node", "n1")
	if rc, _, _ := captureRun(t, []string{"doctree", "move-node"}); rc == 0 {
		t.Fatal("move-node without a node id: rc 0")
	}
}
