//go:build linux

package keydesk

import (
	"bytes"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"filippo.io/age"
)

// sfBadRecipient refuses every wrap, so Seal never gets a file key to send.
type sfBadRecipient struct{}

func (sfBadRecipient) Wrap([]byte) ([]*age.Stanza, error) {
	return nil, errors.New("sf: wrap refused")
}

// sfIdentity is a throwaway desk key, generated for the one test.
func sfIdentity(t *testing.T) *age.X25519Identity {
	t.Helper()
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// sfSealRaw encrypts plain as it is, for a body Seal itself would not write.
func sfSealRaw(t *testing.T, to age.Recipient, plain string) []byte {
	t.Helper()
	var out bytes.Buffer
	w, err := age.Encrypt(&out, to)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write([]byte(plain)); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

// sfWantOpenRefused holds Open to its one refusal text and an empty payload.
func sfWantOpenRefused(t *testing.T, id age.Identity, sealed []byte, want string) {
	t.Helper()
	p, err := Open(id, sealed)
	if err == nil || err.Error() != want {
		t.Fatalf("Open error = %v, want %q", err, want)
	}
	if p != (Payload{}) {
		t.Fatal("Open refused but returned a payload")
	}
}

func TestPeerOfRefusesANonUnixConn(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close() //nolint:errcheck
	defer b.Close() //nolint:errcheck
	p, err := peerOf(a)
	if err == nil || err.Error() != "not a unix connection" {
		t.Fatalf("peerOf error = %v, want not a unix connection", err)
	}
	if p != (Peer{}) {
		t.Fatalf("peerOf refused but returned %+v", p)
	}
}

func TestSealRefusesARecipientThatCannotWrap(t *testing.T) {
	out, err := Seal(sfBadRecipient{}, Payload{Kind: "grok", Box: "b1"})
	if err == nil || !strings.Contains(err.Error(), "sf: wrap refused") {
		t.Fatalf("Seal error = %v, want the wrap refusal", err)
	}
	if out != nil {
		t.Fatalf("Seal refused but wrote %d bytes", len(out))
	}
}

func TestOpenRefusals(t *testing.T) {
	id := sfIdentity(t)
	sealed, err := Seal(id.Recipient(), Payload{Kind: "grok", Box: "b1"})
	if err != nil {
		t.Fatal(err)
	}
	flipped := bytes.Clone(sealed)
	flipped[len(flipped)-1] ^= 0xff
	const (
		sizeMsg  = "keydesk: sealed lease empty or too large"
		cutMsg   = "keydesk: the sealed lease is cut short"
		shapeMsg = "keydesk: the sealed lease is not a lease payload"
	)
	cases := []struct {
		name, want string
		sealed     []byte
	}{
		{"empty", sizeMsg, nil},
		{"over the cap", sizeMsg, make([]byte, maxSealed+1)},
		{"body does not decrypt", cutMsg, flipped},
		{"unknown field", shapeMsg, sfSealRaw(t, id.Recipient(), `{"kind":"grok","nope":1}`)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { sfWantOpenRefused(t, id, c.sealed, c.want) })
	}
}

func TestLoadOrCreateIdentityRefusesGarbage(t *testing.T) {
	const garbage = "not-an-age-identity"
	_, parseErr := age.ParseX25519Identity(garbage)
	if parseErr == nil {
		t.Fatal("the garbage parsed as an identity")
	}
	p := filepath.Join(t.TempDir(), IdentityName)
	if err := os.WriteFile(p, []byte(garbage+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	id, err := LoadOrCreateIdentity(p)
	if err == nil || err.Error() != parseErr.Error() {
		t.Fatalf("error = %v, want the parse error %v", err, parseErr)
	}
	if id != nil {
		t.Fatal("garbage gave an identity")
	}
}

func TestLoadOrCreateIdentityMissingDirMakesNoFile(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "missing")
	p := filepath.Join(dir, IdentityName)
	id, err := LoadOrCreateIdentity(p)
	if err == nil || !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("error = %v, want not exist", err)
	}
	if id != nil {
		t.Fatal("a missing directory gave an identity")
	}
	if _, serr := os.Stat(dir); !errors.Is(serr, os.ErrNotExist) {
		t.Fatalf("the directory was created: %v", serr)
	}
}
