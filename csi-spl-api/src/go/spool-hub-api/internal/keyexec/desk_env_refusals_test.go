package keyexec

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// drDesk answers every ask on a local socket with one fixed reply: fakeDesk
// always answers OK on exhausted, so it cannot show a refused report.
func drDesk(t *testing.T, reply Reply) (path string, asks <-chan Request) {
	t.Helper()
	path = filepath.Join(t.TempDir(), "k.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	got := make(chan Request, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		line, err := bufio.NewReader(c).ReadBytes('\n')
		if err != nil {
			return
		}
		var req Request
		_ = json.Unmarshal(line, &req)
		got <- req
		_ = json.NewEncoder(c).Encode(reply)
	}()
	return path, got
}

func drSeatDir(t *testing.T, mode os.FileMode) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.Chmod(dir, mode); err != nil {
		t.Fatal(err)
	}
	return dir
}

func drWantErr(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("err = %v, want one containing %q", err, want)
	}
}

func TestDrExhaustedNoSocket(t *testing.T) {
	drWantErr(t, SockDesk{}.Exhausted(context.Background(), "grok"), "no desk key socket")
}

func TestDrExhaustedRefused(t *testing.T) {
	cases := []struct{ name, sent, want string }{
		{"token", "no_key", "no_key"},
		{"blank", "", "refused"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			path, asks := drDesk(t, Reply{OK: false, Error: c.sent})
			d := SockDesk{Path: path, Seat: "seat-a", Task: "task-a"}
			err := d.Exhausted(context.Background(), "grok")
			var refused *RefusedError
			if !errors.As(err, &refused) {
				t.Fatalf("err = %v, want a *RefusedError", err)
			}
			if refused.Token != c.want {
				t.Fatalf("token = %q, want %q", refused.Token, c.want)
			}
			want := Request{Op: "exhausted", Kind: "grok", Seat: "seat-a", Task: "task-a"}
			if got := <-asks; got != want {
				t.Fatalf("ask = %+v, want %+v", got, want)
			}
		})
	}
}

func TestDrNoVibeEnvFile(t *testing.T) {
	if err := noVibeEnvFile(nil); err != nil {
		t.Fatalf("no HOME: err = %v, want nil", err)
	}
	home := t.TempDir()
	base := []string{"HOME=" + home}
	if err := noVibeEnvFile(base); err != nil {
		t.Fatalf(".vibe/.env absent: err = %v, want nil", err)
	}
	if err := os.Mkdir(filepath.Join(home, ".vibe"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".vibe", ".env"), []byte("FAKE=1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	drWantErr(t, noVibeEnvFile(base), "holds .vibe/.env")
}

func TestDrWriteClaudeSettingsRefusals(t *testing.T) {
	cases := []struct {
		name, dir, helper, want string
	}{
		{"empty seat dir", "", "fake-helper", "no seat dir"},
		{"mode 0755", drSeatDir(t, 0o755), "fake-helper", "want 0700"},
		{"blank helper", drSeatDir(t, 0o700), " \t", "no apiKeyHelper"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f, err := writeClaudeSettings(c.dir, c.helper)
			drWantErr(t, err, c.want)
			if f != "" {
				t.Fatalf("path = %q, want none on a refusal", f)
			}
		})
	}
}

func TestDrWriteClaudeSettingsGood(t *testing.T) {
	dir := drSeatDir(t, 0o700)
	f, err := writeClaudeSettings(dir, "fake-helper --seat")
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(dir, "claude-settings.json"); f != want {
		t.Fatalf("path = %q, want %q", f, want)
	}
	st, err := os.Stat(f)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %o, want 600", st.Mode().Perm())
	}
	b, err := os.ReadFile(f) // #nosec G304 -- the test's own temp dir
	if err != nil {
		t.Fatal(err)
	}
	var body map[string]string
	if err := json.Unmarshal(b, &body); err != nil {
		t.Fatalf("body %q: %v", b, err)
	}
	if len(body) != 1 || body["apiKeyHelper"] != "fake-helper --seat" {
		t.Fatalf("body = %v, want the helper and nothing else", body)
	}
}
