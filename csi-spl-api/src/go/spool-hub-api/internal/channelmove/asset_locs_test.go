package channelmove

// Unit tests for the picture places (assetLocs), the clock (now) and the
// attachment read (Open) of a channel move: temp-dir stores and a stub
// Holder only (refactor round 25, row 08).

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
)

const alBadID = "not-a-sha256"

// alHolder is a Holder whose answers are fixed, or fail.
type alHolder struct {
	attached bool
	err      error
}

func (h alHolder) FileAttached(context.Context, string, string, time.Time) (bool, error) {
	return h.attached, h.err
}

func (h alHolder) DocAssetHeld(context.Context, string, string) (bool, error) {
	return false, nil
}

// alDocs answers every tenant with st and err.
func alDocs(st blob.Store, err error) func(context.Context, string) (blob.Store, error) {
	return func(context.Context, string) (blob.Store, error) { return st, err }
}

// alKeys is the key of each place, in order.
func alKeys(ls []loc) []string {
	ks := make([]string, len(ls))
	for i, l := range ls {
		ks[i] = l.key
	}
	return ks
}

func alWantKeys(t *testing.T, ls []loc, err error, want ...string) {
	t.Helper()
	if err != nil {
		t.Fatalf("assetLocs: %v", err)
	}
	if got := strings.Join(alKeys(ls), ","); got != strings.Join(want, ",") {
		t.Fatalf("assetLocs keys = %q, want %q", got, strings.Join(want, ","))
	}
}

func TestAssetLocsBadID(t *testing.T) {
	o := Objects{Files: blob.Dir{Root: t.TempDir()}}
	if ls, err := o.assetLocs(context.Background(), srcT, alBadID); err == nil {
		t.Fatalf("assetLocs(bad id) = %v, nil; want an error", alKeys(ls))
	}
}

func TestAssetLocsNoDocs(t *testing.T) {
	id, _ := blobOf(t, "pic")
	files := blob.Dir{Root: t.TempDir()}
	ls, err := Objects{Files: files}.assetLocs(context.Background(), srcT, id)
	alWantKeys(t, ls, err, "t/"+srcT+"/files/"+id)
	if ls[0].st != files {
		t.Fatal("the one place is not the files bucket")
	}
}

func TestAssetLocsDocsError(t *testing.T) {
	id, _ := blobOf(t, "pic")
	boom := errors.New("boom")
	o := Objects{Files: blob.Dir{Root: t.TempDir()}, Docs: alDocs(nil, boom)}
	_, err := o.assetLocs(context.Background(), srcT, id)
	if !errors.Is(err, boom) || !strings.HasPrefix(err.Error(), "docs store of "+srcT+":") {
		t.Fatalf("assetLocs err = %v, want %q wrapping boom", err, "docs store of "+srcT+":")
	}
}

func TestAssetLocsDocsNilStore(t *testing.T) {
	id, _ := blobOf(t, "pic")
	o := Objects{Files: blob.Dir{Root: t.TempDir()}, Docs: alDocs(nil, nil)}
	ls, err := o.assetLocs(context.Background(), srcT, id)
	alWantKeys(t, ls, err, fkey(srcT, id))
}

func TestAssetLocsDocsStoreFirst(t *testing.T) {
	id, _ := blobOf(t, "pic")
	docs := blob.Dir{Root: t.TempDir()}
	o := Objects{Files: blob.Dir{Root: t.TempDir()}, Docs: alDocs(docs, nil)}
	ls, err := o.assetLocs(context.Background(), srcT, id)
	alWantKeys(t, ls, err, docAssetPrefix+id, fkey(srcT, id))
	if ls[0].st != docs {
		t.Fatal("the first place is not the docs store")
	}
}

func TestNowInjected(t *testing.T) {
	at := time.Date(2026, 11, 6, 8, 0, 0, 0, time.UTC)
	if got := (Objects{Now: func() time.Time { return at }}).now(); !got.Equal(at) {
		t.Fatalf("now() = %v, want %v", got, at)
	}
}

func TestNowDefault(t *testing.T) {
	if d := time.Since(Objects{}.now()); d < 0 || d > time.Second {
		t.Fatalf("now() is %v from time.Now(), want within a second", d)
	}
}

func TestOpenBadID(t *testing.T) {
	o := Objects{Files: blob.Dir{Root: t.TempDir()}, Held: alHolder{attached: true}}
	if _, err := o.Open(context.Background(), srcT, alBadID); !errors.Is(err, blob.ErrNotFound) {
		t.Fatalf("Open(bad id) err = %v, want blob.ErrNotFound", err)
	}
}

func TestOpenHolderError(t *testing.T) {
	id, b := blobOf(t, "att")
	files := blob.Dir{Root: t.TempDir()}
	seed(t, files, fkey(srcT, id), b)
	boom := errors.New("db down")
	o := Objects{Files: files, Held: alHolder{err: boom}}
	if _, err := o.Open(context.Background(), srcT, id); !errors.Is(err, boom) {
		t.Fatalf("Open err = %v, want the holder's error", err)
	}
}

func TestOpenNotHeld(t *testing.T) {
	id, b := blobOf(t, "att")
	files := blob.Dir{Root: t.TempDir()}
	seed(t, files, fkey(srcT, id), b)
	o := Objects{Files: files, Held: alHolder{}}
	if _, err := o.Open(context.Background(), srcT, id); !errors.Is(err, blob.ErrNotFound) {
		t.Fatalf("Open(not held) err = %v, want blob.ErrNotFound", err)
	}
}
