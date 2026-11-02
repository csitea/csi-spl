package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/vendorkey"
)

// A raw pepper reaches the sealer whole, NUL and invalid UTF-8 included; that
// is why it is a file and not an env value (spec 159 section 11, SPL-4623).
func TestReadVendorKeyPepperKeepsRawBytes(t *testing.T) {
	want := bytes.Repeat([]byte{0x00, 0xff}, vendorkey.PepperBytes/2)
	f := filepath.Join(t.TempDir(), "pepper")
	if err := os.WriteFile(f, want, 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := readVendorKeyPepper(f)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("read %d bytes, not the %d written", len(got), len(want))
	}
}

func TestReadVendorKeyPepperRefusesAnyOtherLength(t *testing.T) {
	for _, n := range []int{0, vendorkey.MinPepper, vendorkey.PepperBytes - 1, vendorkey.PepperBytes + 1} {
		secret := bytes.Repeat([]byte("s"), n)
		f := filepath.Join(t.TempDir(), "pepper")
		if err := os.WriteFile(f, secret, 0o600); err != nil {
			t.Fatal(err)
		}
		_, err := readVendorKeyPepper(f)
		if err == nil {
			t.Fatalf("a %d-byte pepper was accepted", n)
		}
		if n > 0 && strings.Contains(err.Error(), string(secret)) {
			t.Fatalf("the error prints the pepper: %v", err)
		}
	}
	if _, err := readVendorKeyPepper(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("a missing pepper file was accepted")
	}
}

// Off, not a crash and not an unsealed write: nil is 503 vendor_keys_off.
func TestVendorKeySealerOffWithoutAGoodPepperFile(t *testing.T) {
	short := filepath.Join(t.TempDir(), "pepper")
	if err := os.WriteFile(short, bytes.Repeat([]byte("s"), vendorkey.MinPepper), 0o600); err != nil {
		t.Fatal(err)
	}
	for name, hc := range map[string]*config.Hub{
		"nothing": {},
		"no key":  {VendorKeysPepperFile: short},
		"no file": {VendorKeysKMSKey: "k"},
		"short":   {VendorKeysKMSKey: "k", VendorKeysPepperFile: short},
		"missing": {VendorKeysKMSKey: "k", VendorKeysPepperFile: short + ".gone"},
	} {
		if s := vendorKeySealer(t.Context(), hc, zerolog.Nop()); s != nil {
			t.Errorf("%s: got a sealer, want nil", name)
		}
	}
}
