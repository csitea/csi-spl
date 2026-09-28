package hub_test

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// Pins of POST /v1/files when the object store fails, taken before
// handlePutFile was split into named steps (SPL-1029 round 2): each failure
// is a 503 that leaves no object behind, and a promote that finds the bytes
// already there (a concurrent upload of the same file) is a success.

type failingBlob struct {
	blob.Store
	prefixErr, putErr, promoteErr error
	promoteExisted                bool
}

func (f *failingBlob) PrefixBytes(ctx context.Context, p string) (int64, error) {
	if f.prefixErr != nil {
		return 0, f.prefixErr
	}
	return f.Store.PrefixBytes(ctx, p)
}

func (f *failingBlob) PutReader(ctx context.Context, key string, r io.Reader) (int64, error) {
	if f.putErr != nil {
		io.Copy(io.Discard, r) //nolint:errcheck
		return 0, f.putErr
	}
	return f.Store.PutReader(ctx, key, r)
}

func (f *failingBlob) Promote(ctx context.Context, src, dst string) (bool, error) {
	if f.promoteErr != nil {
		return false, f.promoteErr
	}
	if f.promoteExisted {
		f.Store.Delete(ctx, src) //nolint:errcheck
		return true, nil
	}
	return f.Store.Promote(ctx, src, dst)
}

func TestUploadObjectStoreFailures(t *testing.T) {
	down := errors.New("object store down")
	for _, c := range []struct {
		name     string
		fb       failingBlob
		chunked  bool
		code     int
		token    string
		objects  int
		touchIDs bool
	}{
		{"quota read fails", failingBlob{prefixErr: down}, false, http.StatusServiceUnavailable, "internal", 0, false},
		{"stream fails", failingBlob{putErr: down}, true, http.StatusServiceUnavailable, "internal", 0, false},
		{"reserve fails", failingBlob{prefixErr: down}, true, http.StatusServiceUnavailable, "internal", 0, false},
		{"promote fails", failingBlob{promoteErr: down}, true, http.StatusServiceUnavailable, "internal", 0, false},
		{"promote finds it there", failingBlob{promoteExisted: true}, true, http.StatusCreated, "", 0, true},
	} {
		t.Run(c.name, func(t *testing.T) {
			fb := c.fb
			e := newEnv(t, func(o *hub.Options) {
				fb.Store = o.Blob
				o.Blob = &fb
				o.QuotaFileBytes = 1 << 20 // a quota, so the store's usage is read
			})
			tid, _ := e.tenant()
			a := e.box(tid, "box-a", "GRK-03")
			e.pin(tid, a)
			tok := e.uploadToken(tid, a)
			data := []byte(strings.Repeat("upload me ", 100))
			size := int64(len(data))
			if c.chunked {
				size = -1
			}
			code, fr, eb := e.postFile(tid, tok, bytes.NewReader(data), size)
			if code != c.code || eb.Error != c.token {
				t.Fatalf("%d %+v %+v, want %d %q", code, fr, eb, c.code, c.token)
			}
			if c.touchIDs && fr.Bytes != int64(len(data)) {
				t.Fatalf("result %+v", fr)
			}
			if got := e.blobFiles(); len(got) != c.objects {
				t.Fatalf("objects left behind: %v", got)
			}
		})
	}
}
