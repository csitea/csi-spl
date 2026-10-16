package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// serveAsset is the hub's /{doc}/assets/{path} route (internal/hub
// wsdoc_assets.go) in memory: PUT keeps the bytes with their Content-Type,
// GET answers them.
func (h *dtHub) serveAsset(w http.ResponseWriter, r *http.Request, key string, body []byte) {
	if h.assets == nil {
		h.assets = map[string][2]string{}
	}
	switch r.Method {
	case http.MethodPut:
		h.assets[key] = [2]string{r.Header.Get("Content-Type"), string(body)}
		sum := sha256.Sum256(body)
		writeJSON(w, http.StatusOK, map[string]any{"path": key, "sha256": hex.EncodeToString(sum[:]), "bytes": len(body)})
	case http.MethodGet:
		a, ok := h.assets[key]
		if !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found", "detail": "no such picture in this document"})
			return
		}
		w.Header().Set("Content-Type", a[0])
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(a[1])) //nolint:errcheck
	}
}

// TestDocTreeAsset: asset-put sends a picture's bytes under its relative
// path with the type its extension names, and asset-get gives back the same
// bytes, base64 in JSON, with their sha256; the fs flag reaches the hub.
// A path off the layout and a missing --file fail before any hub call.
func TestDocTreeAsset(t *testing.T) {
	h := newDTHub(t)
	t.Setenv("SPOOL_DOCTREE_FS", "repo")
	pic := []byte("\x89PNG\r\n\x1a\n\x00\x01binary\xff\x00bytes")
	f := filepath.Join(t.TempDir(), "flow.png")
	if err := os.WriteFile(f, pic, 0o600); err != nil {
		t.Fatal(err)
	}
	dtOK(t, "asset-put", dtDocID, "guide.assets/01-flow-map.png", "--file", f)
	got := h.assets[dtDocID+"/guide.assets/01-flow-map.png"]
	if got[0] != "image/png" || got[1] != string(pic) {
		t.Fatalf("hub got %q, %d bytes, want image/png and the file's %d bytes", got[0], len(got[1]), len(pic))
	}
	out := dtOK(t, "asset-get", dtDocID, "guide.assets/01-flow-map.png")
	b, err := base64.StdEncoding.DecodeString(out["base64"].(string))
	sum := sha256.Sum256(pic)
	if err != nil || !bytes.Equal(b, pic) || out["sha256"] != hex.EncodeToString(sum[:]) || out["bytes"] != float64(len(pic)) {
		t.Fatalf("asset-get: %v (%v)", out, err)
	}
	for _, fs := range h.fs {
		if fs != "repo" {
			t.Fatalf("a call went without fs=repo: %v", h.fs)
		}
	}
	calls := len(h.calls)
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"asset-put", dtDocID, "img/flow.png", "--file", f}, "not a picture path"},
		{[]string{"asset-put", dtDocID, "guide.assets/01-Flow.png", "--file", f}, "not a picture path"},
		{[]string{"asset-put", dtDocID, "guide.assets/01-flow.png"}, "--file is required"},
		{[]string{"asset-get", dtDocID, "../x.png"}, "not a picture path"},
	} {
		rc, _, errOut := captureRun(t, append([]string{"doctree"}, c.args...))
		if rc == 0 || !strings.Contains(errOut, c.want) {
			t.Errorf("%v: rc %d, stderr %q, want %q", c.args, rc, errOut, c.want)
		}
	}
	if len(h.calls) != calls {
		t.Errorf("a refused verb called the hub: %v", h.calls[calls:])
	}
	if rc, _, errOut := captureRun(t, []string{"doctree", "asset-get", dtDocID, "guide.assets/02-none.png"}); rc == 0 || !strings.Contains(errOut, "404") {
		t.Errorf("unknown picture: rc %d, %q", rc, errOut)
	}
}
