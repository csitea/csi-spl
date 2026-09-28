package hub

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/coder/websocket"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/cicdlogs"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// POST /v1/files: raw bytes with the WS-issued upload token (OQ-10).
func (s *Server) handlePutFile(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)             // browser uploads from the WUI origin (wui-live-ws.md §5)
	t, _, ok := s.tokenTenant(w, r) // specs/026: the token's tenant
	if !ok {
		return
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return
	}
	// 027 T020: the body streams to a scratch object while it is hashed, so
	// the hub holds a few MiB per upload, not the file. Refusals that need no
	// byte (size, quota by Content-Length) answer before reading any.
	if r.ContentLength > msg.MaxFileBytes {
		writeErr(w, http.StatusRequestEntityTooLarge, "limit_file", "file exceeds the per-file limit")
		return
	}
	if r.ContentLength > 0 {
		over, err := s.fileUsage.over(r.Context(), s.o.Blob, s.quota(), t.ID, r.ContentLength, s.o.Now())
		if err != nil {
			s.o.Log.Error().Err(err).Msg("blob prefix bytes")
			writeErr(w, http.StatusServiceUnavailable, "internal", "object store unavailable")
			return
		}
		if over {
			writeQuota(w, "stored file bytes exceed the tenant quota")
			return
		}
	}
	// Cleanup must outlive a client that went away mid-body.
	bg := context.WithoutCancel(r.Context())
	tmp := blob.TmpKey(t.ID, uid.Hex(16))
	h := sha256.New()
	body := &readErr{r: http.MaxBytesReader(w, r.Body, msg.MaxFileBytes)}
	n, err := s.o.Blob.PutReader(r.Context(), tmp, io.TeeReader(body, h))
	if err != nil {
		s.o.Blob.Delete(bg, tmp) //nolint:errcheck // PutReader leaves nothing; belt and braces
		var mbe *http.MaxBytesError
		switch {
		case errors.As(body.err, &mbe):
			writeErr(w, http.StatusRequestEntityTooLarge, "limit_file", "file exceeds the per-file limit")
		case body.err != nil:
			writeErr(w, http.StatusBadRequest, "bad_json", "could not read the body")
		default:
			s.o.Log.Error().Err(err).Msg("blob put")
			writeErr(w, http.StatusServiceUnavailable, "internal", "object store unavailable")
		}
		return
	}
	id := hex.EncodeToString(h.Sum(nil))
	key, _ := blob.Key(t.ID, id)
	exists, _ := s.o.Blob.Exists(r.Context(), key)
	if exists {
		s.o.Blob.Delete(bg, tmp) //nolint:errcheck
		s.touchUpload(bg, key)
		writeJSON(w, http.StatusCreated, wire.FileResult{FileID: id, SHA256: id, Bytes: n})
		return
	}
	fits, err := s.fileUsage.reserve(r.Context(), s.o.Blob, s.quota(), t.ID, n, s.o.Now())
	if err != nil {
		s.o.Blob.Delete(bg, tmp) //nolint:errcheck
		s.o.Log.Error().Err(err).Msg("blob prefix bytes")
		writeErr(w, http.StatusServiceUnavailable, "internal", "object store unavailable")
		return
	}
	if !fits {
		s.o.Blob.Delete(bg, tmp) //nolint:errcheck
		writeQuota(w, "stored file bytes exceed the tenant quota")
		return
	}
	existed, err := s.o.Blob.Promote(bg, tmp, key)
	if err != nil || existed {
		s.fileUsage.release(t.ID, n)
	}
	if err == nil && existed {
		s.touchUpload(bg, key)
	}
	if err != nil {
		s.o.Blob.Delete(bg, tmp) //nolint:errcheck
		s.o.Log.Error().Err(err).Msg("blob promote")
		writeErr(w, http.StatusServiceUnavailable, "internal", "object store unavailable")
		return
	}
	writeJSON(w, http.StatusCreated, wire.FileResult{FileID: id, SHA256: id, Bytes: n})
}

// touchUpload restarts the upload grace of bytes the store already held
// (content-addressed: the object was not rewritten). Best effort: without it
// the uploader cannot fetch back a blob no message carries any more, which is
// no leak, and the send itself does not need it.
func (s *Server) touchUpload(ctx context.Context, key string) {
	if err := s.o.Blob.Touch(ctx, key); err != nil {
		s.o.Log.Warn().Err(err).Msg("blob touch")
	}
}

// readErr remembers the body's read error, so a failed PutReader can tell a
// client fault (413 / 400) from an object-store fault (503).
type readErr struct {
	r   io.Reader
	err error
}

func (e *readErr) Read(p []byte) (int, error) {
	n, err := e.r.Read(p)
	if err != nil && err != io.EOF {
		e.err = err
	}
	return n, err
}

// GET /v1/files/{file_id}: needs a caller credential of the Host tenant (017
// FR-SEC-002): a box/box-wui upload token or a member session. The file_id
// alone is not a capability. Checked before the blob lookup, so an anonymous
// caller learns nothing about which ids exist; another tenant's id is 404.
func (s *Server) handleGetFile(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r) // the viewer downloads attachments cross-origin (FR-021)
	t, ok := s.fileReader(w, r)
	if !ok {
		return
	}
	fileID := r.PathValue("file_id")
	// The read door on the attachment (rdb 0028 + 0030, privacy.go). Until
	// this, a file was scoped to the TENANT and nothing else, so a signed-in
	// member who knew a file_id could fetch it out of a channel they were
	// never in, or out of another member's DM. 404, as everywhere else in the
	// door: "not yours" and "no such file" must not be distinguishable.
	switch may, err := s.mayReadFile(r, t.ID, fileID); {
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "file lookup failed")
		return
	case !may:
		writeErr(w, http.StatusNotFound, "not_found", "no such file")
		return
	}
	key, err := blob.Key(t.ID, fileID)
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
	h := w.Header()
	h.Set("Content-Type", "application/octet-stream")
	// Bytes a member uploaded, served from the API origin that holds the
	// session cookie (CLE-34986): never sniffed into HTML or script, never
	// rendered as a page when opened directly - a download, in a sandbox.
	// None of the three touches an <img> or a fetch(), which is how the WUI
	// reads them.
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Content-Disposition", "attachment")
	h.Set("Content-Security-Policy", "sandbox; default-src 'none'")
	// The file_id IS the sha256 of the bytes, so they never change under this
	// URL: the browser keeps them instead of re-downloading an attached
	// picture on every page (CLE-34985, 100-650 ms each, up to 8x a page on
	// dev). private: never a shared cache. Vary on the credentials: a cached
	// copy answers only the same session that passed the read door above, so
	// a sign-out or another member on the same browser goes back through it.
	// A member removed from the channel keeps what this browser already
	// holds for at most fileCacheMaxAge - bytes they had already downloaded.
	h.Set("Cache-Control", "private, max-age="+strconv.Itoa(int(fileCacheMaxAge.Seconds()))+", immutable")
	h.Add("Vary", "Cookie")
	h.Add("Vary", "Authorization")
	w.WriteHeader(http.StatusOK)
	io.Copy(w, rc) //nolint:errcheck
}

// fileCacheMaxAge bounds how long a browser keeps a downloaded attachment.
const fileCacheMaxAge = 24 * time.Hour

// fileReader resolves a file read (specs/026 §2): an upload token reads its
// own tenant (a pinned box or box-wui), anything else is a browser read of
// the session's active tenant (or, view door off in lde, the Host's).
func (s *Server) fileReader(w http.ResponseWriter, r *http.Request) (store.Tenant, bool) {
	if strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
		t, _, ok := s.tokenTenant(w, r)
		return t, ok
	}
	t, _, ok := s.humanTenant(w, r)
	return t, ok
}

// mayReadFile: an attachment is exactly as private as the messages carrying
// it (rdb 0028 + 0030). Which messages those are depends on who is asking.
//
//   - a BOX, by its upload token: a message with that box at either end, or
//     one delivered to it (a channel post is addressed to box-wui and reaches
//     member boxes as delivery rows).
//   - box-wui, the virtual browser audience, is NOT a principal here. A
//     browser holds a box-wui upload token from its `welcome` frame, and the
//     WUI downloads with its session cookie, never that token - so honouring
//     it would hand every member a key that walks straight past the human
//     door it is standing next to.
//   - a HUMAN session: the 0028 rule, through the channels it belongs to and
//     the DMs it is an end of.
//   - no human at all: the door-off lde rig, which filters nothing, exactly
//     as the rest of privacy.go does.
func (s *Server) mayReadFile(r *http.Request, tenant, fileID string) (bool, error) {
	if fileID == "" {
		return false, nil
	}
	if strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
		_, box, ok := s.bearerAny(r)
		if !ok || box == WUIBox {
			return false, nil
		}
		return s.fileReadableBy(r.Context(), tenant, fileID, box, "")
	}
	hum, ok := s.readerID(r, tenant) // fails closed (CLE-34986): an error read as "door off"
	if !ok {
		return false, nil
	}
	if hum == "" {
		return true, nil // door-off lde, as the rest of privacy.go
	}
	return s.fileReadableBy(r.Context(), tenant, fileID, "", hum)
}

// fileReadableBy is mayReadFile's rule for a principal already resolved: a
// box (box != "") or a human. The send paths ask it too (CLE-34986): an
// attachment is a capability to READ the blob, so a sender may attach only a
// file it may already read - else anyone who knew a file_id (a member
// removed from #hr, a log line) re-attached it to their own DM and then
// downloaded it through that message.
func (s *Server) fileReadableBy(ctx context.Context, tenant, fileID, box, hum string) (bool, error) {
	if fileID == "" {
		return false, nil
	}
	now := s.o.Now()
	// An AVATAR is not an attachment. GET /v1/view/roster already lists every
	// member's avatar_file_id to every member, so the picture is exactly as
	// private as the roster - refusing it here would only break the WUI.
	switch avatar, err := s.isTenantAvatar(ctx, tenant, fileID); {
	case err != nil:
		return false, err
	case avatar:
		return true, nil
	}
	var may bool
	var err error
	if box != "" {
		may, err = s.o.Store.FileReadableByBox(ctx, tenant, fileID, box, now)
	} else {
		var mine []string
		if mine, err = s.readerChannels(ctx, tenant, hum); err == nil {
			may, err = s.o.Store.FileReadableByHuman(ctx, tenant, fileID, hum, mine, now)
		}
	}
	if err != nil || may {
		return may, err
	}
	// Nothing this principal may read carries it. A blob no message in
	// retention references is either an upload whose message has not been
	// sent yet (a box uploads, then sends, and must be able to fetch back
	// what it just produced) or the leftover of messages that EXPIRED. The
	// second must not become readable by the whole tenant (CLE-34962): only
	// a fresh upload passes, and retention deletes the rest (sweepFiles).
	attached, err := s.o.Store.FileAttached(ctx, tenant, fileID, now)
	if err != nil || attached {
		return false, err
	}
	key, err := blob.Key(tenant, fileID)
	if err != nil {
		return false, nil
	}
	up, err := s.o.Blob.Uploaded(ctx, key)
	if errors.Is(err, blob.ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return now.Sub(up) < FileUploadGrace, nil
}

// isTenantAvatar reports whether fileID is some member of tenant's stored
// IdP picture. A store without the 010 tables has none.
func (s *Server) isTenantAvatar(ctx context.Context, tenant, fileID string) (bool, error) {
	h, ok := s.o.Store.(store.Humans)
	if !ok {
		return false, nil
	}
	avatars, err := h.TenantAvatars(ctx, tenant)
	if err != nil {
		return false, err
	}
	for _, fid := range avatars {
		if fid == fileID {
			return true, nil
		}
	}
	return false, nil
}

// GET /v1/pins: the tenant's active box pubkeys (authorized_keys sync).
func (s *Server) handleListPins(w http.ResponseWriter, r *http.Request) {
	t, _, ok := s.tokenTenant(w, r) // specs/026: the token's tenant
	if !ok {
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
	t, ok := s.boxTenant(w, r) // named, proven by the root signature below
	if !ok {
		return
	}
	var req wire.PinRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 8<<10)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "pin body does not parse")
		return
	}
	if req.BoxID == WUIBox {
		// Pinnable only with this hub's own key (specs/014 §2.2); the tenant
		// root signature below is still what makes the pin.
		if pub := s.wuiPub(); pub == nil {
			writeErr(w, http.StatusBadRequest, "bad_json", WUIBox+" is the reserved browser box and this hub has no box-wui key")
			return
		} else if req.PubKey != base64.StdEncoding.EncodeToString(pub) {
			writeErr(w, http.StatusBadRequest, "wui_key_mismatch", WUIBox+" may only be pinned to this hub's key (GET /v1/wui/pubkey)")
			return
		}
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
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return
	}
	_, pinErr := s.o.Store.GetPin(r.Context(), t.ID, req.BoxID)
	if errors.Is(pinErr, store.ErrNotFound) {
		pins, err := s.o.Store.ListPins(r.Context(), t.ID)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "internal", "pins unavailable")
			return
		}
		if s.quota().Over(billing.Usage{Pins: len(pins)}, 0, 1, 0) != "" {
			writeQuota(w, "pin count exceeds the tenant quota")
			return
		}
	}
	opTS, _ := time.Parse(time.RFC3339, req.TS) // skewOK parsed it already
	err = s.o.Store.PutPin(r.Context(), t.ID, req.BoxID, ed25519.PublicKey(pub), req.Force, opTS, s.o.Now())
	if errors.Is(err, store.ErrConflict) {
		writeErr(w, http.StatusConflict, "pin_conflict", "box_id is pinned to a different key or revoked (use force)")
		return
	}
	if errors.Is(err, store.ErrStale) {
		writeErr(w, http.StatusConflict, "stale_pin_op", "ts is not later than the last op on this pin (replay?)")
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
	t, ok := s.boxTenant(w, r) // named, proven by the root signature below
	if !ok {
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
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return
	}
	opTS, _ := time.Parse(time.RFC3339, req.TS) // skewOK parsed it already
	if err := s.o.Store.RevokePin(r.Context(), t.ID, req.BoxID, opTS, s.o.Now()); errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such pin")
		return
	} else if errors.Is(err, store.ErrStale) {
		writeErr(w, http.StatusConflict, "stale_pin_op", "ts is not later than the last op on this pin (replay?)")
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

// PutFile stores data in the tenant blob prefix (cicdlogs.Bus).
func (s *Server) PutFile(ctx context.Context, tenant, name string, data []byte) (msg.Attachment, error) {
	if int64(len(data)) > msg.MaxFileBytes {
		return msg.Attachment{}, fmt.Errorf("file exceeds the per-file limit")
	}
	sum := sha256.Sum256(data)
	id := hex.EncodeToString(sum[:])
	key, err := blob.Key(tenant, id)
	if err != nil {
		return msg.Attachment{}, err
	}
	if err := s.o.Blob.Put(ctx, key, data); err != nil {
		return msg.Attachment{}, err
	}
	s.touchUpload(ctx, key)    // Put of bytes already held writes nothing
	s.fileUsage.forget(tenant) // unquota'd writer: the next upload lists afresh
	if name == "" {
		name = id
	}
	return msg.Attachment{Mode: "blob", Kind: "file", FileID: id, SHA256: id, Name: name, Bytes: int64(len(data))}, nil
}

// POST /v1/cicd-logs: hub-side fetch+deliver (008). Registered only when enabled.
func (s *Server) handleCICDLogs(w http.ResponseWriter, r *http.Request) {
	t, box, ok := s.tokenTenant(w, r)
	if !ok {
		return
	}
	var req cicdlogs.Request
	if err := json.NewDecoder(io.LimitReader(r.Body, 8<<10)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "cicd-logs body does not parse")
		return
	}
	if req.ToBox == "" {
		req.ToBox = box
	}
	if req.ToBox != box {
		writeErr(w, http.StatusForbidden, "cicd_forbidden", "to_box must be the authenticated box")
		return
	}
	res, err := s.cicd.Run(r.Context(), t.ID, req)
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, cicdlogs.HTTPResultFrom(res))
	case errors.Is(err, cicdlogs.ErrForbidden):
		writeErr(w, http.StatusForbidden, "cicd_forbidden", "repo is not allowlisted for this tenant")
	case errors.Is(err, cicdlogs.ErrBadRequest):
		writeErr(w, http.StatusBadRequest, "bad_json", "url or owner+repo+run_id, task_id, to and to_box are required")
	default:
		s.o.Log.Error().Err(err).Msg("cicd-logs")
		writeErr(w, http.StatusServiceUnavailable, "internal", "cicd-logs failed")
	}
}
