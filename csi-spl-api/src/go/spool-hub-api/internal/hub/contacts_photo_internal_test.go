package hub

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// N1 of the spec 154 B16 R7 review: the fetch's own size cap, alone (the
// store's check refuses an oversized picture too, so the sync test cannot
// tell the two apart). store.ContactPhotoMax bytes pass; one more is refused.
func TestContactsPhotoFetchSizeCap(t *testing.T) {
	bodies := map[string][]byte{}
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(bodies[r.URL.Path])
	}))
	t.Cleanup(srv.Close)
	png := func(n int) []byte {
		b := append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{1}, n)...)
		return b[:n]
	}
	bodies["/at"], bodies["/over"] = png(store.ContactPhotoMax), png(store.ContactPhotoMax+1)
	c := ContactsPhotoConfig{Hosts: []string{"127.0.0.1"}, MaxPerPerson: 2000, HTTP: srv.Client()}
	for path, wantErr := range map[string]error{"/at": nil, "/over": errPhotoTooBig} {
		u, err := url.Parse(srv.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		mime, body, err := c.fetch(context.Background(), u)
		if !errors.Is(err, wantErr) {
			t.Errorf("%s: err %v, want %v", path, err, wantErr)
		}
		if wantErr == nil && (mime != "image/png" || len(body) != store.ContactPhotoMax) {
			t.Errorf("%s: %q %d bytes, want image/png %d", path, mime, len(body), store.ContactPhotoMax)
		}
	}
}
