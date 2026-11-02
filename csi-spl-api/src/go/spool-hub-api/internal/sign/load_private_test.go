package sign

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// lpWriteKeyFile puts body in box id's key file under a fresh temp keys dir.
func lpWriteKeyFile(t *testing.T, id, body string) string {
	t.Helper()
	keys := t.TempDir()
	if err := os.WriteFile(filepath.Join(keys, "box-"+id+".key"), []byte(body), 0o600); err != nil {
		t.Fatalf("write key file: %v", err)
	}
	return keys
}

func TestLoadPrivateNoFileIsUnpinned(t *testing.T) {
	key, err := LoadPrivate(t.TempDir(), "box-a")
	if !errors.Is(err, ErrUnpinned) {
		t.Fatalf("no file: want ErrUnpinned, got %v", err)
	}
	if key != nil {
		t.Fatalf("no file: want a nil key, got %d bytes", len(key))
	}
}

func TestLoadPrivateNotBase64NamesTheBox(t *testing.T) {
	key, err := LoadPrivate(lpWriteKeyFile(t, "box-a", "not base64 !!\n"), "box-a")
	var corrupt base64.CorruptInputError
	if !errors.As(err, &corrupt) {
		t.Fatalf("not base64: want a base64 decode error, got %v", err)
	}
	if !strings.Contains(err.Error(), "decode private key for box-a") {
		t.Fatalf("not base64: the error must name the box, got %v", err)
	}
	if errors.Is(err, ErrUnpinned) {
		t.Fatalf("not base64: a file that exists is not unpinned, got %v", err)
	}
	if key != nil {
		t.Fatalf("not base64: want a nil key, got %d bytes", len(key))
	}
}

func TestLoadPrivateWrongSizeIsRefused(t *testing.T) {
	short := base64.StdEncoding.EncodeToString(make([]byte, 10))
	key, err := LoadPrivate(lpWriteKeyFile(t, "box-a", short+"\n"), "box-a")
	if err == nil {
		t.Fatalf("10 bytes: want the wrong-size error, got a key of %d bytes", len(key))
	}
	if !strings.Contains(err.Error(), "private key for box-a has wrong size") {
		t.Fatalf("10 bytes: want the wrong-size error naming the box, got %v", err)
	}
	if key != nil {
		t.Fatalf("10 bytes: want a nil key, got %d bytes", len(key))
	}
}

func TestLoadPrivateOwnKeySignsForItsPublicKey(t *testing.T) {
	keys := t.TempDir()
	pubB64, err := GenerateKey(keys, "box-a", false)
	if err != nil {
		t.Fatalf("keygen: %v", err)
	}
	raw, err := base64.StdEncoding.DecodeString(pubB64)
	if err != nil {
		t.Fatalf("decode the public key: %v", err)
	}
	pub := ed25519.PublicKey(raw)

	priv, err := LoadPrivate(keys, "box-a")
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(priv) != ed25519.PrivateKeySize {
		t.Fatalf("load: want %d bytes, got %d", ed25519.PrivateKeySize, len(priv))
	}

	payload := []byte("canonical payload")
	sig := Sign(priv, payload)
	if err := Verify(pub, payload, sig); err != nil {
		t.Fatalf("the matching public key must verify: %v", err)
	}
	if err := Verify(pub, []byte("another payload"), sig); !errors.Is(err, ErrVerify) {
		t.Fatalf("another payload: want ErrVerify, got %v", err)
	}
}
