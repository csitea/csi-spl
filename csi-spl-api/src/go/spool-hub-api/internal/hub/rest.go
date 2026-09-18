package hub

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/coder/websocket"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// POST /v1/files: raw bytes with the WS-issued upload token (OQ-10).
func (s *Server) handlePutFile(w http.ResponseWriter, r *http.Request) {
	t, err := s.tenantOf(r)
	if err != nil {
		writeErr(w, http.StatusNotFound, "unknown_tenant", "no tenant for this host")
		return
	}
	if _, ok := s.bearer(r, t.ID); !ok {
		writeErr(w, http.StatusUnauthorized, "door", "a valid upload token from the WS hello is required")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, msg.MaxFileBytes))
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			writeErr(w, http.StatusRequestEntityTooLarge, "limit_file", "file exceeds the per-file limit")
			return
		}
		writeErr(w, http.StatusBadRequest, "bad_json", "could not read the body")
		return
	}
	sum := sha256.Sum256(body)
	id := hex.EncodeToString(sum[:])
	key, _ := blob.Key(t.ID, id)
	if err := s.o.Blob.Put(r.Context(), key, body); err != nil {
		s.o.Log.Error().Err(err).Msg("blob put")
		writeErr(w, http.StatusServiceUnavailable, "internal", "object store unavailable")
		return
	}
	writeJSON(w, http.StatusCreated, wire.FileResult{FileID: id, SHA256: id, Bytes: int64(len(body))})
}

// GET /v1/files/{file_id}: tenant-scoped capability; another tenant's id is 404.
func (s *Server) handleGetFile(w http.ResponseWriter, r *http.Request) {
	t, err := s.tenantOf(r)
	if err != nil {
		writeErr(w, http.StatusNotFound, "unknown_tenant", "no tenant for this host")
		return
	}
	key, err := blob.Key(t.ID, r.PathValue("file_id"))
	if err != nil {
		writeErr(w, http.StatusNotFound, "not_found", "no such file")
		return
	}
	rc, err := s.o.Blob.Get(r.Context(), key)
	if errors.Is(err, blob.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such file")
		return
	}
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "internal", "object store unavailable")
		return
	}
	defer rc.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.WriteHeader(http.StatusOK)
	io.Copy(w, rc) //nolint:errcheck
}

// GET /v1/pins: the tenant's active box pubkeys (authorized_keys sync).
func (s *Server) handleListPins(w http.ResponseWriter, r *http.Request) {
	t, err := s.tenantOf(r)
	if err != nil {
		writeErr(w, http.StatusNotFound, "unknown_tenant", "no tenant for this host")
		return
	}
	if _, ok := s.bearer(r, t.ID); !ok {
		writeErr(w, http.StatusUnauthorized, "door", "a valid upload token from the WS hello is required")
		return
	}
	pins, err := s.o.Store.ListPins(r.Context(), t.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "pins unavailable")
		return
	}
	out := wire.PinList{Pins: []wire.PinEntry{}}
	for _, p := range pins {
		out.Pins = append(out.Pins, wire.PinEntry{BoxID: p.BoxID, PubKey: base64.StdEncoding.EncodeToString(p.PubKey)})
	}
	writeJSON(w, http.StatusOK, out)
}

// POST /v1/pins: pin a box pubkey, signed by the tenant root key.
func (s *Server) handlePin(w http.ResponseWriter, r *http.Request) {
	t, err := s.tenantOf(r)
	if err != nil {
		writeErr(w, http.StatusNotFound, "unknown_tenant", "no tenant for this host")
		return
	}
	var req wire.PinRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 8<<10)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "pin body does not parse")
		return
	}
	pub, err := base64.StdEncoding.DecodeString(req.PubKey)
	if err != nil || len(pub) != ed25519.PublicKeySize || !msg.ValidBoxID(req.BoxID) {
		writeErr(w, http.StatusBadRequest, "bad_json", "box_id or pubkey is malformed")
		return
	}
	payload, _ := wire.PinPayload(req.BoxID, req.PubKey, req.TS, req.Force)
	if !s.skewOK(req.TS) || verify(t.RootPubKey, payload, req.Sig) != nil {
		writeErr(w, http.StatusBadRequest, "bad_sig", "tenant root signature does not verify")
		return
	}
	err = s.o.Store.PutPin(r.Context(), t.ID, req.BoxID, ed25519.PublicKey(pub), req.Force, s.o.Now())
	if errors.Is(err, store.ErrConflict) {
		writeErr(w, http.StatusConflict, "pin_conflict", "box_id is pinned to a different key (use force)")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "pin not stored")
		return
	}
	writeJSON(w, http.StatusOK, wire.PinEntry{BoxID: req.BoxID, PubKey: req.PubKey})
}

// DELETE /v1/pins/{box_id}: revoke, signed by the tenant root key. A live
// session of the revoked box is closed.
func (s *Server) handleRevoke(w http.ResponseWriter, r *http.Request) {
	t, err := s.tenantOf(r)
	if err != nil {
		writeErr(w, http.StatusNotFound, "unknown_tenant", "no tenant for this host")
		return
	}
	var req wire.RevokeRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 8<<10)).Decode(&req); err != nil || req.BoxID != r.PathValue("box_id") {
		writeErr(w, http.StatusBadRequest, "bad_json", "revoke body does not parse or names another box")
		return
	}
	payload, _ := wire.RevokePayload(req.BoxID, req.TS)
	if !s.skewOK(req.TS) || verify(t.RootPubKey, payload, req.Sig) != nil {
		writeErr(w, http.StatusBadRequest, "bad_sig", "tenant root signature does not verify")
		return
	}
	if err := s.o.Store.RevokePin(r.Context(), t.ID, req.BoxID, s.o.Now()); errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such pin")
		return
	} else if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "revoke not stored")
		return
	}
	s.mu.Lock()
	var victims []*session
	for x := range s.sessions {
		if x.tenant == t.ID && x.box == req.BoxID {
			victims = append(victims, x)
		}
	}
	s.mu.Unlock()
	for _, x := range victims {
		go x.close(websocket.StatusCode(wire.CloseUnauthorized), "unpinned_box")
	}
	writeJSON(w, http.StatusOK, map[string]string{"box_id": req.BoxID, "revoked": "true"})
}

func verify(pub ed25519.PublicKey, payload []byte, sig string) error {
	if len(pub) != ed25519.PublicKeySize {
		return sign.ErrVerify
	}
	return sign.Verify(pub, payload, sig)
}
