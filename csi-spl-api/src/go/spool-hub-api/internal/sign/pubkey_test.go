package sign

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
)

// specs/023 §3.2: both public forms parse to the same key; private material
// and anything else are refused.
func TestParsePublicForms(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(nil)
	for _, in := range []string{PinForm(pub), PinForm(pub) + "\n", OpenSSH(pub, "spool:HUM-1"), OpenSSH(pub, "")} {
		got, err := ParsePublic(in)
		if err != nil || !got.Equal(pub) {
			t.Fatalf("%q: %v", in, err)
		}
	}
	// CONTROLS: private forms, malformed and wrong-algorithm input.
	priv64 := base64.StdEncoding.EncodeToString(priv)
	for in, want := range map[string]error{
		priv64: ErrPrivateKey,
		"-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----": ErrPrivateKey,
		base64.StdEncoding.EncodeToString(make([]byte, 48)):                           ErrPrivateKey,
		"":                ErrBadPublicKey,
		"not base64 !!":   ErrBadPublicKey,
		PinForm(pub)[:40]: ErrBadPublicKey,
		base64.StdEncoding.EncodeToString(make([]byte, 31)):                         ErrBadPublicKey,
		"ssh-rsa " + strings.Fields(OpenSSH(pub, ""))[1]:                            ErrBadPublicKey,
		"ssh-ed25519 " + PinForm(pub):                                               ErrBadPublicKey,
		"ssh-ed25519 " + base64.StdEncoding.EncodeToString(append(sshBlob(pub), 0)): ErrBadPublicKey,
	} {
		if _, err := ParsePublic(in); !errors.Is(err, want) {
			t.Fatalf("%q: got %v, want %v", in, err, want)
		}
	}
}

// The fingerprint is OpenSSH's, pinned to a known vector: the all-zero key
// (ssh-keygen -lf on "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA").
func TestFingerprintOpenSSHVector(t *testing.T) {
	zero := ed25519.PublicKey(make([]byte, 32))
	if got := OpenSSH(zero, ""); got != "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" {
		t.Fatalf("openssh line %q", got)
	}
	if fp := Fingerprint(zero); fp != "SHA256:kmYcvdi2GkPeWxB6XLjrZB8JHsy2Hm8luHMFp9GMvqk" {
		t.Fatalf("fingerprint %q", fp)
	}
	// A real ssh-keygen key: `ssh-keygen -lf` printed SHA256:b50O9136QC+qHvRlKdf6A0cK7az1IOsUpvB5Vk1WcQ0.
	pub, err := ParsePublic("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAuxpwgDCEfyJLzw0RDRZToUpFjnh8ce/+CaVQ7bxars x")
	if err != nil {
		t.Fatal(err)
	}
	if fp := Fingerprint(pub); fp != "SHA256:b50O9136QC+qHvRlKdf6A0cK7az1IOsUpvB5Vk1WcQ0" {
		t.Fatalf("fingerprint %q", fp)
	}
}
