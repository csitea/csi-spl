package hub

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strconv"
	"time"

	"filippo.io/age"

	"github.com/csitea/csi-spl/spool-hub-api/internal/keydesk"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/vendorkey"
)

// A workspace key on a box (spec 127 v1.4 5.1-5.2, row H2; spec 159 v0.2 9,
// row T5; rdb 0235). The box's desk (127 X1, hubclient.VendorKeyHub) asks
// over REST with its session's upload token, like every desk REST call:
//
//	POST /v1/vendor-keys/{kind}/lease      -> 200 {"sealed":"<base64>"}
//	POST /v1/vendor-keys/{kind}/exhausted  -> 200 {"kind","exhausted":true,"first"}
//	     optional body {"task_id": "<the running task>"}
//
// The box is the token's, proven by the session's hello; no body names it.
// A lease is answered only for a pin that declared box_mode dedicated, a box
// a manager of the workspace approved for keys (127 5.1), a key of that kind
// that is set and not exhausted; the row is read in the pin's own tenant
// scope (127 L1). Refusals, in that order: 401 door, 403 box_only (a
// member's token), 503 vendor_keys_off, 400 bad_kind, 409
// kind_not_available, 403 box_not_dedicated, 403 box_not_approved, 409
// no_key, 409 key_exhausted. No refusal is a 404: the desk reads a 404 as
// "this hub has no lease route" (keydesk.TokNoLeaseRoute). The answer is
// sealed (127 5.2 step 3) to the X25519 recipient the box's desk sent at
// join (rdb 0235), with age, as keydesk.Payload: kind, box, key_id, key,
// base_url and the TTL. A pin with no recipient is 409
// box_key_not_enrolled, and nothing is opened; an answered lease writes
// its lease audit row (box, kind, last4) before it is sent.
//
// exhausted is the desk's report that the vendor refused the key for
// credit, quota or a revoked key (keyexec's classifier; no vendor text). Its
// only body field is the running task's id, when the seat knows it. The
// hub marks the key exhausted, so the next lease of that kind is
// 409 key_exhausted on every box of the workspace, until a manager replaces
// the key or presses retry (POST /v1/vendor-keys/{kind}/retry). first is
// false when the key was already exhausted. On the first report only, the
// task's topic gets one hub line (159 9 point 3), in the box's workspace.

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

// handleVendorKeyLease runs every check of a lease (127 5.2 step 2), then
// answers the sealed key.
func (s *Server) handleVendorKeyLease(w http.ResponseWriter, r *http.Request) {
	st, tenant, box, kind, ok := s.vendorKeyBox(w, r)
	if !ok {
		return
	}
	row, err := st.VendorKeyForLease(r.Context(), tenant, kind, box)
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
		s.answerVendorKeyLease(w, r, st, tenant, box, kind, row)
	}
}

// vendorKeyLeaseTTL is the lease TTL the sealed answer names (127 5.2: 15
// min); the desk keeps the shorter of it and its own.
const vendorKeyLeaseTTL = 15 * time.Minute

// answerVendorKeyLease seals the key to the pin's desk recipient (127 5.2
// step 3), writes the lease audit row and answers {"sealed": base64}. The
// plaintext key lives in this function only and is never logged; a pin
// with no recipient is 409 box_key_not_enrolled, and nothing is opened.
func (s *Server) answerVendorKeyLease(w http.ResponseWriter, r *http.Request, st store.VendorKeyLeases,
	tenant, box, kind string, row store.VendorKeyLeaseRow) {
	px, ok := s.o.Store.(store.PinX25519)
	var rcpt string
	var err error
	if ok {
		rcpt, err = px.PinBoxX25519(r.Context(), tenant, box)
	}
	to, perr := age.ParseX25519Recipient(rcpt)
	if !ok || err != nil || rcpt == "" || perr != nil {
		writeErr(w, http.StatusConflict, "box_key_not_enrolled", "this box registered no X25519 key at join, so no lease can be sealed to it; join it again with a fresh token")
		return
	}
	key, err := s.o.VendorKeySealer.Open(r.Context(), tenant, kind, row.KeyID, vendorkey.Sealed{Ciphertext: row.Ciphertext,
		WrappedDEK: row.WrappedDEK, KMSKeyVersion: row.KMSKeyVersion, Last4: row.Last4})
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("kind", kind).Msg("vendor_key.lease_open_failed")
		writeErr(w, http.StatusInternalServerError, "internal", "the key did not open")
		return
	}
	sealed, err := keydesk.Seal(to, keydesk.Payload{Kind: kind, Box: box, KeyID: row.KeyID, Key: key, BaseURL: row.BaseURL,
		TTLSeconds: int(vendorKeyLeaseTTL / time.Second)})
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("kind", kind).Msg("vendor_key.lease_seal_failed")
		writeErr(w, http.StatusInternalServerError, "internal", "the lease was not sealed")
		return
	}
	if err := st.AuditVendorKeyLease(r.Context(), tenant, kind, box, row.Last4, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("kind", kind).Msg("vendor_key.lease_audit_failed")
		writeErr(w, http.StatusInternalServerError, "internal", "the lease was not audited, so it is not answered")
		return
	}
	s.o.Log.Info().Str("tenant", tenant).Str("box", box).Str("kind", kind).Str("last4", row.Last4).Msg("vendor_key.leased")
	writeJSON(w, http.StatusOK, map[string]string{"sealed": base64.StdEncoding.EncodeToString(sealed)})
}

// handleVendorKeyExhausted records the vendor's refusal a box reports.
func (s *Server) handleVendorKeyExhausted(w http.ResponseWriter, r *http.Request) {
	st, tenant, box, kind, ok := s.vendorKeyBox(w, r)
	if !ok {
		return
	}
	task := vendorKeyReportTask(w, r)
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
	if first { // 159 9 point 5: every admin and biz owner, once per refusal
		s.o.Log.Info().Str("tenant", tenant).Str("box", box).Str("kind", kind).Str("last4", last4).Msg("vendor_key.exhausted")
		s.mailVendorKeyNotice(r.Context(), VendorKeyNotice{Tenant: tenant, Kind: kind, Action: store.VendorKeyExhausted,
			Last4: last4, By: box, At: s.o.Now()})
		s.postVendorKeyExhaustedLine(r.Context(), tenant, kind, task)
	}
	writeJSON(w, http.StatusOK, vendorKeyExhaustedOut{Kind: kind, Exhausted: true, First: first})
}

// vendorKeyReportTask reads the optional body of an exhausted report,
// {"task_id": "<the running task>"} (159 9 points 3-4). No body is today's
// report. A body that does not parse, or a task id that is not a UUID (a
// topic's task_id is one), reads as no task: the refusal is recorded either
// way, only the topic line is skipped.
func vendorKeyReportTask(w http.ResponseWriter, r *http.Request) string {
	raw, err := readAllCapped(w, r, vendorKeysMaxBody)
	if err != nil || len(bytes.TrimSpace(raw)) == 0 {
		return ""
	}
	var in struct {
		TaskID string `json:"task_id"`
	}
	if json.Unmarshal(raw, &in) != nil || !uuidRe.MatchString(in.TaskID) {
		return ""
	}
	return in.TaskID
}

// vendorKeyExhaustedLine is the line of 159 9 point 3: the kind only, no
// vendor text, no key, no box.
func vendorKeyExhaustedLine(kind string) string {
	return kind + " key of this workspace refused by the vendor (out of credit or quota); " +
		"a workspace admin or business owner can replace it on Agent keys."
}

// postVendorKeyExhaustedLine posts that line once into the running task's
// topic, as a hub note (HUB-0). The topic is looked up in the reporting
// box's own workspace only (RLS), so a task id of another workspace, an
// unknown one or a direct-message topic finds no channel and nothing is
// posted. A failure is logged: the refusal is recorded and mailed anyway.
func (s *Server) postVendorKeyExhaustedLine(ctx context.Context, tenant, kind, task string) {
	if task == "" {
		return
	}
	channel := s.channelOf(ctx, tenant, "", task)
	if channel == "" {
		s.o.Log.Info().Str("tenant", tenant).Str("kind", kind).Msg("vendor_key.exhausted_line_skipped")
		return
	}
	id := uid.FromSeed("spool-vendor-key-exhausted:" + tenant + ":" + task + ":" + kind + ":" +
		strconv.FormatInt(s.o.Now().UnixNano(), 10))
	if err := s.postHubNote(ctx, tenant, channel, task, id, vendorKeyExhaustedLine(kind)); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("kind", kind).Msg("vendor_key.exhausted_line_failed")
	}
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

// joinBoxX25519 records the desk recipient a join sent (or clears it, for a
// join that sent none) on the pin the join just seated (rdb 0235). A
// failure is logged and the join stands: the box then gets no lease (409
// box_key_not_enrolled) until it joins again, which fails closed.
func (s *Server) joinBoxX25519(ctx context.Context, tenant, box, recipient string) {
	px, ok := s.o.Store.(store.PinX25519)
	if !ok {
		return
	}
	if err := px.SetPinBoxX25519(ctx, tenant, box, recipient, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("box", box).Msg("join: box_x25519 not recorded")
	}
}
