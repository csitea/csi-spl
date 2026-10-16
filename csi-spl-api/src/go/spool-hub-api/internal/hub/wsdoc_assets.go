package hub

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A document's pictures under their md-relative path (gap G6, SPL-2201;
// spec 137 unified-fs.md section 7, owner layout A: `foo.md` ->
// `foo.assets/01-flow-map.png`, the link text the same in the repo and in
// Qto):
//
//	PUT /v1/workspace/doctree/{doc}/assets/{path...}  the bytes (Content-Type image/png|jpeg|gif|webp)
//	GET /v1/workspace/doctree/{doc}/assets/{path...}  one picture
//
// The bytes live in the hub's object store at t/<tenant>/files/<sha256>
// (owner msg 78f4ffd3: Qto's files go to the bucket, the text stays in the
// database), tenant "system" for the repo tree; the doc root's attrs.assets
// maps the path to that sha256 (store.DocAssetPath checks both). A blob a doc
// names is kept by the file retention sweep and by an attachment's removal
// (fileKept). The type is sniffed from the bytes and must match the path's
// extension; no SVG. Who: as every doctree route, ?fs=repo included.

// docAssetStore is the store side of the asset routes beyond docTreeStore:
// whether any doc of the tenant names a blob (the retention keep).
type docAssetStore interface {
	DocAssetHeld(ctx context.Context, tenant, fileID string) (bool, error)
}

var _ docAssetStore = (*store.Postgres)(nil)

// docAssetPutTries bounds the retries of the root's attrs edit when another
// write moved the root's rev between the read and the edit.
const docAssetPutTries = 3

// docAsset resolves the caller, the doc (its tenant's, else 404), the path
// and the object store, or writes the refusal.
func (s *Server) docAsset(w http.ResponseWriter, r *http.Request, perm string) (docTreeCall, store.DocHead, string, bool) {
	c, ok := s.docTreeCaller(w, r, perm)
	if !ok {
		return c, store.DocHead{}, "", false
	}
	if s.o.Blob == nil {
		writeErr(w, http.StatusNotFound, "files_off", "this hub has no object store")
		return c, store.DocHead{}, "", false
	}
	path := r.PathValue("path")
	if !store.DocAssetPath(path) {
		writeErr(w, http.StatusBadRequest, "bad_asset_path",
			"an asset path is <doc>.assets/NN-name.ext: two digits, a dash, a lower-case name, png, jpg, jpeg, gif or webp")
		return c, store.DocHead{}, "", false
	}
	h, err := c.st.DocHeadOf(r.Context(), c.tenant, r.PathValue("doc"))
	if err != nil {
		docTreeFail(w, err)
		return c, store.DocHead{}, "", false
	}
	return c, h, path, true
}

func (s *Server) handleDocTreeAssetPut(w http.ResponseWriter, r *http.Request) {
	c, h, path, ok := s.docAsset(w, r, rbac.DocsWrite)
	if !ok {
		return
	}
	data, err := readAllCapped(w, r, DocTreeImageMax)
	var tooBig *http.MaxBytesError
	if errors.As(err, &tooBig) {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", fmt.Sprintf("a picture is at most %d bytes", DocTreeImageMax))
		return
	}
	if err != nil || len(data) == 0 {
		writeErr(w, http.StatusBadRequest, "bad_body", "the picture bytes did not arrive")
		return
	}
	if !docAssetTypeOK(path, data, r.Header.Get("Content-Type")) {
		writeErr(w, http.StatusUnsupportedMediaType, "bad_image",
			"a picture is png, jpeg, gif or webp, its bytes, its Content-Type and its path's extension the same type")
		return
	}
	sum := sha256.Sum256(data)
	id := hex.EncodeToString(sum[:])
	if !s.docAssetKeep(w, r, c.tenant, id, data) {
		return
	}
	for try := 1; ; try++ {
		attrs, err := docAssetAttrs(h.RootAttrs, path, id)
		if err == nil {
			_, err = c.st.DocItemUpdateField(r.Context(), c.tenant, h.ID, h.RootID, "attrs", attrs, h.RootRev)
		}
		if err == nil {
			break
		}
		if !errors.Is(err, store.ErrDocStale) || try == docAssetPutTries {
			docTreeFail(w, err)
			return
		}
		if h, err = c.st.DocHeadOf(r.Context(), c.tenant, h.ID); err != nil {
			docTreeFail(w, err)
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"path": path, "sha256": id, "bytes": len(data)})
}

// docAssetKeep stores the bytes at the tenant's content key: a new blob
// takes the tenant's file quota, one already there restarts its upload time.
// false has written the refusal.
func (s *Server) docAssetKeep(w http.ResponseWriter, r *http.Request, tenant, id string, data []byte) bool {
	key, err := blob.Key(tenant, id)
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "content key", err)
		return false
	}
	bg := context.WithoutCancel(r.Context())
	if s.blobExists(r.Context(), key) {
		s.touchUpload(bg, key)
		return true
	}
	n := int64(len(data))
	fits, err := s.fileUsage.reserve(r.Context(), s.o.Blob, s.quota(), tenant, n, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("blob prefix bytes")
		writeErr(w, http.StatusServiceUnavailable, "internal", "object store unavailable")
		return false
	}
	if !fits {
		writeQuota(w, "stored file bytes exceed the tenant quota")
		return false
	}
	if err := s.o.Blob.Put(bg, key, data); err != nil {
		s.fileUsage.release(tenant, n)
		s.o.Log.Error().Err(err).Msg("blob put")
		writeErr(w, http.StatusServiceUnavailable, "internal", "object store unavailable")
		return false
	}
	return true
}

func (s *Server) handleDocTreeAssetGet(w http.ResponseWriter, r *http.Request) {
	c, h, path, ok := s.docAsset(w, r, rbac.DocsRead)
	if !ok {
		return
	}
	id := store.DocAssetOf(h.RootAttrs, path)
	key, err := blob.Key(c.tenant, id)
	if id == "" || err != nil {
		writeErr(w, http.StatusNotFound, "not_found", "no such picture in this document")
		return
	}
	rc, err := s.o.Blob.Get(r.Context(), key)
	if errors.Is(err, blob.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such picture in this document")
		return
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("key", key).Msg("blob get")
		writeErr(w, http.StatusServiceUnavailable, "internal", "object store unavailable")
		return
	}
	defer rc.Close()
	docHeaders(w.Header(), docAssetType[docAssetExt(path)])
	w.Header().Set("ETag", `"`+id+`"`) // the path may be uploaded again with other bytes
	w.WriteHeader(http.StatusOK)
	io.Copy(w, rc) //nolint:errcheck
}

// docAssetType is a picture's type by its path's extension.
var docAssetType = map[string]string{"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"}

func docAssetExt(path string) string { return path[strings.LastIndexByte(path, '.')+1:] }

// docAssetTypeOK: the sniffed type, the sent Content-Type and the path's
// extension name one allowed picture type.
func docAssetTypeOK(path string, data []byte, sent string) bool {
	want := docAssetType[docAssetExt(path)]
	sent, _, _ = strings.Cut(sent, ";")
	return want != "" && http.DetectContentType(data) == want && strings.TrimSpace(sent) == want
}

// docAssetAttrs is the root's attrs with attrs.assets[path] = id.
func docAssetAttrs(raw json.RawMessage, path, id string) (string, error) {
	m := map[string]any{}
	if len(bytes.TrimSpace(raw)) > 0 {
		if err := json.Unmarshal(raw, &m); err != nil {
			return "", err
		}
	}
	assets, _ := m["assets"].(map[string]any)
	next := map[string]any{}
	for k, v := range assets {
		next[k] = v
	}
	next[path] = id
	m["assets"] = next
	b, err := json.Marshal(m)
	return string(b), err
}

// fileKept reports whether a blob of tenant must stay although no message
// carries it: a doc's attrs.assets names it. A store without docs keeps none.
func (s *Server) fileKept(ctx context.Context, tenant, fileID string) (bool, error) {
	d, ok := s.o.Store.(docAssetStore)
	if !ok {
		return false, nil
	}
	return d.DocAssetHeld(ctx, tenant, fileID)
}
