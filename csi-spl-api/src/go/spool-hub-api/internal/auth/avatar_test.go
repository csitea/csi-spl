package auth

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/png"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"
)

func tinyPNG(t *testing.T) []byte {
	t.Helper()
	var b bytes.Buffer
	if err := png.Encode(&b, image.NewRGBA(image.Rect(0, 0, 4, 4))); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

// 010 T044: the picture is fetched server-side under a fixed policy. Every
// refusal is errAvatar with no bytes; the CONTROL is the https fetch that
// succeeds with the same server and client.
func TestFetchAvatarPolicy(t *testing.T) {
	pic := tinyPNG(t)
	var plainURL string
	mux := http.NewServeMux()
	mux.HandleFunc("/ok.png", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "image/png; charset=binary")
		w.Write(pic) //nolint:errcheck
	})
	mux.HandleFunc("/html", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		w.Write([]byte("<html></html>")) //nolint:errcheck
	})
	mux.HandleFunc("/svg", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "image/svg+xml")
		w.Write([]byte(`<svg xmlns="http://www.w3.org/2000/svg"><script>x</script></svg>`)) //nolint:errcheck
	})
	mux.HandleFunc("/lies.png", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		w.Write([]byte("<html><script>alert(1)</script></html>")) //nolint:errcheck
	})
	big := append(append([]byte{}, pic...), make([]byte, AvatarMaxBytes)...)
	mux.HandleFunc("/big.png", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Content-Length", strconv.Itoa(len(big)))
		w.Write(big) //nolint:errcheck
	})
	mux.HandleFunc("/big-chunked.png", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		w.Write(big[:1024]) //nolint:errcheck
		w.(http.Flusher).Flush()
		w.Write(big[1024:]) //nolint:errcheck
	})
	mux.HandleFunc("/404.png", http.NotFound)
	// A valid png after a 2 s wait: only the timeout can refuse it. Once the
	// client gives up the handler aborts and writes nothing: the client's
	// cancel reaches this handler first, and a png written then raced the
	// client's own deadline and won (wf 10 run 38041284106: nil error, 75
	// bytes, at 1.0017 s). A real slow server does not answer the hang-up.
	mux.HandleFunc("/slow.png", func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
			panic(http.ErrAbortHandler)
		case <-time.After(2 * time.Second):
		}
		w.Header().Set("Content-Type", "image/png")
		w.Write(pic) //nolint:errcheck
	})
	mux.HandleFunc("/to-http", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, plainURL+"/ok.png", http.StatusFound)
	})
	mux.HandleFunc("/to-https", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/ok.png", http.StatusFound)
	})
	mux.HandleFunc("/loop", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/loop", http.StatusFound)
	})
	tls := httptest.NewTLSServer(mux)
	defer tls.Close()
	plain := httptest.NewServer(mux)
	defer plain.Close()
	plainURL = plain.URL
	hc := tls.Client() // trusts the test CA; fetchAvatar keeps its transport only

	old := avatarTimeout
	// 1 s, not 300 ms: the budget also covers the first TLS handshake to a
	// fresh httptest server, which a loaded CI runner took past 300 ms (wf 10
	// runs 37963828126, 37965905561: the https CONTROL hit "context deadline
	// exceeded"). /slow.png still waits 2 s, so the timeout case still times out.
	avatarTimeout = time.Second
	defer func() { avatarTimeout = old }()
	ctx := context.Background()

	// CONTROL: https, png, under the cap.
	got, ct, err := fetchAvatar(ctx, hc, tls.URL+"/ok.png", "")
	if err != nil || ct != "image/png" || !bytes.Equal(got, pic) {
		t.Fatalf("https control: %v %q %d bytes", err, ct, len(got))
	}
	// An https redirect to https is followed.
	if got, _, err := fetchAvatar(ctx, hc, tls.URL+"/to-https", ""); err != nil || !bytes.Equal(got, pic) {
		t.Fatalf("https->https redirect: %v", err)
	}
	// http is refused unless it is the fake IdP's own origin.
	if _, _, err := fetchAvatar(ctx, hc, plain.URL+"/ok.png", ""); !errors.Is(err, errAvatar) {
		t.Fatalf("plain http fetched: %v", err)
	}
	if got, _, err := fetchAvatar(ctx, hc, plain.URL+"/ok.png", plain.URL); err != nil || !bytes.Equal(got, pic) {
		t.Fatalf("http on the fake IdP origin: %v", err)
	}
	if _, _, err := fetchAvatar(ctx, hc, plain.URL+"/ok.png", "http://other.invalid:1"); !errors.Is(err, errAvatar) {
		t.Fatalf("http on another origin fetched: %v", err)
	}

	for name, u := range map[string]string{
		"empty":             "",
		"no host":           "https:///ok.png",
		"userinfo":          "https://u:p@" + tls.Listener.Addr().String() + "/ok.png",
		"data uri":          "data:image/png;base64,AAAA",
		"javascript":        "javascript:alert(1)",
		"https->http":       tls.URL + "/to-http",
		"redirect loop":     tls.URL + "/loop",
		"text/html":         tls.URL + "/html",
		"svg":               tls.URL + "/svg",
		"sniff mismatch":    tls.URL + "/lies.png",
		"over the cap":      tls.URL + "/big.png",
		"over cap, chunked": tls.URL + "/big-chunked.png",
		"404":               tls.URL + "/404.png",
	} {
		if b, _, err := fetchAvatar(ctx, hc, u, ""); !errors.Is(err, errAvatar) || b != nil {
			t.Errorf("%s: want errAvatar and no bytes, got %v (%d bytes)", name, err, len(b))
		}
	}
	// The slow png is refused by the timeout itself, not by its content.
	b, _, err := fetchAvatar(ctx, hc, tls.URL+"/slow.png", "")
	var ne net.Error
	if !errors.Is(err, errAvatar) || b != nil || !errors.As(err, &ne) || !ne.Timeout() {
		t.Errorf("timeout: want errAvatar wrapping a net.Error timeout and no bytes, got %v (%d bytes)", err, len(b))
	}
	// http->http redirects are refused even on the fake IdP origin.
	if _, _, err := fetchAvatar(ctx, hc, plain.URL+"/to-https", plain.URL); !errors.Is(err, errAvatar) {
		t.Fatalf("http redirect followed on the fake origin: %v", err)
	}
}
