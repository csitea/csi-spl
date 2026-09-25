package hub

import (
	"bytes"
	"encoding/json"
	"errors"
	"mime"
	"net/http"
	"regexp"
	"strconv"
	"time"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/edge"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A human's public keys (specs/023 contracts/keys-v1.md). Mounted under the
// auth prefix so the credentialed CORS of /api/v1/auth/* covers it (GET and
// POST only: no CORS change). Member session with a HUM-*; the human reads
// and changes only their own keys. Public material only: an unknown JSON
// field (a "private_key") and private-key-shaped input are refused, and no
// answer carries anything but the public key.

const (
	keysPrefix = auth.RoutePrefix + "keys"
	// keysWritesPerHour is the per-human write ceiling (FR-008) when
	// Options.KeysWriteLimit is 0.
	keysWritesPerHour = 30
	keysMaxBody       = 8 << 10
	keysLabelMax      = 80
)

// humanIDRe is rdb 0006 humans.human_id: only a registered human has keys.
var humanIDRe = regexp.MustCompile(`^HUM-[0-9]+$`)

type keyJSON struct {
	ID            int64      `json:"id"`
	Fingerprint   string     `json:"fingerprint"`
	PublicKey     string     `json:"public_key"`
	OpenSSH       string     `json:"openssh"`
	Source        string     `json:"source"`
	Label         string     `json:"label"`
	CreatedAt     time.Time  `json:"created_at"`
	RevokedAt     *time.Time `json:"revoked_at"`
	RevokedReason string     `json:"revoked_reason"`
	Active        bool       `json:"active"`
}

func toKeyJSON(k store.HumanKey) keyJSON {
	out := keyJSON{ID: k.ID, Fingerprint: k.Fingerprint, PublicKey: k.PublicKey, Source: k.Source, Label: k.Label,
		CreatedAt: k.CreatedAt.UTC(), RevokedAt: k.RevokedAt, RevokedReason: k.RevokedReason, Active: k.RevokedAt == nil}
	if pub, err := sign.ParsePublic(k.PublicKey); err == nil {
		out.OpenSSH = sign.OpenSSH(pub, "spool:"+k.HumanID)
	}
	return out
}

func (s *Server) registerKeys(mux *http.ServeMux) {
	s.keysLim = edge.NewWindow(time.Hour, s.o.Now)
	mux.HandleFunc("GET "+keysPrefix, s.handleKeysList)
	mux.HandleFunc("POST "+keysPrefix, s.handleKeyAdd)
	// {id}/public, not {id}: GET /api/v1/auth/{provider}/start would overlap.
	mux.HandleFunc("GET "+keysPrefix+"/{id}/public", s.handleKeyGet)
	mux.HandleFunc("POST "+keysPrefix+"/{id}/revoke", s.handleKeyRevoke)
}

// keysHuman answers the caller's HUM-* and the key store, or writes the error.
func (s *Server) keysHuman(w http.ResponseWriter, r *http.Request) (string, store.HumanKeys, bool) {
	w.Header().Set("Cache-Control", "no-store")
	var hum string
	if s.o.SessionID != nil {
		hum, _ = s.o.SessionID(r, "")
	} else if sess, ok := s.o.Auth.SessionFromRequest(r); ok {
		hum = sess.HumanID
	}
	if !humanIDRe.MatchString(hum) {
		writeErr(w, http.StatusUnauthorized, "unauthenticated", "sign in first")
		return "", nil, false
	}
	ks, ok := s.o.Store.(store.HumanKeys)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "this hub keeps no human keys")
		return "", nil, false
	}
	return hum, ks, true
}

// keysWrite applies the per-human write window; false = 429 answered.
func (s *Server) keysWrite(w http.ResponseWriter, hum string) bool {
	max := s.o.KeysWriteLimit
	if max <= 0 {
		max = keysWritesPerHour
	}
	ok, retry := s.keysLim.Allow(hum, max)
	if ok {
		return true
	}
	w.Header().Set("Retry-After", strconv.Itoa(int(retry.Seconds())+1))
	writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many key changes")
	s.o.Log.Warn().Str("human_id", hum).Msg("keys.rate_limited")
	return false
}

// readKeysJSON: application/json, capped, no unknown field; false = answered.
func readKeysJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	return readJSONStrict(w, r, v, keysMaxBody, "invalid JSON body (only public_key, source, label)")
}

// readJSONStrict is readKeysJSON with the cap and the refusal text as
// arguments (events.go shares it).
func readJSONStrict(w http.ResponseWriter, r *http.Request, v any, maxBody int64, refusal string) bool {
	if mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mt != "application/json" {
		writeErr(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "Content-Type must be application/json")
		return false
	}
	raw, err := readAllCapped(w, r, maxBody)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "body too large or unreadable")
		return false
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		raw = []byte("{}")
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", refusal)
		return false
	}
	return true
}

func readAllCapped(w http.ResponseWriter, r *http.Request, max int64) ([]byte, error) {
	var b bytes.Buffer
	_, err := b.ReadFrom(http.MaxBytesReader(w, r.Body, max))
	return b.Bytes(), err
}

func (s *Server) handleKeysList(w http.ResponseWriter, r *http.Request) {
	hum, ks, ok := s.keysHuman(w, r)
	if !ok {
		return
	}
	list, err := ks.HumanKeys(r.Context(), hum)
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "key store")
		return
	}
	out := struct {
		Active *keyJSON  `json:"active"`
		Keys   []keyJSON `json:"keys"`
	}{Keys: []keyJSON{}}
	for _, k := range list {
		j := toKeyJSON(k)
		if j.Active && out.Active == nil {
			a := j
			out.Active = &a
		}
		out.Keys = append(out.Keys, j)
	}
	writeJSON(w, http.StatusOK, out)
}

func keyID(r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	return id, err == nil && id > 0
}

func (s *Server) handleKeyGet(w http.ResponseWriter, r *http.Request) {
	hum, ks, ok := s.keysHuman(w, r)
	if !ok {
		return
	}
	id, ok := keyID(r)
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "no such key")
		return
	}
	k, err := ks.HumanKey(r.Context(), hum, id)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such key")
		return
	}
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "key store")
		return
	}
	writeJSON(w, http.StatusOK, toKeyJSON(k))
}

type keyAddReq struct {
	PublicKey string `json:"public_key"`
	Source    string `json:"source"`
	Label     string `json:"label"`
}

func (s *Server) handleKeyAdd(w http.ResponseWriter, r *http.Request) {
	hum, ks, ok := s.keysHuman(w, r)
	if !ok || !s.keysWrite(w, hum) {
		return
	}
	var req keyAddReq
	if !readKeysJSON(w, r, &req) {
		return
	}
	if req.Source == "" {
		req.Source = store.KeySourceUploaded
	}
	if (req.Source != store.KeySourceGenerated && req.Source != store.KeySourceUploaded) ||
		len(req.Label) > keysLabelMax || !utf8.ValidString(req.Label) {
		writeErr(w, http.StatusBadRequest, "bad_request", "source must be generated or uploaded; label at most 80 bytes")
		return
	}
	pub, err := sign.ParsePublic(req.PublicKey)
	if errors.Is(err, sign.ErrPrivateKey) {
		s.o.Log.Warn().Str("human_id", hum).Msg("keys.private_key_refused")
		writeErr(w, http.StatusBadRequest, "private_key_refused", err.Error())
		return
	}
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_public_key", err.Error())
		return
	}
	k, err := ks.AddHumanKey(r.Context(), store.HumanKey{HumanID: hum, PublicKey: sign.PinForm(pub),
		Fingerprint: sign.Fingerprint(pub), Source: req.Source, Label: req.Label}, s.o.Now().UTC())
	switch {
	case errors.Is(err, store.ErrConflict):
		writeErr(w, http.StatusConflict, "duplicate_key", "this public key is registered already")
		return
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusUnauthorized, "unauthenticated", "no such human")
		return
	case err != nil:
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "key store")
		return
	}
	s.o.Log.Info().Str("human_id", hum).Int64("key_id", k.ID).Str("fingerprint", k.Fingerprint).
		Str("source", k.Source).Msg("keys.added")
	writeJSON(w, http.StatusCreated, toKeyJSON(k))
}

func (s *Server) handleKeyRevoke(w http.ResponseWriter, r *http.Request) {
	hum, ks, ok := s.keysHuman(w, r)
	if !ok || !s.keysWrite(w, hum) {
		return
	}
	var req struct{}
	if !readKeysJSON(w, r, &req) {
		return
	}
	id, ok := keyID(r)
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "no such key")
		return
	}
	k, err := ks.RevokeHumanKey(r.Context(), hum, id, s.o.Now().UTC())
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such key")
		return
	}
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "key store")
		return
	}
	s.o.Log.Info().Str("human_id", hum).Int64("key_id", k.ID).Str("fingerprint", k.Fingerprint).
		Str("reason", k.RevokedReason).Msg("keys.revoked")
	writeJSON(w, http.StatusOK, toKeyJSON(k))
}
