package mcp

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	sdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit/fakehub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// pdfStubHub speaks the hub handshake (challenge, welcome with upload token
// "tok") and serves the spec 183 7.1.1 route: body for topic ok, 404
// not_found for any other.
func pdfStubHub(t *testing.T, ok string, body []byte) string {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		defer conn.CloseNow() //nolint:errcheck
		ctx := r.Context()
		var hello wire.Frame
		if wsjson.Write(ctx, conn, wire.Frame{Type: wire.TChallenge, Nonce: "nonce-nonce-nonce"}) != nil || wsjson.Read(ctx, conn, &hello) != nil {
			return
		}
		if wsjson.Write(ctx, conn, wire.Frame{Type: wire.TWelcome, BoxID: hello.BoxID,
			UploadToken: "tok", UploadTokenExpiresAt: time.Now().Add(time.Hour).UTC().Format(time.RFC3339)}) != nil {
			return
		}
		for {
			var f wire.Frame
			if wsjson.Read(ctx, conn, &f) != nil {
				return
			}
		}
	})
	mux.HandleFunc("/v1/topics/", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tok" || r.URL.Path != "/v1/topics/"+ok+"/export.pdf" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusNotFound)
			w.Write([]byte(`{"error":"not_found"}`)) //nolint:errcheck
			return
		}
		w.Header().Set("Content-Type", "application/pdf")
		w.Header().Set("Content-Disposition", `attachment; filename="t-0f8fad5b-20261120T120000Z.pdf"`)
		w.Header().Set("X-Spool-Rows", "2")
		w.Header().Set("X-Spool-Pictures", "0")
		w.Write(body) //nolint:errcheck
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv.URL
}

// TestTopicPDFToolEqualsCLI (spec 183 row P3): spool_topic_pdf returns the
// JSON line `spool topic-pdf` prints for the same export, and a 404 is a
// tool error carrying exit 3, as the verb exits.
func TestTopicPDFToolEqualsCLI(t *testing.T) {
	const task = "0f8fad5b-d9cb-469f-a165-70867728950e"
	url := pdfStubHub(t, task, []byte("%PDF-1.7\nsynthetic\n%%EOF\n"))
	cfg := testkit.NewConfig(t)
	(&fakehub.Hub{URL: url}).Wire(t, cfg, "box-a")
	out := filepath.Join(t.TempDir(), "topic.pdf")

	bin := filepath.Join(t.TempDir(), "spool")
	if b, err := exec.Command("go", "build", "-o", bin, "../../cmd/spool").CombinedOutput(); err != nil {
		t.Fatalf("build spool: %v\n%s", err, b)
	}
	cli := func(args ...string) (string, string, int) {
		cmd := exec.Command(bin, append([]string{"topic-pdf"}, args...)...)
		cmd.Env = append(scrubSpoolEnv(os.Environ()), "SPOOL_ROOT="+cfg.SpoolRoot, "SPOOL_KEYS_DIR="+cfg.KeysDir, "SPOOL_PINS_DIR="+cfg.PinsDir,
			"SPOOL_BOX_ID=box-a", "SPOOL_HUB_URL="+url, "SPOOL_TENANT=t1", "SPOOL_SUBMIT_SOCKET=off", "SPOOL_LOG_LEVEL=error",
			"SPOOL_DESKS=")
		var so, se bytes.Buffer
		cmd.Stdout, cmd.Stderr = &so, &se
		err := cmd.Run()
		rc := 0
		if ee, ok := err.(*exec.ExitError); ok {
			rc = ee.ExitCode()
		} else if err != nil {
			t.Fatal(err)
		}
		return strings.TrimSuffix(so.String(), "\n"), se.String(), rc
	}
	cliOut, cliErr, rc := cli("--task", task, "--out", out)
	if rc != 0 {
		t.Fatalf("cli rc %d %q", rc, cliErr)
	}

	ctx := context.Background()
	ct, st := sdk.NewInMemoryTransports()
	if _, err := NewServer(cfg, "test").Connect(ctx, st, nil); err != nil {
		t.Fatal(err)
	}
	cs, err := sdk.NewClient(&sdk.Implementation{Name: "p3", Version: "test"}, nil).Connect(ctx, ct, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cs.Close() })
	got, isErr := callText(t, cs, "spool_topic_pdf", map[string]any{"task": task, "out": out})
	if isErr || got != cliOut {
		t.Fatalf("tool %q (isErr %v), want the CLI's %q", got, isErr, cliOut)
	}
	if !strings.Contains(got, `"path":"`+out+`"`) || !strings.Contains(got, `"rows":2`) {
		t.Errorf("tool JSON %q", got)
	}

	other := "1f8fad5b-d9cb-469f-a165-70867728950e"
	_, cliErr, rc = cli("--task", other, "--out", out+".2")
	got, isErr = callText(t, cs, "spool_topic_pdf", map[string]any{"task": other, "out": out + ".2"})
	if rc != 3 || !isErr || !strings.Contains(got, "not_found") || !strings.Contains(got, "(exit 3)") || !strings.Contains(cliErr, "not_found") {
		t.Errorf("404: cli rc %d %q, tool %q isErr %v; want exit 3 both", rc, cliErr, got, isErr)
	}
	if _, err := os.Stat(out + ".2"); !os.IsNotExist(err) {
		t.Errorf("a 404 left a file: %v", err)
	}
}
