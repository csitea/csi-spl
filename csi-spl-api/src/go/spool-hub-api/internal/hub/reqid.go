package hub

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"sync/atomic"
)

// A request id is a log-correlation handle, not a secret: it is echoed in
// X-Request-ID and logged, never used to authorize anything. The middleware
// minted one for every request that arrived without an X-Request-ID by reading
// 8 bytes from crypto/rand — a getrandom(2) syscall on the hot path of a
// single-vCPU (GOMAXPROCS=1) instance, where every request shares the one
// core. A per-process random nonce XORed with a monotonic counter is unique
// for the life of the process (XOR by a constant is injective, so no two
// counter values collide) and unguessable across processes, at the cost of one
// atomic add and no syscall. The shape is unchanged: 8 bytes, 11 base64 chars.
var (
	reqIDNonce   = randUint64()
	reqIDCounter atomic.Uint64
)

func randUint64() uint64 {
	var b [8]byte
	rand.Read(b[:]) //nolint:errcheck // fails only on a broken kernel CSPRNG
	return binary.BigEndian.Uint64(b[:])
}

// newRequestID returns an opaque, per-process-unique request id without a
// per-request syscall.
func newRequestID() string {
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], reqIDNonce^reqIDCounter.Add(1))
	return base64.RawURLEncoding.EncodeToString(b[:])
}
