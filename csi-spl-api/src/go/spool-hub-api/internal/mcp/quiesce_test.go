package mcp

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// TestWritingToolsWaitOutQuiesce: under a live <desk>.quiesce marker (wait
// 0 s) spool_send, spool_recv and spool_put_file refuse and write nothing.
func TestWritingToolsWaitOutQuiesce(t *testing.T) {
	desk := filepath.Join(t.TempDir(), "desk", "t1", "box-q")
	root := filepath.Join(desk, "spool")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(desk+".quiesce", []byte("do_spl_desk_move test\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DESK_QUIESCE_WAIT_SECS", "0")
	tl := tools{cfg: &config.Config{SpoolRoot: root, BoxID: "box-q"}}
	ctx := context.Background()
	_, _, errSend := tl.send(ctx, nil, SendIn{From: "c-101", To: "HUM-10", TaskID: "t", Kind: "note", Body: "x"})
	_, _, errRecv := tl.recv(ctx, nil, RecvIn{As: "c-101", Ack: true})
	_, _, errPut := tl.putFile(ctx, nil, PutFileIn{Path: desk + ".quiesce"})
	for name, err := range map[string]error{"send": errSend, "recv": errRecv, "put": errPut} {
		if err == nil || !strings.Contains(err.Error(), "desk quiesced") {
			t.Fatalf("%s under a live marker: %v, want desk quiesced", name, err)
		}
	}
	if ents, _ := os.ReadDir(root); len(ents) != 0 {
		t.Fatalf("a refused tool wrote into the spool: %d entries", len(ents))
	}
}
