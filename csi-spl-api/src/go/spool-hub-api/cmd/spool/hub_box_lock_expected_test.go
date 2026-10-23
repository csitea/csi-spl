package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit/fakehub"
)

// Spec 025 box owner lock, row B6 (section 6.4, SPL-3014): the hub start
// check. A hub started with SPOOL_HUB_BOX_LOCKS_EXPECTED naming a box that
// has no lock row refuses that box: here the workspace root key's pin of it
// (path 8) is 403 box_locked, while an unlisted box pins (the control).
// Remove the ExpectBoxLocks call from expectBoxLocks and this test fails.
func TestHubStartRefusesExpectedBoxWithoutLock(t *testing.T) {
	ctx := context.Background()
	st := store.NewMemory()
	lockPub, _, _ := ed25519.GenerateKey(nil)
	var logs bytes.Buffer
	raw := "t1:box-own:" + base64.StdEncoding.EncodeToString(lockPub)
	if err := expectBoxLocks(ctx, zerolog.New(&logs), st, raw); err != nil {
		t.Fatalf("expectBoxLocks: %v", err)
	}
	if !strings.Contains(logs.String(), "box_lock.expected_missing") || !strings.Contains(logs.String(), "box-own") {
		t.Fatalf("start log %q, want box-own named as refused", logs.String())
	}

	srv, err := hub.New(hub.Options{Store: st, Blob: blob.Dir{Root: t.TempDir()}, Log: zerolog.Nop(),
		TenantHostPattern: "{tenant}.hub.test", HelloSkew: 300 * time.Second, Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(func() { srv.Shutdown(); ts.Close() })
	cfg := testkit.NewConfig(t)
	(&fakehub.Hub{URL: ts.URL}).Wire(t, cfg, "box-a")
	root := filepath.Join(t.TempDir(), "root.key")
	rc, rootPub, errOut := capture(t, "", func() int { return cmdRootKeygen([]string{"--out", root}) })
	if rc != 0 {
		t.Fatalf("root-keygen: rc %d %q", rc, errOut)
	}
	rp, err := base64.StdEncoding.DecodeString(strings.TrimSpace(rootPub))
	if err != nil {
		t.Fatal(err)
	}
	if err := st.CreateTenant(ctx, store.Tenant{ID: "t1", RootPubKey: rp}); err != nil {
		t.Fatal(err)
	}
	pin := func(box string) (int, string) {
		boxPub, _, _ := ed25519.GenerateKey(nil) // a key of its own: no pin_conflict
		rc, out, errOut := capture(t, "", func() int {
			return cmdHubPin(cfg, []string{"--box", box, "--pubkey", base64.StdEncoding.EncodeToString(boxPub), "--root-key", root})
		})
		return rc, out + errOut
	}
	if rc, out := pin("box-sh"); rc != 0 {
		t.Fatalf("CONTROL: pin of an unlisted box: rc %d %q", rc, out)
	}
	if rc, out := pin("box-own"); rc == 0 || !strings.Contains(out, "box_locked") {
		t.Fatalf("pin of a listed box with no lock row: rc %d %q, want 403 box_locked", rc, out)
	}
}

// TestExpectBoxLocksRefusesBadList: a malformed list stops the start, and
// an empty one is a no-op.
func TestExpectBoxLocksRefusesBadList(t *testing.T) {
	ctx, st := context.Background(), store.NewMemory()
	if err := expectBoxLocks(ctx, zerolog.Nop(), st, ""); err != nil {
		t.Fatalf("empty list: %v", err)
	}
	for _, bad := range []string{"t1:box-own", "t1:box-own:not-a-key"} {
		if err := expectBoxLocks(ctx, zerolog.Nop(), st, bad); err == nil || !strings.Contains(err.Error(), "box_locks_expected") {
			t.Fatalf("%q: %v, want a refusal", bad, err)
		}
	}
}
