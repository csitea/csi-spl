package hub

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A workspace key on a box (spec 127 v1.4 5.1-5.2, row H2; spec 159 v0.2 9,
// row T5; rdb 0233). The box's desk (127 X1, hubclient.VendorKeyHub) asks
// over REST with its session's upload token, like every desk REST call:
//
//	POST /v1/vendor-keys/{kind}/lease      -> 200 {"sealed":"<base64>"}
//	POST /v1/vendor-keys/{kind}/exhausted  -> 200 {"kind","exhausted":true,"first"}
//
// The box is the token's, proven by the session's hello; no body names it.
// A lease is answered only for a pin that declared box_mode dedicated, a box
// a manager of the workspace approved for keys (127 5.1), a key of that kind
// that is set and not exhausted; the row is read in the pin's own tenant
// scope (127 L1). Refusals, in that order: 401 door, 403 box_only (a
// member's token), 503 vendor_keys_off, 400 bad_kind, 409
// kind_not_available, 403 box_not_dedicated, 403 box_not_approved, 409
// no_key, 409 key_exhausted. No refusal is a 404: the desk reads a 404 as
// "this hub has no lease route" (keydesk.TokNoLeaseRoute). The sealed answer
// (127 5.2 step 3) needs the box's X25519 key, which the join does not carry
// yet (T5 increment 3): until then every lease that passes the checks is
// 409 box_key_not_enrolled, and nothing is opened or audited.
//
// exhausted is the desk's report that the vendor refused the key for
// credit, quota or a revoked key (keyexec's classifier; no vendor text, no
// body). The hub marks the key exhausted, so the next lease of that kind is
// 409 key_exhausted on every box of the workspace, until a manager replaces
// the key or presses retry (POST /v1/vendor-keys/{kind}/retry). first is
// false when the key was already exhausted.

// vendorKeyExhaustedOut answers POST /v1/vendor-keys/{kind}/exhausted.
type vendorKeyExhaustedOut struct {
	Kind      string `json:"kind"`
	Exhausted bool   `json:"exhausted"`
	First     bool   `json:"first"`
}

// vendorKeyBox runs the checks a lease and a report share: a box's token,
// the routes are on, the kind takes a key, and the box's pin is dedicated.
func (s *Server) vendorKeyBox(w http.ResponseWriter, r *http.Request) (st store.VendorKeyLeases, tenant, box, kind string, ok bool) {
	t, box, ok := s.tokenTenant(w, r)
	if !ok {
		return nil, "", "", "", false
	}
	if box == WUIBox {
		writeErr(w, http.StatusForbidden, "box_only", "a workspace key is leased only to a box's desk")
		return nil, "", "", "", false
	}
	st, ok = s.o.Store.(store.VendorKeyLeases)
	pm, pmOK := s.o.Store.(store.BoxJoinSwitch)
	if s.o.VendorKeySealer == nil || !ok || !pmOK {
		writeErr(w, http.StatusServiceUnavailable, "vendor_keys_off", "workspace vendor keys are not configured on this hub")
		return nil, "", "", "", false
	}
	kind = r.PathValue("kind")
	if !slices.Contains(store.VendorKeyKinds, kind) {
		writeErr(w, http.StatusBadRequest, "bad_kind", "not a vendor key kind")
		return nil, "", "", "", false
	}
	if !slices.Contains(VendorKeyAvailable, kind) {
		writeErr(w, http.StatusConflict, "kind_not_available", "not available for workspace keys: waiting for the vendor's terms or its gate")
		return nil, "", "", "", false
	}
	mode, err := pm.PinBoxMode(r.Context(), t.ID, box)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusInternalServerError, "internal", "box mode unavailable")
		return nil, "", "", "", false
	}
	if mode != store.BoxModeDedicated {
		writeErr(w, http.StatusForbidden, "box_not_dedicated", "workspace keys go only to a box that joined this workspace as dedicated")
		return nil, "", "", "", false
	}
	return st, t.ID, box, kind, true
}

// handleVendorKeyLease runs every check of a lease (127 5.2 step 2). It
// answers a refusal in every case today: the seal is increment 3.
func (s *Server) handleVendorKeyLease(w http.ResponseWriter, r *http.Request) {
	st, tenant, box, kind, ok := s.vendorKeyBox(w, r)
	if !ok {
		return
	}
	_, err := st.VendorKeyForLease(r.Context(), tenant, kind, box)
	switch {
	case errors.Is(err, store.ErrVendorKeyBoxNotApproved):
		writeErr(w, http.StatusForbidden, "box_not_approved", "no admin or business owner of this workspace approved this box for keys")
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusConflict, "no_key", "this workspace holds no key of that kind")
	case errors.Is(err, store.ErrVendorKeyExhausted):
		writeErr(w, http.StatusConflict, "key_exhausted", "the vendor refused this workspace's key of that kind; a workspace admin or business owner can replace it on Agent keys")
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("box", box).Str("kind", kind).Msg("vendor_key.lease_failed")
		writeErr(w, http.StatusInternalServerError, "internal", "the key was not read")
	default:
		s.o.Log.Info().Str("tenant", tenant).Str("box", box).Str("kind", kind).Msg("vendor_key.lease_unsealed")
		writeErr(w, http.StatusConflict, "box_key_not_enrolled", "this box registered no X25519 key at join, so no lease can be sealed to it; re-enrol the box")
	}
}

// handleVendorKeyExhausted records the vendor's refusal a box reports.
func (s *Server) handleVendorKeyExhausted(w http.ResponseWriter, r *http.Request) {
	st, tenant, box, kind, ok := s.vendorKeyBox(w, r)
	if !ok {
		return
	}
	first, last4, err := st.MarkVendorKeyExhausted(r.Context(), tenant, kind, box, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusConflict, "no_key", "this workspace holds no key of that kind")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("box", box).Str("kind", kind).Msg("vendor_key.exhausted_failed")
		writeErr(w, http.StatusInternalServerError, "internal", "the refusal was not recorded")
		return
	}
	if first {
		s.o.Log.Info().Str("tenant", tenant).Str("box", box).Str("kind", kind).Str("last4", last4).Msg("vendor_key.exhausted")
	}
	writeJSON(w, http.StatusOK, vendorKeyExhaustedOut{Kind: kind, Exhausted: true, First: first})
}

// handleRetryVendorKey: a manager clears the exhausted state (159 9 point
// 2), POST /v1/vendor-keys/{kind}/retry -> 204, 404 not_set. Clearing a key
// that is not exhausted writes nothing and is 204 too.
func (s *Server) handleRetryVendorKey(w http.ResponseWriter, r *http.Request) {
	act, ok := s.vendorKeyActor(w, r, true)
	if !ok {
		return
	}
	st, ok := s.o.Store.(store.VendorKeyLeases)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "vendor_keys_off", "workspace vendor keys are not configured on this hub")
		return
	}
	kind := r.PathValue("kind")
	if !slices.Contains(store.VendorKeyKinds, kind) {
		writeErr(w, http.StatusNotFound, "unknown_kind", "not a vendor key kind")
		return
	}
	cleared, err := st.RetryVendorKey(r.Context(), act.tenant, kind, act.hum, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_set", "this workspace holds no key of that kind")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", act.tenant).Str("kind", kind).Msg("vendor_key.retry_failed")
		writeErr(w, http.StatusInternalServerError, "internal", "the key state was not cleared")
		return
	}
	if cleared {
		s.o.Log.Info().Str("tenant", act.tenant).Str("kind", kind).Str("by", act.hum).Msg("vendor_key.retry")
	}
	w.WriteHeader(http.StatusNoContent)
}

// handlePutVendorKeySettings: PUT /v1/vendor-keys/settings
// {"metered_fallback": bool} -> 204, the switch "fall back to spool-hub's
// metered agents" (159 9, owner Q-2 B; off by default). GET /v1/vendor-keys
// reads it as metered_fallback.
func (s *Server) handlePutVendorKeySettings(w http.ResponseWriter, r *http.Request) {
	act, ok := s.vendorKeyActor(w, r, true)
	if !ok {
		return
	}
	st, ok := s.o.Store.(store.VendorKeyLeases)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "vendor_keys_off", "workspace vendor keys are not configured on this hub")
		return
	}
	var in struct {
		MeteredFallback *bool `json:"metered_fallback"`
	}
	if !readJSONStrict(w, r, &in, vendorKeysMaxBody, "invalid JSON body (only metered_fallback)") {
		return
	}
	if in.MeteredFallback == nil {
		writeErr(w, http.StatusBadRequest, "bad_body", `the body is {"metered_fallback": true|false}`)
		return
	}
	if err := st.SetVendorKeyMeteredFallback(r.Context(), act.tenant, *in.MeteredFallback, act.hum, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", act.tenant).Msg("vendor_key.fallback_failed")
		writeErr(w, http.StatusInternalServerError, "internal", "the setting was not saved")
		return
	}
	s.o.Log.Info().Str("tenant", act.tenant).Bool("metered_fallback", *in.MeteredFallback).Str("by", act.hum).Msg("vendor_key.fallback")
	w.WriteHeader(http.StatusNoContent)
}

// vendorKeyMeteredFallback reads the fall-back switch for GET
// /v1/vendor-keys. A store error reads as off (the default).
func (s *Server) vendorKeyMeteredFallback(ctx context.Context, tenant string) bool {
	st, ok := s.o.Store.(store.VendorKeyLeases)
	if !ok {
		return false
	}
	on, err := st.VendorKeyMeteredFallback(ctx, tenant)
	return err == nil && on
}

// exhaustedAt formats a row's exhausted time, "" when usable.
func exhaustedAt(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}
