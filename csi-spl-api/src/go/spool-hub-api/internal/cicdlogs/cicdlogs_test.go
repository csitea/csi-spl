package cicdlogs

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

const taskID = "11111111-1111-4111-8111-111111111111"

func signer(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	return priv
}

func baseReq() Request {
	return Request{Owner: "acme", Repo: "app", RunID: "99", TaskID: taskID, To: "CLE-07", ToBox: "box-a"}
}

func enabled(t *testing.T, token, allow string) Settings {
	t.Helper()
	s, err := ParseSettings(true, "lde", token, "", allow, "https://api.example.test", "hub", "CI-0")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Validate(); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestParseRunURL(t *testing.T) {
	o, r, id, job, err := ParseRunURL("https://example.test/acme/app/actions/runs/12345")
	if err != nil || o != "acme" || r != "app" || id != "12345" || job != "" {
		t.Fatalf("got %s %s %s %s %v", o, r, id, job, err)
	}
	_, _, id, job, err = ParseRunURL("https://example.test/acme/app/actions/runs/9/job/7")
	if err != nil || id != "9" || job != "7" {
		t.Fatalf("job: %s %s %v", id, job, err)
	}
	if _, _, _, _, err := ParseRunURL("not-a-url"); err == nil {
		t.Fatal("bad url accepted")
	}
}

func TestAllowlistEmptyDenies(t *testing.T) {
	s := enabled(t, "tok", "")
	if s.Allowed("acme", "o", "r") {
		t.Fatal("empty allowlist must deny")
	}
	s = enabled(t, "tok", "acme:o/r,acme:org/*")
	if !s.Allowed("acme", "o", "r") || !s.Allowed("acme", "org", "x") {
		t.Fatal("exact and org/* should allow")
	}
	if s.Allowed("acme", "other", "r") || s.Allowed("other", "o", "r") {
		t.Fatal("cross-tenant or other owner allowed")
	}
}

func TestStarPatternsRejected(t *testing.T) {
	if _, err := ParseAllowlist("acme:*/*"); err == nil {
		t.Fatal("*/* accepted")
	}
	if _, err := ParseAllowlist("acme:*"); err == nil {
		t.Fatal("bare * accepted")
	}
}

func TestPrdFailClosed(t *testing.T) {
	s, err := ParseSettings(true, "prd", "", "", "t1:o/r", "https://api.example.test", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Validate(); err == nil {
		t.Fatal("prd enabled without token accepted")
	}
	s, err = ParseSettings(true, "prd", "CHANGE_ME", "", "t1:o/r", "https://api.example.test", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Validate(); !IsPlaceholder("CHANGE_ME") || err == nil {
		t.Fatalf("placeholder not fail-closed: %v", err)
	}
	s, err = ParseSettings(false, "prd", "", "", "", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Validate(); err != nil {
		t.Fatalf("disabled prd: %v", err)
	}
}

func TestValidateHubEnvOffIsNoop(t *testing.T) {
	if err := ValidateHubEnv(false, "prd", "", "", "", "", "", ""); err != nil {
		t.Fatal(err)
	}
	if err := ValidateHubEnv(true, "lde", "tok", "", "t:o/r", "", "", ""); err == nil {
		t.Fatal("enabled without API accepted")
	}
}

func TestUnconfiguredNoteNoFetch(t *testing.T) {
	fetch := &FakeFetcher{Logs: map[string][]byte{"acme/app/99": []byte("secret-log")}}
	bus := &MemoryBus{}
	svc := &Service{Settings: enabled(t, "", "t1:acme/app"), Fetch: fetch, Bus: bus, Signer: signer(t)}
	// tenant t1 has allowlist but no token
	res, err := svc.Run(context.Background(), "t1", baseReq())
	if err != nil {
		t.Fatal(err)
	}
	if res.Configured || res.Message.Body != NotConfiguredBody || len(res.Message.Files) != 0 {
		t.Fatalf("%+v", res)
	}
	if fetch.LastToken != "" {
		t.Fatal("fetched without a token")
	}
	if len(bus.Envs) != 1 {
		t.Fatal("note not delivered")
	}
}

func TestForbiddenNoFetch(t *testing.T) {
	fetch := &FakeFetcher{Logs: map[string][]byte{"acme/app/99": []byte("x")}}
	svc := &Service{Settings: enabled(t, "tok", "t1:other/repo"), Fetch: fetch, Bus: &MemoryBus{}, Signer: signer(t)}
	_, err := svc.Run(context.Background(), "t1", baseReq())
	if err != ErrForbidden {
		t.Fatalf("got %v", err)
	}
	if fetch.LastToken != "" {
		t.Fatal("fetched a forbidden repo")
	}
}

func TestFetchDeliverNoteAndFile(t *testing.T) {
	fetch := &FakeFetcher{Logs: map[string][]byte{"acme/app/99": []byte("ok-log")}}
	bus := &MemoryBus{}
	priv := signer(t)
	svc := &Service{Settings: enabled(t, "tok", "t1:acme/*"), Fetch: fetch, Bus: bus, Signer: priv}
	res, err := svc.Run(context.Background(), "t1", baseReq())
	if err != nil {
		t.Fatal(err)
	}
	if !res.Configured || res.Truncated || res.Message.Kind != "note" || res.Message.From != "CI-0" {
		t.Fatalf("%+v", res)
	}
	if !strings.Contains(res.Message.Body, "CI run acme/app #99") {
		t.Fatalf("body %q", res.Message.Body)
	}
	if len(res.Message.Files) != 1 || res.Message.Files[0].Bytes != 6 {
		t.Fatalf("files %+v", res.Message.Files)
	}
	if fetch.LastToken != "tok" {
		t.Fatal("token not passed to fetcher")
	}
	inner, err := bus.Envs[0].Inner()
	if err != nil || inner.Kind != "note" {
		t.Fatal(err)
	}
	if err := bus.Envs[0].Verify(priv.Public().(ed25519.PublicKey)); err != nil {
		t.Fatal(err)
	}
}

func TestTruncatePrefersFile(t *testing.T) {
	fetch := &FakeFetcher{Logs: map[string][]byte{"acme/app/99": []byte("abcdefghij")}}
	bus := &MemoryBus{}
	svc := &Service{
		Settings: enabled(t, "tok", "t1:acme/app"), Fetch: fetch, Bus: bus, Signer: signer(t),
		MaxFileBytes: 4,
	}
	res, err := svc.Run(context.Background(), "t1", baseReq())
	if err != nil {
		t.Fatal(err)
	}
	if !res.Truncated || !strings.Contains(res.Message.Body, TruncationLine) {
		t.Fatalf("%+v", res)
	}
	if res.Message.Files[0].Bytes != 4 {
		t.Fatalf("stored %d", res.Message.Files[0].Bytes)
	}
	got := bus.Files["t1/"+res.Message.Files[0].FileID]
	if string(got) != "abcd" {
		t.Fatalf("got %q", got)
	}
}

func TestDefaultCapIs32MiB(t *testing.T) {
	if (&Service{}).cap() != msg.MaxFileBytes || msg.MaxFileBytes != 32*1024*1024 {
		t.Fatalf("cap %d want 32 MiB", (&Service{}).cap())
	}
}

func TestScrubTokenFromFetchError(t *testing.T) {
	const tok = "secret-token-xyz"
	svc := &Service{
		Settings: enabled(t, tok, "t1:acme/app"),
		Fetch:    &FakeFetcher{Err: errWith(tok)},
		Bus:      &MemoryBus{}, Signer: signer(t),
	}
	_, err := svc.Run(context.Background(), "t1", baseReq())
	if err == nil || strings.Contains(err.Error(), tok) {
		t.Fatalf("token leaked: %v", err)
	}
}

type tokErr struct{ t string }

func (e tokErr) Error() string { return "401 token=" + e.t }
func errWith(t string) error   { return tokErr{t} }

func TestURLRequestAndNoTokenInBody(t *testing.T) {
	const tok = "secret-token-xyz"
	fetch := &FakeFetcher{Logs: map[string][]byte{"acme/app/99": []byte("log")}}
	svc := &Service{Settings: enabled(t, tok, "t1:acme/app"), Fetch: fetch, Bus: &MemoryBus{}, Signer: signer(t)}
	req := Request{
		URL: "https://ci.example.test/acme/app/actions/runs/99", TaskID: taskID, To: "CLE-07", ToBox: "box-a",
	}
	res, err := svc.Run(context.Background(), "t1", req)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(res.Message.Body, tok) || strings.Contains(DumpJSON(HTTPResultFrom(res)), tok) {
		t.Fatal("token in chat body")
	}
}

func TestHTTPFetcherStripsAuthOnRedirect(t *testing.T) {
	const tok = "secret-token-xyz"
	var sawAuthOnBlob bool
	mux := http.NewServeMux()
	mux.HandleFunc("/repos/acme/app/actions/runs/1/logs", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+tok {
			http.Error(w, "no", http.StatusUnauthorized)
			return
		}
		http.Redirect(w, r, "/blob", http.StatusFound)
	})
	mux.HandleFunc("/blob", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" {
			sawAuthOnBlob = true
		}
		w.Write([]byte("zip-bytes")) //nolint:errcheck
	})
	ts := httptest.NewServer(mux)
	t.Cleanup(ts.Close)
	c := &http.Client{CheckRedirect: stripAuthRedirect}
	b, err := (HTTPFetcher{Client: c}).FetchLogs(context.Background(), tok, ts.URL, "acme", "app", "1", "")
	if err != nil || string(b) != "zip-bytes" {
		t.Fatalf("%q %v", b, err)
	}
	if sawAuthOnBlob {
		t.Fatal("Authorization forwarded to the blob URL")
	}
}

func TestM1DockerfileOmitsGh(t *testing.T) {
	_, f, _, _ := runtime.Caller(0)
	p := filepath.Join(filepath.Dir(f), "..", "..", "..", "..", "..", "..", "csi-spl-api", "src", "docker", "hub.Dockerfile")
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(bytes.ToLower(raw), []byte("github.com/cli/cli")) {
		t.Fatal("Dockerfile references github.com/cli/cli")
	}
	for _, line := range strings.Split(string(raw), "\n") {
		for _, field := range strings.Fields(line) {
			if field == "gh" {
				t.Fatalf("M1 Dockerfile installs gh: %s", line)
			}
		}
	}
}

func TestEnvelopeFromBoxHub(t *testing.T) {
	bus := &MemoryBus{}
	svc := &Service{
		Settings: enabled(t, "tok", "t1:acme/app"),
		Fetch:    &FakeFetcher{Logs: map[string][]byte{"acme/app/99": []byte("x")}},
		Bus:      bus, Signer: signer(t),
	}
	if _, err := svc.Run(context.Background(), "t1", baseReq()); err != nil {
		t.Fatal(err)
	}
	if bus.Envs[0].FromBox != "hub" || bus.Envs[0].ToBox != "box-a" {
		t.Fatalf("%+v", bus.Envs[0])
	}
}
