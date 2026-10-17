package auth

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"math"
	"strconv"
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
	// maxHashLen bounds the stored hash a verify recomputes (32 today).
	maxHashLen = 1024
)

// ErrPasswordMismatch is VerifyPassword's answer for a wrong password.
var ErrPasswordMismatch = errors.New("auth: password mismatch")

var errHashParamRange = errors.New("auth: hash parameters out of range")

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
	version, err := phcUint(parts[2], "v", 32)
	if err != nil {
		return fmt.Errorf("auth: hash version parse: %w", err)
	}
	if version != argon2.Version {
		return errors.New("auth: hash version mismatch")
	}
	memoryKiB, iterations, parallelism, err := phcParams(parts[3])
	if err != nil {
		return err
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil {
		return fmt.Errorf("auth: salt decode: %w", err)
	}
	want, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil {
		return errors.New("auth: hash decode")
	}
	keyLen := len(want)
	if keyLen < 1 || keyLen > maxHashLen {
		return errors.New("auth: hash decode")
	}
	got := argon2.IDKey([]byte(candidate), salt, iterations, memoryKiB, parallelism, uint32(keyLen))
	if subtle.ConstantTimeCompare(want, got) == 1 {
		return nil
	}
	return ErrPasswordMismatch
}

// phcParams reads "m=<KiB>,t=<iter>,p=<lanes>" with every value range-checked
// before it is narrowed (bounded parsing, no fmt.Sscanf: SPL-2153).
func phcParams(s string) (memoryKiB, iterations uint32, parallelism uint8, err error) {
	fields := strings.Split(s, ",")
	if len(fields) != 3 {
		return 0, 0, 0, errors.New("auth: hash parameter parse")
	}
	m, err := phcUint(fields[0], "m", 32)
	if err != nil {
		return 0, 0, 0, errors.New("auth: hash parameter parse")
	}
	if m < 8 || m > 4<<20 {
		return 0, 0, 0, errHashParamRange
	}
	memoryKiB = uint32(m)
	t, err := phcUint(fields[1], "t", 32)
	if err != nil {
		return 0, 0, 0, errors.New("auth: hash parameter parse")
	}
	if t < 1 || t > 64 {
		return 0, 0, 0, errHashParamRange
	}
	iterations = uint32(t)
	par, err := phcUint(fields[2], "p", 8)
	if err != nil {
		return 0, 0, 0, errors.New("auth: hash parameter parse")
	}
	if par < 1 || par > math.MaxUint8 {
		return 0, 0, 0, errHashParamRange
	}
	parallelism = uint8(par)
	return memoryKiB, iterations, parallelism, nil
}

// phcUint reads one "<key>=<decimal>" field of a PHC string as an unsigned
// number of at most bits bits; anything else (a sign, a space, a trailing
// byte) fails.
func phcUint(field, key string, bits int) (uint64, error) {
	v, ok := strings.CutPrefix(field, key+"=")
	if !ok || v == "" || v[0] == '+' {
		return 0, fmt.Errorf("want %s=<n>", key)
	}
	return strconv.ParseUint(v, 10, bits)
}
