package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"filippo.io/age"
	"golang.org/x/sys/unix"

	"github.com/csitea/csi-spl/spool-hub-api/internal/keyd"
)

// The test binary is re-exec'd for the pty. init runs before the testing
// flag parser, so dashed key flags are not rejected as unknown test flags.
func init() {
	if os.Getenv("SPOOL_KEY_HELPER") != "1" {
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "keyd" {
		writeKeydAttest()
	}
	os.Exit(run(os.Args[1:]))
}

// writeKeydAttest runs in the keyd child before harden. A dumpable process
// hides /proc/<pid>/environ from its parent, so the child records the check.
func writeKeydAttest() {
	path := os.Getenv("SPOOL_KEY_ATTEST")
	if path == "" {
		return
	}
	want := os.Getenv("SPOOL_KEY_PASS_SHA")
	status := "clean"
	for _, e := range os.Environ() {
		k, v, _ := strings.Cut(e, "=")
		switch k {
		case "SPOOL_KEY_PASSPHRASE", "PASSPHRASE", "AGE_PASSPHRASE":
			status = "dirty"
		}
		if envHasPass(v, want) || strings.Contains(v, "AGE-SECRET-KEY-") {
			status = "dirty"
		}
	}
	if cmd, err := os.ReadFile("/proc/self/cmdline"); err == nil {
		for _, a := range bytes.Split(cmd, []byte{0}) {
			if envHasPass(string(a), want) {
				status = "dirty"
			}
		}
	}
	_ = os.WriteFile(path, []byte(status+"\n"), 0600)
}

func envHasPass(v, want string) bool {
	if want == "" || v == "" {
		return false
	}
	sum := sha256.Sum256([]byte(v))
	return hex.EncodeToString(sum[:]) == want
}

func TestKeyRefusesPassphraseFlag(t *testing.T) {
	dir := shortState(t)
	t.Setenv("SPOOL_ENC_STATE", dir)
	token := randHex(t)
	ws := randWS(t)
	errOut := captureFD(t, &os.Stderr, func() {
		rc := run([]string{"key", "init", "--as", "c-101", "--workspace", ws, "--passphrase=" + token})
		if rc != keyd.ExitPassphrase {
			t.Fatalf("rc %d, want %d", rc, keyd.ExitPassphrase)
		}
	})
	if bytes.Contains(errOut, []byte(token)) {
		t.Fatal("stderr contains the secret")
	}
	t.Setenv("SPOOL_KEY_PASSPHRASE", token)
	errOut = captureFD(t, &os.Stderr, func() {
		rc := run([]string{"key", "init", "--as", "c-101", "--workspace", ws})
		if rc != keyd.ExitPassphrase {
			t.Fatalf("env rc %d", rc)
		}
	})
	if bytes.Contains(errOut, []byte(token)) {
		t.Fatal("stderr contains the secret")
	}
}

func TestKeyUsageAndAbsentStatus(t *testing.T) {
	dir := shortState(t)
	t.Setenv("SPOOL_ENC_STATE", dir)
	if rc := run([]string{"key"}); rc != 1 {
		t.Fatalf("key with no subcommand: rc %d", rc)
	}
	if rc := run([]string{"key", "init", "--workspace", randWS(t)}); rc != 1 {
		t.Fatalf("init without --as: rc %d", rc)
	}
	if rc := run([]string{"key", "init", "--as", "c-000", "--workspace", randWS(t)}); rc != 1 {
		t.Fatalf("init c-000: rc %d", rc)
	}
	out := captureFD(t, &os.Stdout, func() {
		rc := run([]string{"key", "status"})
		if rc != 0 {
			t.Fatalf("status rc %d", rc)
		}
	})
	if string(out) != "locked\n" {
		t.Fatalf("status %q", out)
	}
	if rc := run([]string{"key", "lock"}); rc != 0 {
		t.Fatalf("lock rc %d", rc)
	}
	if rc := run([]string{"keyd", "nope"}); rc != 1 {
		t.Fatalf("keyd args rc %d", rc)
	}
}

func TestKeyInitUnlockStatusLock(t *testing.T) {
	dir := shortState(t)
	ws := randWS(t)
	pass := randPassCLI(t)
	defer keyd.Wipe(pass)
	t.Setenv("SPOOL_ENC_STATE", dir)
	sum := sha256.Sum256(pass)
	t.Setenv("SPOOL_KEY_PASS_SHA", hex.EncodeToString(sum[:]))
	t.Setenv("SPOOL_KEY_ATTEST", filepath.Join(dir, "keyd.attest"))
	t.Cleanup(func() {
		keyd.Lock(dir)
		if b, err := os.ReadFile(filepath.Join(dir, "keyd.pid")); err == nil {
			if n, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && n > 0 {
				syscall.Kill(n, syscall.SIGTERM)
			}
		}
	})
	runKeyPTY(t, dir, pass, true, "key", "init", "--workspace", ws, "--as", "c-101")
	assertStateSealed(t, dir)
	out := captureFD(t, &os.Stdout, func() {
		if rc := run([]string{"key", "status"}); rc != 0 {
			t.Fatalf("status rc %d", rc)
		}
	})
	if string(out) != "locked\n" {
		t.Fatalf("after init status %q", out)
	}
	runKeyPTY(t, dir, pass, false, "key", "unlock", "--workspace", ws)
	out = captureFD(t, &os.Stdout, func() {
		if rc := run([]string{"key", "status"}); rc != 0 {
			t.Fatalf("status rc %d", rc)
		}
	})
	if string(out) != "unlocked\n" {
		t.Fatalf("after unlock status %q", out)
	}
	assertStateSealed(t, dir)
	assertKeydEnv(t, dir, pass)
	out = captureFD(t, &os.Stdout, func() {
		if rc := run([]string{"key", "unlock", "--workspace", ws}); rc != 0 {
			t.Fatalf("second unlock rc %d", rc)
		}
	})
	if string(out) != "unlocked\n" {
		t.Fatalf("already unlocked %q", out)
	}
	if rc := run([]string{"key", "lock"}); rc != 0 {
		t.Fatalf("lock rc %d", rc)
	}
	out = captureFD(t, &os.Stdout, func() {
		if rc := run([]string{"key", "status"}); rc != 0 {
			t.Fatalf("status rc %d", rc)
		}
	})
	if string(out) != "locked\n" {
		t.Fatalf("after lock status %q", out)
	}
	if _, err := os.Stat(filepath.Join(dir, "keyd.sock")); !os.IsNotExist(err) {
		t.Fatal("socket still present")
	}
}

func TestCmdKeydServes(t *testing.T) {
	dir := shortState(t)
	t.Setenv("SPOOL_ENC_STATE", dir)
	ws := randWS(t)
	if err := os.MkdirAll(filepath.Join(dir, "keys"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "keys", "workspace"), []byte(ws+"\n"), 0644); err != nil {
		t.Fatal(err)
	}
	secret, pub := newIdentity(t)
	raw, err := keyd.Bundle(ws, []keyd.AgentKey{{
		ID: "c-101", Identity: secret, Created: "2026-01-01T00:00:00Z",
	}})
	if err != nil {
		t.Fatal(err)
	}
	defer keyd.Wipe(raw)
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdin
	os.Stdin = r
	defer func() { os.Stdin = old }()
	rcCh := make(chan int, 1)
	go func() { rcCh <- cmdKeyd(nil) }()
	if _, err := w.Write(raw); err != nil {
		t.Fatal(err)
	}
	w.Close()
	waitCLI(t, dir, "unlocked")
	assertStateSealed(t, dir)
	ct := sealPub(t, pub, "body")
	plain, err := keyd.Open(dir, "c-101", ct)
	if err != nil || string(plain) != "body" {
		t.Fatal("open failed")
	}
	keyd.Wipe(plain)
	if rc := run([]string{"key", "lock"}); rc != 0 {
		t.Fatalf("lock rc %d", rc)
	}
	select {
	case rc := <-rcCh:
		if rc != 0 {
			t.Fatalf("keyd rc %d", rc)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("keyd did not exit")
	}
	out := captureFD(t, &os.Stdout, func() {
		if rc := run([]string{"key", "status"}); rc != 0 {
			t.Fatalf("status rc %d", rc)
		}
	})
	if string(out) != "locked\n" {
		t.Fatalf("status %q", out)
	}
}

func newIdentity(t *testing.T) (secret, pub string) {
	t.Helper()
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	return id.String(), id.Recipient().String()
}

func sealPub(t *testing.T, pub, body string) []byte {
	t.Helper()
	rec, err := age.ParseX25519Recipient(pub)
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	w, err := age.Encrypt(&buf, rec)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(w, body); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func runKeyPTY(t *testing.T, dir string, pass []byte, twice bool, args ...string) {
	t.Helper()
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer master.Close()
	if err := unix.IoctlSetPointerInt(int(master.Fd()), unix.TIOCSPTLCK, 0); err != nil {
		t.Fatal(err)
	}
	n, err := unix.IoctlGetInt(int(master.Fd()), unix.TIOCGPTN)
	if err != nil {
		t.Fatal(err)
	}
	slave, err := os.OpenFile(fmt.Sprintf("/dev/pts/%d", n), os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(exe, args...)
	env := append(os.Environ(), "SPOOL_KEY_HELPER=1")
	cmd.Env = env
	cmd.Stdin = slave
	cmd.Stdout = slave
	errPipe, err := cmd.StderrPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
	if err := cmd.Start(); err != nil {
		slave.Close()
		t.Fatal(err)
	}
	slave.Close()
	waitPTY(t, master, "passphrase: ")
	if _, err := master.Write(append(append([]byte{}, pass...), '\n')); err != nil {
		t.Fatal(err)
	}
	if twice {
		waitPTY(t, master, "again: ")
		if _, err := master.Write(append(append([]byte{}, pass...), '\n')); err != nil {
			t.Fatal(err)
		}
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	var errOut bytes.Buffer
	readDone := make(chan struct{})
	go func() {
		io.Copy(&errOut, errPipe)
		close(readDone)
	}()
	select {
	case err := <-done:
		<-readDone
		if err != nil {
			if bytes.Contains(errOut.Bytes(), pass) {
				t.Fatal("pty command failed and stderr contains the passphrase")
			}
			t.Fatalf("pty command failed: %s", errOut.Bytes())
		}
	case <-time.After(60 * time.Second):
		cmd.Process.Kill()
		t.Fatal("pty command timed out")
	}
	if bytes.Contains(errOut.Bytes(), pass) {
		t.Fatal("stderr contains the passphrase")
	}
}

func waitPTY(t *testing.T, master *os.File, prompt string) {
	t.Helper()
	var buf bytes.Buffer
	tmp := make([]byte, 64)
	deadline := time.Now().Add(10 * time.Second)
	for !bytes.Contains(buf.Bytes(), []byte(prompt)) {
		if time.Now().After(deadline) {
			t.Fatalf("prompt %q not seen", prompt)
		}
		master.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
		n, err := master.Read(tmp)
		if n > 0 {
			buf.Write(tmp[:n])
		}
		if err != nil && !errors.Is(err, os.ErrDeadlineExceeded) && n == 0 {
			continue
		}
	}
}

func assertKeydEnv(t *testing.T, dir string, pass []byte) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, "keyd.attest"))
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != "clean\n" || bytes.Contains(b, pass) {
		t.Fatal("passphrase is in the keyd process")
	}
}

func assertStateSealed(t *testing.T, dir string) {
	t.Helper()
	err := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info == nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if bytes.Contains(b, []byte("AGE-SECRET-KEY-")) {
			t.Fatalf("clear identity in %s", filepath.Base(path))
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func waitCLI(t *testing.T, dir, want string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		st, err := keyd.Status(dir)
		if err == nil && st == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("status did not become %s", want)
}

func captureFD(t *testing.T, target **os.File, fn func()) []byte {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := *target
	*target = w
	fn()
	w.Close()
	*target = old
	b, err := io.ReadAll(r)
	r.Close()
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func shortState(t *testing.T) string {
	t.Helper()
	d, err := os.MkdirTemp("/tmp", "kd")
	if err != nil {
		t.Fatal(err)
	}
	if len(filepath.Join(d, "keyd.sock")) >= 100 {
		os.RemoveAll(d)
		t.Fatal("socket path too long")
	}
	t.Cleanup(func() { os.RemoveAll(d) })
	return d
}

func randWS(t *testing.T) string {
	t.Helper()
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		t.Fatal(err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func randHex(t *testing.T) string {
	t.Helper()
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(b[:])
}

func randPassCLI(t *testing.T) []byte {
	t.Helper()
	const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	var rb [24]byte
	if _, err := rand.Read(rb[:]); err != nil {
		t.Fatal(err)
	}
	out := make([]byte, len(rb))
	for i, c := range rb {
		out[i] = letters[int(c)%len(letters)]
	}
	return out
}
