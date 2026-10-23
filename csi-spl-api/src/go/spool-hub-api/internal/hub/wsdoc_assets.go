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
// The bytes of a workspace's picture live in that workspace's own docs
// bucket (spec 114 section 9.2, step 052) at qto-assets/<sha256>; tenant
// "system" (the repo tree, no 052 bucket) and a hub without workspace docs
// stores keep the hub's object store at t/<tenant>/files/<sha256> (owner msg
// 78f4ffd3: Qto's files go to the bucket, the text stays in the database).
// A workspace picture stored before (050) is still read from there until the
// copy action (spec 114 R4) has moved it. The doc root's attrs.assets maps
// the path to that sha256 (store.DocAssetPath checks both). A 050 blob a doc
// names is kept by the file retention sweep and by an attachment's removal
// (fileKept). The type is sniffed from the bytes and must match the path's
// extension; no SVG. Who: as every doctree route, ?fs=repo included.

// docAssetStore is the store side of the asset routes beyond docTreeStore:
// whether any doc of the tenant names a blob (the retention keep).
type docAssetStore interface {
	DocAssetHeld(ctx context.Context, tenant, fileID string) (bool, error)
}

var _ docAssetStore = (*store.Postgres)(nil)

// DocAssetPrefix is where a workspace's Qto pictures sit in its own docs
// store: qto-assets/<sha256>.
const DocAssetPrefix = "qto-assets/"

// docAssetBucket is tenant's own docs store for its pictures; own=false is
// the hub's object store (tenant "system", or no workspace docs stores).
func (s *Server) docAssetBucket(ctx context.Context, tenant string) (st blob.Store, own bool, err error) {
	if tenant == store.SystemTenant || s.o.WorkspaceDocs == nil {
		return nil, false, nil
	}
	st, err = s.o.WorkspaceDocs.Store(ctx, tenant)
	return st, true, err
}

// docAssetBytes is the size of tenant's pictures in its own docs store, for
// the file quota (fileUsage.extra). A store that cannot be listed counts 0
// and is logged: an attachment upload never fails over the docs bucket.
func (s *Server) docAssetBytes(ctx context.Context, tenant string) int64 {
	st, own, err := s.docAssetBucket(ctx, tenant)
	if !own {
		return 0
	}
	var n int64
	if err == nil {
		n, err = st.PrefixBytes(ctx, DocAssetPrefix)
	}
	if err != nil {
		s.o.Log.Warn().Err(err).Str("workspace", tenant).Msg("doc asset bytes; counted 0")
		return 0
	}
	return n
}

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
	if _, own, _ := s.docAssetBucket(r.Context(), c.tenant); !own && s.o.Blob == nil {
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
	st, own, err := s.docAssetBucket(r.Context(), tenant)
	if own {
		if err != nil {
			s.docsUnavailable(w, tenant, "open", err)
			return false
		}
		return s.docAssetKeepOwn(w, r, st, tenant, id, data)
	}
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

// docAssetKeepOwn is docAssetKeep in the workspace's own docs store, at
// qto-assets/<sha256>: content-addressed, so bytes already there are kept
// and their upload time restarts, as the shared store's do: the retention
// sweep (sweepOwnAssets) then keeps them until the doc names them.
func (s *Server) docAssetKeepOwn(w http.ResponseWriter, r *http.Request, st blob.Store, tenant, id string, data []byte) bool {
	key := DocAssetPrefix + id
	if ok, err := st.Exists(r.Context(), key); err == nil && ok {
		if err := st.Touch(context.WithoutCancel(r.Context()), key); err != nil {
			s.o.Log.Warn().Err(err).Str("workspace", tenant).Str("sha256", id).Msg("doc asset touch")
		}
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
	if err := putDoc(context.WithoutCancel(r.Context()), st, key, data); err != nil {
		s.fileUsage.release(tenant, n)
		s.docsUnavailable(w, tenant, "put asset "+id, err)
		return false
	}
	return true
}

// docAssetOpen opens picture id of tenant: its own docs store first, then
// the hub's object store, where a picture stored before spec 114 R3 still
// sits until R4 moves it.
func (s *Server) docAssetOpen(ctx context.Context, tenant, id string) (io.ReadCloser, error) {
	key, err := blob.Key(tenant, id)
	if err != nil {
		return nil, blob.ErrNotFound
	}
	st, own, err := s.docAssetBucket(ctx, tenant)
	if own {
		if err != nil {
			return nil, err
		}
		rc, err := st.Get(ctx, DocAssetPrefix+id)
		if !errors.Is(err, blob.ErrNotFound) || s.o.Blob == nil {
			return rc, err
		}
	}
	return s.o.Blob.Get(ctx, key)
}

func (s *Server) handleDocTreeAssetGet(w http.ResponseWriter, r *http.Request) {
	c, h, path, ok := s.docAsset(w, r, rbac.DocsRead)
	if !ok {
		return
	}
	id := store.DocAssetOf(h.RootAttrs, path)
	if id == "" {
		writeErr(w, http.StatusNotFound, "not_found", "no such picture in this document")
		return
	}
	rc, err := s.docAssetOpen(r.Context(), c.tenant, id)
	if errors.Is(err, blob.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such picture in this document")
		return
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("workspace", c.tenant).Str("sha256", id).Msg("doc asset get")
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
