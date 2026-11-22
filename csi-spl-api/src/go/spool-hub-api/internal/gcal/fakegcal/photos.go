package fakegcal

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// photos.go is the fake's contact pictures (spec 154 11.4 and 11.5, build
// row B16): a TLS server, as Google's photo host is https only, that answers
// each path a test put with its bytes or a redirect, and counts every
// request as the call "people.photo" and, by its sz query, as "people.photo
// sz=<n>". The hub reaches it through the client ServePhotos answers, which
// trusts its certificate; a test puts its URLs in photos[].url.

type photoState struct {
	srv  *httptest.Server
	byPa map[string]fphoto // URL path -> what it answers
}

type fphoto struct {
	body     []byte
	redirect string // a Location to answer 302 with, "" = the body
}

// ServePhotos starts the photo server for t (once) and answers a client
// that trusts it. The server closes with t.
func (f *Fake) ServePhotos(t testing.TB) *http.Client {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.pho == nil {
		f.pho = &photoState{byPa: map[string]fphoto{}}
		f.pho.srv = httptest.NewTLSServer(http.HandlerFunc(f.photoGet))
		t.Cleanup(f.pho.srv.Close)
	}
	return f.pho.srv.Client()
}

// PhotoBase is the photo server's https root (after ServePhotos).
func (f *Fake) PhotoBase() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.pho.srv.URL
}

// PutPhoto serves body at /<name> and answers its URL (after ServePhotos).
func (f *Fake) PutPhoto(name string, body []byte) string {
	return f.putPhoto(name, fphoto{body: body})
}

// PutPhotoRedirect answers 302 to location at /<name> and answers its URL.
func (f *Fake) PutPhotoRedirect(name, location string) string {
	return f.putPhoto(name, fphoto{redirect: location})
}

func (f *Fake) putPhoto(name string, p fphoto) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pho.byPa["/"+name] = p
	return f.pho.srv.URL + "/" + name
}

func (f *Fake) photoGet(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	f.calls["people.photo"]++
	f.calls["people.photo sz="+r.URL.Query().Get("sz")]++
	p, ok := f.pho.byPa[r.URL.Path]
	f.mu.Unlock()
	switch {
	case !ok || r.Method != http.MethodGet:
		http.NotFound(w, r)
	case p.redirect != "":
		// the Location a test put, never one the request carries
		w.Header().Set("Location", p.redirect)
		w.WriteHeader(http.StatusFound)
	default:
		w.Header().Set("Content-Type", contentTypeOf(p.body))
		_, _ = w.Write(p.body)
	}
}

// contentTypeOf is what a photo host would say; the hub never trusts it.
func contentTypeOf(b []byte) string {
	if ct := http.DetectContentType(b); !strings.HasPrefix(ct, "text/") {
		return ct
	}
	return "image/jpeg"
}
