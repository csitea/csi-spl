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
	"net/url"
	"strings"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
	"github.com/csitea/csi-spl/spool-hub-api/internal/invitemail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Routes (checkout-v1 §1; csi-rel paths). Not tenant-scoped: any Host.
const (
	RoutePrefix        = "/api/v1/checkout"
	RouteStripeWebhook = "/api/v1/webhooks/payment/stripe"
	RoutePayPalWebhook = "/api/v1/webhooks/payment/paypal"
)

// TemplateTenantPaid is the one email (mail.Message.Template, logs): tenant
// URL + single-use claim link, NEVER key material (017 T008 / SEC-03).
const TemplateTenantPaid = mail.TemplateTenantPaid

// Store is what the handler needs from the hub store.
type Store interface {
	store.Payments
	GetTenant(ctx context.Context, tenantID string) (store.Tenant, error)
	TenantHost(ctx context.Context, tenantID string) (store.TenantHost, error)
}

// PayPalRail is the wallet driver (csi-rel PayPal Orders v2).
type PayPalRail interface {
	PaymentProvider
	ProviderOrderProvider
}

// Deps wires a Handler.
type Deps struct {
	Store             Store
	Log               zerolog.Logger
	Mail              mail.Sender     // nil = mail.None
	MailDelivers      bool            // the transport reaches an inbox (smtp)
	TenantHostPattern string          // "{tenant}.<fqdn>"
	Card              PaymentProvider // StripePayments, or StubPayments on the fake rail
	PayPal            PayPalRail      // nil unless SPOOL_HUB_ENABLE_PAYPAL
	PayPalVerifier    *PayPalVerifier // nil unless SPOOL_HUB_ENABLE_PAYPAL
	Now               func() time.Time
	// DefaultLocale is SPOOL_HUB_DEFAULT_LOCALE: the claim mail's language
	// when the checkout kept no buyer locale, and the claim link's
	// prefix_except_default reference. "" = i18n.DefaultLocale.
	DefaultLocale string
}

// Handler is the checkout-v1 surface.
type Handler struct {
	cfg *Config
	d   Deps
}

// Wire builds the drivers cnf names (csi-rel cmd/api paymentWiring).
func Wire(c *Config) (card PaymentProvider, pp PayPalRail, ppv *PayPalVerifier) {
	switch c.Rail() {
	case RailFake:
		card = StubPayments{}
	case RailCard:
		card = &StripePayments{SecretKey: c.StripeSecretKey, BaseURL: c.StripeAPIBase, APIVersion: c.StripeAPIVersion}
	}
	if c.EnablePayPal {
		p := NewPayPal(c.PayPalClientID, c.PayPalClientSecret, c.PayPalMode)
		p.BaseURL, p.Currency = c.PayPalAPIBase, c.Currency
		pp, ppv = p, &PayPalVerifier{WebhookID: c.PayPalWebhookID}
	}
	return card, pp, ppv
}

// NewWired is New with the drivers cnf names wired in (Wire), so callers
// outside this package never name a vendor (no-baked-host.tst.sh).
func NewWired(cfg *Config, d Deps) (*Handler, error) {
	d.Card, d.PayPal, d.PayPalVerifier = Wire(cfg)
	return New(cfg, d)
}

// CardKeyMode is "test" / "live" for a well-shaped card key, "" otherwise
// (boot log; never the key).
func (c *Config) CardKeyMode() string { return StripeKeyMode(c.StripeSecretKey) }

// New builds the handler for a loaded Config.
func New(cfg *Config, d Deps) (*Handler, error) {
	if cfg == nil || d.Store == nil {
		return nil, errors.New("payments: config and store are required")
	}
	if cfg.Rail() != RailNone && d.Card == nil {
		return nil, errors.New("payments: rail " + cfg.Rail() + " has no driver")
	}
	if cfg.EnablePayPal && (d.PayPal == nil || d.PayPalVerifier == nil) {
		return nil, errors.New("payments: PayPal enabled without its driver and verifier")
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
	if !i18n.IsSupported(d.DefaultLocale) {
		d.DefaultLocale = i18n.DefaultLocale
	}
	return &Handler{cfg: cfg, d: d}, nil
}

// Register mounts the routes. fake-pay exists only when FakePayMounted
// (never on prd: Load refuses the flag there); the PayPal capture only when
// PayPal is enabled.
func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET "+RoutePrefix+"/plan", h.plan)
	mux.HandleFunc("POST "+RoutePrefix, h.checkout)
	mux.HandleFunc("GET "+RoutePrefix+"/{checkout_id}", h.status)
	mux.HandleFunc("POST "+RoutePrefix+"/claim", h.claim)
	if h.cfg.FakePayMounted() {
		mux.HandleFunc("POST "+RoutePrefix+"/fake-pay", h.fakePay)
	}
	if h.cfg.EnablePayPal {
		mux.HandleFunc("POST "+RoutePrefix+"/paypal/capture", h.paypalCapture)
	}
	mux.HandleFunc("POST "+RouteStripeWebhook, h.stripeWebhook)
	mux.HandleFunc("POST "+RoutePayPalWebhook, h.paypalWebhook)
}

// ServeHTTP makes the Handler usable on its own (tests).
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	mux := http.NewServeMux()
	h.Register(mux)
	mux.ServeHTTP(w, r)
}

func (h *Handler) cardProvider() string {
	if h.cfg.Rail() == RailCard {
		return ProviderStripe
	}
	return ProviderFake
}

// tenantURL is where the buyer signs in to the new tenant: the WUI sign-in
// page <app>/login?tenant=<id> (owner decision 2026-09-19, "tenant from
// identity": no per-tenant host; the same shape invitemail.SignInURL builds).
// The WUI origin is the claim page's (SPOOL_HUB_PAYMENT_CLAIM_URL, required
// with a rail), so no second setting can disagree with it. "" when unset.
func (h *Handler) tenantURL(id string) string {
	u, err := url.Parse(strings.TrimSpace(h.cfg.ClaimURL))
	if err != nil || u.Host == "" {
		return ""
	}
	s, err := invitemail.SignInURL(u.Scheme+"://"+u.Host, "", "", id)
	if err != nil {
		return ""
	}
	return s
}

func (h *Handler) tenantHost(id string) string {
	return strings.Replace(h.d.TenantHostPattern, "{tenant}", id, 1)
}

// hostStatus is the tenant host's provisioning status (rdb 0015, specs/024):
// "pending" until the reconcile has mapped, certified and probed
// <tenant>.<fqdn>, then "ready". "unknown" when the hub cannot tell (no row,
// or the read failed): the page then shows no "being prepared" notice.
func (h *Handler) hostStatus(ctx context.Context, id string) string {
	th, err := h.d.Store.TenantHost(ctx, id)
	if err == nil && (th.Status == store.HostReady || th.Status == store.HostPending || th.Status == store.HostFailed) {
		if th.Status == store.HostFailed {
			return store.HostPending // retried by the next reconcile: still being prepared for the buyer
		}
		return th.Status
	}
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		h.d.Log.Warn().Err(err).Str("tenant_id", id).Msg("checkout: tenant host status read")
	}
	return "unknown"
}

func (h *Handler) plan(w http.ResponseWriter, _ *http.Request) {
	methods := h.cfg.Methods()
	if methods == nil {
		methods = []string{}
	}
	out := map[string]any{
		"plan_id": h.cfg.PlanID, "amount_cents": h.cfg.PlanCents, "currency": h.cfg.Currency,
		"rail": h.cfg.Rail(), "methods": methods, "available": h.cfg.Guard() == "" && len(methods) > 0,
	}
	if h.cfg.Rail() == RailCard {
		out["publishable_key"] = strings.TrimSpace(h.cfg.StripePublishableKey)
	}
	if h.cfg.EnablePayPal {
		out["paypal_client_id"] = strings.TrimSpace(h.cfg.PayPalClientID)
	}
	if h.cfg.SeatsSold() { // M4 only: the M2 plan names no seat (009 T001)
		out["seat_user_cents"], out["seat_bot_cents"], out["seats_max"] = h.cfg.SeatUserCents, h.cfg.SeatBotCents, h.cfg.SeatsMax
	}
	if h.cfg.Dedicated {
		out["dedicated"] = true
	}
	writeJSON(w, http.StatusOK, out)
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
	Method   string `json:"method"` // "" = card
	// M4 (009 T004): seats bought per month, and a dedicated SKU's org/app.
	SeatsUsers int    `json:"seats_users"`
	SeatsBots  int    `json:"seats_bots"`
	Org        string `json:"org"`
	App        string `json:"app"`
	// Locale is the language the buyer is reading the checkout in (spec 021
	// T022): the WUI's active locale. "" / unsupported = not said, and the
	// request headers get a say instead (buyerLocale).
	Locale string `json:"locale"`
}

// lineItems checks the M4 part of a checkout request against the plan and
// returns its line items and total. The M2 SKU (no seat priced) accepts no
// seats and yields no items (009 T001). A priced kind is bought 1..SeatsMax;
// an unpriced kind must stay 0 (0 = unlimited, 009 D-2). "" = ok, else the
// 400 error token.
func (h *Handler) lineItems(req *checkoutReq) (items []LineItem, total int, bad string) {
	total = h.cfg.PlanCents
	if !h.cfg.SeatsSold() {
		if req.SeatsUsers != 0 || req.SeatsBots != 0 {
			return nil, 0, "seats_not_sold"
		}
	} else {
		for _, k := range []struct {
			name      string
			qty, unit int
		}{{"user_seat", req.SeatsUsers, h.cfg.SeatUserCents}, {"bot_seat", req.SeatsBots, h.cfg.SeatBotCents}} {
			switch {
			case k.unit == 0 && k.qty != 0, k.unit > 0 && (k.qty < 1 || k.qty > h.cfg.SeatsMax):
				return nil, 0, "bad_seats"
			case k.unit > 0:
				items = append(items, LineItem{Name: k.name, Quantity: k.qty, UnitCents: k.unit})
				total += k.qty * k.unit
			}
		}
		items = append([]LineItem{{Name: "tenant", Quantity: 1, UnitCents: h.cfg.PlanCents}}, items...)
	}
	req.Org, req.App = strings.ToLower(strings.TrimSpace(req.Org)), strings.ToLower(strings.TrimSpace(req.App))
	if h.cfg.Dedicated {
		if _, err := store.MintProjectID(req.Org, req.App, h.cfg.Env, h.d.Now()); err != nil {
			return nil, 0, "bad_org_app"
		}
	} else if req.Org != "" || req.App != "" {
		return nil, 0, "bad_org_app"
	}
	return items, total, ""
}

// buyerLocale is the language the buyer is reading the checkout in, kept on
// the checkout row (rdb 0025) so the claim mail the paid webhook sends -- long
// after this request is gone -- speaks it. The WUI's explicit body `locale`
// wins, then X-Locale, then Accept-Language; "" means the buyer never said and
// the mail follows SPOOL_HUB_DEFAULT_LOCALE at send time.
//
// Normalize, never the raw value: this string picks a mail template file and
// prefixes a URL path, so only one of the 19 i18n.Supported codes may pass.
func buyerLocale(r *http.Request, body string) string {
	if loc := i18n.Normalize(body); loc != "" {
		return loc
	}
	return i18n.Match(r.Header.Get(i18n.HeaderLocale), r.Header.Get("Accept-Language"), "")
}

func (h *Handler) checkout(w http.ResponseWriter, r *http.Request) {
	var req checkoutReq
	if err := json.NewDecoder(io.LimitReader(r.Body, maxJSONBody)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "body is not checkout JSON")
		return
	}
	ctx := r.Context()
	in, rf := h.checkoutInput(&req)
	if rf == nil {
		rf = h.tenantFree(ctx, in.tid)
	}
	if rf != nil {
		writeErr(w, rf.status, rf.token, rf.detail)
		return
	}
	// A PLACEHOLDER root key: its private half is dropped here, so nothing
	// can use the tenant's root until the claim mints the real key (§0.2).
	pub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "keygen failed")
		return
	}
	id, token := newCheckoutID(), NewClaimToken()
	// Provider first: a failed provider call must not hold the slug. The
	// checkout id is the provider's order reference / idempotency key.
	out := map[string]any{"checkout_id": id, "claim_token": token, "method": in.method,
		"amount_cents": in.total, "currency": h.cfg.Currency, "tenant_id": in.tid, "tenant_url": h.tenantURL(in.tid)}
	if len(in.items) > 0 {
		out["line_items"] = in.items
	}
	pay, err := h.startPayment(ctx, in, id, out)
	if err != nil {
		h.d.Log.Error().Err(err).Str("checkout_id", id).Str("provider", pay.provider).Msg("checkout: provider refused")
		writeErr(w, http.StatusServiceUnavailable, "payment_unavailable", "the payment provider did not start a payment")
		return
	}
	c := store.Checkout{ID: id, TenantID: in.tid, PlanID: h.cfg.PlanID, Provider: pay.provider, ProviderRef: pay.ref,
		AmountCents: in.total, Currency: h.cfg.Currency, Email: in.email, RootPubKey: pub,
		ClaimHash: ClaimHash(token), SeatsUsers: req.SeatsUsers, SeatsBots: req.SeatsBots, Org: req.Org, App: req.App,
		Locale: buyerLocale(r, req.Locale)}
	if rf := h.holdCheckout(ctx, c, pay); rf != nil {
		writeErr(w, rf.status, rf.token, rf.detail)
		return
	}
	h.d.Log.Info().Str("checkout_id", id).Str("tenant_id", in.tid).Str("provider", pay.provider).
		Str("to", mail.Digest(in.email)).Msg("checkout: slug held")
	writeJSON(w, http.StatusCreated, out)
}

// refusal is an error answer of the checkout: status, token and detail.
type refusal struct {
	status        int
	token, detail string
}

// checkoutIn is a checkout request that passed checkoutInput.
type checkoutIn struct {
	method, tid, email string
	items              []LineItem
	total              int
}

// checkoutInput normalizes and checks the request: the payment method is
// configured, the rail is not guarded, the slug, the email and the seats fit.
func (h *Handler) checkoutInput(req *checkoutReq) (checkoutIn, *refusal) {
	in := checkoutIn{method: strings.ToLower(strings.TrimSpace(req.Method)),
		tid: strings.ToLower(strings.TrimSpace(req.TenantID)), email: strings.TrimSpace(req.Email)}
	if in.method == "" {
		in.method = MethodCard
	}
	switch {
	case in.method == MethodCard && h.cfg.Rail() == RailNone, in.method == MethodPayPal && !h.cfg.EnablePayPal:
		return in, &refusal{http.StatusServiceUnavailable, "payment_unavailable", "that payment method is not configured"}
	case in.method != MethodCard && in.method != MethodPayPal:
		return in, &refusal{http.StatusBadRequest, "bad_method", "method must be card or paypal"}
	case h.cfg.Guard() != "":
		return in, &refusal{http.StatusServiceUnavailable, "payment_unavailable", GuardReasonMisconfigured}
	case !msg.ValidTenantID(in.tid):
		return in, &refusal{http.StatusBadRequest, "bad_tenant_id", "tenant_id is not a valid, unreserved slug"}
	case !validEmail(in.email):
		return in, &refusal{http.StatusBadRequest, "bad_request", "email is not an address"}
	}
	var bad string
	in.items, in.total, bad = h.lineItems(req)
	if bad != "" {
		return in, &refusal{http.StatusBadRequest, bad, "seats / org / app do not fit this plan (GET " + RoutePrefix + "/plan)"}
	}
	return in, nil
}

// tenantFree refuses a slug that is already a tenant.
func (h *Handler) tenantFree(ctx context.Context, tid string) *refusal {
	_, err := h.d.Store.GetTenant(ctx, tid)
	switch {
	case err == nil:
		return &refusal{http.StatusConflict, "tenant_taken", "that tenant exists"}
	case !errors.Is(err, store.ErrNotFound):
		h.d.Log.Error().Err(err).Msg("checkout: tenant lookup")
		return &refusal{http.StatusInternalServerError, "internal", "tenant lookup failed"}
	}
	return nil
}

// payment is a provider-side payment that startPayment opened.
type payment struct {
	provider, ref string
	cancel        func(context.Context, string) error
}

// startPayment opens the payment at the provider of the method (the PayPal
// order, or the card intent with its line items) and adds what the browser
// needs to out.
func (h *Handler) startPayment(ctx context.Context, in checkoutIn, id string, out map[string]any) (payment, error) {
	if in.method == MethodPayPal {
		p := payment{provider: ProviderPayPal, cancel: h.d.PayPal.CancelIntent}
		orderID, approve, err := h.d.PayPal.CreateProviderOrder(ctx, id, in.total, h.cfg.Currency)
		p.ref = orderID
		out["rail"], out["provider_order_id"], out["approve_url"] = MethodPayPal, orderID, approve
		return p, err
	}
	p := payment{provider: h.cardProvider(), cancel: h.d.Card.CancelIntent}
	var clientSecret string
	var err error
	if li, ok := h.d.Card.(LineItemProvider); ok && len(in.items) > 0 {
		p.ref, clientSecret, err = li.CreateIntentWithItems(ctx, id, in.total, h.cfg.Currency, in.items)
	} else {
		p.ref, clientSecret, err = h.d.Card.CreateIntent(ctx, id, in.total, h.cfg.Currency)
	}
	out["rail"] = h.cfg.Rail()
	if h.cfg.Rail() == RailCard {
		out["client_secret"], out["publishable_key"] = clientSecret, strings.TrimSpace(h.cfg.StripePublishableKey)
	}
	return p, err
}

// holdCheckout stores the hold on the slug; when it cannot, the provider-side
// payment is cancelled so it can never be confirmed.
func (h *Handler) holdCheckout(ctx context.Context, c store.Checkout, pay payment) *refusal {
	err := h.d.Store.HoldCheckout(ctx, c, h.d.Now().UTC(), h.cfg.Hold)
	if err == nil {
		return nil
	}
	_ = pay.cancel(context.WithoutCancel(ctx), pay.ref)
	if errors.Is(err, store.ErrConflict) {
		return &refusal{http.StatusConflict, "tenant_taken", "that tenant exists or is being bought"}
	}
	h.d.Log.Error().Err(err).Str("checkout_id", c.ID).Msg("checkout: hold not stored")
	return &refusal{http.StatusInternalServerError, "internal", "checkout not stored"}
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
	// locale: the buyer's language as the row kept it (rdb 0025), "" when they
	// never said — so the buy can be checked from outside the hub, without a
	// DB or a log line (spec 021 T022).
	out := map[string]any{"checkout_id": c.ID, "tenant_id": c.TenantID,
		"status": c.Status, "claimed": !c.ClaimedAt.IsZero(), "tenant_host": h.tenantHost(c.TenantID),
		"locale": c.Locale}
	if c.Status == store.CheckoutPaid {
		out["host_status"] = h.hostStatus(r.Context(), c.TenantID)
	}
	writeJSON(w, http.StatusOK, out)
}

type claimReq struct {
	CheckoutID string `json:"checkout_id"`
	ClaimToken string `json:"claim_token"`
}

func (h *Handler) claim(w http.ResponseWriter, r *http.Request) {
	var req claimReq
	if err := json.NewDecoder(io.LimitReader(r.Body, maxJSONBody)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "body is not claim JSON")
		return
	}
	// The root key is minted HERE, once, and never stored or emailed.
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "keygen failed")
		return
	}
	c, err := h.d.Store.ClaimCheckout(r.Context(), strings.TrimSpace(req.CheckoutID), ClaimHash(req.ClaimToken), h.d.Now().UTC(), pub)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such checkout for that claim token")
		return
	case errors.Is(err, store.ErrNotPaid):
		writeErr(w, http.StatusConflict, "not_paid", "the payment has not arrived yet")
		return
	case errors.Is(err, store.ErrClaimed):
		writeErr(w, http.StatusGone, "claimed", "the key was already shown once; the hub never held it")
		return
	case errors.Is(err, store.ErrClaimExpired):
		writeErr(w, http.StatusGone, "claim_expired", "the claim window has closed; ask the operator to re-key the tenant")
		return
	case errors.Is(err, store.ErrConflict):
		h.d.Log.Error().Str("severity", "CRITICAL").Str("checkout_id", req.CheckoutID).
			Msg("claim: the tenant no longer carries the checkout's placeholder root key; operator re-key needed")
		writeErr(w, http.StatusConflict, "conflict", "the tenant was re-keyed; contact support")
		return
	case err != nil:
		h.d.Log.Error().Err(err).Msg("checkout: claim")
		writeErr(w, http.StatusInternalServerError, "internal", "claim failed")
		return
	}
	h.d.Log.Info().Str("checkout_id", c.ID).Str("tenant_id", c.TenantID).Msg("checkout: claimed, root key minted and shown once")
	writeJSON(w, http.StatusOK, map[string]any{"tenant_id": c.TenantID, "tenant_url": h.tenantURL(c.TenantID),
		"tenant_host": h.tenantHost(c.TenantID), "host_status": h.hostStatus(r.Context(), c.TenantID),
		"root_private_key": base64.StdEncoding.EncodeToString(priv)})
}

// afterPaid sends the one email (017 T008): tenant URL + a fresh single-use
// claim link valid for ClaimTTL. The link token exists in clear only in this
// function and the mail; the store keeps its hash. Best-effort: the buyer's
// browser token claims too.
func (h *Handler) afterPaid(ctx context.Context, checkoutID string) {
	ctx = context.WithoutCancel(ctx)
	c, err := h.d.Store.GetCheckout(ctx, checkoutID)
	if err != nil {
		h.d.Log.Error().Err(err).Str("checkout_id", checkoutID).Msg("paid: checkout lookup for the claim link")
		return
	}
	tok := NewClaimToken()
	expires := h.d.Now().UTC().Add(h.cfg.ClaimTTL)
	if err := h.d.Store.SetClaimLink(ctx, c.ID, ClaimHash(tok), expires); err != nil {
		h.d.Log.Error().Err(err).Str("checkout_id", c.ID).Msg("paid: claim link not stored; no mail sent")
		return
	}
	// The buyer's own language (rdb 0025, spec 021 T022), and the hub default
	// when the checkout kept none -- or kept one this build no longer ships,
	// which Normalize drops rather than carry into a template path or a URL.
	loc := i18n.Normalize(c.Locale)
	if loc == "" {
		loc = h.d.DefaultLocale
	}
	link := i18n.LocalizeURL(strings.TrimSpace(h.cfg.ClaimURL), loc, h.d.DefaultLocale) + "#checkout=" + c.ID + "&token=" + tok
	m, err := TenantPaid(c.Email, loc, c.TenantID, h.tenantURL(c.TenantID), link, h.cfg.ClaimTTL)
	if err != nil {
		h.d.Log.Error().Err(err).Str("checkout_id", c.ID).Msg("paid: claim-link mail not rendered (the browser can still claim)")
		return
	}
	if err := h.d.Mail.Send(ctx, m); err != nil {
		h.d.Log.Warn().Err(err).Str("checkout_id", c.ID).Msg("paid: claim-link mail not sent (the browser can still claim)")
		return
	}
	h.d.Log.Info().Str("checkout_id", c.ID).Str("to", mail.Digest(c.Email)).Bool("delivered", h.d.MailDelivers).
		Str("locale", m.Locale).Msg("paid: claim-link mail sent")
}

type fakePayReq struct {
	CheckoutID string `json:"checkout_id"`
}

// fakePay (csi-rel 077): the paid transition without money, lde/dev only.
// Refuses a checkout on a real rail and anything no longer pending.
func (h *Handler) fakePay(w http.ResponseWriter, r *http.Request) {
	var req fakePayReq
	if err := json.NewDecoder(io.LimitReader(r.Body, maxJSONBody)).Decode(&req); err != nil {
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
		CheckoutID: c.ID, Kind: store.PayEventPaid, Env: h.cfg.Env}, h.d.Now().UTC())
	if err != nil {
		h.d.Log.Error().Err(err).Str("checkout_id", c.ID).Msg("fake-pay: apply")
		writeErr(w, http.StatusInternalServerError, "internal", "paid not applied")
		return
	}
	if out == store.PayOutcomeConflict {
		writeErr(w, http.StatusConflict, "tenant_taken", "the slug was taken meanwhile")
		return
	}
	if out == store.PayOutcomePaid {
		h.afterPaid(ctx, c.ID)
	}
	h.d.Log.Warn().Str("checkout_id", c.ID).Str("tenant_id", c.TenantID).
		Msg("tenant paid through the DEV fake-pay rail (no money moved)")
	writeJSON(w, http.StatusOK, map[string]any{"checkout_id": c.ID, "status": store.CheckoutPaid,
		"applied": out == store.PayOutcomePaid})
}

type paypalCaptureReq struct {
	CheckoutID string `json:"checkout_id"`
}

// paypalCapture is csi-rel's POST /api/v1/checkout/paypal/capture: the WUI's
// onApprove asks us to capture; the PAYMENT.CAPTURE.COMPLETED webhook, not
// this response, marks the checkout paid (one authoritative transition).
func (h *Handler) paypalCapture(w http.ResponseWriter, r *http.Request) {
	var req paypalCaptureReq
	if err := json.NewDecoder(io.LimitReader(r.Body, maxJSONBody)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "body is not capture JSON")
		return
	}
	c, err := h.d.Store.GetCheckout(r.Context(), strings.TrimSpace(req.CheckoutID))
	if errors.Is(err, store.ErrNotFound) || (err == nil && c.Provider != ProviderPayPal) {
		writeErr(w, http.StatusNotFound, "not_found", "no such wallet checkout")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "checkout lookup failed")
		return
	}
	if c.Status != store.CheckoutPending && c.Status != store.CheckoutPaid {
		writeErr(w, http.StatusConflict, "not_pending", "checkout is "+c.Status)
		return
	}
	if c.Status == store.CheckoutPending {
		if _, _, err := h.d.PayPal.CaptureProviderOrder(r.Context(), c.ProviderRef, c.ID); err != nil && !errors.Is(err, ErrAlreadyCaptured) {
			h.d.Log.Error().Err(err).Str("checkout_id", c.ID).Msg("paypal capture failed")
			writeErr(w, http.StatusBadGateway, "payment_failed", "the wallet capture failed")
			return
		}
	}
	writeJSON(w, http.StatusAccepted, map[string]string{"checkout_id": c.ID, "status": "capturing"})
}

// stripeEvent is the slice of the Stripe event envelope we consume (csi-rel).
type stripeEvent struct {
	ID   string `json:"id"`
	Type string `json:"type"`
	Data struct {
		Object struct {
			ID            string `json:"id"`
			PaymentIntent string `json:"payment_intent"` // present on charge.* events
		} `json:"object"`
	} `json:"data"`
}

// stripeKind is csi-rel's eventTarget for Stripe, onto tenant billing.
func stripeKind(t string) string {
	switch t {
	case "payment_intent.succeeded":
		return store.PayEventPaid
	case "charge.refunded":
		return store.PayEventRefund
	}
	// payment_intent.payment_failed: audit only, the buyer may retry the
	// same intent (csi-rel); disputes: audit + CRITICAL in apply, but only
	// for a payment of ours (the account is shared).
	return store.PayEventIgnore
}

// stripeWebhook verifies BEFORE any write (T019): a bad signature answers 400
// with no detail and writes nothing, not even the dedup row.
//
// The rail flag is NOT part of that door. The signing secret is: a delivery
// that verifies against it came from our own endpoint, whatever
// SPOOL_HUB_PAYMENT_PROVIDER says today (it is held at "" between provisioning
// the endpoint and the owner's go to charge). Refusing those with a 400 had
// Stripe retry every one of them for days and then disable the endpoint —
// which would drop the paid events that ARE ours. Verified goes through; the
// checkout lookup in apply decides what, if anything, happens.
func (h *Handler) stripeWebhook(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(io.LimitReader(r.Body, maxWebhookBody))
	if err != nil ||
		VerifyStripe(r.Header.Get("Stripe-Signature"), string(body), strings.TrimSpace(h.cfg.StripeWebhookSecret), h.d.Now()) != nil {
		h.d.Log.Warn().Str("provider", ProviderStripe).Msg("webhook signature rejected")
		writeErr(w, http.StatusBadRequest, "bad_request", "")
		return
	}
	var ev stripeEvent
	if err := json.Unmarshal(body, &ev); err != nil || ev.ID == "" || ev.Type == "" {
		writeErr(w, http.StatusBadRequest, "bad_request", "")
		return
	}
	intentID := ev.Data.Object.PaymentIntent
	if intentID == "" {
		intentID = ev.Data.Object.ID
	}
	h.apply(w, r, delivery{Provider: ProviderStripe, EventID: ev.ID, Type: ev.Type, Ref: intentID,
		Kind: stripeKind(ev.Type), Dispute: strings.HasPrefix(ev.Type, "charge.dispute."),
		SharedAccount: true})
}

// paypalEvent is the slice of the PayPal webhook envelope we need (csi-rel).
type paypalEvent struct {
	ID        string `json:"id"`
	EventType string `json:"event_type"`
	Resource  struct {
		ID                string `json:"id"`
		SupplementaryData struct {
			RelatedIDs struct {
				OrderID string `json:"order_id"`
			} `json:"related_ids"`
		} `json:"supplementary_data"`
	} `json:"resource"`
}

func paypalKind(t string) string {
	switch t {
	case "PAYMENT.CAPTURE.COMPLETED":
		return store.PayEventPaid
	case "PAYMENT.CAPTURE.REFUNDED", "PAYMENT.CAPTURE.REVERSED":
		return store.PayEventRefund
	}
	return store.PayEventIgnore
}

func (h *Handler) paypalWebhook(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(io.LimitReader(r.Body, maxWebhookBody))
	if err != nil || h.d.PayPalVerifier == nil ||
		h.d.PayPalVerifier.Verify(r.Context(), PayPalHeadersFrom(r.Header.Get), string(body)) != nil {
		h.d.Log.Warn().Str("provider", ProviderPayPal).Msg("webhook signature rejected")
		writeErr(w, http.StatusBadRequest, "bad_request", "")
		return
	}
	var ev paypalEvent
	if err := json.Unmarshal(body, &ev); err != nil || ev.ID == "" || ev.EventType == "" {
		writeErr(w, http.StatusBadRequest, "bad_request", "")
		return
	}
	// capture events carry the ORDER id (our provider_ref) as related_ids;
	// CHECKOUT.ORDER.* events carry it as resource.id.
	ref := ev.Resource.SupplementaryData.RelatedIDs.OrderID
	if ref == "" {
		ref = ev.Resource.ID
	}
	// The wallet account is this hub's alone, so a dispute naming no checkout
	// of ours is still our money (csi-rel flagDispute): SharedAccount false.
	h.apply(w, r, delivery{Provider: ProviderPayPal, EventID: ev.ID, Type: ev.EventType, Ref: ref,
		Kind: paypalKind(ev.EventType), Dispute: ev.EventType == "CUSTOMER.DISPUTE.CREATED"})
}

// delivery is one signature-verified provider delivery, ready to apply.
type delivery struct {
	Provider string // ProviderStripe | ProviderPayPal: the dedup key's half
	EventID  string // the provider's event id: the other half
	Type     string // the provider's event type, for the logs
	Ref      string // the provider-side id (card intent, wallet order) it names
	Kind     string // store.PayEvent*
	Dispute  bool   // a chargeback was opened on Ref
	// SharedAccount: another app bills on the same provider account (006
	// T022, one Stripe account for both), so a delivery naming no checkout
	// of ours is that app's ordinary traffic and not an incident.
	SharedAccount bool
}

// EventWebhookForeign is the fixed log `event` for a verified delivery that
// names no checkout of ours — the counter for the noise the shared provider
// account sends this endpoint. A rise in it is normal; a rise in it while OUR
// paid events stop is the endpoint being mis-pointed.
const EventWebhookForeign = "payment_webhook_foreign"

// Request-body caps: a checkout / portal call is a few fields; a provider
// webhook event is a larger signed document.
const (
	maxJSONBody    = 8 << 10
	maxWebhookBody = 1 << 20
)

// apply resolves the checkout by the provider's id and applies the verified
// event: dedup + transition in ONE store transaction.
func (h *Handler) apply(w http.ResponseWriter, r *http.Request, d delivery) {
	ctx := r.Context()
	checkoutID := ""
	if c, err := h.d.Store.CheckoutByProviderRef(ctx, d.Provider, d.Ref); err == nil {
		checkoutID = c.ID
	} else if !errors.Is(err, store.ErrNotFound) {
		h.d.Log.Error().Err(err).Str("provider", d.Provider).Msg("payment webhook: checkout lookup")
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	switch {
	case checkoutID == "":
		// Acked below, whatever it is: no retry of an event about someone
		// else's payment will ever match, and a 4xx only spends the
		// endpoint's retry budget until Stripe disables it.
		h.d.Log.Info().Str("event", EventWebhookForeign).Str("provider", d.Provider).
			Str("event_type", d.Type).Str("event_id", d.EventID).Str("ref", d.Ref).
			Bool("dispute", d.Dispute).Bool("shared_account", d.SharedAccount).
			Msg("payment webhook: no checkout of ours names that payment")
		if d.Dispute && !d.SharedAccount {
			h.d.Log.Error().Str("severity", "CRITICAL").Str("event", "payment_dispute_opened").
				Str("event_type", d.Type).Str("event_id", d.EventID).Str("intent_id", d.Ref).
				Msg("payment dispute on this hub's provider account: handle it in the provider dashboard")
		}
	case d.Dispute:
		h.d.Log.Error().Str("severity", "CRITICAL").Str("event", "payment_dispute_opened").
			Str("event_type", d.Type).Str("event_id", d.EventID).Str("intent_id", d.Ref).
			Str("checkout_id", checkoutID).Msg("payment dispute: handle it in the provider dashboard")
	}
	out, err := h.d.Store.ApplyPayment(ctx, store.PaymentEvent{Provider: d.Provider, EventID: d.EventID,
		CheckoutID: checkoutID, Kind: d.Kind, Env: h.cfg.Env}, h.d.Now().UTC())
	if err != nil {
		// Nothing committed: the provider's retry will be applied, not swallowed.
		h.d.Log.Error().Err(err).Str("checkout_id", checkoutID).Msg("payment webhook: apply failed")
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	if out == store.PayOutcomeConflict {
		h.d.Log.Error().Str("severity", "CRITICAL").Str("checkout_id", checkoutID).Str("event_id", d.EventID).
			Msg("paid for a slug another root key already owns: refund by hand")
	}
	if out == store.PayOutcomeDuplicate {
		writeJSON(w, http.StatusOK, map[string]string{"status": "duplicate"})
		return
	}
	if out == store.PayOutcomePaid {
		h.afterPaid(ctx, checkoutID)
	}
	h.d.Log.Info().Str("provider", d.Provider).Str("checkout_id", checkoutID).Str("action", out).Msg("payment webhook applied")
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "action": out})
}

// TenantPaid is the one email (FR-014 as amended by 017 T008): tenant URL +
// a single-use claim link, in locale. It carries NO key material. The
// wording lives in mail/templates/tenant_paid/<locale>.{subject,txt}.
func TenantPaid(to, locale, tenantID, tenantURL, claimLink string, ttl time.Duration) (mail.Message, error) {
	return mail.TenantPaid(to, locale, tenantID, tenantURL, claimLink, ttl)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Cache-Control", "no-store")
	wire.WriteJSON(w, status, v)
}

func writeErr(w http.ResponseWriter, status int, token, detail string) {
	wire.WriteError(w, status, token, detail)
}
