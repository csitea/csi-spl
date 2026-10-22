package main

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/keyd"
	"github.com/csitea/csi-spl/spool-hub-api/internal/lockkey"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 025 box-owner-lock.md row B4: `spool lock` end to end on a temp keys
// dir, the terminal reads replaced by a queue of typed entries, the holder
// in-process. n = 1 per command; every refusal has its accepted twin.

const (
	ltSecret = "correct horse battery staple"
	ltOther  = "a different secret, long enough"
)

type lockEnv struct {
	cfg    *config.Config
	typed  []string
	cancel []context.CancelFunc
	done   []chan error
}

func newLockEnv(t *testing.T) *lockEnv {
	t.Helper()
	keys, err := os.MkdirTemp("", "lc") // short: the holder's socket path has a length limit
	if err != nil {
		t.Fatal(err)
	}
	e := &lockEnv{cfg: &config.Config{KeysDir: keys, SpoolRoot: t.TempDir(), BoxID: "box-lt", Tenant: "ws-lt"}}
	oNew, oOnce, oP, oStart := lockReadNew, lockReadOnce, lockParams, lockStartHolder
	next := func() ([]byte, error) {
		if len(e.typed) == 0 {
			t.Fatal("a terminal read with nothing typed")
		}
		s := e.typed[0]
		e.typed = e.typed[1:]
		return []byte(s), nil
	}
	lockReadNew, lockReadOnce = next, next
	lockParams = lockkey.Params{Time: 1, MemKiB: 64, Threads: 1}
	lockStartHolder = func(dir string) error {
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		h := &lockkey.Holder{KeysDir: dir, Backoff: time.Minute}
		go func() { done <- h.Serve(ctx) }()
		e.cancel, e.done = append(e.cancel, cancel), append(e.done, done)
		for i := 0; i < 300; i++ {
			if _, _, err := lockkey.HolderStatus(dir); err == nil {
				return nil
			}
			time.Sleep(10 * time.Millisecond)
		}
		return os.ErrDeadlineExceeded
	}
	t.Cleanup(func() {
		for i, c := range e.cancel {
			c()
			<-e.done[i]
		}
		lockReadNew, lockReadOnce, lockParams, lockStartHolder = oNew, oOnce, oP, oStart
		os.RemoveAll(keys)
	})
	return e
}

func (e *lockEnv) run(t *testing.T, typed []string, args ...string) (int, string, string) {
	t.Helper()
	e.typed = typed
	rc, out, errOut := capture(t, "", func() int { return cmdLock(e.cfg, args) })
	if len(e.typed) != 0 {
		t.Fatalf("lock %v left %d typed entries unread", args, len(e.typed))
	}
	return rc, out, errOut
}

var codeRe = regexp.MustCompile(`(?m)^\s+([A-Z2-7]{4}(?:-[A-Z2-7]{1,4}){12})$`)

func verifies(t *testing.T, pubB64, sigB64 string, payload []byte) bool {
	t.Helper()
	pub, err1 := base64.StdEncoding.DecodeString(pubB64)
	sig, err2 := base64.StdEncoding.DecodeString(sigB64)
	return err1 == nil && err2 == nil && ed25519.Verify(pub, payload, sig)
}

func TestLockCLI(t *testing.T) {
	e := newLockEnv(t)
	keys := e.cfg.KeysDir

	if rc, out, _ := e.run(t, nil, "status"); rc != 0 || strings.TrimSpace(out) != "not-sealed" {
		t.Fatalf("status before seal: %d %q", rc, out)
	}
	rc, out, _ := e.run(t, []string{ltSecret}, "seal")
	if rc != 0 {
		t.Fatalf("seal rc %d", rc)
	}
	m := codeRe.FindStringSubmatch(out)
	if m == nil {
		t.Fatalf("seal printed no recovery code:\n%s", out)
	}
	code := m[1]
	if rc, _, _ := e.run(t, nil, "seal"); rc == 0 {
		t.Fatal("a second seal was not refused")
	}
	if _, err := os.Stat(filepath.Join(keys, "box-box-lt.key")); !os.IsNotExist(err) {
		t.Fatal("a clear box key is on disk after seal")
	}
	if rc, out, _ := e.run(t, nil, "status"); rc != 0 || strings.TrimSpace(out) != "sealed" {
		t.Fatalf("status after seal: %d %q", rc, out)
	}

	// unlock: a wrong secret stays sealed; the right one opens.
	if rc, _, _ := e.run(t, []string{ltOther}, "unlock"); rc == 0 {
		t.Fatal("a wrong secret unlocked")
	}
	if rc, out, _ := e.run(t, nil, "status"); strings.TrimSpace(out) != "sealed" {
		t.Fatalf("status after a wrong secret: %d %q", rc, out)
	}
	if rc, out, _ := e.run(t, []string{ltSecret}, "unlock"); rc != 0 || strings.TrimSpace(out) != "unlocked" {
		t.Fatalf("unlock: %d %q", rc, out)
	}
	if rc, out, _ := e.run(t, nil, "status"); strings.TrimSpace(out) != "unlocked" {
		t.Fatalf("status after unlock: %d %q", rc, out)
	}
	meta, _ := lockkey.ReadMeta(keys)

	// create: the body is the 6.1 canonical form, signed by K_lock and K_box.
	if rc, _, _ := e.run(t, nil, "create", "--owners", "not-a-human"); rc == 0 {
		t.Fatal("create with a non-HUM owner was not refused")
	}
	rc, out, _ = e.run(t, []string{ltSecret}, "create", "--owners", "HUM-1")
	var sl signedLock
	if rc != 0 || json.Unmarshal([]byte(out), &sl) != nil {
		t.Fatalf("create: %d %s", rc, out)
	}
	want, _ := lockkey.Body{TenantID: "ws-lt", BoxID: "box-lt", LockPubkey: meta.LockPubkey, BoxPubkey: meta.BoxPubkey,
		Owners: []string{"HUM-1"}, HidePosts: true, Version: 1}.Canonical()
	if sl.SignedBody != string(want) {
		t.Fatalf("signed_body\n got %s\nwant %s", sl.SignedBody, want)
	}
	if !verifies(t, meta.LockPubkey, sl.Signature, want) || !verifies(t, meta.BoxPubkey, sl.BoxSignature, want) {
		t.Fatal("create's signatures do not verify against lock_pubkey and box_pubkey")
	}
	// The hub's own check (row B1) accepts what create signed; a widened
	// owners list with the same signature does not.
	row := store.BoxLock{TenantID: "ws-lt", BoxID: "box-lt", LockPubKey: meta.LockPubkey, BoxPubKey: meta.BoxPubkey,
		Owners: []string{"HUM-1"}, HidePosts: true, Version: 1, SignedBody: sl.SignedBody, Signature: sl.Signature}
	if err := store.VerifyBoxLock(row); err != nil {
		t.Fatalf("store.VerifyBoxLock refuses create's output: %v", err)
	}
	row.Owners = []string{"HUM-1", "HUM-2"}
	if err := store.VerifyBoxLock(row); err == nil {
		t.Fatal("CONTROL: a widened owners list verified")
	}

	// sign: a file's bytes; an unlock-proof payload is refused.
	bodyPath := filepath.Join(t.TempDir(), "lift.txt")
	os.WriteFile(bodyPath, []byte("spool-lock-lift-v1|ws-lt|box-lt|nonce\n"), 0o600)
	rc, out, _ = e.run(t, []string{ltSecret}, "sign", "--file", bodyPath)
	if rc != 0 || !verifies(t, meta.LockPubkey, strings.TrimSpace(out), []byte("spool-lock-lift-v1|ws-lt|box-lt|nonce")) {
		t.Fatalf("sign: %d %q", rc, out)
	}
	os.WriteFile(bodyPath, []byte("spool-unlock-v1|ws-lt|box-lt|n|b|p|t"), 0o600)
	if rc, _, _ := e.run(t, nil, "sign", "--file", bodyPath); rc == 0 {
		t.Fatal("sign accepted an unlock-proof payload")
	}

	// rotate-recovery: the old code stops opening, the new one opens.
	rc, out, _ = e.run(t, []string{ltSecret}, "rotate-recovery")
	m = codeRe.FindStringSubmatch(out)
	if rc != 0 || m == nil || m[1] == code {
		t.Fatalf("rotate-recovery: %d %q", rc, out)
	}
	if rc, _, _ := e.run(t, []string{code}, "reseal", "--recovery"); rc == 0 {
		t.Fatal("the rotated-out recovery code still reseals")
	}
	newCode := m[1]

	// reseal by recovery: a new secret; the old box key is replaced.
	newSecret := "the second lock secret, typed twice"
	rc, out, _ = e.run(t, []string{newCode, newSecret}, "reseal", "--recovery")
	if rc != 0 || !strings.Contains(out, "NEW box_pubkey") {
		t.Fatalf("reseal --recovery: %d %q", rc, out)
	}
	if rc, out, _ := e.run(t, nil, "status"); strings.TrimSpace(out) != "sealed" {
		t.Fatalf("a reseal must leave the running holder sealed: %d %q", rc, out)
	}
	m2, _ := lockkey.ReadMeta(keys)

	// rebind: a new box key, the version+1 body signed by the same K_lock.
	if rc, _, _ := e.run(t, nil, "rebind", "--version", "1", "--owners", "HUM-1"); rc == 0 {
		t.Fatal("rebind --version 1 was not refused")
	}
	rc, out, _ = e.run(t, []string{newSecret}, "rebind", "--version", "2", "--owners", "HUM-1")
	if rc != 0 || json.Unmarshal([]byte(out), &sl) != nil {
		t.Fatalf("rebind: %d %s", rc, out)
	}
	m3, _ := lockkey.ReadMeta(keys)
	if m3.BoxPubkey == m2.BoxPubkey || m3.LockPubkey != meta.LockPubkey {
		t.Fatal("rebind kept the box key, or changed the lock key")
	}
	var b lockkey.Body
	json.Unmarshal([]byte(sl.SignedBody), &b) //nolint:errcheck
	if b.Version != 2 || b.BoxPubkey != m3.BoxPubkey || !verifies(t, meta.LockPubkey, sl.Signature, []byte(sl.SignedBody)) {
		t.Fatalf("rebind body %+v does not carry the new key, or its signature fails", b)
	}
	if rc, out, _ := e.run(t, []string{newSecret}, "unlock"); rc != 0 || strings.TrimSpace(out) != "unlocked" {
		t.Fatalf("unlock after rebind: %d %q", rc, out)
	}
	bk, err := lockkey.HolderBoxKey(keys)
	if err != nil || lockkey.PubB64(bk.Public().(ed25519.PublicKey)) != m3.BoxPubkey {
		t.Fatalf("the holder's box key after rebind: %v", err)
	}
}

func TestLockRefusesPassphraseFlag(t *testing.T) {
	e := newLockEnv(t)
	if rc, _, _ := e.run(t, nil, "seal", "--passphrase=x"); rc != keyd.ExitPassphrase {
		t.Fatalf("a --passphrase flag: rc %d, want %d", rc, keyd.ExitPassphrase)
	}
	if rc, _, _ := e.run(t, nil, "unlock"); rc == 0 {
		t.Fatal("unlock on a box that is not sealed was not refused")
	}
}

// Every refusal before a secret is read, each with n = 1; the accepted twin
// of each is in TestLockCLI.
func TestLockRefusals(t *testing.T) {
	e := newLockEnv(t)
	for _, c := range []struct {
		name string
		args []string
		rc   int
	}{
		{"no sub-command", nil, 1},
		{"help", []string{"--help"}, 0},
		{"unknown sub-command", []string{"nosuch"}, 1},
		{"status with an argument", []string{"status", "x"}, 1},
		{"unlock with an argument", []string{"unlock", "x"}, 1},
		{"serve with an argument", []string{"serve", "x"}, 1},
		{"rotate-recovery with an argument", []string{"rotate-recovery", "x"}, 1},
		{"seal with a bad box id", []string{"seal", "--box", "Bad Box"}, 1},
		{"seal with an argument", []string{"seal", "x"}, 1},
		{"reseal with an argument", []string{"reseal", "x"}, 1},
		{"sign without --file", []string{"sign"}, 1},
		{"sign a missing file", []string{"sign", "--file", filepath.Join(t.TempDir(), "none")}, 1},
		{"create before seal", []string{"create", "--owners", "HUM-1"}, 1},
		{"create with an argument", []string{"create", "x"}, 1},
		{"rebind before seal", []string{"rebind", "--version", "2", "--owners", "HUM-1"}, 1},
		{"rebind with an argument", []string{"rebind", "x"}, 1},
	} {
		if rc, _, _ := e.run(t, nil, c.args...); rc != c.rc {
			t.Errorf("%s: rc %d, want %d", c.name, rc, c.rc)
		}
	}
	empty := filepath.Join(t.TempDir(), "empty")
	os.WriteFile(empty, []byte("\n"), 0o600)
	if rc, _, _ := e.run(t, nil, "sign", "--file", empty); rc == 0 {
		t.Error("sign accepted an empty body")
	}
	if rc, _, _ := e.run(t, []string{ltSecret}, "seal"); rc != 0 {
		t.Fatal("seal")
	}
	for _, c := range []struct {
		name string
		args []string
	}{
		{"no owners", []string{"create"}},
		{"a peer box that is this box", []string{"create", "--owners", "HUM-1", "--peer-boxes", "box-lt"}},
		{"a bad peer box", []string{"rebind", "--version", "2", "--owners", "HUM-1", "--peer-boxes", "Bad Box"}},
	} {
		if rc, _, _ := e.run(t, nil, c.args...); rc == 0 {
			t.Errorf("%s: accepted", c.name)
		}
	}
	// A wrong secret is refused by every command that opens the keys.
	for _, args := range [][]string{{"create", "--owners", "HUM-1"}, {"rotate-recovery"}, {"reseal"},
		{"rebind", "--version", "2", "--owners", "HUM-1"}} {
		if rc, _, _ := e.run(t, []string{ltOther}, args...); rc == 0 {
			t.Errorf("%v with a wrong secret: accepted", args)
		}
	}
	if rc, _, _ := e.run(t, []string{"not a recovery code at all"}, "reseal", "--recovery"); rc == 0 {
		t.Error("reseal with a malformed recovery code: accepted")
	}
}

// reseal with the old secret keeps the box key (no rebind needed); an
// unlock of an unlocked holder answers at once, with nothing typed. n = 1.
func TestLockResealWithSecret(t *testing.T) {
	e := newLockEnv(t)
	if rc, _, _ := e.run(t, []string{ltSecret}, "seal"); rc != 0 {
		t.Fatal("seal")
	}
	before, _ := lockkey.ReadMeta(e.cfg.KeysDir)
	rc, out, _ := e.run(t, []string{ltSecret, ltOther}, "reseal")
	if rc != 0 || strings.Contains(out, "NEW box_pubkey") {
		t.Fatalf("reseal: %d %q", rc, out)
	}
	if after, _ := lockkey.ReadMeta(e.cfg.KeysDir); after != before {
		t.Fatal("a reseal with the old secret changed a key")
	}
	if rc, _, _ := e.run(t, []string{ltOther}, "unlock"); rc != 0 {
		t.Fatal("unlock with the new secret")
	}
	if rc, out, _ := e.run(t, nil, "unlock"); rc != 0 || strings.TrimSpace(out) != "unlocked" {
		t.Fatalf("unlock of an unlocked holder: %d %q", rc, out)
	}
	if err := lockkey.HolderDropLock(e.cfg.KeysDir); err != nil {
		t.Fatal(err)
	}
	if _, out, _ := e.run(t, nil, "status"); strings.TrimSpace(out) != "unlocked (lock key dropped)" {
		t.Fatalf("status after drop-lock: %q", out)
	}
	// rebind with the recovery path sets a new secret too.
	rc, out, _ = e.run(t, []string{ltOther}, "rotate-recovery")
	code := codeRe.FindStringSubmatch(out)
	if rc != 0 || code == nil {
		t.Fatal("rotate-recovery")
	}
	third := "a third lock secret, long enough"
	if rc, _, _ := e.run(t, []string{code[1], third}, "rebind", "--recovery", "--version", "2", "--owners", "HUM-1"); rc != 0 {
		t.Fatal("rebind --recovery")
	}
	if _, err := lockkey.Unseal(e.cfg.KeysDir, []byte(third)); err != nil {
		t.Fatalf("the secret set by rebind --recovery: %v", err)
	}
}
