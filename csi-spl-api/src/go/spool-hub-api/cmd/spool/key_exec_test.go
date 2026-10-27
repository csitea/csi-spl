package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/keyexec"
)

func TestKeyExecArgs(t *testing.T) {
	kind, cli, rest, ok := keyExecArgs([]string{"grok", "--", "/usr/bin/grok", "-x"})
	if !ok || kind != "grok" || cli != "/usr/bin/grok" || len(rest) != 1 || rest[0] != "-x" {
		t.Fatalf("got %q %q %v %v", kind, cli, rest, ok)
	}
	for _, bad := range [][]string{{"grok"}, {"grok", "/usr/bin/grok"}, {"nope", "--", "x"}, {"grok", "-", "x"}} {
		if _, _, _, ok := keyExecArgs(bad); ok {
			t.Errorf("keyExecArgs(%v) accepted", bad)
		}
	}
	if rc := cmdKeyExec([]string{"nope"}); rc != keyexec.ExitUsage {
		t.Errorf("bad call exit %d, want %d", rc, keyexec.ExitUsage)
	}
	if rc := cmdKeyHelper([]string{"claude"}); rc != keyexec.ExitUsage {
		t.Errorf("helper bad call exit %d, want %d", rc, keyexec.ExitUsage)
	}
}

func TestShQuote(t *testing.T) {
	if got := shQuote("/a b/it's"); got != `'/a b/it'\''s'` {
		t.Fatalf("shQuote = %s", got)
	}
}

// The helper prints the leased key and nothing else; a refusal is silent.
func TestCmdKeyHelper(t *testing.T) {
	dir, err := os.MkdirTemp("", "kh")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	sock := filepath.Join(dir, "k.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	answers := []string{`{"ok":true,"key":"sk-test-0000"}`, `{"ok":false,"error":"key_exhausted"}`}
	go func() {
		for _, a := range answers {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			_, _ = bufio.NewReader(c).ReadBytes('\n')
			fmt.Fprintln(c, a)
			c.Close()
		}
	}()
	if rc := cmdKeyHelper([]string{"--sock", sock, "claude"}); rc != 0 {
		t.Fatalf("lease answered: exit %d, want 0", rc)
	}
	if rc := cmdKeyHelper([]string{"--sock", sock, "claude"}); rc != 1 {
		t.Fatalf("key_exhausted: exit %d, want 1", rc)
	}
}
