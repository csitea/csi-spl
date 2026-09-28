package blob

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"testing"
	"time"
)

// SPL-1123: PromoteNew (the upload handler has just seen the key missing)
// moves the scratch object to the content key exactly as Promote does -
// existed=false, scratch gone, the bytes readable - on every store: GCS
// through its own one-check-fewer path, Dir and Cached through theirs.
func TestPromoteNewMovesLikePromote(t *testing.T) {
	stores := map[string]func(t *testing.T) Store{
		"dir":    func(t *testing.T) Store { return Dir{Root: t.TempDir()} },
		"cached": func(t *testing.T) Store { return NewCached(Dir{Root: t.TempDir()}, 1<<20, 1<<20, time.Minute) },
		"gcs":    func(t *testing.T) Store { return openTestGCS(t) },
	}
	for name, open := range stores {
		t.Run(name, func(t *testing.T) {
			s := open(t)
			ctx := context.Background()
			tenant := "t-" + uid()
			data := make([]byte, 64<<10)
			rand.Read(data) //nolint:errcheck
			sum := sha256.Sum256(data)
			key, _ := Key(tenant, hex.EncodeToString(sum[:]))
			tmp := TmpKey(tenant, uid())
			if _, err := s.PutReader(ctx, tmp, bytes.NewReader(data)); err != nil {
				t.Fatal(err)
			}
			existed, err := PromoteNew(ctx, s, tmp, key)
			if err != nil || existed {
				t.Fatalf("PromoteNew: existed=%v %v", existed, err)
			}
			if ok, _ := s.Exists(ctx, tmp); ok {
				t.Fatalf("tmp %s left after PromoteNew", tmp)
			}
			r, err := s.Get(ctx, key)
			if err != nil {
				t.Fatal(err)
			}
			got, _ := io.ReadAll(r)
			r.Close()
			if !bytes.Equal(got, data) {
				t.Fatal("promoted bytes differ")
			}
		})
	}
}
