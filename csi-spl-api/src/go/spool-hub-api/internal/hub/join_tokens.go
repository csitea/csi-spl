package hub

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/edge"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Agent join tokens (spec 073 4.1-4.3, T003): a workspace admin mints a
// one-use token; the box redeems it with a signature of its own key, and the
// hub pins that key. The root key never leaves its holder.
//
//	POST   /v1/tenant/agents/join-tokens       agents.join  mint (the token, once)
//	GET    /v1/tenant/agents/join-tokens       agents.join  the unexpired tokens, never a token
//	DELETE /v1/tenant/agents/join-tokens/{id}  agents.join  revoke an unused token
//	DELETE /v1/tenant/agents/pins/{box_id}     agents.join  revoke one seat, close its sessions
//	POST   /v1/pins/join                       the token + the box key's signature
//
// The lifetime is Options.JoinTokenTTL (cnf SPOOL_HUB_JOIN_TOKEN_TTL); the
// plain token is in the mint answer only, never in a log or the database.

const (
	// joinTokenPrefix marks a token so a secret scanner finds a leaked one.
	joinTokenPrefix = "spj1."
	joinSecretBytes = 32
	// joinWritesPerHour is the per-human mint / revoke window (keys.go's 30).
	joinWritesPerHour = keysWritesPerHour
	// joinRedeemsPerHour is the per-source-address redeem window (spec 4.3).
	joinRedeemsPerHour = 20
	joinLabelMax       = 80
	// joinFix ends every redeem refusal: where a new token comes from.
	joinFix = "ask a tenant admin for a join token in Tenant settings -> Agents"
	// codeBoxJoinDisabled is the 403 of a workspace whose spec 108 switch
	// is off (section 3.8, rdb 0170): no join token is minted or redeemed.
	codeBoxJoinDisabled = "box_join_disabled"
	// codeBoxModeShared is the 403 of a box that is not dedicated to the
	// workspace it joins, when that workspace's switch is on (section 3.8).
	codeBoxModeShared  = "box_mode_shared"
	boxJoinDisabledMsg = "joining boxes with a join token is not enabled for this workspace; the operator of this hub turns it on"
	boxModeSharedMsg   = "this workspace accepts only boxes dedicated to it; enrol the box with do_spl_box_workspace_setup first"
)

var joinIDRe = regexp.MustCompile(`^[0-9a-f]{8}$`)

func (s *Server) routeJoinTokens(mux *http.ServeMux) {
	s.joinLim = edge.NewWindow(time.Hour, s.o.Now)
	s.redeemLim = edge.NewWindow(time.Hour, s.o.Now)
	mux.HandleFunc("POST /v1/tenant/agents/join-tokens", s.handleJoinMint)
	mux.HandleFunc("GET /v1/tenant/agents/join-tokens", s.handleJoinList)
	mux.HandleFunc("DELETE /v1/tenant/agents/join-tokens/{id}", s.handleJoinRevoke)
	mux.HandleFunc("DELETE /v1/tenant/agents/pins/{box_id}", s.handleSeatRevoke)
	mux.HandleFunc("OPTIONS /v1/tenant/agents/join-tokens", s.membersPreflight)
	mux.HandleFunc("OPTIONS /v1/tenant/agents/join-tokens/{id}", s.membersPreflight)
	mux.HandleFunc("OPTIONS /v1/tenant/agents/pins/{box_id}", s.membersPreflight)
	mux.HandleFunc("POST /v1/pins/join", s.handleJoinRedeem)
}

// newJoinToken answers the plain token and the hash the store keeps.
func newJoinToken(tenant string) (token, hash string, err error) {
	b := make([]byte, joinSecretBytes)
	if _, err := rand.Read(b); err != nil {
		return "", "", err
	}
	secret := base64.RawURLEncoding.EncodeToString(b)
	return joinTokenPrefix + tenant + "." + secret, joinHash(secret), nil
}

func joinHash(secret string) string {
	sum := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(sum[:])
}

// parseJoinToken splits spj1.<tenant>.<secret>; ok false = not a join token.
func parseJoinToken(tok string) (tenant, hash string, ok bool) {
	rest, ok := strings.CutPrefix(strings.TrimSpace(tok), joinTokenPrefix)
	if !ok {
		return "", "", false
	}
	tenant, secret, ok := strings.Cut(rest, ".")
	if !ok || !msg.ValidTenantID(tenant) {
		return "", "", false
	}
	if raw, err := base64.RawURLEncoding.DecodeString(secret); err != nil || len(raw) != joinSecretBytes {
		return "", "", false
	}
	return tenant, joinHash(secret), true
}

// joinStore answers the store's join-token half, or writes 501.
func (s *Server) joinStore(w http.ResponseWriter) (store.JoinTokens, bool) {
	js, ok := s.o.Store.(store.JoinTokens)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no join tokens")
	}
	return js, ok
}

// boxJoinOn reads the workspace's spec 108 switch (section 3.8). A store that
// keeps no switch answers off: the feature is off unless switched on.
func (s *Server) boxJoinOn(ctx context.Context, tenant string) (bool, error) {
	sw, ok := s.o.Store.(store.BoxJoinSwitch)
	if !ok {
		return false, nil
	}
	return sw.BoxJoinEnabled(ctx, tenant)
}

// boxJoinAllowed answers 403 box_join_disabled when tenant's switch is off,
// 503 when it was not read; false = answered.
func (s *Server) boxJoinAllowed(w http.ResponseWriter, r *http.Request, tenant string) bool {
	on, err := s.boxJoinOn(r.Context(), tenant)
	switch {
	case err != nil:
		writeErrCause(w, http.StatusServiceUnavailable, "unavailable", "the workspace's join switch was not read", err)
		return false
	case !on:
		writeErr(w, http.StatusForbidden, codeBoxJoinDisabled, boxJoinDisabledMsg)
		return false
	}
	return true
}

// joinWrite applies the per-human mint / revoke window; false = 429 answered.
func (s *Server) joinWrite(w http.ResponseWriter, hum string) bool {
	ok, retry := s.joinLim.Allow(hum, joinWritesPerHour)
	if !ok {
		w.Header().Set("Retry-After", strconv.Itoa(int(retry.Seconds())+1))
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many join token changes")
	}
	return ok
}

// hubURL is the base URL the request reached, for the pasteable join line.
func hubURL(r *http.Request) string {
	scheme := "https"
	if p := strings.TrimSpace(strings.Split(r.Header.Get("X-Forwarded-Proto"), ",")[0]); p != "" {
		scheme = p
	} else if r.TLS == nil {
		scheme = "http"
	}
	return scheme + "://" + r.Host
}

type joinMintBody struct {
	Label    string `json:"label"`
	BoxID    string `json:"box_id"`
	ForHuman string `json:"for_human"`
}

type joinTokenJSON struct {
	ID          string    `json:"id"`
	Label       string    `json:"label"`
	BoxID       string    `json:"box_id"`
	ForHuman    string    `json:"for_human"`
	CreatedBy   string    `json:"created_by"`
	CreatedAt   time.Time `json:"created_at"`
	ExpiresAt   time.Time `json:"expires_at"`
	State       string    `json:"state"`
	ConsumedBox string    `json:"consumed_box,omitempty"`
}

// POST /v1/tenant/agents/join-tokens {label?, box_id?, for_human?}
func (s *Server) handleJoinMint(w http.ResponseWriter, r *http.Request) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.AgentsJoin)
	if !ok {
		return
	}
	js, ok := s.joinStore(w)
	if !ok || !s.boxJoinAllowed(w, r, t.ID) {
		return
	}
	if s.o.JoinTokenTTL <= 0 {
		writeErr(w, http.StatusServiceUnavailable, "join_tokens_off", "this hub has no join token lifetime (SPOOL_HUB_JOIN_TOKEN_TTL)")
		return
	}
	var in joinMintBody
	if !readJSONStrict(w, r, &in, keysMaxBody, "invalid JSON body (only label, box_id, for_human)") || !s.joinWrite(w, a.HumanID) {
		return
	}
	in.Label = strings.TrimSpace(in.Label)
	switch {
	case utf8.RuneCountInString(in.Label) > joinLabelMax:
		writeErr(w, http.StatusBadRequest, "bad_request", "label is longer than 80 characters")
		return
	case in.BoxID == WUIBox:
		writeErr(w, http.StatusBadRequest, "reserved_box", WUIBox+" is the reserved browser box")
		return
	case in.BoxID != "" && !msg.ValidBoxID(in.BoxID):
		writeErr(w, http.StatusBadRequest, "bad_request", "box_id is not a box id ([a-z0-9-], up to 32)")
		return
	}
	if in.ForHuman != "" {
		if _, err := s.access(r.Context(), in.ForHuman, t.ID); !humanIDRe.MatchString(in.ForHuman) || err != nil {
			writeErr(w, http.StatusBadRequest, "join_token_member",
				"for_human is not a current member of this workspace; pick a current member in Tenant settings -> Members")
			return
		}
	}
	token, hash, err := newJoinToken(t.ID)
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "no join token minted", err)
		return
	}
	now := s.o.Now().UTC()
	jt := store.JoinToken{Hash: hash, TenantID: t.ID, CreatedBy: a.HumanID, ForHuman: in.ForHuman,
		Label: in.Label, BoxID: in.BoxID, CreatedAt: now, ExpiresAt: now.Add(s.o.JoinTokenTTL)}
	if err := js.CreateJoinToken(r.Context(), jt); err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "join token not stored", err)
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("join_token", jt.ID()).Str("by", a.HumanID).
		Str("box_id", in.BoxID).Str("for_human", in.ForHuman).Msg("join token minted")
	writeJSON(w, http.StatusCreated, map[string]any{
		"id": jt.ID(), "token": token, "expires_at": jt.ExpiresAt, "box_id": in.BoxID, "for_human": in.ForHuman,
		"join_line": "SPOOL_JOIN_TOKEN=" + token + " spool join " + hubURL(r),
	})
}

// GET /v1/tenant/agents/join-tokens
func (s *Server) handleJoinList(w http.ResponseWriter, r *http.Request) {
	t, _, _, _, ok := s.membersActor(w, r, rbac.AgentsJoin)
	if !ok {
		return
	}
	js, ok := s.joinStore(w)
	if !ok {
		return
	}
	toks, err := js.ListJoinTokens(r.Context(), t.ID, s.o.Now())
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "join tokens unavailable", err)
		return
	}
	// enabled: the spec 108 switch (3.8), so the WUI offers a new token only
	// when the hub would mint one. Open tokens stay listed either way, to revoke.
	enabled, err := s.boxJoinOn(r.Context(), t.ID)
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "unavailable", "the workspace's join switch was not read", err)
		return
	}
	out := make([]joinTokenJSON, 0, len(toks))
	for _, jt := range toks {
		out = append(out, joinTokenJSON{ID: jt.ID(), Label: jt.Label, BoxID: jt.BoxID, ForHuman: jt.ForHuman,
			CreatedBy: jt.CreatedBy, CreatedAt: jt.CreatedAt.UTC(), ExpiresAt: jt.ExpiresAt.UTC(), State: jt.State(),
			ConsumedBox: jt.ConsumedBox})
	}
	writeJSON(w, http.StatusOK, map[string]any{"tokens": out, "enabled": enabled})
}

// DELETE /v1/tenant/agents/join-tokens/{id}
func (s *Server) handleJoinRevoke(w http.ResponseWriter, r *http.Request) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.AgentsJoin)
	if !ok {
		return
	}
	js, ok := s.joinStore(w)
	if !ok {
		return
	}
	id := r.PathValue("id")
	if !joinIDRe.MatchString(id) {
		writeErr(w, http.StatusBadRequest, "bad_request", "id is the 8 hex of a join token")
		return
	}
	if !s.joinWrite(w, a.HumanID) {
		return
	}
	jt, err := js.RevokeJoinToken(r.Context(), t.ID, id, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such join token")
		return
	case errors.Is(err, store.ErrJoinTokenUsed):
		writeErr(w, http.StatusConflict, "join_token_used", "this token already seated "+jt.ConsumedBox+"; revoke that seat in Tenant settings -> Agents")
		return
	case err != nil:
		writeErrCause(w, http.StatusInternalServerError, "internal", "join token not revoked", err)
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("join_token", id).Str("by", a.HumanID).Msg("join token revoked")
	writeJSON(w, http.StatusOK, map[string]string{"id": id, "state": jt.State()})
}

// DELETE /v1/tenant/agents/pins/{box_id}: revoke one seat from a member
// session (FR-004). Not billing-gated: dropping a seat never adds access.
func (s *Server) handleSeatRevoke(w http.ResponseWriter, r *http.Request) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.AgentsJoin)
	if !ok {
		return
	}
	js, ok := s.joinStore(w)
	if !ok {
		return
	}
	box := r.PathValue("box_id")
	switch {
	case box == WUIBox:
		writeErr(w, http.StatusBadRequest, "reserved_box", WUIBox+" is the reserved browser box")
		return
	case !msg.ValidBoxID(box):
		writeErr(w, http.StatusBadRequest, "bad_request", "box_id is not a box id")
		return
	}
	if err := js.RevokeSeat(r.Context(), t.ID, box, s.o.Now()); errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such pin")
		return
	} else if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "revoke not stored", err)
		return
	}
	s.closeBoxSessions(t.ID, box)
	s.o.Log.Info().Str("tenant", t.ID).Str("box_id", box).Str("by", a.HumanID).Msg("seat revoked")
	writeJSON(w, http.StatusOK, map[string]string{"box_id": box, "revoked": "true"})
}

// POST /v1/pins/join {token, box_id, pubkey, ts, sig}: pins the box key the
// token's holder proves it holds. The workspace is the token's; a Host or
// X-Spool-Tenant naming another is refused (spec 108 3.2).
func (s *Server) handleJoinRedeem(w http.ResponseWriter, r *http.Request) {
	if ok, retry := s.redeemLim.Allow(s.edge.ClientIP(r), joinRedeemsPerHour); !ok {
		w.Header().Set("Retry-After", strconv.Itoa(int(retry.Seconds())+1))
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many join attempts from this address")
		return
	}
	js, ok := s.joinStore(w)
	if !ok {
		return
	}
	var req wire.JoinRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, maxJSONBody)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "join body does not parse")
		return
	}
	tenant, hash, ok := parseJoinToken(req.Token)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "join_token_invalid", "unknown join token; "+joinFix)
		return
	}
	if !s.tenantConsistent(w, r, tenant) {
		return
	}
	if _, err := s.o.Store.GetTenant(r.Context(), tenant); err != nil {
		writeErr(w, http.StatusUnauthorized, "join_token_invalid", "unknown join token; "+joinFix)
		return
	}
	t, ok := s.loadTenant(w, r, tenant)
	if !ok || !s.boxJoinAllowed(w, r, t.ID) {
		return
	}
	if req.BoxMode != store.BoxModeDedicated {
		// Switch on = a restricted workspace: dedicated boxes only (3.8).
		// An undeclared mode is an older spool join on a shared box.
		if req.BoxMode != "" && !store.ValidBoxMode(req.BoxMode) {
			writeErr(w, http.StatusBadRequest, "bad_json", "box_mode is dedicated or shared")
			return
		}
		writeErr(w, http.StatusForbidden, codeBoxModeShared, boxModeSharedMsg)
		return
	}
	if req.BoxID == WUIBox {
		writeErr(w, http.StatusBadRequest, "reserved_box", WUIBox+" is the reserved browser box")
		return
	}
	pub, err := base64.StdEncoding.DecodeString(req.PubKey)
	if err != nil || len(pub) != ed25519.PublicKeySize || !msg.ValidBoxID(req.BoxID) {
		writeErr(w, http.StatusBadRequest, "bad_json", "box_id or pubkey is malformed")
		return
	}
	payload, _ := wire.JoinModePayload(hash, req.BoxID, req.PubKey, req.TS, req.BoxMode)
	if !s.skewOK(req.TS) || verify(ed25519.PublicKey(pub), payload, req.Sig) != nil {
		writeErr(w, http.StatusBadRequest, "bad_sig", "the box key signature does not verify")
		return
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return
	}
	if !s.pinQuotaOK(w, r, t.ID, req.BoxID) {
		return
	}
	jt, err := js.RedeemJoinToken(r.Context(), t.ID, hash, req.BoxID, ed25519.PublicKey(pub), req.BoxMode, s.o.Now())
	if s.joinRefused(w, jt, err) {
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("join_token", jt.ID()).Str("box_id", req.BoxID).
		Str("box_mode", req.BoxMode).Msg("join token redeemed")
	writeJSON(w, http.StatusOK, map[string]string{"tenant": t.ID, "box_id": req.BoxID, "pubkey": req.PubKey})
}

// pinQuotaOK applies the pin quota to a box not pinned yet; false = answered.
func (s *Server) pinQuotaOK(w http.ResponseWriter, r *http.Request, tenant, box string) bool {
	if _, err := s.o.Store.GetPin(r.Context(), tenant, box); !errors.Is(err, store.ErrNotFound) {
		return true
	}
	pins, err := s.o.Store.ListPins(r.Context(), tenant)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "pins unavailable")
		return false
	}
	if s.quota().Over(billing.Usage{Pins: len(pins)}, 0, 1, 0) != "" {
		writeQuota(w, "pin count exceeds the tenant quota")
		return false
	}
	return true
}

// joinRefused writes the refusal table of spec 4.3 for a redeem error.
func (s *Server) joinRefused(w http.ResponseWriter, jt store.JoinToken, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, store.ErrJoinTokenInvalid):
		writeErr(w, http.StatusUnauthorized, "join_token_invalid", "unknown join token; "+joinFix)
	case errors.Is(err, store.ErrJoinTokenUsed):
		writeErr(w, http.StatusGone, "join_token_used", "this join token was already used; "+joinFix)
	case errors.Is(err, store.ErrJoinTokenExpired):
		writeErr(w, http.StatusGone, "join_token_expired",
			"this join token expired (expired at "+jt.ExpiresAt.UTC().Format(time.RFC3339)+"); "+joinFix)
	case errors.Is(err, store.ErrJoinTokenRevoked):
		writeErr(w, http.StatusGone, "join_token_revoked", "this join token was revoked; "+joinFix)
	case errors.Is(err, store.ErrJoinTokenBoxMismatch):
		writeErr(w, http.StatusConflict, "join_token_box_mismatch", "this token seats "+jt.BoxID+" only")
	case errors.Is(err, store.ErrConflict):
		// One message for both cases, so it never says whether, or where,
		// the key is seated in another workspace (spec 108 3.1).
		writeErr(w, http.StatusConflict, "pin_conflict",
			"box_id is already seated with another key, or this key is seated elsewhere; revoke it in Tenant settings -> Agents first")
	default:
		writeErrCause(w, http.StatusInternalServerError, "internal", "pin not stored", err)
	}
	return true
}
