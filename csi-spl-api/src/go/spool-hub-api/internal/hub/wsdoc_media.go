package hub

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"regexp"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The images of the workspace documents (spec 113 T006 follow-up, owner go
// 33ced864): an image item's attrs.img_http_path points here.
//
//	POST /v1/workspace/doctree/{doc}/images         the bytes (Content-Type image/png|jpeg|gif|webp)
//	GET  /v1/workspace/doctree/{doc}/images/{name}  one image
//
// The bytes live in the workspace's own docs store (spec 075, one bucket per
// workspace) at .doctree/<doc>/<sha256>.<ext>: content-addressed, so a
// re-upload is the same name and a served image never changes. The hidden
// prefix keeps them out of the 075 tree and its routes (ValidDocsPath). The
// type is sniffed from the bytes and must match the header; no SVG (it can
// carry script). Who: as every doctree route; the doc must be the caller's
// tenant's (DocHeadOf), so another tenant's doc id is a 404 here too.

// DocTreeImageMax caps one image.
const DocTreeImageMax = 5 << 20

// docTreeImageExt is the allowed image types and their stored extension.
var docTreeImageExt = map[string]string{
	"image/png":  "png",
	"image/jpeg": "jpg",
	"image/gif":  "gif",
	"image/webp": "webp",
}

var docTreeImageType = map[string]string{"png": "image/png", "jpg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"}

var docTreeImageName = regexp.MustCompile(`^[0-9a-f]{64}\.(png|jpg|gif|webp)$`)

// docTreeImageKey is the store key of one image of doc.
func docTreeImageKey(doc, name string) string { return ".doctree/" + doc + "/" + name }

// docTreeMedia resolves the caller, the doc (its tenant's, else 404) and
// the workspace's docs store, or writes the refusal.
func (s *Server) docTreeMedia(w http.ResponseWriter, r *http.Request, perm string) (string, blob.Store, bool) {
	c, ok := s.docTreeCaller(w, r, perm)
	if !ok {
		return "", nil, false
	}
	if s.o.WorkspaceDocs == nil {
		writeErr(w, http.StatusNotFound, "workspace_docs_off", "this hub has no workspace docs store")
		return "", nil, false
	}
	h, err := c.st.DocHeadOf(r.Context(), c.tenant, r.PathValue("doc"))
	if err != nil {
		docTreeFail(w, err)
		return "", nil, false
	}
	st, err := s.o.WorkspaceDocs.Store(r.Context(), c.tenant)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", c.tenant).Msg("workspace docs store")
		writeErr(w, http.StatusServiceUnavailable, "internal", "workspace docs store unavailable")
		return "", nil, false
	}
	return h.ID, st, true
}

func (s *Server) handleDocTreeImagePut(w http.ResponseWriter, r *http.Request) {
	doc, st, ok := s.docTreeMedia(w, r, rbac.DocsWrite)
	if !ok {
		return
	}
	data, err := readAllCapped(w, r, DocTreeImageMax)
	var tooBig *http.MaxBytesError
	if errors.As(err, &tooBig) {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", fmt.Sprintf("an image is at most %d bytes", DocTreeImageMax))
		return
	}
	if err != nil || len(data) == 0 {
		writeErr(w, http.StatusBadRequest, "bad_body", "the image bytes did not arrive")
		return
	}
	ext, ok := docTreeImageExt[http.DetectContentType(data)]
	sent, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if !ok || docTreeImageType[ext] != sent {
		writeErr(w, http.StatusUnsupportedMediaType, "bad_image", "an image is png, jpeg, gif or webp, sent with its own Content-Type")
		return
	}
	sum := sha256.Sum256(data)
	name := hex.EncodeToString(sum[:]) + "." + ext
	if err := putDoc(context.WithoutCancel(r.Context()), st, docTreeImageKey(doc, name), data); err != nil {
		writeErr(w, http.StatusServiceUnavailable, "internal", "workspace docs store unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"name": name, "bytes": len(data),
		"img_http_path": store.DocImagePathPrefix + doc + "/images/" + name})
}

func (s *Server) handleDocTreeImageGet(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	doc, st, ok := s.docTreeMedia(w, r, rbac.DocsRead)
	if !ok {
		return
	}
	m := docTreeImageName.FindStringSubmatch(name)
	if m == nil {
		writeErr(w, http.StatusNotFound, "not_found", "no such image")
		return
	}
	rc, err := st.Get(r.Context(), docTreeImageKey(doc, name))
	if errors.Is(err, blob.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such image")
		return
	}
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "internal", "workspace docs store unavailable")
		return
	}
	defer rc.Close()
	docHeaders(w.Header(), docTreeImageType[m[1]])
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable") // content-addressed
	w.WriteHeader(http.StatusOK)
	io.Copy(w, rc) //nolint:errcheck
}
