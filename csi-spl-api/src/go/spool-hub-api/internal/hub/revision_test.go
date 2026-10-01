package hub_test

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// revisionOf reads GET /v1/wui/revision from the WUI's origin.
func revisionOf(t *testing.T, e *env) (string, *http.Response) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, "http://t1"+domain+"/v1/wui/revision", nil)
	req.Header.Set("Origin", wuiOrigin)
	res, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("GET /v1/wui/revision: %v", err)
	}
	defer res.Body.Close()
	var out struct {
		Revision string `json:"revision"`
	}
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return out.Revision, res
}

// Bug B (4ecb4b0d): a browser can only tell that its socket sits on a retired
// Cloud Run revision if the welcome names the socket's revision and a fresh
// request names the serving one. Both are the process's Options.Revision.
func TestWUIWelcomeNamesRevision(t *testing.T) {
	const rev = "csi-spl-hub-x-00042-abc"
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.Revision = rev
	})
	tid, _ := e.tenant()
	if c := dialWUI(t, e, tid, "HUM-1"); c.w.Revision != rev {
		t.Fatalf("welcome.revision = %q, want %q", c.w.Revision, rev)
	}
	got, res := revisionOf(t, e)
	if got != rev {
		t.Fatalf("GET /v1/wui/revision = %q, want %q", got, rev)
	}
	if res.Header.Get("Access-Control-Allow-Origin") != wuiOrigin {
		t.Fatalf("the WUI origin cannot read it: ACAO %q", res.Header.Get("Access-Control-Allow-Origin"))
	}
	if res.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("a cached answer would hide a deploy: Cache-Control %q", res.Header.Get("Cache-Control"))
	}
}

// CONTROL: with no $K_REVISION each process names itself, so two processes
// (a restart) never read as the same one, and the welcome agrees with GET.
func TestWUIRevisionPerProcessWhenUnset(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()
	a, _ := revisionOf(t, e)
	if c := dialWUI(t, e, tid, "HUM-1"); a == "" || c.w.Revision != a {
		t.Fatalf("welcome.revision %q, GET %q: want one non-empty id per process", c.w.Revision, a)
	}
	if b, _ := revisionOf(t, wuiEnv(t)); b == "" || b == a {
		t.Fatalf("per-process revisions %q and %q: want two distinct ids", a, b)
	}
}
