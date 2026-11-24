//go:build linux

package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/keydesk"
)

func keyDeskCfg(t *testing.T) (*config.Config, *hubclient.Client) {
	t.Helper()
	d, err := os.MkdirTemp("", "kdc")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(d) })
	cfg := &config.Config{SpoolRoot: filepath.Join(d, "spool"), BoxID: "box-a"}
	t.Setenv("SPOOL_SEAT_ROOT", filepath.Join(d, "spool-seat"))
	return cfg, hubclient.New(cfg)
}

// Off by default: a fleet desk's hub-run opens no key socket.
func TestKeyDeskOffByDefault(t *testing.T) {
	cfg, c := keyDeskCfg(t)
	t.Setenv("SPOOL_KEY_DESK", "")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	startKeyDesk(ctx, cfg, c)
	time.Sleep(50 * time.Millisecond)
	if _, err := os.Lstat(keydesk.SockPath(cfg.HubDir())); err == nil {
		t.Fatal("a key socket opened without SPOOL_KEY_DESK=1")
	}
}

func TestKeyDeskOnListensWithIdentity(t *testing.T) {
	cfg, c := keyDeskCfg(t)
	t.Setenv("SPOOL_KEY_DESK", "1")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	startKeyDesk(ctx, cfg, c)
	sock := keydesk.SockPath(cfg.HubDir())
	// Wait for the state asserted, the 0600 mode, not for the file: Listen
	// binds the socket with the umask's bits and chmods it after, so the
	// file exists before it is 0600 (b43-01). The 10 s budget is a cap.
	last := "the socket never appeared"
	deadline := time.Now().Add(10 * time.Second)
	for {
		st, err := os.Stat(sock)
		if err == nil {
			if st.Mode().Perm() == 0o600 {
				break
			}
			last = "last mode " + st.Mode().Perm().String()
		}
		if time.Now().After(deadline) {
			t.Fatalf("key socket %s not 0600 within 10s: %s", sock, last)
		}
		time.Sleep(10 * time.Millisecond)
	}
	idf, err := os.Stat(filepath.Join(cfg.HubDir(), "desk-x25519.key"))
	if err != nil || idf.Mode().Perm() != 0o600 {
		t.Fatalf("identity file: %v %v", idf, err)
	}
}

func TestKeyDeskBadTTLRefused(t *testing.T) {
	cfg, c := keyDeskCfg(t)
	t.Setenv("SPOOL_KEY_LEASE_TTL", "soon")
	if _, err := keyDeskServer(cfg, c); err == nil {
		t.Fatal("a bad lease TTL was accepted")
	}
	t.Setenv("SPOOL_KEY_LEASE_TTL", "5m")
	s, err := keyDeskServer(cfg, c)
	if err != nil || s.TTL != 5*time.Minute || s.Box != "box-a" {
		t.Fatalf("server: %+v %v", s, err)
	}
}
