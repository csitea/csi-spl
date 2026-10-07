package hub_test

import (
	"encoding/json"
	"io"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// GET /v1/openapi.json (spec 104 §4.2, T003): the embedded reference, served
// to a signed-in member with info.version = /version. No session: 401 view_door
// from humanTenant on a live hub (FR-004); 403 forbidden on this view-door-off test hub.

func getOpenAPI(t *testing.T, e *env, tid, path, as string) (int, []byte, http.Header) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, e.url(tid)+path, nil)
	if as != "" {
		req.Header.Set(memberHeader, as)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("GET %s: %v", path, err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b, resp.Header
}

func TestOpenAPIServedToMember(t *testing.T) {
	e := rbacEnv(t, func(o *hub.Options) { o.Version = "9.8.7" })
	tid, _ := e.tenant()
	hum := seat(t, e, tid, rbac.Tester)

	code, body, h := getOpenAPI(t, e, tid, "/v1/openapi.json", hum)
	if code != http.StatusOK {
		t.Fatalf("member: %d %s", code, body)
	}
	if ct, cc := h.Get("Content-Type"), h.Get("Cache-Control"); ct != "application/json; charset=utf-8" || cc != "private, no-cache" {
		t.Fatalf("headers: Content-Type %q Cache-Control %q", ct, cc)
	}
	var doc struct {
		OpenAPI string `json:"openapi"`
		Info    struct {
			Version string `json:"version"`
		} `json:"info"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		t.Fatalf("body does not parse: %v", err)
	}
	_, vb, _ := getOpenAPI(t, e, tid, "/version", "")
	var v struct {
		Version string `json:"version"`
	}
	if err := json.Unmarshal(vb, &v); err != nil || v.Version == "" {
		t.Fatalf("/version: %v %s", err, vb)
	}
	if doc.OpenAPI != "3.0.3" || doc.Info.Version != v.Version {
		t.Fatalf("openapi %q info.version %q, want 3.0.3 and /version %q", doc.OpenAPI, doc.Info.Version, v.Version)
	}
}

func TestOpenAPINoSessionForbidden(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	code, body, _ := getOpenAPI(t, e, tid, "/v1/openapi.json", "")
	var b struct{ Error, Detail string }
	if err := json.Unmarshal(body, &b); err != nil || code != http.StatusForbidden || b.Error != "forbidden" || b.Detail == "" {
		t.Fatalf("no session: %d %s, want 403 {error: forbidden, detail}", code, body)
	}
}

// CONTROL: the real hub sources with the operation removed from the file fail
// the route gate, so the route cannot ship undocumented.
func TestOpenAPIServeRouteNeedsItsOperation(t *testing.T) {
	var doc map[string]any
	if err := json.Unmarshal(openapiJSON, &doc); err != nil {
		t.Fatal(err)
	}
	delete(doc["paths"].(map[string]any), "/v1/openapi.json")
	spec, _ := json.Marshal(doc)
	fset, files, tab := parseHub(t)
	_, errs := gate(fset, files, tab, spec)
	wantErr(t, errs, "route without an openapi.json operation: GET /v1/openapi.json")
}
