package blob

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"testing"
	"time"
)

// countingStore counts the Gets that reach the store behind the cache.
type countingStore struct {
	Store
	gets int
}

func (c *countingStore) Get(ctx context.Context, key string) (io.ReadCloser, error) {
	c.gets++
	return c.Store.Get(ctx, key)
}

func sha(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

func readAll(t *testing.T, s Store, key string) []byte {
	t.Helper()
	rc, err := s.Get(context.Background(), key)
	if err != nil {
		t.Fatalf("get %s: %v", key, err)
	}
	defer rc.Close()
	b, err := io.ReadAll(rc)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// The cached Store keeps the Store contract.
func TestCachedIsAStore(t *testing.T) {
	testStore(t, NewCached(Dir{Root: t.TempDir()}, 1<<20, 64<<10, time.Minute))
	testUploaded(t, NewCached(Dir{Root: t.TempDir()}, 1<<20, 64<<10, time.Minute))
}

func TestCachedReadsOnce(t *testing.T) {
	ctx := context.Background()
	inner := &countingStore{Store: Dir{Root: t.TempDir()}}
	now := time.Date(2026, 9, 27, 21, 0, 0, 0, time.UTC)
	c := NewCached(inner, 10_000, 4_000, 10*time.Minute)
	c.now = func() time.Time { return now }

	small := bytes.Repeat([]byte("a"), 3_000)
	key, _ := Key("t1", sha(small))
	if err := c.Put(ctx, key, small); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		if got := readAll(t, c, key); !bytes.Equal(got, small) {
			t.Fatalf("read %d: %d bytes, want the %d stored", i, len(got), len(small))
		}
	}
	if inner.gets != 1 {
		t.Errorf("3 reads of one attachment reached the store %d times, want 1", inner.gets)
	}

	// Past the ttl it is read again (another instance may have deleted it).
	now = now.Add(11 * time.Minute)
	readAll(t, c, key)
	if inner.gets != 2 {
		t.Errorf("after the ttl: %d store reads, want 2", inner.gets)
	}

	// A Delete through the cache evicts at once.
	if err := c.Delete(ctx, key); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Get(ctx, key); err != ErrNotFound {
		t.Errorf("after Delete: %v, want ErrNotFound", err)
	}

	// Over the object limit: served whole, streamed, never kept.
	big := bytes.Repeat([]byte("b"), 5_000)
	bkey, _ := Key("t1", sha(big))
	c.Put(ctx, bkey, big) //nolint:errcheck
	before := inner.gets
	for i := 0; i < 2; i++ {
		if got := readAll(t, c, bkey); !bytes.Equal(got, big) {
			t.Fatalf("big read %d: %d bytes, want %d", i, len(got), len(big))
		}
	}
	if inner.gets-before != 2 {
		t.Errorf("a big object was cached: %d store reads for 2 Gets", inner.gets-before)
	}

	// Scratch keys are not content-addressed: never cached.
	tmp := TmpKey("t1", "nonce-1")
	c.Put(ctx, tmp, small) //nolint:errcheck
	before = inner.gets
	readAll(t, c, tmp)
	readAll(t, c, tmp)
	if inner.gets-before != 2 {
		t.Errorf("a tmp/ key was cached: %d store reads for 2 Gets", inner.gets-before)
	}
}

func TestCachedStaysUnderItsBudget(t *testing.T) {
	ctx := context.Background()
	inner := &countingStore{Store: Dir{Root: t.TempDir()}}
	c := NewCached(inner, 10_000, 4_000, time.Hour)
	var keys []string
	for i := 0; i < 5; i++ { // 5 x 3 000 bytes into a 10 000 byte budget
		b := bytes.Repeat([]byte{byte('a' + i)}, 3_000)
		k, _ := Key("t1", sha(b))
		c.Put(ctx, k, b) //nolint:errcheck
		readAll(t, c, k)
		keys = append(keys, k)
	}
	if c.size > 10_000 || len(c.items) != 3 {
		t.Fatalf("cache holds %d bytes in %d objects, want <= 10000 in 3", c.size, len(c.items))
	}
	before := inner.gets
	readAll(t, c, keys[4]) // newest: kept
	if inner.gets != before {
		t.Error("the most recent object was evicted")
	}
	readAll(t, c, keys[0]) // oldest: evicted
	if inner.gets != before+1 {
		t.Error("the least recently used object was still cached")
	}
}

func TestCacheable(t *testing.T) {
	h := sha([]byte("x"))
	for key, want := range map[string]bool{
		"t/t1/files/" + h: true, "avatars/" + h: true,
		"tmp/t1/nonce": false, "t/t1/files/not-a-sha": false, "t/t1/other/" + h: false, h: false,
	} {
		if got := cacheable(key); got != want {
			t.Errorf("cacheable(%q) = %v, want %v", key, got, want)
		}
	}
}
