package hub_test

import (
	"context"
	"testing"

	"github.com/coder/websocket/wsjson"
)

// a socket looping {"type":"token"} minted a new upload token per
// frame, and each mint walked the whole token map under the hub-wide mutex.
// Within the first half of its TTL a socket now gets its current token back:
// 50 frames, one token. (The clients refresh with 30 s / 15 s left, so they
// still get a fresh one when they need it.)
func TestTokenFrameReusesTheSocketsToken(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	c := dialMember(t, e, tid, "HUM-1", "HUM-1")
	ctx := context.Background()
	seen := map[string]bool{}
	for i := 0; i < 50; i++ {
		wsjson.Write(ctx, c, map[string]string{"type": "token"}) //nolint:errcheck
		f := readType(t, c, "token")
		tok, _ := f["upload_token"].(string)
		if tok == "" {
			t.Fatalf("frame %d: no upload_token: %v", i, f)
		}
		seen[tok] = true
	}
	if len(seen) != 1 {
		t.Fatalf("50 token frames minted %d tokens, want 1", len(seen))
	}
}
