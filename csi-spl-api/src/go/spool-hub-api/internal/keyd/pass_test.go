package keyd

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
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestMain(m *testing.M) {
	switch os.Getenv("KEYD_HELPER") {
	case "readnew":
		os.Exit(helperRead(true))
	case "readonce":
		os.Exit(helperRead(false))
	case "peer":
		os.Exit(helperPeer())
	case "serve":
		os.Exit(helperServe())
	}
	// Tests seal with a lower scrypt cost. The production default stays 18.
	scryptLogN = 14
	os.Exit(m.Run())
}

// TestPassphraseRefusedBeforeRead is FR5: env, argv, a pipe, a file and a
// sudo with no tty are refused, and neither OpenTTY nor ReadPassword runs.
func TestPassphraseRefusedBeforeRead(t *testing.T) {
	token := randToken(t)
	prevOpen, prevRead := openTTY, readPassword
	t.Cleanup(func() { openTTY, readPassword = prevOpen, prevRead })
	openTTY = func() (*os.File, error) {
		t.Fatal("OpenTTY called")
		return nil, errors.New("OpenTTY called")
	}
	readPassword = func(int) ([]byte, error) {
		t.Fatal("ReadPassword called")
		return nil, errors.New("ReadPassword called")
	}

	cases := []struct {
		name      string
		env       string
		argv      []string
		stdinTTY  bool
		stdoutTTY bool
	}{
		{name: "env SPOOL_KEY_PASSPHRASE", env: "SPOOL_KEY_PASSPHRASE", stdinTTY: true, stdoutTTY: true},
		{name: "env PASSPHRASE", env: "PASSPHRASE", stdinTTY: true, stdoutTTY: true},
		{name: "env AGE_PASSPHRASE", env: "AGE_PASSPHRASE", stdinTTY: true, stdoutTTY: true},
		{name: "argv --passphrase", argv: []string{"--passphrase", token}, stdinTTY: true, stdoutTTY: true},
		{name: "argv --passphrase=value", argv: []string{"--passphrase=" + token}, stdinTTY: true, stdoutTTY: true},
		{name: "argv --passphrase-file", argv: []string{"--passphrase-file", token}, stdinTTY: true, stdoutTTY: true},
		{name: "argv --password", argv: []string{"--password", token}, stdinTTY: true, stdoutTTY: true},
		{name: "argv --password-file", argv: []string{"--password-file=" + token}, stdinTTY: true, stdoutTTY: true},
		{name: "pipe", stdinTTY: false, stdoutTTY: true},
		{name: "file", stdinTTY: true, stdoutTTY: false},
		{name: "sudo without a tty", stdinTTY: false, stdoutTTY: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if tc.env != "" {
				t.Setenv(tc.env, token)
			}
			_, err := readNew(tc.argv, tc.stdinTTY, tc.stdoutTTY)
			if !errors.Is(err, ErrPassphrase) {
				t.Fatalf("got %v, want passphrase refused", err)
			}
			if token != "" && strings.Contains(err.Error(), token) {
				t.Fatal("refusal error contains the secret")
			}
		})
	}

	// A name that merely contains PASSPHRASE is not one of the three.
	t.Setenv("OTHER_PASSPHRASE", token)
	t.Setenv("SPOOL_KEY_PASSPHRASE_FILE", token)
	if err := Refuse(nil, true, true); err != nil {
		t.Fatalf("unrelated passphrase variable refused: %v", err)
	}
}

// TestPassphraseRules covers length and a second entry, with the tty read
// replaced so the secret stays inside the test.
func TestPassphraseRules(t *testing.T) {
	prevOpen, prevRead := openTTY, readPassword
	t.Cleanup(func() { openTTY, readPassword = prevOpen, prevRead })
	openTTY = func() (*os.File, error) {
		return os.OpenFile("/dev/null", os.O_RDWR, 0)
	}
	var answers [][]byte
	readPassword = func(int) ([]byte, error) {
		if len(answers) == 0 {
			return nil, errors.New("no answer")
		}
		a := answers[0]
		answers = answers[1:]
		out := make([]byte, len(a))
		copy(out, a)
		return out, nil
	}
	short := []byte("too-short")
	if len(short) >= minPassphrase {
		t.Fatal("fixture is not short")
	}
	answers = [][]byte{short, short}
	if _, err := readNew(nil, true, true); !errors.Is(err, ErrPassphrase) {
		t.Fatalf("short: %v", err)
	}
	long := bytes.Repeat([]byte("a"), minPassphrase)
	other := bytes.Repeat([]byte("b"), minPassphrase)
	answers = [][]byte{long, other}
	if _, err := readNew(nil, true, true); !errors.Is(err, ErrPassphrase) {
		t.Fatalf("mismatch: %v", err)
	}
	answers = [][]byte{long, append([]byte{}, long...)}
	got, err := readNew(nil, true, true)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, long) {
		t.Fatal("accepted passphrase does not match the entry")
	}
	Wipe(got)
}

// TestPassphraseReadFromTTY is the FR5 pty control: ReadPassword on /dev/tty,
// compared by hash so the passphrase is not printed.
func TestPassphraseReadFromTTY(t *testing.T) {
	pass := randPass(t)
	sum := sha256.Sum256(pass)
	got := ttyHash(t, "readnew", pass, true)
	if !bytes.Equal(got, sum[:]) {
		t.Fatal("tty read hash mismatch")
	}
	got = ttyHash(t, "readonce", pass, false)
	if !bytes.Equal(got, sum[:]) {
		t.Fatal("tty unlock read hash mismatch")
	}
	Wipe(pass)
}

func ttyHash(t *testing.T, helper string, pass []byte, twice bool) []byte {
	t.Helper()
	master, slave := openPTY(t)
	defer master.Close()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(exe)
	cmd.Env = append(os.Environ(), "KEYD_HELPER="+helper)
	cmd.Stdin = slave
	cmd.Stdout = slave
	errPipe, err := cmd.StderrPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	slave.Close()
	waitPrompt(t, master, "passphrase: ")
	if _, err := master.Write(append(append([]byte{}, pass...), '\n')); err != nil {
		t.Fatal(err)
	}
	if twice {
		waitPrompt(t, master, "again: ")
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
			t.Fatalf("helper exit: %v", err)
		}
	case <-time.After(15 * time.Second):
		cmd.Process.Kill()
		t.Fatal("tty helper timed out")
	}
	line := strings.TrimSpace(errOut.String())
	raw, err := hex.DecodeString(line)
	if err != nil || len(raw) != sha256.Size {
		t.Fatal("helper did not report a hash")
	}
	return raw
}

func waitPrompt(t *testing.T, master *os.File, prompt string) {
	t.Helper()
	var buf bytes.Buffer
	tmp := make([]byte, 64)
	deadline := time.Now().Add(5 * time.Second)
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

func openPTY(t *testing.T) (master, slave *os.File) {
	t.Helper()
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := unix.IoctlSetPointerInt(int(master.Fd()), unix.TIOCSPTLCK, 0); err != nil {
		master.Close()
		t.Fatal(err)
	}
	n, err := unix.IoctlGetInt(int(master.Fd()), unix.TIOCGPTN)
	if err != nil {
		master.Close()
		t.Fatal(err)
	}
	slave, err = os.OpenFile(fmt.Sprintf("/dev/pts/%d", n), os.O_RDWR, 0)
	if err != nil {
		master.Close()
		t.Fatal(err)
	}
	return master, slave
}

func helperRead(twice bool) int {
	var pass []byte
	var err error
	if twice {
		pass, err = ReadNew()
	} else {
		pass, err = ReadOnce()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "read failed")
		return ExitPassphrase
	}
	sum := sha256.Sum256(pass)
	Wipe(pass)
	fmt.Fprintf(os.Stderr, "%x\n", sum)
	return 0
}

func randToken(t *testing.T) string {
	t.Helper()
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(b[:])
}

func randPass(t *testing.T) []byte {
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
