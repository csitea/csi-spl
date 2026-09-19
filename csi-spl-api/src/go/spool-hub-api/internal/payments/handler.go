package payments

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base32"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Route prefixes (checkout-v1 §1). Not tenant-scoped: they answer on any Host.
const (
	RoutePrefix  = "/api/v1/checkout"
	RouteWebhook = "/api/v1/webhooks/payment"
)

// TemplateTenantWelcome is the one email (mail.Message.Template, logs).
const TemplateTenantWelcome = "tenant_welcome"

// Store is what the handler needs from the hub store.
type Store interface {
	store.Payments
	GetTenant(ctx context.Context, tenantID string) (store.Tenant, error)
}

// Deps wires a Handler.
type Deps struct {
	Store             Store
	Log               zerolog.Logger
	Mail              mail.Sender // nil = mail.None
	MailDelivers      bool        // the transport reaches an inbox (smtp)
	TenantHostPattern string      // "{tenant}.<fqdn>"
	Provider          PaymentProvider
	Verifier          WebhookVerifier // nil = the webhook refuses everything
	Now               func() time.Time
}

// Handler is the checkout-v1 surface.
type Handler struct {
	cfg *Config
	d   Deps
}

// New builds the handler for a loaded Config. A rail other than none needs
// its driver.
func New(cfg *Config, d Deps) (*Handler, error) {
	if cfg == nil || d.Store == nil {
		return nil, errors.New("payments: config and store are required")
	}
	if cfg.Rail() != RailNone && d.Provider == nil {
		return nil, errors.New("payments: rail " + cfg.Rail() + " has no driver")
	}
	if !strings.HasPrefix(d.TenantHostPattern, "{tenant}.") {
		return nil, errors.New("payments: tenant host pattern must start with {tenant}.")
	}
	if d.Mail == nil {
		d.Mail = mail.None{}
	}
	if d.Now == nil {
		d.Now = time.Now
	}
	return &Handler{cfg: cfg, d: d}, nil
}

// Register mounts the routes. fake-pay exists only when FakePayMounted
// (never on prd: Load refuses the flag there).
func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET "+RoutePrefix+"/plan", h.plan)
	mux.HandleFunc("POST "+RoutePrefix, h.checkout)
	mux.HandleFunc("GET "+RoutePrefix+"/{checkout_id}", h.status)
	mux.HandleFunc("POST "+RoutePrefix+"/claim", h.claim)
	if h.cfg.FakePayMounted() {
		mux.HandleFunc("POST "+RoutePrefix+"/fake-pay", h.fakePay)
	}
	mux.HandleFunc("POST "+RouteWebhook, h.webhook)
	mux.HandleFunc("GET "+RouteWebhook, h.webhook)
}

// ServeHTTP makes the Handler usable on its own (tests).
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	mux := http.NewServeMux()
	h.Register(mux)
	mux.ServeHTTP(w, r)
}

func (h *Handler) providerName() string {
	if h.cfg.Rail() == RailHosted {
		return ProviderHostedHMAC
	}
	return ProviderFake
}

func (h *Handler) tenantURL(id string) string {
	return h.cfg.PublicScheme + "://" + strings.Replace(h.d.TenantHostPattern, "{tenant}", id, 1)
}

func (h *Handler) plan(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"plan_id": h.cfg.PlanID, "amount_cents": h.cfg.PlanCents, "currency": h.cfg.Currency,
		"rail": h.cfg.Rail(), "tenant_url_pattern": h.cfg.PublicScheme + "://" + h.d.TenantHostPattern,
	})
}

func newCheckoutID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return "co_" + strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b))
}

type checkoutReq struct {
	TenantID string `json:"tenant_id"`
	Email    string `json:"email"`
}

func (h *Handler) checkout(w http.ResponseWriter, r *http.Request) {
	if h.cfg.Rail() == RailNone {
		writeErr(w, http.StatusServiceUnavailable, "payment_unavailable", "no payment rail is configured")
		return
	}
	var req checkoutReq
	if err := json.NewDecoder(io.LimitReader(r.Body, 8<<10)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "body is not checkout JSON")
		return
	}
	tid := strings.ToLower(strings.TrimSpace(req.TenantID))
	email := strings.TrimSpace(req.Email)
	if !msg.ValidTenantID(tid) {
		writeErr(w, http.StatusBadRequest, "bad_tenant_id", "tenant_id is not a valid, unreserved slug")
		return
	}
	if !validEmail(email) {
		writeErr(w, http.StatusBadRequest, "bad_request", "email is not an address")
		return
	}
	ctx := r.Context()
	if _, err := h.d.Store.GetTenant(ctx, tid); err == nil {
		writeErr(w, http.StatusConflict, "tenant_taken", "that tenant exists")
		return
	} else if !errors.Is(err, store.ErrNotFound) {
		h.d.Log.Error().Err(err).Msg("checkout: tenant lookup")
		writeErr(w, http.StatusInternalServerError, "internal", "tenant lookup failed")
		return
	}
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "keygen failed")
		return
	}
	id, token := newCheckoutID(), NewClaimToken()
	sealed, err := Seal(token, id, priv)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "seal failed")
		return
	}
	// Provider first: a failed provider call must not hold the slug.
	ref, redirect, err := h.d.Provider.CreateRedirectOrder(ctx, id, email, h.cfg.Currency, h.cfg.PlanCents)
	if err != nil {
		h.d.Log.Error().Err(err).Str("checkout_id", id).Str("rail", h.cfg.Rail()).Msg("checkout: provider refused")
		writeErr(w, http.StatusServiceUnavailable, "payment_unavailable", "the payment provider did not start a payment")
		return
	}
	c := store.Checkout{ID: id, TenantID: tid, PlanID: h.cfg.PlanID, Provider: h.providerName(), ProviderRef: ref,
		AmountCents: h.cfg.PlanCents, Currency: h.cfg.Currency, Email: email, RootPubKey: pub,
		SealedRootKey: sealed, ClaimHash: ClaimHash(token)}
	if err := h.d.Store.HoldCheckout(ctx, c, h.d.Now().UTC(), h.cfg.Hold); err != nil {
		_ = h.d.Provider.CancelIntent(context.WithoutCancel(ctx), ref)
		if errors.Is(err, store.ErrConflict) {
			writeErr(w, http.StatusConflict, "tenant_taken", "that tenant exists or is being bought")
			return
		}
		h.d.Log.Error().Err(err).Str("checkout_id", id).Msg("checkout: hold not stored")
		writeErr(w, http.StatusInternalServerError, "internal", "checkout not stored")
		return
	}
	h.d.Log.Info().Str("checkout_id", id).Str("tenant_id", tid).Str("rail", h.cfg.Rail()).
		Str("to", mail.Digest(email)).Msg("checkout: slug held")
	out := map[string]any{"checkout_id": id, "claim_token": token, "rail": h.cfg.Rail(),
		"amount_cents": h.cfg.PlanCents, "currency": h.cfg.Currency, "tenant_id": tid, "tenant_url": h.tenantURL(tid)}
	if redirect != "" {
		out["redirect_url"] = redirect
	}
	writeJSON(w, http.StatusCreated, out)
}

func (h *Handler) status(w http.ResponseWriter, r *http.Request) {
	c, err := h.d.Store.GetCheckout(r.Context(), r.PathValue("checkout_id"))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such checkout")
		return
	}
	if err != nil {
		h.d.Log.Error().Err(err).Msg("checkout: status lookup")
		writeErr(w, http.StatusInternalServerError, "internal", "checkout lookup failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"checkout_id": c.ID, "tenant_id": c.TenantID,
		"status": c.Status, "claimed": !c.ClaimedAt.IsZero()})
}

type claimReq struct {
	CheckoutID string `json:"checkout_id"`
	ClaimToken string `json:"claim_token"`
}

func (h *Handler) claim(w http.ResponseWriter, r *http.Request) {
	var req claimReq
	if err := json.NewDecoder(io.LimitReader(r.Body, 8<<10)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "body is not claim JSON")
		return
	}
	ctx := r.Context()
	c, err := h.d.Store.ClaimCheckout(ctx, strings.TrimSpace(req.CheckoutID), ClaimHash(req.ClaimToken), h.d.Now().UTC())
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such checkout for that claim token")
		return
	case errors.Is(err, store.ErrNotPaid):
		writeErr(w, http.StatusConflict, "not_paid", "the payment has not arrived yet")
		return
	case errors.Is(err, store.ErrClaimed):
		writeErr(w, http.StatusGone, "claimed", "the key was already shown once; the hub no longer holds it")
		return
	case err != nil:
		h.d.Log.Error().Err(err).Msg("checkout: claim")
		writeErr(w, http.StatusInternalServerError, "internal", "claim failed")
		return
	}
	priv, err := Open(req.ClaimToken, c.ID, c.SealedRootKey)
	if err != nil || !priv.Public().(ed25519.PublicKey).Equal(c.RootPubKey) {
		// The claim hash matched, so this is corruption, not a guess.
		h.d.Log.Error().Str("severity", "CRITICAL").Str("checkout_id", c.ID).Str("tenant_id", c.TenantID).
			Msg("checkout: sealed root key does not open for a matching claim token; operator re-key needed (payment.md Recovery)")
		writeErr(w, http.StatusInternalServerError, "internal", "the key could not be recovered; contact support")
		return
	}
	key := base64.StdEncoding.EncodeToString(priv)
	url := h.tenantURL(c.TenantID)
	emailed := false
	if err := h.d.Mail.Send(context.WithoutCancel(ctx), TenantWelcome(c.Email, c.TenantID, url, key)); err != nil {
		h.d.Log.Warn().Err(err).Str("checkout_id", c.ID).Msg("checkout: welcome mail not sent (key still shown once)")
	} else {
		emailed = h.d.MailDelivers
	}
	h.d.Log.Info().Str("checkout_id", c.ID).Str("tenant_id", c.TenantID).Bool("emailed", emailed).Msg("checkout: claimed")
	writeJSON(w, http.StatusOK, map[string]any{"tenant_id": c.TenantID, "tenant_url": url,
		"root_private_key": key, "emailed": emailed})
}

type fakePayReq struct {
	CheckoutID string `json:"checkout_id"`
}

// fakePay (csi-rel 077): the paid transition without money, lde/dev only.
// Refuses a checkout on a real rail and anything no longer pending.
func (h *Handler) fakePay(w http.ResponseWriter, r *http.Request) {
	var req fakePayReq
	if err := json.NewDecoder(io.LimitReader(r.Body, 8<<10)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "body is not fake-pay JSON")
		return
	}
	ctx := r.Context()
	c, err := h.d.Store.GetCheckout(ctx, strings.TrimSpace(req.CheckoutID))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such checkout")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "checkout lookup failed")
		return
	}
	if c.Provider != ProviderFake {
		writeErr(w, http.StatusUnprocessableEntity, "not_fake_checkout", "this checkout is on a real payment rail")
		return
	}
	if c.Status == store.CheckoutPaid {
		writeJSON(w, http.StatusOK, map[string]any{"checkout_id": c.ID, "status": store.CheckoutPaid, "applied": false})
		return
	}
	if c.Status != store.CheckoutPending {
		writeErr(w, http.StatusConflict, "not_pending", "checkout is "+c.Status)
		return
	}
	out, err := h.d.Store.ApplyPayment(ctx, store.PaymentEvent{Provider: ProviderFake, EventID: "fake-pay:" + c.ID,
		CheckoutID: c.ID, Kind: store.PayEventPaid}, h.d.Now().UTC())
	if err != nil {
		h.d.Log.Error().Err(err).Str("checkout_id", c.ID).Msg("fake-pay: apply")
		writeErr(w, http.StatusInternalServerError, "internal", "paid not applied")
		return
	}
	if out == store.PayOutcomeConflict {
		writeErr(w, http.StatusConflict, "tenant_taken", "the slug was taken meanwhile")
		return
	}
	h.d.Log.Warn().Str("checkout_id", c.ID).Str("tenant_id", c.TenantID).
		Msg("tenant paid through the DEV fake-pay rail (no money moved)")
	writeJSON(w, http.StatusOK, map[string]any{"checkout_id": c.ID, "status": store.CheckoutPaid,
		"applied": out == store.PayOutcomePaid})
}

// webhook verifies BEFORE any write (T019): a bad signature answers 400 with
// no detail and writes nothing, not even the dedup row.
func (h *Handler) webhook(w http.ResponseWriter, r *http.Request) {
	if h.d.Verifier == nil {
		h.d.Log.Warn().Str("rail", h.cfg.Rail()).Msg("payment webhook refused: this rail has no signed callback")
		writeErr(w, http.StatusBadRequest, "bad_request", "")
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "")
		return
	}
	ev, err := h.d.Verifier.VerifyWebhook(r, body)
	if err != nil {
		h.d.Log.Warn().Str("provider", h.d.Verifier.Name()).Msg("payment webhook signature rejected")
		writeErr(w, http.StatusBadRequest, "bad_request", "")
		return
	}
	out, err := h.d.Store.ApplyPayment(r.Context(), store.PaymentEvent{Provider: h.d.Verifier.Name(), EventID: ev.ID,
		CheckoutID: ev.CheckoutID, Kind: ev.Kind}, h.d.Now().UTC())
	if err != nil {
		// Nothing committed (dedup + apply are one transaction): the
		// provider's retry will be applied, not swallowed.
		h.d.Log.Error().Err(err).Str("checkout_id", ev.CheckoutID).Msg("payment webhook: apply failed")
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	if out == store.PayOutcomeConflict {
		h.d.Log.Error().Str("severity", "CRITICAL").Str("checkout_id", ev.CheckoutID).Str("event_id", ev.ID).
			Msg("paid for a slug another root key already owns: refund by hand")
	}
	if out == store.PayOutcomeDuplicate {
		writeJSON(w, http.StatusOK, map[string]string{"status": "duplicate"})
		return
	}
	h.d.Log.Info().Str("checkout_id", ev.CheckoutID).Str("action", out).Msg("payment webhook applied")
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "action": out})
}

// TenantWelcome is the one email (FR-014): tenant URL + root private key.
func TenantWelcome(to, tenantID, tenantURL, rootKey string) mail.Message {
	return mail.Message{To: to, Template: TemplateTenantWelcome,
		Subject: "Your spool hub tenant " + tenantID,
		TextBody: strings.Join([]string{
			"Your spool hub tenant is ready.",
			"",
			"Tenant URL:",
			tenantURL,
			"",
			"Tenant ROOT private key (base64):",
			rootKey,
			"",
			"This is the only copy: the hub does not keep it. Save it to a file readable",
			"only by you (mode 0600) and point $SPOOL_TENANT_ROOT_KEY at that file; it",
			"pins and revokes your boxes' keys. Anyone holding it controls your tenant.",
			"Then delete this mail.",
		}, "\n")}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v) //nolint:errcheck
}

func writeErr(w http.ResponseWriter, status int, token, detail string) {
	writeJSON(w, status, wire.ErrorBody{Error: token, Detail: detail})
}
