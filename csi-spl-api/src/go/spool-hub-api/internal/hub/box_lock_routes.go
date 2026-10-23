package hub

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/coder/websocket"

	"github.com/csitea/csi-spl/spool-hub-api/internal/lockkey"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The box owner lock's routes and its hello (spec 025 box-owner-lock.md
// sections 4.4 and 6.2, row B2). The data, its signature check and the
// audit rows are row B1's (store/box_locks.go); the box side that signs is
// row B4's (lockkey, spool lock). No other route, role, permission or
// operator scope writes box_locks: every write here needs an owner's WUI
// session AND a K_lock signature made on the locked box.
//
// Statements K_lock signs besides the lock body (spool lock sign --file):
//
//	change: "spool-lock-change-v1|<tenant>|<box>|<nonce>|<sha256 hex of signed_body>"
//	lift:   "spool-lock-lift-v1|<tenant>|<box>|<version>|<nonce>"
//
// <nonce> is the one GET /v1/boxes/{box}/lock answers: the hub's own
// signature over its time, good for boxLockNonceTTL.

const (
	// boxLockNonceTTL: how old a hub nonce a change or lift may carry (6.2).
	boxLockNonceTTL = 300 * time.Second
	// unlockProofSkew: how far an unlock proof's ts may be from the hub's
	// clock (4.4 step 2).
	unlockProofSkew = 120 * time.Second
	// unlockTicketTTL: the unlock ticket's life (OQ-3 default; cnf in B6).
	unlockTicketTTL = 7 * 24 * time.Hour
	// boxLockAuditLimit: the audit rows GET answers, newest first.
	boxLockAuditLimit = 200
	// boxLockMaxBody bounds a lock request (two keys, owners, peers, sigs).
	boxLockMaxBody = 16 << 10
)

// Audit paths of this file's refusals and of a sealed hello.
const (
	boxLockPathHello  = "hello"
	boxLockPathGet    = "lock_get"
	boxLockPathCreate = "lock_create"
	boxLockPathChange = "lock_change"
	boxLockPathLift   = "lock_lift"
)

// Hello refusal reasons (close 4401).
const (
	// helloLockedSealed: a locked box's hello with no valid proof or ticket,
	// or a tampered lock (6.1: the box is refused at hello).
	helloLockedSealed = "locked_box_sealed"
	// helloLockedKey: the pinned key is not the box key the lock accepts.
	helloLockedKey = "locked_box_key"
)

func (s *Server) routeBoxLocks(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/boxes/{box}/lock", s.handleCreateBoxLock)
	mux.HandleFunc("PUT /v1/boxes/{box}/lock", s.handleChangeBoxLock)
	mux.HandleFunc("DELETE /v1/boxes/{box}/lock", s.handleLiftBoxLock)
	mux.HandleFunc("GET /v1/boxes/{box}/lock", s.handleGetBoxLock)
	mux.HandleFunc("OPTIONS /v1/boxes/{box}/lock", s.boxLockPreflight)
}

func (s *Server) boxLockPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- the hello (4.4) ---------------------------------------------------------

// lockedHelloRefusal is helloRefusal's last step: nothing for an unlocked
// box. A locked box's pinned key must be the lock's box_pubkey, and a box
// session must show a valid unlock ticket or proof; a proof earns a new
// ticket. A role=cli hello proves K_box, which exists only inside the
// unlocked holder (4.2), and is not a delivery target: it needs the key
// check only. A store error refuses (5.2: fail closed).
func (s *Server) lockedHelloRefusal(ctx context.Context, tenant string, f wire.Frame, pin ed25519.PublicKey) (websocket.StatusCode, string, string) {
	ls, ok := s.o.Store.(store.BoxLockStore)
	if !ok {
		return 0, "", ""
	}
	l, err := ls.BoxLock(ctx, tenant, f.BoxID)
	if err != nil {
		return websocket.StatusTryAgainLater, "store_unavailable", ""
	}
	if l == nil {
		return 0, "", ""
	}
	if l.Tampered {
		s.sealedHello(ctx, ls, tenant, f.BoxID)
		return wire.CloseUnauthorized, helloLockedSealed, ""
	}
	if base64.StdEncoding.EncodeToString(pin) != l.BoxPubKey {
		s.sealedHello(ctx, ls, tenant, f.BoxID)
		return wire.CloseUnauthorized, helloLockedKey, ""
	}
	if f.Role != wire.RoleBox {
		return 0, "", ""
	}
	if f.UnlockTicket != "" && s.ticketOK(f.UnlockTicket, l, f.BootID) {
		return 0, "", ""
	}
	if f.UnlockProof != "" && s.unlockProofOK(l, f) {
		return 0, "", s.issueTicket(l, f.BootID)
	}
	s.sealedHello(ctx, ls, tenant, f.BoxID)
	return wire.CloseUnauthorized, helloLockedSealed, ""
}

// sealedHello writes (or bumps) the sealed_hello audit row.
func (s *Server) sealedHello(ctx context.Context, ls store.BoxLockStore, tenant, box string) {
	a := store.BoxLockAudit{TenantID: tenant, BoxID: box, FromBox: box, Path: boxLockPathHello, Verdict: store.BoxLockSealedHello}
	if err := ls.RecordBoxLockAudit(ctx, a, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("box", box).Msg("box lock audit: sealed hello")
	}
}

// unlockProofOK verifies the proof against the lock's K_lock: over this
// socket's nonce (the hello's, already checked), the box key the lock
// accepts, a boot id, and the hello's ts within unlockProofSkew.
func (s *Server) unlockProofOK(l *store.BoxLock, f wire.Frame) bool {
	ts, err := time.Parse(time.RFC3339, f.TS)
	if err != nil || f.BootID == "" {
		return false
	}
	if d := s.o.Now().Sub(ts); d > unlockProofSkew || d < -unlockProofSkew {
		return false
	}
	pub, err := base64.StdEncoding.DecodeString(l.LockPubKey)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return false
	}
	p := lockkey.ProofPayload(l.TenantID, l.BoxID, f.Nonce, f.BootID, l.BoxPubKey, f.TS)
	return verify(ed25519.PublicKey(pub), p, f.UnlockProof) == nil
}

// unlockTicket is the hub-signed ticket body (4.4 step 2).
type unlockTicket struct {
	V         int    `json:"v"`
	TenantID  string `json:"tenant"`
	BoxID     string `json:"box"`
	BoxPubKey string `json:"box_pubkey"`
	BootID    string `json:"boot_id"`
	ExpiresAt string `json:"expires_at"`
}

const unlockTicketPrefix = "spool-unlock-ticket-v1|"

// issueTicket signs a ticket with the hub's key (box-wui's, the key the hub
// already signs as); "" when this hub has none: the box then shows a proof
// on every hello.
func (s *Server) issueTicket(l *store.BoxLock, bootID string) string {
	if len(s.o.WUIKey) != ed25519.PrivateKeySize {
		return ""
	}
	b, _ := json.Marshal(unlockTicket{V: 1, TenantID: l.TenantID, BoxID: l.BoxID, BoxPubKey: l.BoxPubKey,
		BootID: bootID, ExpiresAt: s.o.Now().Add(unlockTicketTTL).UTC().Format(time.RFC3339)})
	body := base64.RawURLEncoding.EncodeToString(b)
	sig := ed25519.Sign(s.o.WUIKey, []byte(unlockTicketPrefix+body))
	return body + "." + base64.RawURLEncoding.EncodeToString(sig)
}

// ticketOK checks a ticket: the hub's signature, this lock's tenant, box
// and box key, the same boot (a reboot needs the secret again, 4.3), and
// not expired.
func (s *Server) ticketOK(raw string, l *store.BoxLock, bootID string) bool {
	pub := s.wuiPub()
	body, sigB64, ok := strings.Cut(raw, ".")
	if pub == nil || !ok || bootID == "" {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(sigB64)
	if err != nil || !ed25519.Verify(pub, []byte(unlockTicketPrefix+body), sig) {
		return false
	}
	b, err := base64.RawURLEncoding.DecodeString(body)
	var t unlockTicket
	if err != nil || json.Unmarshal(b, &t) != nil {
		return false
	}
	exp, err := time.Parse(time.RFC3339, t.ExpiresAt)
	return err == nil && t.V == 1 && t.TenantID == l.TenantID && t.BoxID == l.BoxID &&
		t.BoxPubKey == l.BoxPubKey && t.BootID == bootID && s.o.Now().Before(exp)
}

// ---- the hub nonce (6.2) -----------------------------------------------------

const boxLockNoncePrefix = "spool-lock-nonce-v1|"

// boxLockNonce is "<unix seconds>.<hub signature>", bound to the tenant and
// box; "" when this hub has no key.
func (s *Server) boxLockNonce(tenant, box string) string {
	if len(s.o.WUIKey) != ed25519.PrivateKeySize {
		return ""
	}
	ts := strconv.FormatInt(s.o.Now().Unix(), 10)
	sig := ed25519.Sign(s.o.WUIKey, []byte(boxLockNoncePrefix+tenant+"|"+box+"|"+ts))
	return ts + "." + base64.RawURLEncoding.EncodeToString(sig)
}

// boxLockNonceOK checks the hub's signature and that the nonce is at most
// boxLockNonceTTL old.
func (s *Server) boxLockNonceOK(tenant, box, nonce string) bool {
	pub := s.wuiPub()
	ts, sigB64, ok := strings.Cut(nonce, ".")
	if pub == nil || !ok {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(sigB64)
	if err != nil || !ed25519.Verify(pub, []byte(boxLockNoncePrefix+tenant+"|"+box+"|"+ts), sig) {
		return false
	}
	sec, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return false
	}
	age := s.o.Now().Sub(time.Unix(sec, 0))
	return age >= -time.Minute && age <= boxLockNonceTTL
}

// BoxLockChangeStatement is what K_lock signs to change a lock (PUT).
func BoxLockChangeStatement(tenant, box, nonce, signedBody string) string {
	h := sha256.Sum256([]byte(signedBody))
	return strings.Join([]string{"spool-lock-change-v1", tenant, box, nonce, hex.EncodeToString(h[:])}, "|")
}

// BoxLockLiftStatement is what K_lock signs to lift a lock (DELETE).
func BoxLockLiftStatement(tenant, box string, version int64, nonce string) string {
	return strings.Join([]string{"spool-lock-lift-v1", tenant, box, strconv.FormatInt(version, 10), nonce}, "|")
}

// ---- the routes (6.2) --------------------------------------------------------

// boxLockReq is every lock route's body; each route reads its own fields.
type boxLockReq struct {
	SignedBody     string `json:"signed_body"`
	Signature      string `json:"signature"`
	BoxSignature   string `json:"box_signature"`
	Nonce          string `json:"nonce"`
	NonceSignature string `json:"nonce_signature"`
}

// boxLockCall is a lock route's resolved caller.
type boxLockCall struct {
	tenant string
	hum    string
	box    string
	ls     store.BoxLockStore
}

// boxLockActor resolves the caller: a signed-in member's session (an
// act-as clone is a new HUM-*, never an owner), a valid box id, and a store
// that keeps locks. No role or permission grants anything here: only the
// lock's owners decide (2.3). ok=false: it answered.
func (s *Server) boxLockActor(w http.ResponseWriter, r *http.Request) (boxLockCall, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return boxLockCall{}, false
	}
	if hum == "" {
		writeErr(w, http.StatusForbidden, "forbidden", "a box lock needs a member session")
		return boxLockCall{}, false
	}
	// A visitor role (demo_user, channel_guest) never owns a box: refused
	// before any lookup (specs/077 FR-003).
	if a, err := s.access(r.Context(), hum, t.ID); err != nil || rbac.Exclusive(a.Role) {
		writeForbidden(w, "", "a visitor role cannot hold a box lock")
		return boxLockCall{}, false
	}
	box := r.PathValue("box")
	if !msg.ValidBoxID(box) || box == WUIBox {
		writeErr(w, http.StatusNotFound, "not_found", "no such box lock")
		return boxLockCall{}, false
	}
	ls, ok := s.o.Store.(store.BoxLockStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no box locks")
		return boxLockCall{}, false
	}
	return boxLockCall{tenant: t.ID, hum: hum, box: box, ls: ls}, true
}

// ownedLock reads the box's lock and answers it only to an owner. An
// unlocked box is 404; a non-owner (a tampered lock has none) gets
// notOwner and one refused audit row. ok=false: it answered.
func (s *Server) ownedLock(w http.ResponseWriter, r *http.Request, c boxLockCall, path string, notOwner int) (*store.BoxLock, bool) {
	l, err := c.ls.BoxLock(r.Context(), c.tenant, c.box)
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "box lock unavailable", err)
		return nil, false
	}
	if l == nil {
		writeErr(w, http.StatusNotFound, "not_found", "no such box lock")
		return nil, false
	}
	if !l.IsOwner(c.hum) {
		s.refuseLock(r.Context(), c, path)
		if notOwner == http.StatusNotFound {
			writeErr(w, http.StatusNotFound, "not_found", "no such box lock")
		} else {
			writeErr(w, http.StatusForbidden, "box_locked", "only an owner of this box's lock may do this")
		}
		return nil, false
	}
	return l, true
}

// refuseLock writes (or bumps) one refused audit row for the caller.
func (s *Server) refuseLock(ctx context.Context, c boxLockCall, path string) {
	a := store.BoxLockAudit{TenantID: c.tenant, BoxID: c.box, HumanID: c.hum, Path: path, Verdict: store.BoxLockRefused}
	if err := c.ls.RecordBoxLockAudit(ctx, a, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", c.tenant).Str("box", c.box).Msg("box lock audit: refused")
	}
}

// decodeBoxLockReq reads a lock route's JSON body: application/json only
// (as decodeMembers: no simple cross-site form post), unknown keys refused.
func decodeBoxLockReq(w http.ResponseWriter, r *http.Request) (boxLockReq, bool) {
	var req boxLockReq
	if mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mt != "application/json" {
		writeErr(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "Content-Type must be application/json")
		return req, false
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, boxLockMaxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body is not the expected JSON object")
		return req, false
	}
	return req, true
}

// parseLockBody turns a signed_body into the row it describes; it must name
// the caller's tenant and the path's box. The store's VerifyBoxLock then
// checks the K_lock signature and that the body is canonical.
func parseLockBody(w http.ResponseWriter, c boxLockCall, req boxLockReq) (store.BoxLock, bool) {
	var b struct {
		TenantID   string   `json:"tenant_id"`
		BoxID      string   `json:"box_id"`
		LockPubKey string   `json:"lock_pubkey"`
		BoxPubKey  string   `json:"box_pubkey"`
		Owners     []string `json:"owners"`
		PeerBoxes  []string `json:"peer_boxes"`
		HidePosts  bool     `json:"hide_posts"`
		Version    int64    `json:"version"`
	}
	dec := json.NewDecoder(strings.NewReader(req.SignedBody))
	dec.DisallowUnknownFields()
	if req.SignedBody == "" || dec.Decode(&b) != nil {
		writeErr(w, http.StatusBadRequest, "bad_body", "signed_body is not a lock body")
		return store.BoxLock{}, false
	}
	if b.TenantID != c.tenant || b.BoxID != c.box {
		writeErr(w, http.StatusBadRequest, "bad_body", "signed_body names another workspace or box")
		return store.BoxLock{}, false
	}
	return store.BoxLock{TenantID: b.TenantID, BoxID: b.BoxID, LockPubKey: b.LockPubKey, BoxPubKey: b.BoxPubKey,
		Owners: b.Owners, PeerBoxes: b.PeerBoxes, HidePosts: b.HidePosts, Version: b.Version,
		SignedBody: req.SignedBody, Signature: req.Signature}, true
}

// lockWriteErr answers a store write error of a lock route. A bad
// signature, an existing lock or a stale version is a refusal: one refused
// audit row for the caller on path (6.3).
func (s *Server) lockWriteErr(w http.ResponseWriter, r *http.Request, c boxLockCall, path string, err error) {
	if errors.Is(err, store.ErrBoxLockTampered) || errors.Is(err, store.ErrBoxLockKey) ||
		errors.Is(err, store.ErrBoxLockExists) || errors.Is(err, store.ErrBoxLockVersion) {
		s.refuseLock(r.Context(), c, path)
	}
	switch {
	case errors.Is(err, store.ErrBoxLockTampered), errors.Is(err, store.ErrBoxLockKey):
		writeErr(w, http.StatusForbidden, "bad_sig", "the body is not signed by this box's lock key")
	case errors.Is(err, store.ErrBoxLockExists):
		writeErr(w, http.StatusConflict, "box_locked", "this box is already locked")
	case errors.Is(err, store.ErrBoxLockVersion):
		writeErr(w, http.StatusConflict, "stale_version", "version must be the stored version + 1")
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such box lock")
	default:
		writeErrCause(w, http.StatusInternalServerError, "internal", "box lock not stored", err)
	}
}

// POST /v1/boxes/{box}/lock {signed_body, signature, box_signature}: lock
// the box. The confirming member must be in owners; box_signature is K_box's
// over signed_body and box_pubkey must be the pinned key (the box asked for
// it); signature is K_lock's (the store verifies it). A live box session is
// closed: its next hello needs the unlock.
func (s *Server) handleCreateBoxLock(w http.ResponseWriter, r *http.Request) {
	c, ok := s.boxLockActor(w, r)
	if !ok {
		return
	}
	req, ok := decodeBoxLockReq(w, r)
	if !ok {
		return
	}
	l, ok := parseLockBody(w, c, req)
	if !ok {
		return
	}
	if l.Version != 1 {
		writeErr(w, http.StatusBadRequest, "bad_body", "a new lock is version 1")
		return
	}
	if !l.IsOwner(c.hum) {
		s.refuseLock(r.Context(), c, boxLockPathCreate)
		writeErr(w, http.StatusForbidden, "not_owner", "the confirming member is not an owner in the lock body")
		return
	}
	pin, err := s.o.Store.GetPin(r.Context(), c.tenant, c.box)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such box")
		return
	}
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "pin unavailable", err)
		return
	}
	if base64.StdEncoding.EncodeToString(pin) != l.BoxPubKey || verify(pin, []byte(l.SignedBody), req.BoxSignature) != nil {
		s.refuseLock(r.Context(), c, boxLockPathCreate)
		writeErr(w, http.StatusForbidden, "bad_box_sig", "the body is not signed by this box's pinned key")
		return
	}
	if err := c.ls.CreateBoxLock(r.Context(), l, c.hum, s.o.Now()); err != nil {
		s.lockWriteErr(w, r, c, boxLockPathCreate, err)
		return
	}
	s.closeLockedBox(c.tenant, c.box)
	writeJSON(w, http.StatusCreated, s.lockView(r.Context(), c, &l, false))
}

// PUT /v1/boxes/{box}/lock {signed_body, signature, nonce, nonce_signature}:
// an owner changes owners, peer_boxes, hide_posts or box_pubkey (rebind) at
// version + 1. nonce is a hub nonce at most 300 s old, nonce_signature
// K_lock's over BoxLockChangeStatement. A new box_pubkey is pinned in the
// same call, and the box's live session closed.
func (s *Server) handleChangeBoxLock(w http.ResponseWriter, r *http.Request) {
	c, ok := s.boxLockActor(w, r)
	if !ok {
		return
	}
	req, ok := decodeBoxLockReq(w, r)
	if !ok {
		return
	}
	prev, ok := s.ownedLock(w, r, c, boxLockPathChange, http.StatusForbidden)
	if !ok {
		return
	}
	l, ok := parseLockBody(w, c, req)
	if !ok {
		return
	}
	if !s.lockStatementOK(w, r, c, prev, req.Nonce, req.NonceSignature,
		BoxLockChangeStatement(c.tenant, c.box, req.Nonce, req.SignedBody), boxLockPathChange) {
		return
	}
	raw, err := base64.StdEncoding.DecodeString(l.BoxPubKey) // VerifyBoxLock does not check it
	if err != nil || len(raw) != ed25519.PublicKeySize {
		writeErr(w, http.StatusBadRequest, "bad_body", "box_pubkey is not a base64 Ed25519 key")
		return
	}
	if err := c.ls.ChangeBoxLock(r.Context(), l, c.hum, s.o.Now()); err != nil {
		s.lockWriteErr(w, r, c, boxLockPathChange, err)
		return
	}
	if l.BoxPubKey != prev.BoxPubKey {
		now := s.o.Now()
		if err := s.o.Store.PutPin(r.Context(), c.tenant, c.box, ed25519.PublicKey(raw), true, now, now); err != nil {
			writeErrCause(w, http.StatusInternalServerError, "internal", "lock changed, new box key not pinned", err)
			return
		}
		s.closeLockedBox(c.tenant, c.box)
	}
	writeJSON(w, http.StatusOK, s.lockView(r.Context(), c, &l, false))
}

// DELETE /v1/boxes/{box}/lock {nonce, signature}: an owner lifts the lock;
// signature is K_lock's over BoxLockLiftStatement at the stored version.
func (s *Server) handleLiftBoxLock(w http.ResponseWriter, r *http.Request) {
	c, ok := s.boxLockActor(w, r)
	if !ok {
		return
	}
	req, ok := decodeBoxLockReq(w, r)
	if !ok {
		return
	}
	prev, ok := s.ownedLock(w, r, c, boxLockPathLift, http.StatusForbidden)
	if !ok {
		return
	}
	if !s.lockStatementOK(w, r, c, prev, req.Nonce, req.Signature,
		BoxLockLiftStatement(c.tenant, c.box, prev.Version, req.Nonce), boxLockPathLift) {
		return
	}
	if err := c.ls.LiftBoxLock(r.Context(), c.tenant, c.box, c.hum, s.o.Now()); err != nil {
		s.lockWriteErr(w, r, c, boxLockPathLift, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// lockStatementOK checks a change or lift statement: a fresh hub nonce for
// this box, signed by the K_lock on file. A bad signature is 403 and one
// refused audit row, and so is a stale or foreign nonce (400). ok=false: it
// answered.
func (s *Server) lockStatementOK(w http.ResponseWriter, r *http.Request, c boxLockCall, prev *store.BoxLock, nonce, sig, statement, path string) bool {
	if len(s.o.WUIKey) != ed25519.PrivateKeySize {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub has no key to issue lock nonces")
		return false
	}
	if !s.boxLockNonceOK(c.tenant, c.box, nonce) {
		s.refuseLock(r.Context(), c, path)
		writeErr(w, http.StatusBadRequest, "stale_nonce", "nonce is not this hub's, or older than 300 s: GET the lock for a new one")
		return false
	}
	pub, err := base64.StdEncoding.DecodeString(prev.LockPubKey)
	if err != nil || len(pub) != ed25519.PublicKeySize || verify(ed25519.PublicKey(pub), []byte(statement), sig) != nil {
		s.refuseLock(r.Context(), c, path)
		writeErr(w, http.StatusForbidden, "bad_sig", "the statement is not signed by this box's lock key")
		return false
	}
	return true
}

// GET /v1/boxes/{box}/lock: the lock, its audit and a fresh nonce, to an
// owner only; anyone else gets 404 (and a refused audit row when locked).
func (s *Server) handleGetBoxLock(w http.ResponseWriter, r *http.Request) {
	c, ok := s.boxLockActor(w, r)
	if !ok {
		return
	}
	l, ok := s.ownedLock(w, r, c, boxLockPathGet, http.StatusNotFound)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, s.lockView(r.Context(), c, l, true))
}

// boxLockView is a lock route's answer.
type boxLockView struct {
	TenantID   string         `json:"tenant_id"`
	BoxID      string         `json:"box_id"`
	LockPubKey string         `json:"lock_pubkey"`
	BoxPubKey  string         `json:"box_pubkey"`
	Owners     []string       `json:"owners"`
	PeerBoxes  []string       `json:"peer_boxes"`
	HidePosts  bool           `json:"hide_posts"`
	Version    int64          `json:"version"`
	SignedBody string         `json:"signed_body"`
	Signature  string         `json:"signature"`
	Nonce      string         `json:"nonce,omitempty"`
	Audit      []boxLockAudit `json:"audit,omitempty"`
}

type boxLockAudit struct {
	HumanID string `json:"human_id,omitempty"`
	FromBox string `json:"from_box,omitempty"`
	Path    string `json:"path"`
	Verdict string `json:"verdict"`
	FirstAt string `json:"first_at"`
	LastAt  string `json:"last_at"`
	Count   int    `json:"count"`
}

// lockView answers l, with its audit rows when audit is set, and a fresh
// nonce for the next change or lift.
func (s *Server) lockView(ctx context.Context, c boxLockCall, l *store.BoxLock, audit bool) boxLockView {
	v := boxLockView{TenantID: l.TenantID, BoxID: l.BoxID, LockPubKey: l.LockPubKey, BoxPubKey: l.BoxPubKey,
		Owners: nonNil(l.Owners), PeerBoxes: nonNil(l.PeerBoxes), HidePosts: l.HidePosts, Version: l.Version,
		SignedBody: l.SignedBody, Signature: l.Signature, Nonce: s.boxLockNonce(c.tenant, c.box)}
	if !audit {
		return v
	}
	rows, err := c.ls.BoxLockAudits(ctx, c.tenant, c.box, boxLockAuditLimit)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", c.tenant).Str("box", c.box).Msg("box lock audit read")
	}
	v.Audit = make([]boxLockAudit, 0, len(rows))
	for _, a := range rows {
		v.Audit = append(v.Audit, boxLockAudit{HumanID: a.HumanID, FromBox: a.FromBox, Path: a.Path, Verdict: a.Verdict,
			FirstAt: a.FirstAt.UTC().Format(time.RFC3339), LastAt: a.LastAt.UTC().Format(time.RFC3339), Count: a.Count})
	}
	return v
}

func nonNil(xs []string) []string {
	if xs == nil {
		return []string{}
	}
	return xs
}

// closeLockedBox closes the box's live session so its next hello shows the
// unlock; GoingAway (not a 4xxx refusal) makes the box redial at once.
func (s *Server) closeLockedBox(tenant, box string) {
	if x := s.boxSession(tenant, box); x != nil {
		x.close(websocket.StatusGoingAway, "box_locked")
	}
}
