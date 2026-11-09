package keyd

import (
	"bytes"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"

	"filippo.io/age"
)

// osWantErr fails unless err carries exactly the message want.
func osWantErr(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil || err.Error() != want {
		t.Fatalf("err = %v, want %q", err, want)
	}
}

// osStubAnswer listens on dir's keyd.sock and answers one status request with
// the line answer.
func osStubAnswer(t *testing.T, dir, answer string) {
	t.Helper()
	ln, err := net.Listen("unix", filepath.Join(dir, "keyd.sock"))
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, err := ln.Accept()
		if err != nil {
			t.Errorf("accept: %v", err)
			return
		}
		defer conn.Close()
		req, err := readReq(conn)
		if err != nil || req.Op != "status" {
			t.Errorf("request = %+v, err %v, want op status", req, err)
			return
		}
		if _, err := conn.Write([]byte(answer + "\n")); err != nil {
			t.Errorf("answer: %v", err)
		}
	}()
	t.Cleanup(func() {
		ln.Close()
		<-done
	})
}

// Rule: InitOwner refuses a state dir it cannot create.
func TestInitOwnerStateDirUnderFile(t *testing.T) {
	file := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(file, []byte("x"), 0600); err != nil {
		t.Fatal(err)
	}
	pub, err := InitOwner(filepath.Join(file, "state"), randWS(t), []byte("owner-pass"))
	osWantErr(t, err, "could not create the key state")
	if pub != "" {
		t.Fatalf("pub = %q on a refusal", pub)
	}
}

// Rule: the first InitOwner seals the identity of the key it returns, and a
// later call, with another workspace or the same one, leaves that file alone.
func TestInitOwnerFirstThenRefusals(t *testing.T) {
	dir := t.TempDir()
	ws := randWS(t)
	pass := []byte("owner-pass")
	pub, err := InitOwner(dir, ws, pass)
	if err != nil {
		t.Fatal(err)
	}
	ownerPath := filepath.Join(dir, "keys", "owner.age")
	sealed, err := os.ReadFile(ownerPath)
	if err != nil {
		t.Fatal(err)
	}
	plain, err := openScrypt(ownerPath, pass)
	if err != nil {
		t.Fatal(err)
	}
	var owner ownerFile
	if err := json.Unmarshal(plain, &owner); err != nil {
		t.Fatal(err)
	}
	ident, err := age.ParseX25519Identity(owner.Identity)
	if err != nil {
		t.Fatal(err)
	}
	if got := ident.Recipient().String(); got != pub {
		t.Fatalf("sealed identity is for %q, InitOwner returned %q", got, pub)
	}

	_, err = InitOwner(dir, randWS(t), pass)
	osWantErr(t, err, "workspace mismatch")
	_, err = InitOwner(dir, ws, pass)
	osWantErr(t, err, "owner key already exists")

	after, err := os.ReadFile(ownerPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(after, sealed) {
		t.Fatal("a refused InitOwner changed owner.age")
	}
}

// Rule: openScrypt names a missing file apart from every other failure, checks
// the passphrase before the file, and opens only under the right passphrase.
func TestOpenScrypt(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sealed.age")
	pass := []byte("right-pass")
	want := []byte("the plain bytes")
	if err := writeScrypt(path, want, pass, 0600); err != nil {
		t.Fatal(err)
	}
	missing := filepath.Join(dir, "missing.age")

	_, err := openScrypt(missing, nil)
	osWantErr(t, err, "could not open the agent keys")
	_, err = openScrypt(missing, pass)
	osWantErr(t, err, "agent keys are not initialised")
	_, err = openScrypt(path, []byte("wrong-pass"))
	osWantErr(t, err, "could not open the agent keys")

	got, err := openScrypt(path, pass)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("plain = %q, want %q", got, want)
	}
}

// Rule: a file that fails part way through its payload is refused, and none
// of the chunks that did authenticate reach the caller.
func TestOpenScryptTamperedLateChunk(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sealed.age")
	pass := []byte("right-pass")
	if err := writeScrypt(path, bytes.Repeat([]byte("k"), 200000), pass, 0600); err != nil {
		t.Fatal(err)
	}
	sealed, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	sealed[len(sealed)-1] ^= 0xff
	if err := os.WriteFile(path, sealed, 0600); err != nil {
		t.Fatal(err)
	}
	got, err := openScrypt(path, pass)
	osWantErr(t, err, "could not open the agent keys")
	if got != nil {
		t.Fatalf("%d bytes of plaintext from a tampered file", len(got))
	}
}

// Rule: openScrypt opens a payload of exactly 1 MiB and refuses a larger one
// instead of returning the first 1 MiB of it.
func TestOpenScryptSizeLimit(t *testing.T) {
	pass := []byte("right-pass")
	path := filepath.Join(t.TempDir(), "sealed.age")
	if err := writeScrypt(path, bytes.Repeat([]byte("k"), 1<<20), pass, 0600); err != nil {
		t.Fatal(err)
	}
	got, err := openScrypt(path, pass)
	if err != nil || len(got) != 1<<20 {
		t.Fatalf("at the limit: %d bytes, %v", len(got), err)
	}
	if err := writeScrypt(path, bytes.Repeat([]byte("k"), 1<<20+1), pass, 0600); err != nil {
		t.Fatal(err)
	}
	got, err = openScrypt(path, pass)
	osWantErr(t, err, "could not open the agent keys")
	if got != nil {
		t.Fatalf("%d bytes returned over the limit", len(got))
	}
}

// Rule: when owner.pub cannot be written InitOwner returns the error and no
// key, leaves no owner.age behind, and a retry gives the caller the key.
func TestInitOwnerRecipientNotWritable(t *testing.T) {
	dir := t.TempDir()
	ws := randWS(t)
	pass := []byte("owner-pass")
	mkKeys(t, dir)
	pubPath := filepath.Join(dir, "keys", "owner.pub")
	if err := os.Mkdir(pubPath, 0700); err != nil {
		t.Fatal(err)
	}
	pub, err := InitOwner(dir, ws, pass)
	osWantErr(t, err, "could not store the recipient")
	if pub != "" {
		t.Fatalf("pub = %q on a refusal", pub)
	}
	if present(filepath.Join(dir, "keys", "owner.age")) {
		t.Fatal("a failed InitOwner left owner.age behind")
	}
	if err := os.Remove(pubPath); err != nil {
		t.Fatal(err)
	}
	pub, err = InitOwner(dir, ws, pass)
	if err != nil {
		t.Fatalf("retry: %v", err)
	}
	stored, err := os.ReadFile(pubPath)
	if err != nil || string(stored) != pub+"\n" {
		t.Fatalf("owner.pub reads %q, %v; want the returned key", stored, err)
	}
}

// Rule: a socket file nothing listens on reads as locked and is removed.
func TestStatusStaleSocketIsLockedAndRemoved(t *testing.T) {
	dir := shortDir(t)
	sock := filepath.Join(dir, "keyd.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	ln.(*net.UnixListener).SetUnlinkOnClose(false)
	if err := ln.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(sock); err != nil {
		t.Fatalf("closed listener left no socket file: %v", err)
	}
	state, err := Status(dir)
	if err != nil || state != "locked" {
		t.Fatalf("Status = %q, %v, want locked", state, err)
	}
	if _, err := os.Stat(sock); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale socket still there: stat err %v", err)
	}
}

// Rule: each bad answer from a daemon is an error, with no state, and the
// socket of that live listener stays.
func TestStatusBadAnswers(t *testing.T) {
	cases := []struct{ name, answer, want string }{
		{"refused without a reason", `{"ok":false}`, "bad status"},
		{"refused with a reason", `{"ok":false,"error":"x"}`, "x"},
		{"unknown state", `{"ok":true,"state":"weird"}`, "bad status"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := shortDir(t)
			osStubAnswer(t, dir, c.answer)
			state, err := Status(dir)
			osWantErr(t, err, c.want)
			if state != "" {
				t.Fatalf("state = %q on an error", state)
			}
			if _, err := os.Stat(filepath.Join(dir, "keyd.sock")); err != nil {
				t.Fatalf("socket gone after a bad answer: %v", err)
			}
		})
	}
}
