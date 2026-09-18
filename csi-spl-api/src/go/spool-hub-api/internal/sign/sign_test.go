package sign

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestBoxKeyPinSignVerify(t *testing.T) {
	root := t.TempDir()
	keys, pins := filepath.Join(root, "keys"), filepath.Join(root, "pins")

	pub, err := GenerateKey(keys, "box-a", false)
	if err != nil {
		t.Fatalf("keygen: %v", err)
	}
	fi, err := os.Stat(filepath.Join(keys, "box-box-a.key"))
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("box key must be box-<id>.key mode 0600: %v %v", err, fi)
	}
	if _, err := GenerateKey(keys, "box-a", false); err == nil {
		t.Fatal("second keygen without force must refuse")
	}

	if _, err := LoadPin(pins, "box-a"); !errors.Is(err, ErrUnpinned) {
		t.Fatalf("want ErrUnpinned before pin, got %v", err)
	}
	if err := Pin(pins, "box-a", pub, false); err != nil {
		t.Fatalf("pin: %v", err)
	}
	if _, err := os.Stat(filepath.Join(pins, "box-box-a.pub")); err != nil {
		t.Fatalf("pin file must be box-<id>.pub: %v", err)
	}
	other, _ := GenerateKey(filepath.Join(root, "k2"), "box-a", false)
	if err := Pin(pins, "box-a", other, false); err == nil {
		t.Fatal("re-pin to a different key without force must refuse")
	}

	priv, err := LoadPrivate(keys, "box-a")
	if err != nil {
		t.Fatal(err)
	}
	pk, _ := LoadPin(pins, "box-a")
	sig := Sign(priv, []byte("payload"))
	if err := Verify(pk, []byte("payload"), sig); err != nil {
		t.Fatalf("verify: %v", err)
	}
	if err := Verify(pk, []byte("tampered"), sig); !errors.Is(err, ErrVerify) {
		t.Fatalf("want ErrVerify on tamper, got %v", err)
	}
}
