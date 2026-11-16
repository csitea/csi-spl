package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/cicdlogs"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// ---- 008 cicd-logs stub ----------------------------------------------------------
func cicdOn(t *testing.T, token, allow string, fetch cicdlogs.Fetcher, priv ed25519.PrivateKey) (*env, *cicdlogs.Service) {
	t.Helper()
	stt, err := cicdlogs.ParseSettings(cicdlogs.HubEnv{
		Enabled: true, Env: "lde", Token: token, Allowlist: allow, API: "https://api.example.test", FromBox: "hub", FromID: "CI-0",
	})
	if err != nil {
		t.Fatal(err)
	}
	svc := &cicdlogs.Service{Settings: stt, Fetch: fetch, Signer: priv, Now: time.Now}
	e := newEnv(t, func(o *hub.Options) { o.CICD = svc })
	return e, svc
}

func postCICD(t *testing.T, e *env, tenant, tok string, body any) (*http.Response, []byte) {
	t.Helper()
	raw, _ := json.Marshal(body)
	req, err := http.NewRequest(http.MethodPost, e.url(tenant)+"/v1/cicd-logs", bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	return resp, b
}

func TestCICDLogsFlagOffIs404(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "CLE-07")
	e.pin(tid, a)
	tok := e.uploadToken(tid, a)
	resp, _ := postCICD(t, e, tid, tok, map[string]string{
		"owner": "acme", "repo": "app", "run_id": "1", "task_id": "11111111-1111-4111-8111-111111111111",
		"to": "CLE-07", "to_box": "box-a",
	})
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("flag off: %d", resp.StatusCode)
	}
}

func TestCICDLogsUnconfiguredNote(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(nil)
	e, _ := cicdOn(t, "", "", &cicdlogs.FakeFetcher{}, priv)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "CLE-07")
	e.pin(tid, a)
	e.pinKey(tid, "hub", priv.Public().(ed25519.PublicKey))
	ctx := context.Background()
	sa, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sa)
	tok := e.uploadToken(tid, a)
	resp, body := postCICD(t, e, tid, tok, cicdlogs.Request{
		Owner: "acme", Repo: "app", RunID: "1", TaskID: "11111111-1111-4111-8111-111111111111",
		To: "CLE-07", ToBox: "box-a",
	})
	if resp.StatusCode != 200 {
		t.Fatalf("%d %s", resp.StatusCode, body)
	}
	var out cicdlogs.HTTPResult
	json.Unmarshal(body, &out) //nolint:errcheck
	if out.Configured || out.Delivery == "" {
		t.Fatalf("%+v", out)
	}
	eventually(t, "CI not configured note", func() bool {
		ms := inbox(t, a, "CLE-07")
		return len(ms) == 1 && ms[0].Kind == "note" && ms[0].Body == cicdlogs.NotConfiguredBody && len(ms[0].Files) == 0
	})
}

func TestCICDLogsAllowlistAndFetch(t *testing.T) {
	const tokval = "secret-token-xyz"
	_, priv, _ := ed25519.GenerateKey(nil)
	fetch := &cicdlogs.FakeFetcher{Logs: map[string][]byte{"acme/app/9": []byte("the-log")}}
	e, svc := cicdOn(t, tokval, "", fetch, priv)
	tid, _ := e.tenant()
	svc.Settings.Allow = map[string][]cicdlogs.Pattern{tid: {{Owner: "acme", Repo: "app"}}}
	a := e.box(tid, "box-a", "CLE-07")
	e.pin(tid, a)
	e.pinKey(tid, "hub", priv.Public().(ed25519.PublicKey))
	ctx := context.Background()
	sa, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sa)
	tok := e.uploadToken(tid, a)

	resp, body := postCICD(t, e, tid, tok, cicdlogs.Request{
		Owner: "other", Repo: "repo", RunID: "9", TaskID: "11111111-1111-4111-8111-111111111111",
		To: "CLE-07", ToBox: "box-a",
	})
	if resp.StatusCode != http.StatusForbidden || !bytes.Contains(body, []byte("cicd_forbidden")) {
		t.Fatalf("forbidden: %d %s", resp.StatusCode, body)
	}
	if fetch.LastToken != "" {
		t.Fatal("fetched a forbidden repo")
	}

	resp, body = postCICD(t, e, tid, tok, cicdlogs.Request{
		URL:    "https://ci.example.test/acme/app/actions/runs/9",
		TaskID: "11111111-1111-4111-8111-111111111111", To: "CLE-07", ToBox: "box-a",
	})
	if resp.StatusCode != 200 {
		t.Fatalf("fetch: %d %s", resp.StatusCode, body)
	}
	if bytes.Contains(body, []byte(tokval)) {
		t.Fatal("token in HTTP body")
	}
	eventually(t, "CI log note+file", func() bool {
		ms := inbox(t, a, "CLE-07")
		return len(ms) == 1 && ms[0].Kind == "note" && strings.Contains(ms[0].Body, "CI run acme/app #9") && len(ms[0].Files) == 1
	})
	got := inbox(t, a, "CLE-07")[0]
	if strings.Contains(got.Body, tokval) {
		t.Fatal("token in chat body")
	}
	dest := filepath.Join(t.TempDir(), "log")
	if _, err := action.Get(a.cfg, got.Files[0].FileID, dest, false); err != nil {
		t.Fatal(err)
	}
	if raw, _ := os.ReadFile(dest); string(raw) != "the-log" {
		t.Fatalf("file %q", raw)
	}
}

func TestCICDLogsCrossTenantAllowlist(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(nil)
	fetch := &cicdlogs.FakeFetcher{Logs: map[string][]byte{"acme/app/1": []byte("x")}}
	e, svc := cicdOn(t, "tok", "", fetch, priv)
	aID, _ := e.tenant()
	bID, _ := e.tenant()
	svc.Settings.Allow = map[string][]cicdlogs.Pattern{aID: {{Owner: "acme", Repo: "app"}}}
	boxB := e.box(bID, "box-a", "CLE-07")
	e.pin(bID, boxB)
	e.pinKey(bID, "hub", priv.Public().(ed25519.PublicKey))
	tokB := e.uploadToken(bID, boxB)
	resp, _ := postCICD(t, e, bID, tokB, cicdlogs.Request{
		Owner: "acme", Repo: "app", RunID: "1", TaskID: "11111111-1111-4111-8111-111111111111",
		To: "CLE-07", ToBox: "box-a",
	})
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("tenant B used tenant A allowlist: %d", resp.StatusCode)
	}
}

func TestCICDLogsDoorAndWrongBox(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(nil)
	e, _ := cicdOn(t, "tok", "", &cicdlogs.FakeFetcher{}, priv)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "CLE-07")
	b := e.box(tid, "box-b", "GRK-03")
	e.pin(tid, a)
	e.pin(tid, b)
	resp, _ := postCICD(t, e, tid, "", cicdlogs.Request{To: "CLE-07", ToBox: "box-a", TaskID: "11111111-1111-4111-8111-111111111111", Owner: "acme", Repo: "app", RunID: "1"})
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("anon: %d", resp.StatusCode)
	}
	tok := e.uploadToken(tid, a)
	resp, _ = postCICD(t, e, tid, tok, cicdlogs.Request{
		Owner: "acme", Repo: "app", RunID: "1", TaskID: "11111111-1111-4111-8111-111111111111",
		To: "GRK-03", ToBox: "box-b",
	})
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("other box: %d", resp.StatusCode)
	}
}
