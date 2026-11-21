package hubclient

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// pdfSession dials a CLI session against a hub whose handshake is opsHub's
// and whose export route (spec 183 7.1.1) is route; every request URI and
// bearer the route saw is returned through got.
func pdfSession(t *testing.T, route http.HandlerFunc) (*Session, func() []string) {
	t.Helper()
	h := &opsHub{}
	var mu sync.Mutex
	var seen []string
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", h.ws)
	mux.HandleFunc("/v1/topics/", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen = append(seen, r.Method+" "+r.URL.RequestURI()+" "+r.Header.Get("Authorization")+" "+r.Header.Get(TenantHeader))
		mu.Unlock()
		route(w, r)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	c := testClient(t)
	c.Cfg.HubURL, c.Cfg.Tenant, c.Cfg.SubmitSocket = srv.URL, "t1", "off"
	c.ReadyTimeout, c.KeepAlive = 5*time.Second, -1
	s, err := c.Dial(context.Background(), wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return s, func() []string { mu.Lock(); defer mu.Unlock(); return append([]string(nil), seen...) }
}

func pdfAnswer(body []byte, name string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/pdf")
		if name != "" {
			w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
		}
		w.Header().Set("X-Spool-Rows", "3")
		w.Header().Set("X-Spool-Pictures", "1")
		w.Write(body) //nolint:errcheck
	}
}

func refuse(status int, token string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		if token != "" {
			w.Write([]byte(`{"error":"` + token + `","detail":"d"}`)) //nolint:errcheck
		}
	}
}

// TestTopicPDFCopiesTheBytes: the route is asked with the box bearer, the
// tenant and typed_by; the body reaches w byte for byte; name, rows and
// pictures come from the headers.
func TestTopicPDFCopiesTheBytes(t *testing.T) {
	body := []byte("%PDF-1.7\n\x00\x01binary\xff%%EOF\n")
	s, seen := pdfSession(t, pdfAnswer(body, "hello-0f8fad5b-20261120T120000Z.pdf"))
	var buf bytes.Buffer
	info, err := s.TopicPDF(context.Background(), "0f8fad5b-d9cb-469f-a165-70867728950e", "HUM-12", &buf)
	if err != nil || !bytes.Equal(buf.Bytes(), body) {
		t.Fatalf("err %v body %q", err, buf.Bytes())
	}
	if info != (TopicPDFInfo{Name: "hello-0f8fad5b-20261120T120000Z.pdf", Rows: 3, Pictures: 1}) {
		t.Errorf("info %+v", info)
	}
	want := "GET /v1/topics/0f8fad5b-d9cb-469f-a165-70867728950e/export.pdf?typed_by=HUM-12 Bearer tok t1"
	if got := seen(); len(got) != 1 || got[0] != want {
		t.Errorf("route saw %q, want %q", got, want)
	}
}

// TestTopicPDFRefusals: each route token is a *HubError with its status and
// nothing written; a 5xx with no route token is an unreachable hub; a 200
// that is not a PDF is refused.
func TestTopicPDFRefusals(t *testing.T) {
	for _, c := range []struct {
		status int
		token  string
	}{
		{404, "not_found"}, {400, "operator_ambiguous"}, {403, "typed_by_not_bound"}, {403, "no_operator"},
		{413, "too_large"}, {503, "render_unavailable"}, {504, "render_timeout"}, {401, ""},
	} {
		s, _ := pdfSession(t, refuse(c.status, c.token))
		var buf bytes.Buffer
		_, err := s.TopicPDF(context.Background(), "t", "", &buf)
		var he *HubError
		if !errors.As(err, &he) || he.Status != c.status || (c.token != "" && he.Token != c.token) || buf.Len() != 0 {
			t.Errorf("%d %s: err %v wrote %d", c.status, c.token, err, buf.Len())
		}
	}
	s, _ := pdfSession(t, refuse(502, "upstream"))
	if _, err := s.TopicPDF(context.Background(), "t", "", &bytes.Buffer{}); !errors.Is(err, ErrUnreachable) {
		t.Errorf("502 with no route token: %v, want ErrUnreachable", err)
	}
	s, _ = pdfSession(t, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		w.Write([]byte("<html>")) //nolint:errcheck
	})
	var buf bytes.Buffer
	if _, err := s.TopicPDF(context.Background(), "t", "", &buf); err == nil || !strings.Contains(err.Error(), "not application/pdf") || buf.Len() != 0 {
		t.Errorf("text/html 200: err %v wrote %d", err, buf.Len())
	}
}

// TestTopicPDFTooLarge: a body past msg.MaxFileBytes is refused as too_large.
func TestTopicPDFTooLarge(t *testing.T) {
	s, _ := pdfSession(t, pdfAnswer(make([]byte, msg.MaxFileBytes+1), ""))
	var he *HubError
	if _, err := s.TopicPDF(context.Background(), "t", "", &bytes.Buffer{}); !errors.As(err, &he) || he.Token != "too_large" || he.Status != 413 {
		t.Fatalf("got %v", err)
	}
}

// TestTopicPDFName keeps only a plain .pdf file name from the header.
func TestTopicPDFName(t *testing.T) {
	for cd, want := range map[string]string{
		`attachment; filename="a-0f8fad5b-20261120T120000Z.pdf"`: "a-0f8fad5b-20261120T120000Z.pdf",
		`attachment; filename="../etc/x.pdf"`:                    "",
		`attachment; filename=".hidden.pdf"`:                     "",
		`attachment; filename="a.html"`:                          "",
		`attachment`:                                             "",
		``:                                                       "",
	} {
		if got := topicPDFName(cd); got != want {
			t.Errorf("%q -> %q, want %q", cd, got, want)
		}
	}
}
