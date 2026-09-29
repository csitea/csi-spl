package hub

import (
	"crypto/rand"
	"encoding/base64"
	"testing"
)

// oldRequestID is the pre-perf id generator (8 bytes of crypto/rand), kept
// here only so the benchmark shows the syscall this change removes.
func oldRequestID() string {
	b := make([]byte, 8)
	rand.Read(b) //nolint:errcheck
	return base64.RawURLEncoding.EncodeToString(b)
}

func TestNewRequestIDShapeAndUniqueness(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 100000; i++ {
		id := newRequestID()
		if len(id) != 11 {
			t.Fatalf("request id %q is %d chars, want 11", id, len(id))
		}
		if _, err := base64.RawURLEncoding.DecodeString(id); err != nil {
			t.Fatalf("request id %q is not base64: %v", id, err)
		}
		if seen[id] {
			t.Fatalf("request id %q repeated within one process", id)
		}
		seen[id] = true
	}
}

func BenchmarkRequestIDCryptoRand(b *testing.B) {
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = oldRequestID()
	}
}

func BenchmarkRequestIDCounter(b *testing.B) {
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = newRequestID()
	}
}
