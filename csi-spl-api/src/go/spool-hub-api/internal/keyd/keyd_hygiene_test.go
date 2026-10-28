package keyd

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"unsafe"

	"filippo.io/age"
)

// Rule: Lock makes serveConns' shutdown wipe every locked identity.
func TestServeConnsLockWipesSecrets(t *testing.T) {
	dir := shortDir(t)
	agents := []AgentKey{{ID: "c-101", Identity: heapIdentity(t)}, {ID: "c-102", Identity: heapIdentity(t)}}
	secs, err := lockIdentities(agents)
	if err != nil {
		t.Fatal(err)
	}
	raws := make([][]byte, len(secs))
	for i := range secs {
		raws[i] = secs[i].raw
	}
	done := startServeConns(t, dir, secs)
	waitStatus(t, dir, "unlocked", nil)
	if err := Lock(dir); err != nil {
		t.Fatal(err)
	}
	<-done
	for i, raw := range raws {
		if secs[i].raw != nil || !allZero(raw) {
			t.Fatalf("identity %d not wiped after lock", i)
		}
	}
}

// Rule: listenSock refuses a dir whose keyd is alive and leaves it serving.
func TestListenSockKeepsLiveDaemon(t *testing.T) {
	dir := shortDir(t)
	done := startServeConns(t, dir, nil)
	waitStatus(t, dir, "unlocked", nil)
	defer func() { _ = Lock(dir); <-done }()
	sock := filepath.Join(dir, "keyd.sock")
	pidPath := filepath.Join(dir, "keyd.pid")
	if ln, err := listenSock(sock, pidPath); err == nil || err.Error() != "keyd already running" {
		if ln != nil {
			ln.Close()
		}
		t.Fatalf("second listen: %v, want keyd already running", err)
	}
	if _, err := os.Stat(pidPath); err != nil {
		t.Fatalf("pid file of the live keyd gone: %v", err)
	}
	if st, err := Status(dir); err != nil || st != "unlocked" {
		t.Fatalf("live keyd after second listen: %q %v", st, err)
	}
}

// Rule: lockIdentities refuses an empty identity and wipes the copy it took.
// The already-locked copy is internal and returned as nil, so the test checks
// the error, the nil result and the earlier caller string, not that copy.
func TestLockIdentitiesRefusesEmpty(t *testing.T) {
	first := heapIdentity(t)
	backing := unsafe.Slice(unsafe.StringData(first), len(first))
	agents := []AgentKey{{ID: "c-101", Identity: first}, {ID: "c-102", Identity: ""}}
	secs, err := lockIdentities(agents)
	if err == nil || err.Error() != "empty identity" {
		wipeSecrets(secs)
		t.Fatalf("empty identity: %v, want empty identity", err)
	}
	if secs != nil {
		t.Fatal("secrets returned with the error")
	}
	if agents[0].Identity != "" || !allZero(backing) {
		t.Fatal("earlier identity not wiped on the error")
	}
}

// Rule: lockIdentities wipes the caller's identity string, field and bytes.
func TestLockIdentitiesWipesCallerCopy(t *testing.T) {
	agents := []AgentKey{{ID: "c-101", Identity: heapIdentity(t)}, {ID: "c-102", Identity: heapIdentity(t)}}
	backings := make([][]byte, len(agents))
	want := make([]string, len(agents))
	for i := range agents {
		backings[i] = unsafe.Slice(unsafe.StringData(agents[i].Identity), len(agents[i].Identity))
		want[i] = string(backings[i])
	}
	secs, err := lockIdentities(agents)
	if err != nil {
		t.Fatal(err)
	}
	defer wipeSecrets(secs)
	for i := range agents {
		if agents[i].Identity != "" || !allZero(backings[i]) {
			t.Fatalf("caller copy %d not wiped", i)
		}
		if string(secs[i].raw) != want[i] {
			t.Fatalf("locked copy %d differs from the identity", i)
		}
	}
}

// startServeConns binds dir's socket with listenSock and serves secs until Lock.
func startServeConns(t *testing.T, dir string, secs []secret) <-chan struct{} {
	t.Helper()
	sock := filepath.Join(dir, "keyd.sock")
	pidPath := filepath.Join(dir, "keyd.pid")
	ln, err := listenSock(sock, pidPath)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	ws := randWS(t)
	done := make(chan struct{})
	go func() {
		serveConns(ctx, ln, sock, pidPath, ws, secs)
		close(done)
	}()
	return done
}

// heapIdentity is a fresh identity string in writable heap memory, so the
// wipe under test may zero it.
func heapIdentity(t *testing.T) string {
	t.Helper()
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	return string([]byte(id.String()))
}

func allZero(b []byte) bool {
	for _, c := range b {
		if c != 0 {
			return false
		}
	}
	return true
}
