package lockkey

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// fast is a test-only argon2id cost; production always seals with DefaultParams.
var fast = Params{Time: 1, MemKiB: 64, Threads: 1}

const (
	tTenant = "ws-test"
	tBox    = "box-lock-test"
	tSecret = "correct horse battery staple"
)

func sealOne(t *testing.T, secret, tenant, box, kind string, plain []byte) []byte {
	t.Helper()
	s, err := NewSealer([]byte(secret), fast)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Wipe()
	f, err := s.Seal(tenant, box, kind, plain)
	if err != nil {
		t.Fatal(err)
	}
	return f
}

func TestSealOpenRoundTrip(t *testing.T) {
	plain := bytes.Repeat([]byte{7}, 32)
	f := sealOne(t, tSecret, tTenant, tBox, KindBox, plain)
	if bytes.Contains(f, plain) || bytes.Contains(f, []byte(tSecret)) {
		t.Fatal("the sealed file carries the seed or the secret in the clear")
	}
	got, err := Open([]byte(tSecret), tTenant, tBox, KindBox, f)
	if err != nil || !bytes.Equal(got, plain) {
		t.Fatalf("open: %v %x", err, got)
	}
}

// TestOpenRefusals is row B4's red control: a wrong secret, or a file sealed
// for another box, tenant or kind, is refused. With the associated-data
// binding dropped, the swapped files open (TestBindingIsWhatRefuses).
func TestOpenRefusals(t *testing.T) {
	plain := bytes.Repeat([]byte{9}, 32)
	f := sealOne(t, tSecret, tTenant, tBox, KindLock, plain)
	cases := []struct {
		name, secret, tenant, box, kind string
	}{
		{"wrong secret", "a different secret, long enough", tTenant, tBox, KindLock},
		{"another box id", tSecret, tTenant, "box-other", KindLock},
		{"another tenant", tSecret, "ws-other", tBox, KindLock},
		{"another kind (lock file as box)", tSecret, tTenant, tBox, KindBox},
		{"another kind (lock file as recovery)", tSecret, tTenant, tBox, KindLockRecovery},
	}
	refused := 0
	for _, c := range cases {
		_, err := Open([]byte(c.secret), c.tenant, c.box, c.kind, f)
		if !errors.Is(err, ErrOpen) {
			t.Errorf("%s: err %v, want ErrOpen", c.name, err)
			continue
		}
		if strings.Contains(err.Error(), c.secret) {
			t.Errorf("%s: the error carries the secret", c.name)
		}
		refused++
	}
	t.Logf("refused %d/%d", refused, len(cases))
}

// TestBindingIsWhatRefuses proves the refusal above comes from the
// associated data: with it replaced by a constant, a file sealed for one box
// opens as another (the red state the row names).
func TestBindingIsWhatRefuses(t *testing.T) {
	old := aad
	aad = func(string, string, string) []byte { return []byte("unbound") }
	defer func() { aad = old }()
	plain := bytes.Repeat([]byte{3}, 32)
	f := sealOne(t, tSecret, tTenant, tBox, KindBox, plain)
	if _, err := Open([]byte(tSecret), tTenant, "box-other", KindBox, f); err != nil {
		t.Fatalf("unbound: the swapped file should open, got %v", err)
	}
}

func TestTamperedFileRefused(t *testing.T) {
	f := sealOne(t, tSecret, tTenant, tBox, KindBox, bytes.Repeat([]byte{1}, 32))
	i := bytes.Index(f, []byte(`"ct":"`)) + 8
	f[i] ^= 0x01
	if f[i] == '"' || f[i] == '\\' {
		f[i] ^= 0x03
	}
	if _, err := Open([]byte(tSecret), tTenant, tBox, KindBox, f); err == nil {
		t.Fatal("a changed ciphertext byte opened")
	}
}

func TestOpenRefusesHugeKDF(t *testing.T) {
	f := sealOne(t, tSecret, tTenant, tBox, KindBox, make([]byte, 32))
	f = bytes.Replace(f, []byte(`"m_kib":64`), []byte(`"m_kib":99999999`), 1)
	if _, err := Open([]byte(tSecret), tTenant, tBox, KindBox, f); err == nil || errors.Is(err, ErrOpen) {
		t.Fatalf("a header asking for ~100 GB: %v", err)
	}
}

func TestEmptySecretRefused(t *testing.T) {
	if _, err := NewSealer(nil, fast); err == nil {
		t.Fatal("an empty secret sealed")
	}
}

func TestDefaultParamsAreTheSpec(t *testing.T) {
	if DefaultParams != (Params{Time: 3, MemKiB: 256 * 1024, Threads: 4}) {
		t.Fatalf("DefaultParams %+v, spec 4.2 says t=3 m=256 MiB p=4", DefaultParams)
	}
}

func TestRecoveryCode(t *testing.T) {
	code, raw, err := NewRecoveryCode()
	if err != nil || len(raw) != 32 {
		t.Fatal(err)
	}
	if g := strings.Split(code, "-"); len(g) != 13 || len(g[0]) != 4 {
		t.Fatalf("code shape %q", code)
	}
	back, err := ParseRecoveryCode(strings.ToLower(strings.ReplaceAll(code, "-", " ")))
	if err != nil || !bytes.Equal(back, raw) {
		t.Fatalf("parse: %v", err)
	}
	if _, err := ParseRecoveryCode("AAAA-BBBB"); err == nil {
		t.Fatal("a short code parsed")
	}
}

func TestProofPayloadAndBody(t *testing.T) {
	if got := string(ProofPayload("t", "b", "n", "boot", "PUB", "2026-10-23T00:00:00Z")); got != "spool-unlock-v1|t|b|n|boot|PUB|2026-10-23T00:00:00Z" {
		t.Fatalf("proof payload %q", got)
	}
	b, err := Body{TenantID: "t", BoxID: "b", LockPubkey: "L", BoxPubkey: "B", Owners: []string{"HUM-1"}, HidePosts: true, Version: 1}.Canonical()
	if err != nil {
		t.Fatal(err)
	}
	want := `{"tenant_id":"t","box_id":"b","lock_pubkey":"L","box_pubkey":"B","owners":["HUM-1"],"peer_boxes":[],"hide_posts":true,"version":1}`
	if string(b) != want {
		t.Fatalf("canonical\n got %s\nwant %s", b, want)
	}
}

// writeClearKey writes a box key the way the sign package does.
func writeClearKey(t *testing.T, dir, box string) ed25519.PrivateKey {
	t.Helper()
	_, priv, _ := ed25519.GenerateKey(nil)
	if err := os.WriteFile(filepath.Join(dir, "box-"+box+".key"), []byte(base64.StdEncoding.EncodeToString(priv)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return priv
}

func TestStoreSealUnseal(t *testing.T) {
	dir := t.TempDir()
	orig := writeClearKey(t, dir, tBox)
	if _, err := Seal(dir, tTenant, tBox, []byte("too short"), fast); err == nil {
		t.Fatal("a 9-character secret sealed")
	}
	res, err := Seal(dir, tTenant, tBox, []byte(tSecret), fast)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "box-"+tBox+".key")); !os.IsNotExist(err) {
		t.Fatal("the clear box key is still on disk")
	}
	if res.Meta.BoxPubkey != PubB64(orig.Public().(ed25519.PublicKey)) {
		t.Fatal("seal changed the box key; it must seal the existing one")
	}
	for _, p := range []string{SealedBoxPath(dir, tBox), filepath.Join(LockDir(dir), lockFile), filepath.Join(LockDir(dir), recoveryFile)} {
		st, err := os.Stat(p)
		if err != nil || st.Mode().Perm() != 0o600 {
			t.Fatalf("%s: %v %v", p, err, st)
		}
	}
	if _, err := Seal(dir, tTenant, tBox, []byte(tSecret), fast); err == nil {
		t.Fatal("a second seal over a sealed box was not refused")
	}
	k, err := Unseal(dir, []byte(tSecret))
	if err != nil || !bytes.Equal(k.Box, orig) {
		t.Fatalf("unseal: %v", err)
	}
	k.Wipe()
	if _, err := Unseal(dir, []byte("a different secret, long enough")); !errors.Is(err, ErrOpen) {
		t.Fatalf("wrong secret: %v", err)
	}
}

// TestStoreSwappedBoxFileRefused: box A's sealed key copied over box B's,
// both under the same secret, does not open as B.
func TestStoreSwappedBoxFileRefused(t *testing.T) {
	a, b := t.TempDir(), t.TempDir()
	if _, err := Seal(a, tTenant, "box-a", []byte(tSecret), fast); err != nil {
		t.Fatal(err)
	}
	if _, err := Seal(b, tTenant, "box-b", []byte(tSecret), fast); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(SealedBoxPath(a, "box-a"))
	if err := os.WriteFile(SealedBoxPath(b, "box-b"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Unseal(b, []byte(tSecret)); !errors.Is(err, ErrOpen) {
		t.Fatalf("box-a's file opened as box-b: %v", err)
	}
}

func TestStoreRecoveryResealRotate(t *testing.T) {
	dir := t.TempDir()
	res, err := Seal(dir, tTenant, tBox, []byte(tSecret), fast)
	if err != nil {
		t.Fatal(err)
	}
	rec, _ := ParseRecoveryCode(res.RecoveryCode)
	m, lock, err := OpenLockByRecovery(dir, rec)
	if err != nil || PubB64(lock.Public().(ed25519.PublicKey)) != m.LockPubkey {
		t.Fatalf("recovery open: %v", err)
	}
	// Recovery reseal: the old K_box is not recoverable, so a new one is made.
	newSecret := []byte("a brand new lock secret, typed twice")
	nm, err := Reseal(dir, Keys{Meta: m, Lock: lock}, newSecret, fast)
	if err != nil || nm.BoxPubkey == m.BoxPubkey || nm.LockPubkey != m.LockPubkey {
		t.Fatalf("reseal: %v", err)
	}
	if _, err := Unseal(dir, []byte(tSecret)); err == nil {
		t.Fatal("the old secret still opens after reseal")
	}
	k, err := Unseal(dir, newSecret)
	if err != nil {
		t.Fatalf("new secret: %v", err)
	}
	code2, err := RotateRecovery(dir, k, fast)
	if err != nil || code2 == res.RecoveryCode {
		t.Fatalf("rotate: %v", err)
	}
	if _, _, err := OpenLockByRecovery(dir, rec); err == nil {
		t.Fatal("the rotated-out recovery code still opens")
	}
	rec2, _ := ParseRecoveryCode(code2)
	if _, _, err := OpenLockByRecovery(dir, rec2); err != nil {
		t.Fatalf("the new recovery code: %v", err)
	}
}

func TestHolder(t *testing.T) {
	dir, err := os.MkdirTemp("", "lk")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	if _, err := Seal(dir, tTenant, tBox, []byte(tSecret), fast); err != nil {
		t.Fatal(err)
	}
	h := &Holder{KeysDir: dir, Backoff: time.Hour}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- h.Serve(ctx) }()
	defer func() { cancel(); <-done }()
	waitSock(t, dir)

	if st, _, err := HolderStatus(dir); err != nil || st != "sealed" {
		t.Fatalf("status at start: %q %v", st, err)
	}
	if _, err := HolderBoxKey(dir); !errors.Is(err, ErrSealed) {
		t.Fatalf("box key while sealed: %v", err)
	}
	if err := HolderUnlock(dir, []byte("a different secret, long enough")); err == nil {
		t.Fatal("a wrong secret unlocked")
	}
	if err := HolderUnlock(dir, []byte(tSecret)); err != nil {
		t.Fatal(err)
	}
	bk, err := HolderBoxKey(dir)
	if err != nil {
		t.Fatal(err)
	}
	m, _ := ReadMeta(dir)
	if PubB64(bk.Public().(ed25519.PublicKey)) != m.BoxPubkey {
		t.Fatal("the holder's box key is not the sealed one")
	}
	sig, pub, err := HolderProof(dir, "nonce-1", "boot-1", "2026-10-23T00:00:00Z")
	if err != nil || pub != m.BoxPubkey {
		t.Fatal(err)
	}
	lp, _ := base64.StdEncoding.DecodeString(m.LockPubkey)
	sb, _ := base64.StdEncoding.DecodeString(sig)
	if !ed25519.Verify(lp, ProofPayload(tTenant, tBox, "nonce-1", "boot-1", m.BoxPubkey, "2026-10-23T00:00:00Z"), sb) {
		t.Fatal("the unlock proof does not verify against lock_pubkey")
	}
	if err := HolderDropLock(dir); err != nil {
		t.Fatal(err)
	}
	if _, _, err := HolderProof(dir, "n", "b", "t"); err == nil {
		t.Fatal("a proof was signed after the lock key was dropped")
	}
	if _, err := HolderBoxKey(dir); err != nil {
		t.Fatalf("the box key must stay after drop-lock: %v", err)
	}
	// Row B9: after drop-lock, unlock with the secret holds K_lock again (a
	// ticket expired); a wrong secret does not.
	if err := HolderUnlock(dir, []byte("a different secret, long enough")); err == nil {
		t.Fatal("a wrong secret re-opened the dropped lock key")
	}
	if _, held, _ := HolderStatus(dir); held {
		t.Fatal("the lock key is held after a wrong secret")
	}
	if err := HolderUnlock(dir, []byte(tSecret)); err != nil {
		t.Fatal(err)
	}
	if _, held, _ := HolderStatus(dir); !held {
		t.Fatal("unlock after drop-lock did not hold the lock key again")
	}
	if _, _, err := HolderProof(dir, "n", "b", "t"); err != nil {
		t.Fatalf("no proof after the re-unlock: %v", err)
	}
	if err := HolderSeal(dir); err != nil {
		t.Fatal(err)
	}
	if _, err := HolderBoxKey(dir); !errors.Is(err, ErrSealed) {
		t.Fatalf("box key after seal: %v", err)
	}
}

func TestHolderBackoff(t *testing.T) {
	calls := 0
	h := &Holder{KeysDir: "unused", Backoff: time.Hour,
		Unseal: func(string, []byte) (Keys, error) { calls++; return Keys{}, ErrOpen }}
	for i := 0; i < MaxFailures; i++ {
		h.handle(request{Op: "unlock", Secret: []byte("x")})
	}
	r := h.handle(request{Op: "unlock", Secret: []byte("x")})
	if r.OK || calls != MaxFailures || !strings.Contains(r.Error, "wait") {
		t.Fatalf("after %d failures: calls %d, resp %+v", MaxFailures, calls, r)
	}
}

func TestHolderSecretWiped(t *testing.T) {
	sec := []byte("secret-to-wipe")
	h := &Holder{Unseal: func(string, []byte) (Keys, error) { return Keys{}, ErrOpen }}
	h.handle(request{Op: "unlock", Secret: sec})
	if !bytes.Equal(sec, make([]byte, len(sec))) {
		t.Fatal("the holder did not wipe the secret buffer")
	}
}

func waitSock(t *testing.T, dir string) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if _, err := os.Stat(filepath.Join(LockDir(dir), sockName)); err == nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("lockd socket did not appear")
}

// deadPID starts this test binary with no test to run and waits for it, so
// its pid names a process that has exited.
func deadPID(t *testing.T) int {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	c := exec.Command(exe, "-test.run=^$")
	if err := c.Run(); err != nil {
		t.Fatal(err)
	}
	return c.Process.Pid
}

func strPtr(s string) *string { return &s }

// Row r43-06: HolderAlive, readPID and pidAlive on each pid file a keys dir
// can hold.
func TestHolderAlivePIDFile(t *testing.T) {
	dead, own := deadPID(t), os.Getpid()
	cases := []struct {
		name  string
		file  *string
		pid   int
		alive bool
	}{
		{"no pid file", nil, 0, false},
		{"garbage", strPtr("not-a-pid\n"), 0, false},
		{"zero", strPtr("0\n"), 0, false},
		{"negative", strPtr("-7\n"), 0, false},
		{"dead pid", strPtr(strconv.Itoa(dead) + "\n"), dead, false},
		{"own pid", strPtr(" " + strconv.Itoa(own) + "\n"), own, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(LockDir(dir), pidName)
			if c.file != nil {
				if err := writeFile(path, []byte(*c.file)); err != nil {
					t.Fatal(err)
				}
			}
			if got := readPID(path); got != c.pid {
				t.Fatalf("readPID: got %d, want %d", got, c.pid)
			}
			if got := HolderAlive(dir); got != c.alive {
				t.Fatalf("HolderAlive: got %v, want %v", got, c.alive)
			}
		})
	}
	if pidAlive(0) || pidAlive(-1) {
		t.Fatal("pidAlive took a pid <= 0 for alive")
	}
}

// Row r43-06: writeFile leaves a 0600 file and no temp file on success, and
// fails where it cannot write.
func TestWriteFileErrors(t *testing.T) {
	dir := t.TempDir()
	ok := filepath.Join(dir, "sub", "f")
	if err := writeFile(ok, []byte("x")); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(ok); err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("written file: %v %v", st, err)
	}
	if _, err := os.Stat(ok + ".tmp"); !os.IsNotExist(err) {
		t.Fatalf("temp file left after a write: %v", err)
	}

	plain := filepath.Join(dir, "plain")
	if err := os.WriteFile(plain, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writeFile(filepath.Join(plain, "f"), []byte("x")); err == nil {
		t.Fatal("writeFile under a regular file did not fail")
	}

	if os.Geteuid() == 0 {
		t.Skip("root writes into a read-only dir")
	}
	ro := filepath.Join(dir, "ro")
	if err := os.Mkdir(ro, 0o500); err != nil {
		t.Fatal(err)
	}
	if err := writeFile(filepath.Join(ro, "f"), []byte("x")); err == nil {
		t.Fatal("writeFile into a read-only dir did not fail")
	}
	if _, err := os.Stat(filepath.Join(ro, "f.tmp")); !os.IsNotExist(err) {
		t.Fatalf("temp file left in a read-only dir: %v", err)
	}
}
