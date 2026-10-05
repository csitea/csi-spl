package auth

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"

	"golang.org/x/crypto/argon2"
)

// Argon2 cost knobs (spec 015 FR-001), read from SPOOL_HUB_AUTH_NATIVE_ARGON2_*.
type Argon2Params struct {
	MemoryKiB  uint32
	Iterations uint32
}

const (
	argon2Parallelism uint8  = 1
	argon2KeyLen      uint32 = 32
	argon2SaltLen            = 16
)

// ErrPasswordMismatch is VerifyPassword's answer for a wrong password.
var ErrPasswordMismatch = errors.New("auth: password mismatch")

// HashPassword produces an argon2id PHC string (ported from csi-rel
// internal/auth/password.go):
// $argon2id$v=19$m=<KiB>,t=<iter>,p=1$<salt-b64>$<hash-b64>
func HashPassword(pw string, p Argon2Params) (string, error) {
	if pw == "" {
		return "", errors.New("auth: empty password")
	}
	if p.MemoryKiB < 8 || p.Iterations < 1 {
		return "", errors.New("auth: invalid argon2 parameters")
	}
	salt := make([]byte, argon2SaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("auth: salt: %w", err)
	}
	hash := argon2.IDKey([]byte(pw), salt, p.Iterations, p.MemoryKiB, argon2Parallelism, argon2KeyLen)
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, p.MemoryKiB, p.Iterations, argon2Parallelism,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(hash)), nil
}

// VerifyPassword compares candidate against a stored PHC hash in constant
// time, using the parameters the hash carries (raising the configured cost
// never locks an existing credential out). nil = match.
func VerifyPassword(stored, candidate string) error {
	parts := strings.Split(stored, "$")
	if len(parts) != 6 || parts[1] != "argon2id" {
		return errors.New("auth: invalid hash encoding")
	}
	var version int
	if _, err := fmt.Sscanf(parts[2], "v=%d", &version); err != nil {
		return fmt.Errorf("auth: hash version parse: %w", err)
	}
	if version != argon2.Version {
		return errors.New("auth: hash version mismatch")
	}
	var memoryKiB, iterations uint32
	var parallelism uint8
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &memoryKiB, &iterations, &parallelism); err != nil {
		return errors.New("auth: hash parameter parse")
	}
	if memoryKiB < 8 || iterations < 1 || parallelism < 1 || memoryKiB > 4<<20 || iterations > 64 {
		return errors.New("auth: hash parameters out of range")
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil {
		return fmt.Errorf("auth: salt decode: %w", err)
	}
	want, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil || len(want) == 0 {
		return errors.New("auth: hash decode")
	}
	got := argon2.IDKey([]byte(candidate), salt, iterations, memoryKiB, parallelism, uint32(len(want)))
	if subtle.ConstantTimeCompare(want, got) == 1 {
		return nil
	}
	return ErrPasswordMismatch
}
