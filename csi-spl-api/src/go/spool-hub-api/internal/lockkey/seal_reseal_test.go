package lockkey

import (
	"crypto/ed25519"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Row r52-09: Seal, Reseal, limited.Read and Sealer.Seal on their untested
// branches, in t.TempDir() only, with keys generated here.

// srBadID is neither a tenant id nor a box id.
const srBadID = "NOT AN ID"

// srLockKey is a new private key; the refusals below must not depend on it.
func srLockKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	return priv
}

// srPlantLockFile writes name under a new keys dir's lock dir and returns the
// keys dir.
func srPlantLockFile(t *testing.T, name string) string {
	t.Helper()
	keysDir := t.TempDir()
	if err := os.MkdirAll(LockDir(keysDir), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(LockDir(keysDir), name), []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return keysDir
}

// srWantErr fails unless err names want.
func srWantErr(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("err %v, want it to name %q", err, want)
	}
}

// srWantEmpty fails when a refusal left anything in keysDir.
func srWantEmpty(t *testing.T, keysDir string) {
	t.Helper()
	left, err := os.ReadDir(keysDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 0 {
		t.Fatalf("the refusal wrote %d entries, first %q", len(left), left[0].Name())
	}
}

func TestSealRefusesABadID(t *testing.T) {
	cases := []struct {
		name, tenant, box, want string
	}{
		{"bad tenant", srBadID, tBox, "is not a tenant id"},
		{"bad box", tTenant, srBadID, "is not a box id"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			keysDir := t.TempDir()
			_, err := Seal(keysDir, c.tenant, c.box, []byte(tSecret), fast)
			srWantErr(t, err, c.want)
			srWantEmpty(t, keysDir)
		})
	}
}

func TestSealRefusesAnExistingLockKey(t *testing.T) {
	keysDir := srPlantLockFile(t, lockFile)
	_, err := Seal(keysDir, tTenant, tBox, []byte(tSecret), fast)
	srWantErr(t, err, "a lock key already exists")
	if IsSealed(keysDir, tBox) {
		t.Fatal("the refused Seal left a sealed box key")
	}
}

// TestSealIgnoresALockJSONAlone is the other side of the refusal: it tests
// lock.key.enc, so a lock.json with no lock key does not stop a seal.
func TestSealIgnoresALockJSONAlone(t *testing.T) {
	keysDir := srPlantLockFile(t, metaFile)
	res, err := Seal(keysDir, tTenant, tBox, []byte(tSecret), fast)
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	if res.Meta.Box != tBox || !IsSealed(keysDir, tBox) {
		t.Fatalf("meta box %q, sealed %v", res.Meta.Box, IsSealed(keysDir, tBox))
	}
}

func TestResealRefusals(t *testing.T) {
	cases := []struct {
		name   string
		keys   Keys
		secret string
		want   string
	}{
		{"short secret", Keys{Lock: srLockKey(t)}, strings.Repeat("x", MinSecret-1), "needs at least"},
		{"no lock key", Keys{Lock: nil}, tSecret, "reseal needs the lock key"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			keysDir := t.TempDir()
			_, err := Reseal(keysDir, c.keys, []byte(c.secret), fast)
			srWantErr(t, err, c.want)
			srWantEmpty(t, keysDir)
		})
	}
}

// srPipe is a net.Pipe whose reading end has a deadline, so a defect fails the
// test instead of hanging it. Closing both ends on cleanup frees a blocked
// writer.
func srPipe(t *testing.T) (reader, writer net.Conn) {
	t.Helper()
	reader, writer = net.Pipe()
	t.Cleanup(func() {
		_ = reader.Close()
		_ = writer.Close()
	})
	if err := reader.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	return reader, writer
}

func TestLimitedReadAtZeroRefusesWithoutReading(t *testing.T) {
	reader, writer := srPipe(t)
	go func() { _, _ = writer.Write([]byte("x")) }()
	l := &limited{c: reader, n: 0}
	n, err := l.Read(make([]byte, 4))
	srWantErr(t, err, "request too large")
	if n != 0 {
		t.Fatalf("n %d, want 0", n)
	}
	// The pending byte is still on the pipe: the refusal did not read it.
	one := make([]byte, 1)
	if got, err := reader.Read(one); err != nil || got != 1 || one[0] != 'x' {
		t.Fatalf("the pending byte: n %d, err %v, byte %q", got, err, one[0])
	}
}

func TestLimitedReadCutsALongerBuffer(t *testing.T) {
	const limit = 4
	reader, writer := srPipe(t)
	go func() { _, _ = writer.Write([]byte("0123456789")) }()
	l := &limited{c: reader, n: limit}
	buf := make([]byte, limit+6)
	n, err := l.Read(buf)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if n != limit || string(buf[:n]) != "0123" {
		t.Fatalf("read %d bytes %q, want at most %d", n, buf[:n], limit)
	}
	_, err = l.Read(buf)
	srWantErr(t, err, "request too large")
}

func TestSealerSealRefusals(t *testing.T) {
	s, err := NewSealer([]byte(tSecret), fast)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Wipe()
	cases := []struct {
		name, tenant, box, kind, want string
	}{
		{"bad tenant", srBadID, tBox, KindBox, "is not a tenant id"},
		{"bad box", tTenant, srBadID, KindBox, "is not a box id"},
		{"unknown kind", tTenant, tBox, "no-such-kind", "unknown key kind"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f, err := s.Seal(c.tenant, c.box, c.kind, make([]byte, ed25519.SeedSize))
			srWantErr(t, err, c.want)
			if f != nil {
				t.Fatalf("a refused seal returned %d bytes", len(f))
			}
		})
	}
}
