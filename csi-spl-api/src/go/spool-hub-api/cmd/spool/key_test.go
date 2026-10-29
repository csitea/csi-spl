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
// The test binary records its own pid for every helper it starts.
func init() {
	if os.Getenv("SPOOL_KEY_HELPER") != "1" {
		os.Setenv("SPOOL_KEY_TEST_PARENT", strconv.Itoa(os.Getpid()))
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "keyd" {
		writeKeydAttest()
		dieWithTestParent()
	}
	os.Exit(run(os.Args[1:]))
}

// dieWithTestParent stops a keyd a test started once the test binary is
// gone, however it died: keyd runs in its own session and its parent (the
// helper) exits at once, so neither Pdeathsig nor t.Cleanup reaches it.
// SIGTERM takes keyd's own shutdown path; production keyd is unchanged.
func dieWithTestParent() {
	n, err := strconv.Atoi(os.Getenv("SPOOL_KEY_TEST_PARENT"))
	if err != nil || n <= 0 {
		return
	}
	fd, err := unix.PidfdOpen(n, 0)
	if err != nil {
		os.Exit(1)
	}
	go func() {
		fds := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
		for {
			if _, err := unix.Poll(fds, -1); err != unix.EINTR {
				break
			}
		}
		syscall.Kill(os.Getpid(), syscall.SIGTERM)
		time.Sleep(5 * time.Second)
		os.Exit(1)
	}()
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

// keyFileState makes a c-101 bundle sealed under a generated key file at
// <state>/keys/unlock.key, mode 0400. Test identities only.
func keyFileState(t *testing.T) (dir, ws, keyPath string, key []byte) {
	t.Helper()
	dir = shortState(t)
	ws = randWS(t)
	t.Setenv("SPOOL_ENC_STATE", dir)
	key, err := keyd.NewUnlockKey()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := keyd.InitAgent(dir, ws, "c-101", key); err != nil {
		t.Fatal(err)
	}
	keyPath = keyd.UnlockKeyPath(dir)
	writeKeyFile(t, keyPath, key)
	return dir, ws, keyPath, key
}

func writeKeyFile(t *testing.T, path string, key []byte) {
	t.Helper()
	os.Remove(path)
	if err := os.WriteFile(path, append(append([]byte{}, key...), '\n'), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0400); err != nil {
		t.Fatal(err)
	}
}

func stopKeyd(t *testing.T, dir string) {
	t.Cleanup(func() {
		keyd.Lock(dir)
		if b, err := os.ReadFile(filepath.Join(dir, "keyd.pid")); err == nil {
			if n, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && n > 0 {
				syscall.Kill(n, syscall.SIGTERM)
			}
		}
	})
}

// runNoTTY runs the CLI as a child in its own session with stdin on
// /dev/null and stdout on a pipe: no terminal anywhere, as under systemd.
func runNoTTY(t *testing.T, args ...string) (int, string, string) {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(exe, args...)
	cmd.Env = append(os.Environ(), "SPOOL_KEY_HELPER=1")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	err = cmd.Run()
	rc := 0
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		rc = ee.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	return rc, out.String(), errOut.String()
}

func keyStatus(t *testing.T) string {
	t.Helper()
	out := captureFD(t, &os.Stdout, func() {
		if rc := run([]string{"key", "status"}); rc != 0 {
			t.Fatalf("status rc %d", rc)
		}
	})
	return strings.TrimSpace(string(out))
}

// TestKeyUnlockKeyFileNoTTY is the Q7 B boot path: `key unlock --key-file`
// with no --workspace and no terminal starts keyd, status reads unlocked,
// keyd opens a message sealed to the agent, and its env holds no secret.
func TestKeyUnlockKeyFileNoTTY(t *testing.T) {
	dir, _, keyPath, key := keyFileState(t)
	stopKeyd(t, dir)
	sum := sha256.Sum256(key)
	t.Setenv("SPOOL_KEY_PASS_SHA", hex.EncodeToString(sum[:]))
	t.Setenv("SPOOL_KEY_ATTEST", filepath.Join(dir, "keyd.attest"))
	rc, out, errOut := runNoTTY(t, "key", "unlock", "--key-file", keyPath)
	if rc != 0 || out != "unlocked\n" {
		t.Fatalf("unlock rc %d out %q err %q", rc, out, errOut)
	}
	if strings.Contains(errOut, string(key)) {
		t.Fatal("stderr holds the key")
	}
	if st := keyStatus(t); st != "unlocked" {
		t.Fatalf("status %q", st)
	}
	pub, err := os.ReadFile(filepath.Join(dir, "keys", "c-101.pub"))
	if err != nil {
		t.Fatal(err)
	}
	plain, err := keyd.Open(dir, "c-101", sealPub(t, strings.TrimSpace(string(pub)), "body"))
	if err != nil || string(plain) != "body" {
		t.Fatal("keyd did not open a sealed message")
	}
	keyd.Wipe(plain)
	assertKeydEnv(t, dir, key)
	assertStateSealed(t, dir)
	if rc := run([]string{"key", "lock"}); rc != 0 {
		t.Fatalf("lock rc %d", rc)
	}
	if st := keyStatus(t); st != "locked" {
		t.Fatalf("after lock %q", st)
	}
}

// TestKeyUnlockKeyFileRefused: each StrictModes refusal exits 2 with one
// line, starts no keyd and leaves status locked; the passphrase flags and
// variables stay refused next to --key-file (FR5). The control is the last
// case: the same file at 0400 does unlock.
func TestKeyUnlockKeyFileRefused(t *testing.T) {
	dir, ws, keyPath, key := keyFileState(t)
	stopKeyd(t, dir)
	link := filepath.Join(dir, "link.key")
	if err := os.Symlink(keyPath, link); err != nil {
		t.Fatal(err)
	}
	wrong := filepath.Join(dir, "wrong.key")
	writeKeyFile(t, wrong, randPassCLI(t))
	cases := []struct {
		name string
		args []string
		mode os.FileMode
		env  string
		rc   int
	}{
		{"missing", []string{"--key-file", filepath.Join(dir, "none.key")}, 0400, "", keyd.ExitPassphrase},
		{"mode 0600", []string{"--key-file", keyPath}, 0600, "", keyd.ExitPassphrase},
		{"mode 0440", []string{"--key-file", keyPath}, 0440, "", keyd.ExitPassphrase},
		{"mode 0644", []string{"--key-file", keyPath}, 0644, "", keyd.ExitPassphrase},
		{"symlink", []string{"--key-file", link}, 0400, "", keyd.ExitPassphrase},
		{"wrong key", []string{"--key-file", wrong}, 0400, "", 1},
		{"passphrase flag", []string{"--key-file", keyPath, "--passphrase-file", wrong}, 0400, "", keyd.ExitPassphrase},
		{"passphrase env", []string{"--key-file", keyPath}, 0400, "SPOOL_KEY_PASSPHRASE", keyd.ExitPassphrase},
		{"other workspace", []string{"--key-file", keyPath, "--workspace", randWS(t)}, 0400, "", 1},
	}
	for _, c := range cases {
		if err := os.Chmod(keyPath, c.mode); err != nil {
			t.Fatal(err)
		}
		if c.env != "" {
			t.Setenv(c.env, "x")
		}
		var rc int
		errOut := captureFD(t, &os.Stderr, func() {
			rc = run(append([]string{"key", "unlock"}, c.args...))
		})
		if c.env != "" {
			os.Unsetenv(c.env)
		}
		if rc != c.rc {
			t.Fatalf("%s: rc %d, want %d (%s)", c.name, rc, c.rc, errOut)
		}
		if n := bytes.Count(errOut, []byte("\n")); n != 1 || bytes.Contains(errOut, key) || bytes.Contains(errOut, []byte(dir)) {
			t.Fatalf("%s: stderr is not one clean line: %q", c.name, errOut)
		}
		if _, err := os.Stat(filepath.Join(dir, "keyd.log")); !os.IsNotExist(err) {
			t.Fatalf("%s: keyd was started", c.name)
		}
		if st := keyStatus(t); st != "locked" {
			t.Fatalf("%s: status %q", c.name, st)
		}
	}
	if err := os.Chmod(keyPath, 0400); err != nil {
		t.Fatal(err)
	}
	rc, out, errOut := runNoTTY(t, "key", "unlock", "--key-file", keyPath, "--workspace", ws)
	if rc != 0 || out != "unlocked\n" {
		t.Fatalf("control: the 0400 file did not unlock: rc %d %q", rc, errOut)
	}
}

// TestKeyRotateUnlockKeyCLI: the rotated key file unlocks, the old secret
// does not, and a rotation that stopped between the renames is recovered by
// the next unlock.
func TestKeyRotateUnlockKeyCLI(t *testing.T) {
	dir, _, keyPath, old := keyFileState(t)
	stopKeyd(t, dir)
	out := captureFD(t, &os.Stdout, func() {
		if rc := run([]string{"key", "rotate-unlock-key"}); rc != 0 {
			t.Fatalf("rotate rc %d", rc)
		}
	})
	if string(out) != "rotated\n" {
		t.Fatalf("rotate out %q", out)
	}
	if _, err := keyd.LoadAgents(dir, old); err == nil {
		t.Fatal("the old key still opens the bundle")
	}
	next, err := keyd.ReadKeyFile(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	defer keyd.Wipe(next)
	if bytes.Equal(next, old) {
		t.Fatal("the key did not change")
	}
	// A crash after agents.age was renamed and before unlock.key was: the
	// bundle is under the .tmp key, unlock.key holds the old one.
	if err := keyd.RekeyToFile(dir, next, keyPath+".new"); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(keyPath+".new", keyPath+".tmp"); err != nil {
		t.Fatal(err)
	}
	rc, so, se := runNoTTY(t, "key", "unlock", "--key-file", keyPath)
	if rc != 0 || so != "unlocked\n" {
		t.Fatalf("unlock after an interrupted rotation: rc %d %q", rc, se)
	}
	if _, err := os.Lstat(keyPath + ".tmp"); !os.IsNotExist(err) {
		t.Fatal("unlock.key.tmp was not recovered")
	}
	if _, err := keyd.LoadAgents(dir, next); err == nil {
		t.Fatal("the pre-crash key still opens the bundle")
	}
}

// TestKeyRekeyCLI moves the bundle key file -> key file -> typed
// passphrase -> key file. After each step the new secret unlocks and the
// old one does not, and a replaced key file is removed.
func TestKeyRekeyCLI(t *testing.T) {
	dir, _, keyPath, key := keyFileState(t)
	stopKeyd(t, dir)
	second := filepath.Join(dir, "keys", "second.key")
	if rc := run([]string{"key", "rekey", "--key-file", keyPath, "--to-key-file", second}); rc != 0 {
		t.Fatalf("rekey to a key file rc %d", rc)
	}
	if _, err := os.Lstat(keyPath); !os.IsNotExist(err) {
		t.Fatal("the replaced key file was kept")
	}
	if _, err := keyd.LoadAgents(dir, key); err == nil {
		t.Fatal("the old key still opens the bundle")
	}
	k2, err := keyd.ReadKeyFile(second)
	if err != nil {
		t.Fatal(err)
	}
	defer keyd.Wipe(k2)
	typed := randPassCLI(t)
	defer keyd.Wipe(typed)
	runKeyPTY(t, dir, typed, true, "key", "rekey", "--key-file", second)
	if _, err := os.Lstat(second); !os.IsNotExist(err) {
		t.Fatal("the key file was kept after a rekey to a typed passphrase")
	}
	if _, err := keyd.LoadAgents(dir, k2); err == nil {
		t.Fatal("the key file still opens the bundle")
	}
	if _, err := keyd.LoadAgents(dir, typed); err != nil {
		t.Fatal("the typed passphrase does not open the bundle")
	}
	runKeyPTY(t, dir, typed, false, "key", "rekey", "--to-key-file", keyPath)
	if _, err := keyd.LoadAgents(dir, typed); err == nil {
		t.Fatal("the typed passphrase still opens the bundle")
	}
	rc, so, se := runNoTTY(t, "key", "unlock", "--key-file", keyPath)
	if rc != 0 || so != "unlocked\n" {
		t.Fatalf("unlock with the rekeyed key file: rc %d %q", rc, se)
	}
}

// TestKeydDiesWithTestBinary: a test binary that unlocks and is then
// SIGKILLed, so no t.Cleanup runs, leaves no keyd behind.
func TestKeydDiesWithTestBinary(t *testing.T) {
	if os.Getenv("SPOOL_KEYD_ORPHAN_KEY") != "" {
		t.Skip("the inner test binary runs TestKeydOrphanParent")
	}
	dir, _, keyPath, _ := keyFileState(t)
	stopKeyd(t, dir)
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(exe, "-test.run=^TestKeydOrphanParent$", "-test.v")
	cmd.Env = append(os.Environ(), "SPOOL_KEYD_ORPHAN_KEY="+keyPath)
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	ready := make(chan bool, 1)
	go func() {
		var buf bytes.Buffer
		tmp := make([]byte, 256)
		for {
			k, err := out.Read(tmp)
			buf.Write(tmp[:k])
			if bytes.Contains(buf.Bytes(), []byte("keyd-orphan-ready")) {
				ready <- true
				io.Copy(io.Discard, out)
				return
			}
			if err != nil {
				ready <- false
				return
			}
		}
	}()
	select {
	case ok := <-ready:
		if !ok {
			cmd.Wait()
			t.Fatal("the inner test binary did not unlock")
		}
	case <-time.After(60 * time.Second):
		cmd.Process.Kill()
		cmd.Wait()
		t.Fatal("the inner test binary timed out")
	}
	b, err := os.ReadFile(filepath.Join(dir, "keyd.pid"))
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || pid <= 0 || !procAlive(pid) {
		t.Fatalf("keyd is not running: pid %q", b)
	}
	cmd.Process.Signal(syscall.SIGKILL)
	cmd.Wait()
	deadline := time.Now().Add(10 * time.Second)
	for procAlive(pid) {
		if time.Now().After(deadline) {
			t.Fatalf("keyd pid %d outlived its SIGKILLed test binary", pid)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// TestKeydOrphanParent is the inner test binary of TestKeydDiesWithTestBinary:
// it unlocks, says so, and waits to be killed.
func TestKeydOrphanParent(t *testing.T) {
	keyPath := os.Getenv("SPOOL_KEYD_ORPHAN_KEY")
	if keyPath == "" {
		t.Skip("run by TestKeydDiesWithTestBinary only")
	}
	rc, out, errOut := runNoTTY(t, "key", "unlock", "--key-file", keyPath)
	if rc != 0 || out != "unlocked\n" {
		t.Fatalf("unlock rc %d out %q err %q", rc, out, errOut)
	}
	fmt.Println("keyd-orphan-ready")
	time.Sleep(10 * time.Minute)
}

// procAlive: the pid exists and is not a zombie.
func procAlive(pid int) bool {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return false
	}
	i := bytes.LastIndexByte(b, ')')
	return i > 0 && i+2 < len(b) && b[i+2] != 'Z'
}
