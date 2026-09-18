// Package sign handles Ed25519 keypairs, the shared pin store, and the
// sign/verify of a message's canonical payload.
//
// Private keys live strictly under the keys dir ($HOME/.spool/keys by default),
// mode 0600, and never enter $SPOOL_ROOT, a message, or a log. Public pins live
// shared under $SPOOL_ROOT/pins, mode 0644, so every agent can verify peers.
package sign

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// ErrUnpinned is returned when an id has no pin. Callers map it to exit 78.
var ErrUnpinned = errors.New("agent id is not pinned")

// ErrVerify is returned when a signature fails to verify. Maps to exit 78.
var ErrVerify = errors.New("signature verification failed")

func keyPath(keysDir, id string) string { return filepath.Join(keysDir, id+".key") }
func pinPath(pinsDir, id string) string { return filepath.Join(pinsDir, id+".pub") }

// GenerateKey creates a keypair for id, writing the private key 0600 under
// keysDir. It refuses to clobber an existing key unless force is set. It
// returns the base64 public key (for pinning).
func GenerateKey(keysDir, id string, force bool) (pubB64 string, err error) {
	if err := os.MkdirAll(keysDir, 0o700); err != nil {
		return "", err
	}
	kp := keyPath(keysDir, id)
	if _, err := os.Stat(kp); err == nil && !force {
		return "", fmt.Errorf("key for %s already exists (use --force to overwrite): %s", id, kp)
	}
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		return "", err
	}
	enc := base64.StdEncoding.EncodeToString(priv)
	if err := os.WriteFile(kp, []byte(enc+"\n"), 0o600); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(pub), nil
}

// LoadPrivate reads id's private key from keysDir.
func LoadPrivate(keysDir, id string) (ed25519.PrivateKey, error) {
	raw, err := os.ReadFile(keyPath(keysDir, id))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("no private key for %s: %w", id, ErrUnpinned)
		}
		return nil, err
	}
	dec, err := base64.StdEncoding.DecodeString(trim(raw))
	if err != nil {
		return nil, fmt.Errorf("decode private key for %s: %w", id, err)
	}
	if len(dec) != ed25519.PrivateKeySize {
		return nil, fmt.Errorf("private key for %s has wrong size", id)
	}
	return ed25519.PrivateKey(dec), nil
}

// Pin records id's public key in the shared pin store. It refuses to change an
// existing pin to a different key unless force is set (no silent key swap).
func Pin(pinsDir, id, pubB64 string, force bool) error {
	if err := os.MkdirAll(pinsDir, 0o755); err != nil {
		return err
	}
	if _, err := base64.StdEncoding.DecodeString(pubB64); err != nil {
		return fmt.Errorf("pubkey is not valid base64: %w", err)
	}
	pp := pinPath(pinsDir, id)
	if existing, err := os.ReadFile(pp); err == nil {
		if trim(existing) != pubB64 && !force {
			return fmt.Errorf("pin for %s already set to a different key (use --force to change): %s", id, pp)
		}
	}
	return os.WriteFile(pp, []byte(pubB64+"\n"), 0o644)
}

// LoadPin reads id's pinned public key. Returns ErrUnpinned if absent.
func LoadPin(pinsDir, id string) (ed25519.PublicKey, error) {
	raw, err := os.ReadFile(pinPath(pinsDir, id))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("%s: %w", id, ErrUnpinned)
		}
		return nil, err
	}
	dec, err := base64.StdEncoding.DecodeString(trim(raw))
	if err != nil {
		return nil, fmt.Errorf("decode pin for %s: %w", id, err)
	}
	if len(dec) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("pin for %s has wrong size", id)
	}
	return ed25519.PublicKey(dec), nil
}

// Sign returns the base64 Ed25519 signature of payload with priv.
func Sign(priv ed25519.PrivateKey, payload []byte) string {
	return base64.StdEncoding.EncodeToString(ed25519.Sign(priv, payload))
}

// Verify checks a base64 signature against payload and pub. Returns ErrVerify
// on mismatch.
func Verify(pub ed25519.PublicKey, payload []byte, sigB64 string) error {
	sig, err := base64.StdEncoding.DecodeString(sigB64)
	if err != nil {
		return fmt.Errorf("%w: bad base64", ErrVerify)
	}
	if !ed25519.Verify(pub, payload, sig) {
		return ErrVerify
	}
	return nil
}

func trim(b []byte) string {
	s := string(b)
	for len(s) > 0 && (s[len(s)-1] == '\n' || s[len(s)-1] == '\r' || s[len(s)-1] == ' ') {
		s = s[:len(s)-1]
	}
	return s
}
