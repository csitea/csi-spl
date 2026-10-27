package hub

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"
	"unicode"

	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// A workspace's own vendor keys, write only (spec 127 v1.4 4.3 and 5.1, row
// H1; spec 159 v0.2 section 3, row T1; SPL-3684):
//
//	GET    /v1/vendor-keys                       per kind: available, set, last4, set_at, set_by, base_url
//	PUT    /v1/vendor-keys/{kind}                {"key", "base_url"?}: set or replace, 204
//	DELETE /v1/vendor-keys/{kind}                remove, 204
//	PUT    /v1/vendor-keys/managers/{human_id}   confirm an operator-made manager, 204
//
// Every route needs vendor_keys.manage (biz_owner and admin, rdb 0232) and is
// refused under an act-as session. PUT, DELETE and the confirm are refused
// to an unconfirmed manager: a membership the operator or the bootstrap
// admitted, in a workspace that holds a key, that no confirmed manager has
// confirmed (127 Q-4 A, 159 L22); GET stays open to it (read-only, 127 8).
// No route answers the key, its ciphertext or its fingerprint; the lease
// route (127 H2) is the only decrypt. The request body is never logged:
// the handlers log the tenant, the kind, the actor and last4 only, and the
// key is sealed (internal/vendorkey) before the store sees it. Every set,
// replace and remove mails every admin and biz owner of the workspace.

// vendorKeysMaxBody caps a PUT body: a key and a base_url, never more.
const vendorKeysMaxBody = 16 << 10

// vendorKeyMaxLen is the longest key PUT takes (rdb 0174 caps the sealed
// ciphertext at 8192 bytes).
const vendorKeyMaxLen = 4096

// VendorKeyAvailable are the kinds a workspace may set a key for today.
// grok and mistral wait for the vendor's written terms (spec 159 4.2, owner
// actions O2 and O3), agy for the B0c gate (spec 127 R5.2). A kind joins
// this list only by a commit that cites that answer or that gate.
var VendorKeyAvailable = []string{"claude", "qwen"}

// VendorKeyNotice is the mail of one set, replace or remove (spec 159 3).
// It never carries the key: last4 only.
type VendorKeyNotice struct {
	Tenant string
	Kind   string
	Action string // store.VendorKeySet, VendorKeyReplace or VendorKeyRemove
	Last4  string
	By     string // the actor's display name, else its HUM-* id
	At     time.Time
}

// VendorKeyMailer mails n to one admin or biz owner (to, in locale). nil =
// no relay: the change is stored and audited, nothing is mailed (logged).
type VendorKeyMailer func(ctx context.Context, to, locale string, n VendorKeyNotice) error

func (s *Server) routeVendorKeys(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/vendor-keys", s.handleVendorKeys)
	mux.HandleFunc("PUT /v1/vendor-keys/{kind}", s.handlePutVendorKey)
	mux.HandleFunc("DELETE /v1/vendor-keys/{kind}", s.handleDeleteVendorKey)
	mux.HandleFunc("PUT /v1/vendor-keys/managers/{human_id}", s.handleConfirmVendorKeyManager)
	mux.HandleFunc("POST /v1/vendor-keys/{kind}/lease", s.handleVendorKeyLease)         // 127 H2, vendor_key_lease.go
	mux.HandleFunc("POST /v1/vendor-keys/{kind}/exhausted", s.handleVendorKeyExhausted) // 159 T5, vendor_key_lease.go
	mux.HandleFunc("POST /v1/vendor-keys/{kind}/retry", s.handleRetryVendorKey)         // 159 T5, vendor_key_lease.go
	mux.HandleFunc("PUT /v1/vendor-keys/settings", s.handlePutVendorKeySettings)        // 159 T5, vendor_key_lease.go
	mux.HandleFunc("OPTIONS /v1/vendor-keys/{kind}/{action}", s.vendorKeysPreflight)
	mux.HandleFunc("OPTIONS /v1/vendor-keys", s.vendorKeysPreflight)
	mux.HandleFunc("OPTIONS /v1/vendor-keys/{kind}", s.vendorKeysPreflight)
	mux.HandleFunc("OPTIONS /v1/vendor-keys/managers/{human_id}", s.vendorKeysPreflight)
}

func (s *Server) vendorKeysPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, PUT, POST, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// vkActor is the caller of a vendor key route, past every check.
type vkActor struct {
	tenant    string
	hum       string
	confirmed bool
	st        store.VendorKeys
}

// vendorKeyActor runs the checks every route shares: vendor_keys.manage
// (first, so a caller without it reads 403 either way), the routes are on (a
// sealer and a store that keeps keys), no act-as
// session, and the caller's confirmation (write = refuse an unconfirmed
// manager with 403 admin_unconfirmed).
func (s *Server) vendorKeyActor(w http.ResponseWriter, r *http.Request, write bool) (vkActor, bool) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.VendorKeysManage)
	if !ok {
		return vkActor{}, false
	}
	st, ok := s.o.Store.(store.VendorKeys)
	if s.o.VendorKeySealer == nil || !ok {
		writeErr(w, http.StatusServiceUnavailable, "vendor_keys_off", "workspace vendor keys are not configured on this hub")
		return vkActor{}, false
	}
	if s.vendorKeyActAs(r.Context(), t.ID, a.HumanID) {
		writeErr(w, http.StatusForbidden, "act_as_refused", "vendor keys are never managed under an act-as session")
		return vkActor{}, false
	}
	confirmed, err := st.VendorKeyManagerConfirmed(r.Context(), t.ID, a.HumanID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "manager confirmation unavailable")
		return vkActor{}, false
	}
	if write && !confirmed {
		writeErr(w, http.StatusForbidden, "admin_unconfirmed",
			"an operator-made admin or business owner manages keys only after a confirmed admin or business owner of this workspace confirms them")
		return vkActor{}, false
	}
	return vkActor{tenant: t.ID, hum: a.HumanID, confirmed: confirmed, st: st}, true
}

// vendorKeyActAs reports a live act-as clone, failing CLOSED: a store error
// reads as a clone, so the route refuses rather than guess.
func (s *Server) vendorKeyActAs(ctx context.Context, tenant, hum string) bool {
	cr, ok := s.o.Store.(cloneReader)
	if !ok {
		return false
	}
	c, err := cr.Clone(ctx, tenant, hum)
	if errors.Is(err, store.ErrNotFound) {
		return false
	}
	return err != nil || c.EndedAt == nil
}

// vendorKeyKind is the path's kind: 404 unknown_kind, 409 kind_not_available.
func vendorKeyKind(w http.ResponseWriter, r *http.Request) (string, bool) {
	kind := r.PathValue("kind")
	if !slices.Contains(store.VendorKeyKinds, kind) {
		writeErr(w, http.StatusNotFound, "unknown_kind", "not a vendor key kind")
		return "", false
	}
	if !slices.Contains(VendorKeyAvailable, kind) {
		writeErr(w, http.StatusConflict, "kind_not_available", "not available for workspace keys: waiting for the vendor's terms or its gate")
		return "", false
	}
	return kind, true
}

type vendorKeyRowOut struct {
	Kind      string `json:"kind"`
	Available bool   `json:"available"`
	Set       bool   `json:"set"`
	Last4     string `json:"last4,omitempty"`
	BaseURL   string `json:"base_url,omitempty"`
	SetBy     string `json:"set_by,omitempty"`
	SetAt     string `json:"set_at,omitempty"`
	// Exhausted: the vendor refused the key (159 9, T5); retry or replace it.
	Exhausted   bool   `json:"exhausted"`
	ExhaustedAt string `json:"exhausted_at,omitempty"`
}

func (s *Server) handleVendorKeys(w http.ResponseWriter, r *http.Request) {
	act, ok := s.vendorKeyActor(w, r, false)
	if !ok {
		return
	}
	rows, err := act.st.VendorKeys(r.Context(), act.tenant)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "vendor keys unavailable")
		return
	}
	out := make([]vendorKeyRowOut, 0, len(store.VendorKeyKinds))
	for _, kind := range store.VendorKeyKinds {
		o := vendorKeyRowOut{Kind: kind, Available: slices.Contains(VendorKeyAvailable, kind)}
		for _, k := range rows {
			if k.Kind == kind {
				o.Set, o.Last4, o.BaseURL, o.SetBy = true, k.Last4, k.BaseURL, k.SetBy
				o.SetAt = k.SetAt.UTC().Format(time.RFC3339)
				o.Exhausted, o.ExhaustedAt = !k.ExhaustedAt.IsZero(), exhaustedAt(k.ExhaustedAt)
			}
		}
		out = append(out, o)
	}
	writeJSON(w, http.StatusOK, map[string]any{"kinds": out, "confirmed": act.confirmed,
		"metered_fallback": s.vendorKeyMeteredFallback(r.Context(), act.tenant)})
}

// vendorKeyBody reads the PUT body. The raw bytes are cleared once decoded;
// a refusal names the field, never its value.
func vendorKeyBody(w http.ResponseWriter, r *http.Request, kind string) (key, baseURL string, ok bool) {
	if mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mt != "application/json" {
		writeErr(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "Content-Type must be application/json")
		return "", "", false
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, vendorKeysMaxBody))
	defer clear(raw)
	var body struct {
		Key     string `json:"key"`
		BaseURL string `json:"base_url"`
	}
	if err != nil || json.Unmarshal(raw, &body) != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body is not the expected JSON object")
		return "", "", false
	}
	if body.Key == "" || len(body.Key) > vendorKeyMaxLen || strings.IndexFunc(body.Key, func(c rune) bool {
		return unicode.IsSpace(c) || unicode.IsControl(c)
	}) >= 0 {
		writeErr(w, http.StatusUnprocessableEntity, "bad_key", "key must be 1 to 4096 characters with no space or control character")
		return "", "", false
	}
	if kind != "qwen" {
		if body.BaseURL != "" {
			writeErr(w, http.StatusUnprocessableEntity, "bad_base_url", "only qwen takes a base_url")
			return "", "", false
		}
		return body.Key, "", true
	}
	if u, err := url.Parse(body.BaseURL); err != nil || u.Scheme != "https" || u.Host == "" || len(body.BaseURL) > 2048 ||
		strings.ContainsFunc(body.BaseURL, unicode.IsSpace) {
		writeErr(w, http.StatusUnprocessableEntity, "bad_base_url", "qwen needs an https base_url")
		return "", "", false
	}
	return body.Key, body.BaseURL, true
}

func (s *Server) handlePutVendorKey(w http.ResponseWriter, r *http.Request) {
	act, ok := s.vendorKeyActor(w, r, true)
	if !ok {
		return
	}
	kind, ok := vendorKeyKind(w, r)
	if !ok {
		return
	}
	key, baseURL, ok := vendorKeyBody(w, r, kind)
	if !ok {
		return
	}
	keyID := uid.New()
	sealed, err := s.o.VendorKeySealer.Seal(r.Context(), act.tenant, kind, keyID, key)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", act.tenant).Str("kind", kind).Msg("vendor_key.seal_failed")
		writeErr(w, http.StatusServiceUnavailable, "seal_failed", "the key was not stored: it could not be sealed")
		return
	}
	now := s.o.Now()
	replaced, err := act.st.PutVendorKey(r.Context(), act.tenant, store.VendorKeyPut{Kind: kind, KeyID: keyID,
		Ciphertext: sealed.Ciphertext, WrappedDEK: sealed.WrappedDEK, KMSKeyVersion: sealed.KMSKeyVersion,
		Last4: sealed.Last4, Fingerprint: sealed.Fingerprint, BaseURL: baseURL, Actor: act.hum}, now)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", act.tenant).Str("kind", kind).Msg("vendor_key.put_failed")
		writeErr(w, http.StatusInternalServerError, "internal", "the key was not stored")
		return
	}
	action := store.VendorKeySet
	if replaced {
		action = store.VendorKeyReplace
	}
	s.o.Log.Info().Str("tenant", act.tenant).Str("kind", kind).Str("by", act.hum).Str("action", action).
		Str("last4", sealed.Last4).Msg("vendor_key.stored")
	s.mailVendorKeyNotice(r.Context(), VendorKeyNotice{Tenant: act.tenant, Kind: kind, Action: action,
		Last4: sealed.Last4, By: act.hum, At: now})
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleDeleteVendorKey(w http.ResponseWriter, r *http.Request) {
	act, ok := s.vendorKeyActor(w, r, true)
	if !ok {
		return
	}
	kind := r.PathValue("kind")
	if !slices.Contains(store.VendorKeyKinds, kind) {
		writeErr(w, http.StatusNotFound, "unknown_kind", "not a vendor key kind")
		return
	}
	now := s.o.Now()
	last4, err := act.st.DeleteVendorKey(r.Context(), act.tenant, kind, act.hum, now)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_set", "this workspace holds no key of that kind")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", act.tenant).Str("kind", kind).Msg("vendor_key.remove_failed")
		writeErr(w, http.StatusInternalServerError, "internal", "the key was not removed")
		return
	}
	s.o.Log.Info().Str("tenant", act.tenant).Str("kind", kind).Str("by", act.hum).Str("last4", last4).Msg("vendor_key.removed")
	s.mailVendorKeyNotice(r.Context(), VendorKeyNotice{Tenant: act.tenant, Kind: kind, Action: store.VendorKeyRemove,
		Last4: last4, By: act.hum, At: now})
	w.WriteHeader(http.StatusNoContent)
}

// handleConfirmVendorKeyManager: a confirmed manager confirms another member
// who holds vendor_keys.manage (127 Q-4 A); the admin_confirm audit row is
// the confirmation (rdb 0232). Confirming a confirmed member writes nothing.
func (s *Server) handleConfirmVendorKeyManager(w http.ResponseWriter, r *http.Request) {
	act, ok := s.vendorKeyActor(w, r, true)
	if !ok {
		return
	}
	target := r.PathValue("human_id")
	acc, err := s.access(r.Context(), target, act.tenant)
	if err != nil || !acc.Can(rbac.VendorKeysManage) {
		writeErr(w, http.StatusNotFound, "not_a_manager", "not a member who holds "+rbac.VendorKeysManage)
		return
	}
	done, err := act.st.VendorKeyManagerConfirmed(r.Context(), act.tenant, target)
	if err == nil && !done {
		err = act.st.ConfirmVendorKeyManager(r.Context(), act.tenant, target, act.hum, s.o.Now())
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_a_manager", "not a member of this workspace")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "the confirmation was not stored")
		return
	}
	if !done {
		s.o.Log.Info().Str("tenant", act.tenant).Str("member", target).Str("by", act.hum).Msg("vendor_key.manager_confirmed")
	}
	w.WriteHeader(http.StatusNoContent)
}

// mailVendorKeyNotice mails n to every admin and biz owner of the workspace
// who is neither disabled nor suspended, each in their own locale (spec 159
// 3). A relay failure is logged (the address as mail.Digest) and does not
// undo the change: it is stored and audited already.
func (s *Server) mailVendorKeyNotice(ctx context.Context, n VendorKeyNotice) {
	if s.o.VendorKeyMail == nil {
		s.o.Log.Warn().Str("tenant", n.Tenant).Str("kind", n.Kind).Msg("vendor_key.mail_off: no relay, nobody mailed")
		return
	}
	md, ok := s.o.Store.(store.MemberDirectory)
	if !ok {
		return
	}
	members, err := md.ListMembers(ctx, n.Tenant)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", n.Tenant).Msg("vendor_key.mail_members")
		return
	}
	h, _ := s.o.Store.(store.Humans)
	for _, m := range members {
		if m.HumanID == n.By && m.DisplayName != "" {
			n.By = m.DisplayName
		}
	}
	for _, m := range members {
		if m.Email == "" || m.Disabled || m.Suspended ||
			!(slices.Contains(m.Roles, rbac.Admin) || slices.Contains(m.Roles, rbac.BizOwner) || m.Role == rbac.Admin || m.Role == rbac.BizOwner) {
			continue
		}
		locale := ""
		if h != nil {
			locale, _ = h.PreferredLocale(ctx, m.HumanID)
		}
		if err := s.o.VendorKeyMail(ctx, m.Email, locale, n); err != nil {
			s.o.Log.Error().Err(err).Str("tenant", n.Tenant).Str("kind", n.Kind).Str("to", mail.Digest(m.Email)).
				Msg("vendor_key.mail_failed")
		}
	}
}
