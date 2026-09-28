// Package uid mints the identifiers the hub, the box CLI and the relay share:
// RFC 4122 version-4 UUIDs (random, or derived from a seed) and random hex.
// It is the one place their shape is decided (SPL-1030).
package uid

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
)

// New returns a random version-4 UUID, e.g. 1f0c2c7e-5b1a-4d3e-9f6a-0b1c2d3e4f5a.
func New() string {
	var b [16]byte
	rand.Read(b[:]) // never returns an error since Go 1.24; it aborts the process instead
	return format(b)
}

// FromSeed returns the version-4-shaped UUID derived from sha256(seed): the
// same seed always yields the same id (the legacy .md bridge keys on it).
func FromSeed(seed string) string {
	sum := sha256.Sum256([]byte(seed))
	var b [16]byte
	copy(b[:], sum[:16])
	return format(b)
}

// Hex returns n random bytes as 2n lowercase hex characters.
func Hex(n int) string {
	b := make([]byte, n)
	rand.Read(b) // never returns an error since Go 1.24
	return hex.EncodeToString(b)
}

// format stamps the version (4) and variant (10) bits and renders 8-4-4-4-12.
func format(b [16]byte) string {
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	h := hex.EncodeToString(b[:])
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}
