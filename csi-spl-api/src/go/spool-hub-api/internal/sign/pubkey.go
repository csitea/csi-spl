package sign

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"strings"
)

// Public-key encodings of a human key (specs/023 §3.2): the pin form (base64
// of the 32 raw bytes, as Pin stores it) and OpenSSH's `ssh-ed25519` line.
// Only public material is parsed here; private material is refused.

// ErrPrivateKey refuses input that carries private key material.
var ErrPrivateKey = errors.New("private key material is refused: upload the public key only")

// ErrBadPublicKey refuses input that is not one Ed25519 public key.
var ErrBadPublicKey = errors.New("not an Ed25519 public key (base64 of 32 bytes, or an ssh-ed25519 line)")

const sshEd25519 = "ssh-ed25519"

// ParsePublic accepts the pin form or an `ssh-ed25519 <b64> [comment]` line
// and returns the 32-byte key. A 64-byte base64 value (the spool private key
// form) or a PEM/OpenSSH PRIVATE KEY block is ErrPrivateKey.
func ParsePublic(in string) (ed25519.PublicKey, error) {
	s := strings.TrimSpace(in)
	if strings.Contains(strings.ToUpper(s), "PRIVATE KEY") {
		return nil, ErrPrivateKey
	}
	if len(s) > 4096 {
		return nil, ErrBadPublicKey
	}
	if f := strings.Fields(s); len(f) >= 2 && f[0] == sshEd25519 {
		blob, err := base64.StdEncoding.DecodeString(f[1])
		if err != nil {
			return nil, ErrBadPublicKey
		}
		return parseSSHBlob(blob)
	}
	raw, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return nil, ErrBadPublicKey
	}
	switch len(raw) {
	case ed25519.PublicKeySize:
		return ed25519.PublicKey(raw), nil
	case ed25519.PrivateKeySize, 48: // 64: the spool seed||pub form; 48: a PKCS#8 DER body
		return nil, ErrPrivateKey
	}
	return nil, ErrBadPublicKey
}

// parseSSHBlob reads string("ssh-ed25519") || string(32 bytes), nothing more.
func parseSSHBlob(b []byte) (ed25519.PublicKey, error) {
	next := func() ([]byte, bool) {
		if len(b) < 4 {
			return nil, false
		}
		n := binary.BigEndian.Uint32(b)
		if uint64(len(b)-4) < uint64(n) {
			return nil, false
		}
		v := b[4 : 4+n]
		b = b[4+n:]
		return v, true
	}
	name, ok := next()
	if !ok || string(name) != sshEd25519 {
		return nil, ErrBadPublicKey
	}
	key, ok := next()
	if !ok || len(key) != ed25519.PublicKeySize || len(b) != 0 {
		return nil, ErrBadPublicKey
	}
	return ed25519.PublicKey(key), nil
}

func sshBlob(pub ed25519.PublicKey) []byte {
	b := make([]byte, 0, 4+len(sshEd25519)+4+len(pub))
	b = binary.BigEndian.AppendUint32(b, uint32(len(sshEd25519)))
	b = append(b, sshEd25519...)
	b = binary.BigEndian.AppendUint32(b, uint32(len(pub)))
	return append(b, pub...)
}

// PinForm is the base64 of the raw 32 bytes (what Pin writes).
func PinForm(pub ed25519.PublicKey) string { return base64.StdEncoding.EncodeToString(pub) }

// OpenSSH is the authorized_keys line; comment "" = none.
func OpenSSH(pub ed25519.PublicKey, comment string) string {
	l := sshEd25519 + " " + base64.StdEncoding.EncodeToString(sshBlob(pub))
	if comment != "" {
		l += " " + comment
	}
	return l
}

// Fingerprint is OpenSSH's: "SHA256:" + unpadded base64 of sha256(blob), the
// string `ssh-keygen -lf` prints.
func Fingerprint(pub ed25519.PublicKey) string {
	sum := sha256.Sum256(sshBlob(pub))
	return "SHA256:" + base64.RawStdEncoding.EncodeToString(sum[:])
}
