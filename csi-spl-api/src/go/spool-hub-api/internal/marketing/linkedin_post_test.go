package marketing

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// SPL-1634: the share client and the blog reader against a fake LinkedIn
// and a fake blog.

func TestEscapeLittleText(t *testing.T) {
	got := EscapeLittleText(`a (b) #c @d *e_ [f] <g> {h} |i ~j \k`)
	want := `a \(b\) \#c \@d \*e\_ \[f\] \<g\> \{h\} \|i \~j \\k`
	if got != want {
		t.Fatalf("escape:\n got %s\nwant %s", got, want)
	}
	if EscapeLittleText("plain text. done") != "plain text. done" {
		t.Fatal("plain text changed")
	}
}

func TestRetryableAndUnauthorized(t *testing.T) {
	for _, c := range []struct {
		err    error
		retry  bool
		unauth bool
	}{
		{&HTTPError{Status: 429}, true, false},
		{&HTTPError{Status: 503}, true, false},
		{&HTTPError{Status: 500}, false, false},
		{&HTTPError{Status: 502}, false, false},
		{fmt.Errorf("wrapped: %w", &HTTPError{Status: 401}), false, true},
		{&net.OpError{Op: "dial", Err: errors.New("refused")}, true, false},
		{&net.OpError{Op: "read", Err: errors.New("reset")}, false, false},
		{ErrUnknownOutcome, false, false},
		{errors.New("other"), false, false},
	} {
		if got := Retryable(c.err); got != c.retry {
			t.Errorf("Retryable(%v) = %v, want %v", c.err, got, c.retry)
		}
		if got := Unauthorized(c.err); got != c.unauth {
			t.Errorf("Unauthorized(%v) = %v, want %v", c.err, got, c.unauth)
		}
	}
}

func TestShareSendsOnePostWithThumbnail(t *testing.T) {
	var body map[string]any
	l := fakeLinkedIn(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/rest/posts" || r.Method != http.MethodPost {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer "+testOAuthToken || r.Header.Get("LinkedIn-Version") != "202606" ||
			r.Header.Get("X-Restli-Protocol-Version") != "2.0.0" {
			t.Errorf("headers: %v", r.Header)
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		w.Header().Set("X-Restli-Id", "urn:li:share:42")
		w.WriteHeader(http.StatusCreated)
	})
	id, err := l.Share(context.Background(), NewPlaintext(testOAuthToken), "abc",
		Article{Commentary: "Title (1)", URL: "https://app.example.com/blog/x", Title: "T", Description: "D"}, "urn:li:image:9")
	if err != nil || id != "urn:li:share:42" {
		t.Fatalf("share: %q %v", id, err)
	}
	if body["author"] != "urn:li:person:abc" || body["commentary"] != `Title \(1\)` || body["visibility"] != "PUBLIC" {
		t.Fatalf("body: %v", body)
	}
	art := body["content"].(map[string]any)["article"].(map[string]any)
	if art["source"] != "https://app.example.com/blog/x" || art["thumbnail"] != "urn:li:image:9" || art["title"] != "T" {
		t.Fatalf("article: %v", art)
	}
}

func TestShareErrors(t *testing.T) {
	ctx, tok := context.Background(), NewPlaintext(testOAuthToken)
	a := Article{URL: "https://app.example.com/blog/x"}

	l := fakeLinkedIn(t, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-LinkedIn-Id", "urn:li:share:7")
		w.WriteHeader(http.StatusCreated)
	})
	if id, err := l.Share(ctx, tok, "abc", a, ""); err != nil || id != "urn:li:share:7" {
		t.Fatalf("fallback id: %q %v", id, err)
	}

	l = fakeLinkedIn(t, func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"message":"slow down"}`, http.StatusTooManyRequests)
	})
	if _, err := l.Share(ctx, tok, "abc", a, ""); !Retryable(err) {
		t.Fatalf("429: %v, want retryable", err)
	}

	l = fakeLinkedIn(t, func(w http.ResponseWriter, _ *http.Request) {
		hj, _ := w.(http.Hijacker)
		c, _, _ := hj.Hijack()
		_ = c.Close() // the request went out, no answer came back
	})
	if _, err := l.Share(ctx, tok, "abc", a, ""); !errors.Is(err, ErrUnknownOutcome) || Retryable(err) {
		t.Fatalf("dropped connection: %v, want ErrUnknownOutcome, not retryable", err)
	}

	srv := httptest.NewServer(http.NotFoundHandler())
	dead := srv.URL
	srv.Close()
	l = &LinkedIn{Version: "202606", APIBase: dead}
	if _, err := l.Share(ctx, tok, "abc", a, ""); !Retryable(err) || errors.Is(err, ErrUnknownOutcome) {
		t.Fatalf("dial failure: %v, want retryable", err)
	}
}

func TestUploadImage(t *testing.T) {
	var put []byte
	var srvURL string
	l := fakeLinkedIn(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/rest/images":
			if r.URL.Query().Get("action") != "initializeUpload" {
				t.Errorf("query: %s", r.URL.RawQuery)
			}
			fmt.Fprintf(w, `{"value":{"uploadUrl":%q,"image":"urn:li:image:1"}}`, srvURL+"/upload")
		case r.Method == http.MethodPut && r.URL.Path == "/upload":
			put, _ = io.ReadAll(r.Body)
			w.WriteHeader(http.StatusCreated)
		default:
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
	})
	srvURL = l.APIBase
	urn, err := l.UploadImage(context.Background(), NewPlaintext(testOAuthToken), "abc", []byte("png-bytes"))
	if err != nil || urn != "urn:li:image:1" || string(put) != "png-bytes" {
		t.Fatalf("upload: %q %v %q", urn, err, put)
	}

	l = fakeLinkedIn(t, func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, `{"value":{}}`) })
	if _, err := l.UploadImage(context.Background(), NewPlaintext(testOAuthToken), "abc", nil); err == nil {
		t.Fatal("no upload url: want an error")
	}
	l = fakeLinkedIn(t, func(w http.ResponseWriter, _ *http.Request) { http.Error(w, "no", http.StatusForbidden) })
	if _, err := l.UploadImage(context.Background(), NewPlaintext(testOAuthToken), "abc", nil); err == nil {
		t.Fatal("403: want an error")
	}
}

func testPNG(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 2, 2))
	img.Set(0, 0, color.RGBA{R: 255, A: 255})
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func fakeBlog(t *testing.T, pic []byte) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/blog-md/index.json":
			_, _ = io.WriteString(w, `{"locales":{"en":[
				{"id":"2026-10-12-new-post","title":"New post","summary":"One line.","image":"new.png"},
				{"id":"not a blog id","title":"Bad"},
				{"id":"2026-10-01-untitled","title":"  "}],
				"fi":[{"id":"2026-10-12-new-post","title":"Uusi"}]}}`)
		case "/blog/img/new.png":
			_, _ = w.Write(pic)
		case "/blog/img/broken.png":
			_, _ = io.WriteString(w, "not an image")
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

func TestFetchBlogIndexAndPicture(t *testing.T) {
	ctx, c := context.Background(), http.DefaultClient
	app := fakeBlog(t, testPNG(t))
	posts, err := FetchBlogIndex(ctx, c, app+"/")
	if err != nil || len(posts) != 1 || posts[0].ID != "2026-10-12-new-post" {
		t.Fatalf("index: %+v %v", posts, err)
	}
	pic, err := FetchBlogPicture(ctx, c, app, posts[0])
	if err != nil {
		t.Fatalf("picture: %v", err)
	}
	if _, err := png.Decode(bytes.NewReader(pic)); err != nil {
		t.Fatalf("picture is not PNG: %v", err)
	}
	for _, img := range []string{"", "../x.png", `a\b.png`} {
		if pic, err := FetchBlogPicture(ctx, c, app, BlogPost{Image: img}); pic != nil || err != nil {
			t.Errorf("image %q: %v %v, want nil nil", img, pic, err)
		}
	}
	for _, img := range []string{"missing.png", "broken.png"} {
		if _, err := FetchBlogPicture(ctx, c, app, BlogPost{Image: img}); err == nil {
			t.Errorf("image %q: want an error", img)
		}
	}
	a := BlogArticle(app+"/", posts[0], pic)
	if a.URL != app+"/blog/2026-10-12-new-post" || a.Title != "New post" || a.Description != "One line." ||
		a.Commentary != "📝 New post\n\n💡 One line.\n\n👉 "+a.URL || a.Picture == nil {
		t.Fatalf("article: %+v", a)
	}
}

func TestFetchBlogIndexErrors(t *testing.T) {
	ctx, c := context.Background(), http.DefaultClient
	for name, h := range map[string]http.HandlerFunc{
		"status":   func(w http.ResponseWriter, _ *http.Request) { http.Error(w, "x", http.StatusBadGateway) },
		"not json": func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, "<html>") },
		"no en":    func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, `{"locales":{"fi":[]}}`) },
	} {
		srv := httptest.NewServer(h)
		if _, err := FetchBlogIndex(ctx, c, srv.URL); err == nil || !strings.Contains(err.Error(), "blog index") {
			t.Errorf("%s: %v, want a blog index error", name, err)
		}
		srv.Close()
	}
}

// SPL-1855 (owner HUM-10, topic f46301d4 msg 8c3e0a83): the share's
// commentary carries emojis, and the little-text escaping keeps them while
// it still escapes the title's markup.
func TestBlogArticleEmojisSurviveLittleText(t *testing.T) {
	p := BlogPost{ID: "2026-10-14-emoji", Title: "Ship it (v2) #fast", Summary: "One [line] @all."}
	a := BlogArticle("https://app.example.com", p, nil)
	for _, e := range []string{"\U0001F4DD", "\U0001F4A1", "\U0001F449"} {
		if strings.Count(a.Commentary, e) != 1 {
			t.Fatalf("commentary %q: want %q once", a.Commentary, e)
		}
	}
	want := "\U0001F4DD Ship it \\(v2\\) \\#fast\n\n\U0001F4A1 One \\[line\\] \\@all.\n\n\U0001F449 https://app.example.com/blog/2026-10-14-emoji"
	if got := EscapeLittleText(a.Commentary); got != want {
		t.Fatalf("escaped:\n got %q\nwant %q", got, want)
	}
	var body map[string]any
	l := fakeLinkedIn(t, func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&body)
		w.Header().Set("X-Restli-Id", "urn:li:share:43")
		w.WriteHeader(http.StatusCreated)
	})
	if _, err := l.Share(context.Background(), NewPlaintext(testOAuthToken), "abc", a, ""); err != nil {
		t.Fatal(err)
	}
	if body["commentary"] != want {
		t.Fatalf("posted commentary %q, want %q", body["commentary"], want)
	}
}
