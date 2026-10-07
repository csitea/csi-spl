package hub

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"net/http"
	"sync"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// The API reference (spec 104 §4.2): openapi.json, embedded at build time,
// served to a signed-in member at GET /v1/openapi.json with info.version set
// to the running hub version (/version). Same door as the Docs section.

//go:embed openapi.json
var openapiSpec []byte

// openapiByVersion caches the stamped file per hub version ([]byte); a
// failed stamp is not cached (it cannot happen past openapi_routes_test.go).
var openapiByVersion sync.Map

func (s *Server) routeOpenAPI(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/openapi.json", s.handleOpenAPI)
	mux.HandleFunc("OPTIONS /v1/openapi.json", s.docsPreflight)
}

func (s *Server) handleOpenAPI(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	_, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	if hum == "" {
		writeForbidden(w, rbac.TopicsRead, "the API reference needs a signed-in member session")
		return
	}
	body, err := openapiFor(s.o.Version)
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "the API reference does not parse", err)
		return
	}
	h := w.Header()
	h.Set("Content-Type", "application/json; charset=utf-8")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Cache-Control", "private, no-cache") // a deploy changes it: revalidate
	h.Add("Vary", "Cookie")
	h.Add("Vary", "Authorization")
	w.WriteHeader(http.StatusOK)
	w.Write(body) //nolint:errcheck
}

// openapiFor is the embedded file stamped with version, cached.
func openapiFor(version string) ([]byte, error) {
	if b, ok := openapiByVersion.Load(version); ok {
		return b.([]byte), nil
	}
	b, err := stampOpenAPIVersion(openapiSpec, version)
	if err != nil {
		return nil, err
	}
	openapiByVersion.Store(version, b)
	return b, nil
}

// stampOpenAPIVersion returns raw with info.version = version, numbers kept
// as written. An empty version leaves the file's own.
func stampOpenAPIVersion(raw []byte, version string) ([]byte, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var doc map[string]any
	if err := dec.Decode(&doc); err != nil {
		return nil, err
	}
	if info, ok := doc["info"].(map[string]any); ok && version != "" {
		info["version"] = version
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(doc); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
