package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/quiesce"
)

// TestRunGatedBoxCmdQuiesceGate: a live <desk>.quiesce marker refuses a writing
// box command with exit 75 after the bounded wait (0 s here) and writes
// nothing; a read-only command passes it; with no marker the command runs.
func TestRunGatedBoxCmdQuiesceGate(t *testing.T) {
	desk := filepath.Join(t.TempDir(), "desk", "t1", "box-q")
	cfg := &config.Config{SpoolRoot: filepath.Join(desk, "spool"), BoxID: "box-q"}
	if err := os.MkdirAll(cfg.SpoolRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(desk+".quiesce", []byte("do_spl_desk_move test\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DESK_QUIESCE_WAIT_SECS", "0")
	if rc := runGatedBoxCmd(cfg, "recv", []string{"--as", "c-101", "--ack"}); rc != quiesce.ExitCode {
		t.Fatalf("recv under a live marker = %d, want %d", rc, quiesce.ExitCode)
	}
	if _, err := os.Stat(filepath.Join(cfg.SpoolRoot, "c-101")); !os.IsNotExist(err) {
		t.Fatalf("the refused recv wrote its mailbox: %v", err)
	}
	if rc := runGatedBoxCmd(cfg, "tail", []string{"--task", "t-none"}); rc == quiesce.ExitCode {
		t.Fatal("tail is read-only and must pass the gate")
	}
	os.Remove(desk + ".quiesce")
	if rc := runGatedBoxCmd(cfg, "recv", []string{"--as", "c-101"}); rc != 0 {
		t.Fatalf("recv with no marker = %d, want 0", rc)
	}
}
