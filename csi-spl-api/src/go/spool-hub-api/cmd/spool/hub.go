package main

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/cicdlogs"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/edge"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/invitemail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/logging"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/notify"
	"github.com/csitea/csi-spl/spool-hub-api/internal/payments"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
	"google.golang.org/api/idtoken"
)

// Serve limits of the hub process. The blob cache is sized for one 512 MiB
// Cloud Run instance using ~80 MiB; the http limits are the
// slow-client defence (017 FR-SEC-004).
const (
	blobCacheBytes     = 64 << 20
	blobCacheItemBytes = 4 << 20
	blobCacheTTL       = 10 * time.Minute
	sweepEvery         = 10 * time.Minute
	readHeaderTimeout  = 10 * time.Second
	idleTimeout        = 120 * time.Second
	maxHeaderBytes     = 64 << 10
)

// applyRuntimeLimits sets GOMAXPROCS and the soft memory limit from cnf
// (SPOOL_HUB_GOMAXPROCS / SPOOL_HUB_GOMEMLIMIT) before anything starts; unset
// leaves the runtime's own. The "hub listening" line reports what is in force.
func applyRuntimeLimits(hc *config.Hub) error {
	procs, bytes, err := hc.RuntimeLimits()
	if err != nil {
		return err
	}
	if procs > 0 {
		runtime.GOMAXPROCS(procs)
	}
	if bytes > 0 {
		debug.SetMemoryLimit(bytes)
	}
	return nil
}

// cmdServe runs the hub until SIGINT/SIGTERM, then drains: sockets get 1001,
// in-flight HTTP finishes within SPOOL_HUB_GRACEFUL_SHUTDOWN (a
// runUntilShutdown pattern).
func cmdServe() int {
	hc, err := config.LoadHub()
	if err != nil {
		return fail(err)
	}
	if err := applyRuntimeLimits(hc); err != nil {
		return fail(err)
	}
	log := logging.New(&config.Config{LogLevel: hc.LogLevel, LogFormat: hc.LogFormat}).
		With().Str("component", "hub").Str("env", hc.Env).Str("version", version).Logger()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	st, err := openStore(ctx, hc.DBDSN, store.PoolLimits{MaxConns: int32(hc.DBMaxConns),
		MinConns: int32(hc.DBMinConns), MaxConnIdleTime: hc.DBMaxConnIdleTime})
	if err != nil {
		return fail(err)
	}
	defer st.Close()
	bs, err := openBlobStore(ctx, hc)
	if err != nil {
		return fail(err)
	}
	defer bs.Close()

	opts, err := hubOptions(ctx, hc, log, st, bs)
	if err != nil {
		return fail(err)
	}
	srv, err := hub.New(opts)
	if err != nil {
		return fail(err)
	}
	go srv.RunSweeper(ctx, sweepEvery)
	go srv.RunRelay(ctx, hc.QueueRelay) // SPL-1004
	return serveUntilDone(ctx, hc, log, srv)
}

// hubOptions wires every dependency of the hub in boot order: the base
// options, the box-wui key, CI logs, auth (OIDC + native), payments and the
// invite mailer (SPL-1036: one named step each). Any error is fatal.
func hubOptions(ctx context.Context, hc *config.Hub, log zerolog.Logger, st store.Store, bs blob.Store) (hub.Options, error) {
	var originTenant *hub.OriginTenant // SPL-959; nil = tenant hosts off
	if hc.WUITenantHosts {
		originTenant = hub.NewOriginTenant(hc.TenantHostPattern, hc.WUIApexTenant)
	}
	opts := baseOptions(hc, log, st, bs, originTenant)
	wuiKey, err := hc.WUIPrivateKey() // specs/014; the private key is never logged
	if err != nil {
		return opts, err
	}
	opts.WUIKey, opts.WUIDispatch = wuiKey, hc.WUIDispatch
	if wuiKey != nil {
		log.Info().Str("box_wui_pubkey", base64.StdEncoding.EncodeToString(wuiKey.Public().(ed25519.PublicKey))).
			Bool("dispatch", hc.WUIDispatch).Bool("ephemeral", strings.TrimSpace(hc.WUIKey) == "").Msg("box-wui key loaded")
	}
	if opts.CICD, err = cicdService(hc); err != nil {
		return opts, err
	}
	ac, nc, err := loadAuthConfig(hc)
	if err != nil {
		return opts, err
	}
	logRLSPosture(ctx, log, st)
	// Registration + membership are store-backed (010 T012/T013, rdb 0006).
	// The IdP picture lands in the same tenant blob store (010 T044).
	hooks := store.AuthHooks{H: st.(store.Humans), Policy: store.AdmitPolicy{BootstrapOwner: hc.AuthBootstrapOwner},
		Blob: bs, AvatarErr: func(hum string, err error) {
			log.Warn().Err(err).Str("human_id", hum).Msg("auth.avatar_not_stored")
		}}
	// preferred_locale lives on the human (rdb 0017); the default
	// locale is cnf, validated by LoadHub.
	opts.Auth = auth.New(ac, log, auth.Options{Registrar: hooks, Membership: hooks, Unlinker: hooks, Avatars: hooks,
		Preferences: hooks, Federated: hooks, DefaultLocale: hc.DefaultLocale, PageTenant: originTenant.Request,
		Impersonation: hub.NewActAs(st, 0, nil)}) // specs/054 act-as; nil under the memory store
	log.Info().Str("default_locale", hc.DefaultLocale).Msg("i18n")
	if err := enableNativeSignIn(opts.Auth, nc, st, log); err != nil {
		return opts, err
	}
	pmc, err := wirePayments(&opts, hc, log, st)
	if err != nil {
		return opts, err
	}
	if err := mailPreflight(ctx, hc, log, pmc); err != nil {
		return opts, err
	}
	opts.InviteMail = inviteMailer(hc, log, st, pmc, ac.AppURL)
	log.Info().Bool("invite_mail", opts.InviteMail != nil).Msg("members api")
	// CLE-77780: the operator invite routes let the box create/mail invites
	// FROM the hub (no box SMTP). Off unless SPOOL_HUB_OPERATOR_EMAILS is set.
	opEmails, opAud, err := operatorInviteConfig()
	if err != nil {
		return opts, err
	}
	if len(opEmails) > 0 {
		opts.OperatorEmails, opts.OperatorAudience = opEmails, opAud
		opts.OperatorVerify = googleOperatorVerify
		opts.OperatorMail = operatorMailer(hc, log, st, pmc, ac.AppURL)
		log.Info().Int("operator_emails", len(opEmails)).Bool("operator_mail", opts.OperatorMail != nil).Msg("operator invite routes")
	}
	return opts, nil
}

// mailPreflight checks the relay at start (spec 047 W7). require: before
// the hub listens, and a failure stops the start; warn: in the background,
// so a dead relay costs one CRITICAL log line and never the boxes' hub.
func mailPreflight(ctx context.Context, hc *config.Hub, log zerolog.Logger, mc *mail.Config) error {
	if mc.Preflight == mail.PreflightRequire {
		return mail.Preflight(ctx, mc, hc.Env, log)
	}
	go func() { _ = mail.Preflight(ctx, mc, hc.Env, log) }()
	return nil
}

// baseOptions maps the hub cnf onto hub.Options; the dependencies that need
// loading or checking are added by hubOptions.
func baseOptions(hc *config.Hub, log zerolog.Logger, st store.Store, bs blob.Store, originTenant *hub.OriginTenant) hub.Options {
	// attachment reads served from memory after the first; the
	// hub is one instance of 512 MiB (hub.cloud_run), ~80 MiB in use.
	cached := blob.NewCached(bs, blobCacheBytes, blobCacheItemBytes, blobCacheTTL)
	return hub.Options{
		Store: st, Blob: cached, Log: log, TenantHostPattern: hc.TenantHostPattern,
		HelloSkew: hc.HelloSkew, UploadTokenTTL: hc.UploadTokenTTL, QueueTTL: hc.QueueTTL,
		QueueMaxPerBox: hc.QueueMaxPerBox, RetentionAlerts: hc.RetentionAlerts,
		RetentionChannels: hc.RetentionChannels, BackfillWindow: hc.BackfillWindow, BackfillMax: hc.BackfillMax,
		Fallback:        hc.Fallback,
		UnansweredGrace: hc.UnansweredGrace,
		ReescalateEvery: hc.ReescalateEvery,
		ReescalateMax:   hc.ReescalateMax,
		AllowTextOnly:   hc.AllowTextOnly, Version: version, Commit: commit, BuiltAt: builtAt,
		QuotaMessagesPerMonth: hc.QuotaMessagesPerMonth, QuotaPins: hc.QuotaPins, QuotaFileBytes: hc.QuotaFileBytes,
		ViewDoor: hc.ViewDoor, ViewCORSOrigins: hc.ViewCORSOrigins, Env: hc.Env, LobbyTaskID: hc.LobbyTaskID,
		OriginTenant: originTenant,
		HelloTimeout: hc.HelloTimeout, PingInterval: hc.WSPingInterval, PingTimeout: hc.WSPingTimeout,
		ClientIPProbe: hc.ClientIPProbe, MsgVersion: hc.MsgVersion,
		Edge: edge.Limits{TrustedProxyHops: hc.TrustedProxyHops, Window: hc.EdgeWindow,
			WSConnsPerIP: hc.EdgeWSConnsPerIP, WSConnsTotal: hc.EdgeWSConnsTotal,
			WSHandshakesPerIP: hc.EdgeWSHandshakesPerIP, AuthPerIP: hc.EdgeAuthPerIP},
	}
}

// openBlobStore is the tenant file store: the GCS bucket when one is set,
// else a local dir.
func openBlobStore(ctx context.Context, hc *config.Hub) (blob.Store, error) {
	if hc.FilesBucket == "" {
		return blob.Dir{Root: hc.FilesDir}, nil
	}
	g, err := blob.OpenGCS(ctx, hc.FilesBucket)
	if err != nil {
		return nil, err
	}
	return g, nil
}

// cicdService is the CI-logs service, or nil when it is off.
func cicdService(hc *config.Hub) (*cicdlogs.Service, error) {
	if !hc.CICDLogsEnabled {
		return nil, nil
	}
	stt, err := cicdlogs.ParseSettings(true, hc.Env, hc.CICDGitHubToken, hc.CICDTenantTokens, hc.CICDRepoAllowlist, hc.CICDGitHubAPI, hc.CICDFromBox, hc.CICDFromID)
	if err != nil {
		return nil, err
	}
	svc := &cicdlogs.Service{Settings: stt, Fetch: cicdlogs.HTTPFetcher{}, Now: time.Now, MsgVersion: hc.MsgVersion}
	if k := strings.TrimSpace(hc.CICDHubBoxKey); k != "" {
		raw, err := base64.StdEncoding.DecodeString(k)
		if err != nil || len(raw) != ed25519.PrivateKeySize {
			return nil, fmt.Errorf("SPOOL_HUB_CICD_HUB_BOX_KEY is not a base64 ed25519 private key")
		}
		svc.Signer = ed25519.PrivateKey(raw)
	}
	return svc, nil
}

// loadAuthConfig loads the OIDC and native sign-in cnf and cross-checks them
// with the hub cnf.
func loadAuthConfig(hc *config.Hub) (*auth.Config, *auth.NativeConfig, error) {
	ac, err := auth.Load(hc.Env) // fails fast on a bad SPOOL_HUB_AUTH_*; no providers = auth off
	if err != nil {
		return nil, nil, err
	}
	nc, err := auth.LoadNative(hc.Env) // spec 015; off unless SPOOL_HUB_AUTH_NATIVE_ENABLED=true
	if err != nil {
		return nil, nil, err
	}
	// 017 FR-SEC-006: one hops value for every per-IP limit. The retired
	// native-only knob may stay set only if it agrees.
	if v, ok := os.LookupEnv("SPOOL_HUB_AUTH_NATIVE_TRUSTED_PROXY_HOPS"); ok && strings.TrimSpace(v) != strconv.Itoa(hc.TrustedProxyHops) {
		return nil, nil, fmt.Errorf("SPOOL_HUB_AUTH_NATIVE_TRUSTED_PROXY_HOPS=%q disagrees with SPOOL_HUB_TRUSTED_PROXY_HOPS=%d: set only SPOOL_HUB_TRUSTED_PROXY_HOPS", v, hc.TrustedProxyHops)
	}
	nc.TrustedProxyHops = hc.TrustedProxyHops
	if hc.ViewDoor == hub.ViewDoorSession && len(ac.Enabled()) == 0 && !nc.Enabled {
		return nil, nil, fmt.Errorf("SPOOL_HUB_VIEW_DOOR=session needs SPOOL_HUB_AUTH_PROVIDERS or SPOOL_HUB_AUTH_NATIVE_ENABLED (nobody could sign in)")
	}
	return ac, nc, nil
}

// logRLSPosture says whether tenant row level security binds this hub's
// database role (017 FR-SEC-013/014). It only logs; a memory store is silent.
func logRLSPosture(ctx context.Context, log zerolog.Logger, st store.Store) {
	pg, ok := st.(*store.Postgres)
	if !ok {
		return
	}
	// rdb 0014 row level security binds only a role that is neither
	// superuser nor BYPASSRLS; say which one this hub got.
	if by, err := pg.RLSBypassed(ctx); err != nil {
		log.Warn().Err(err).Msg("db.rls_role_unknown")
	} else if by {
		log.Warn().Str("severity", "WARNING").Msg("db.rls_bypassed: the hub role is superuser or BYPASSRLS, tenant RLS policies do not apply")
	} else {
		log.Info().Msg("db.rls_role_bound: the hub role is subject to row level security")
	}
	// A role that owns the tables can lift FORCE itself.
	if why, err := pg.HubRoleCanLiftRLS(ctx); err != nil {
		log.Warn().Err(err).Msg("db.rls_lift_unknown")
	} else if len(why) > 0 {
		log.Warn().Str("severity", "WARNING").Int("paths", len(why)).Str("first", why[0]).
			Msg("db.rls_liftable: the hub role could switch tenant row level security off (it should not own the tables)")
	} else {
		log.Info().Msg("db.rls_not_liftable: the hub role cannot switch row level security off")
	}
}

// enableNativeSignIn turns on e-mail + password sign-in (spec 015) when its
// cnf says so, with credentials in Postgres (memory for a memory store).
func enableNativeSignIn(a *auth.Handler, nc *auth.NativeConfig, st store.Store, log zerolog.Logger) error {
	if !nc.Enabled {
		return nil
	}
	mc, err := mail.Load() // SPOOL_HUB_MAIL_*: no default relay host
	if err != nil {
		return err
	}
	var cs auth.CredStore = auth.NewMemoryCredStore()
	if pg, ok := st.(*store.Postgres); ok {
		cs = auth.PgCredStore{Pool: pg.Pool()}
	}
	if err := a.EnableNative(nc, auth.NativeDeps{Store: cs, Sender: mc.Sender(log), Delivers: mc.Delivers()}); err != nil {
		return err
	}
	log.Info().Str("mail_transport", mc.Transport).Bool("verify_required", nc.VerifyRequired).Msg("native sign-in on")
	return nil
}

// wirePayments sets opts.Payments (006 M2 checkout) and returns the mail cnf
// it loaded, which the invite mailer shares. It fails fast on an unknown
// rail, a rail it cannot run, or fake-pay outside lde/dev (T018); no rail =
// checkout 503, hub up.
func wirePayments(opts *hub.Options, hc *config.Hub, log zerolog.Logger, st store.Store) (*mail.Config, error) {
	pc, err := payments.Load(hc.Env)
	if err != nil {
		return nil, err
	}
	pmc, err := mail.Load() // the one welcome mail (T021); same relay as spec 015
	if err != nil {
		return nil, err
	}
	plog := log.With().Str("component", "payments").Logger()
	if g := pc.Guard(); g != "" {
		// csi-rel F-17: the hub stays up for the boxes; checkout answers 503.
		plog.Error().Str("severity", "CRITICAL").Str("event", "payment_secret_invalid").Str("problem", g).
			Msg("card rail keys unusable: checkout fail-closes with 503 until they are provisioned")
	}
	ph, err := payments.NewWired(pc, payments.Deps{Store: st, Log: plog,
		Mail: pmc.Sender(log), MailDelivers: pmc.Delivers(), TenantHostPattern: hc.TenantHostPattern,
		DefaultLocale: hc.DefaultLocale})
	if err != nil {
		return nil, err
	}
	opts.Payments = ph
	log.Info().Str("rail", pc.Rail()).Strs("methods", pc.Methods()).Bool("fake_pay", pc.FakePayMounted()).
		Str("card_key_mode", pc.CardKeyMode()).Str("plan_id", pc.PlanID).
		Int("plan_cents", pc.PlanCents).Str("mail_transport", pmc.Transport).Msg("payment rail")
	return pmc, nil
}

// inviteMailer is the admin's in-app invite mail, through the
// same relay and invitemail.Send as `spool hub-invite` (010 FR-016); nil when
// the store, the relay or the app URL cannot send one.
func inviteMailer(hc *config.Hub, log zerolog.Logger, st store.Store, pmc *mail.Config, appURL string) hub.InviteMailer {
	om := operatorMailer(hc, log, st, pmc, appURL)
	if om == nil {
		return nil
	}
	return func(ctx context.Context, tenant, email, locale string) (string, error) {
		res, err := om(ctx, tenant, email, locale)
		return res.Outcome, err
	}
}

// operatorMailer is the invite mailer that returns the full result
// (message_id, delivered): the operator route (CLE-77780) and the shell proof
// need delivered:true, not just the outcome word. It sends through the same
// relay and invitemail.Send as the WUI/CLI invite. nil when the store, the
// relay or the app URL cannot send one.
func operatorMailer(hc *config.Hub, log zerolog.Logger, st store.Store, pmc *mail.Config, appURL string) hub.OperatorMailer {
	im, ok := st.(store.InviteMails)
	if !ok || pmc.Transport == mail.TransportNone || appURL == "" {
		return nil
	}
	ilog := log.With().Str("component", "invitemail").Logger()
	sender, delivers := pmc.Sender(log), pmc.Delivers()
	return func(ctx context.Context, tenant, email, locale string) (invitemail.Result, error) {
		return invitemail.Send(ctx, invitemail.Deps{Store: im, Sender: sender, Delivers: delivers, Log: ilog,
			AppURL: appURL, Locale: locale, DefaultLocale: hc.DefaultLocale,
			Limits: store.InviteMailLimits{MinGap: invitemail.DefaultMinGap, MaxSends: invitemail.DefaultMaxSends}}, tenant, email)
	}
}

// googleOperatorVerify validates a Google-signed ID token minted by the env
// service account and returns its verified email (CLE-77780). The audience
// binds the token to this hub; the issuer must be Google. It is the production
// hub.OperatorVerify; tests pass a seam.
func googleOperatorVerify(ctx context.Context, token, audience string) (string, error) {
	p, err := idtoken.Validate(ctx, token, audience)
	if err != nil {
		return "", err
	}
	if iss, _ := p.Claims["iss"].(string); iss != "https://accounts.google.com" && iss != "accounts.google.com" {
		return "", fmt.Errorf("operator: unexpected token issuer %q", iss)
	}
	email, _ := p.Claims["email"].(string)
	verified, _ := p.Claims["email_verified"].(bool)
	if email == "" || !verified {
		return "", fmt.Errorf("operator: token carries no verified email")
	}
	return strings.ToLower(email), nil
}

// operatorInviteConfig reads the operator invite surface cnf (CLE-77780):
// SPOOL_HUB_OPERATOR_EMAILS (space/comma-separated service-account emails) and
// SPOOL_HUB_OPERATOR_AUDIENCE (the id-token audience the hub expects, its own
// URL). An empty emails list leaves the routes off. Audience is required when
// emails are set, so a token is always bound to this hub.
func operatorInviteConfig() (emails []string, audience string, err error) {
	for _, f := range strings.FieldsFunc(os.Getenv("SPOOL_HUB_OPERATOR_EMAILS"), func(r rune) bool { return r == ',' || r == ' ' || r == '\t' || r == '\n' }) {
		if f = strings.TrimSpace(f); f != "" {
			emails = append(emails, strings.ToLower(f))
		}
	}
	audience = strings.TrimSpace(os.Getenv("SPOOL_HUB_OPERATOR_AUDIENCE"))
	if len(emails) > 0 && audience == "" {
		return nil, "", fmt.Errorf("SPOOL_HUB_OPERATOR_EMAILS is set but SPOOL_HUB_OPERATOR_AUDIENCE is empty (the id-token audience the hub expects)")
	}
	return emails, audience, nil
}

// serveUntilDone binds, serves until ctx ends or the server fails, then
// drains within SPOOL_HUB_GRACEFUL_SHUTDOWN.
func serveUntilDone(ctx context.Context, hc *config.Hub, log zerolog.Logger, srv *hub.Server) int {
	// IdleTimeout closes an idle keep-alive connection; a hijacked socket is
	// not governed by it (keepalive pings do that, 017 FR-SEC-004).
	hs := &http.Server{Handler: srv.Handler(), ReadHeaderTimeout: readHeaderTimeout,
		IdleTimeout: idleTimeout, MaxHeaderBytes: maxHeaderBytes}
	// Bind BEFORE claiming to listen, and log the address the kernel actually
	// gave us. ListenAndServe binds inside the goroutine, so the old line
	// announced "hub listening" for a socket that might never have bound --
	// a failed bind and a healthy hub read identically in the log, which is
	// why run 35604372799 was undiagnosable. Logging ln.Addr() also lets a
	// harness ask for port 0 and read back the port it got, instead of
	// guessing one out of the ephemeral range and racing the kernel for it.
	ln, err := net.Listen("tcp", hc.ListenAddr)
	if err != nil {
		return fail(fmt.Errorf("listen on %s: %w", hc.ListenAddr, err))
	}
	errc := make(chan error, 1)
	go func() { errc <- hs.Serve(ln) }()
	// The runtime's view of the instance (CLE-35076): Cloud Run gives 1 vCPU,
	// and a GOMAXPROCS above what the quota allows is CPU throttling in the
	// tail latency. Logged once, so it can be read rather than assumed.
	log.Info().Str("addr", ln.Addr().String()).Int("gomaxprocs", runtime.GOMAXPROCS(0)).
		Int("num_cpu", runtime.NumCPU()).Int64("gomemlimit", debug.SetMemoryLimit(-1)).Msg("hub listening")
	select {
	case err := <-errc:
		return fail(err)
	case <-ctx.Done():
	}
	log.Info().Msg("hub draining")
	sctx, cancel := context.WithTimeout(context.Background(), hc.GracefulShutdown)
	defer cancel()
	srv.Shutdown()
	if err := hs.Shutdown(sctx); err != nil {
		log.Error().Err(err).Msg("http shutdown")
	}
	return 0
}

// openStore opens Postgres; the literal DSN "memory:" is an in-process store
// for tests and throwaway lde runs only (state dies with the process).
func openStore(ctx context.Context, dsn string, limits store.PoolLimits) (store.Store, error) {
	if dsn == "memory:" {
		return store.NewMemory(), nil
	}
	return store.OpenPostgres(ctx, dsn, limits)
}

// cmdHubTenant seeds a tenant row (006 owns tenant creation; this is the
// operator bootstrap for M1). Idempotent for the same root key.
func cmdHubTenant(args []string) int {
	fs := flag.NewFlagSet("hub-tenant", flag.ContinueOnError)
	tenant := fs.String("tenant", "", "tenant id")
	root := fs.String("root-pubkey", "", "base64 tenant root public key")
	billing := fs.String("billing-status", "", "active|grace|unpaid|internal|manual (default internal)")
	dsn := fs.String("db", os.Getenv("SPOOL_HUB_DB_DSN"), "postgres DSN (default $SPOOL_HUB_DB_DSN)")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	pub, err := base64.StdEncoding.DecodeString(*root)
	if !msg.ValidTenantID(*tenant) || err != nil || len(pub) != ed25519.PublicKeySize || *dsn == "" {
		return fail(fmt.Errorf("--tenant (valid, non-reserved slug), --root-pubkey (base64 32-byte key) and --db / $SPOOL_HUB_DB_DSN are required"))
	}
	ctx := context.Background()
	st, err := store.OpenPostgres(ctx, *dsn)
	if err != nil {
		return fail(err)
	}
	defer st.Close()
	row := store.Tenant{ID: *tenant, RootPubKey: pub, BillingStatus: *billing}
	if err := st.CreateTenant(ctx, row); err != nil {
		if errors.Is(err, store.ErrConflict) {
			return fail(fmt.Errorf("tenant %s exists with a different root key: %w", *tenant, sign.ErrVerify))
		}
		return fail(err)
	}
	fmt.Println(action.JSON(map[string]string{"tenant": *tenant, "status": "ok"}))
	return 0
}

// cmdHubTenantBilling is the owner's billing lever until M2 webhooks exist
// (006 T013b): a payment event becomes tenants.billing_status through the
// same billing.MapEvent table the webhooks will use.
func cmdHubTenantBilling(args []string) int {
	fs := flag.NewFlagSet("hub-tenant-billing", flag.ContinueOnError)
	tenant := fs.String("tenant", "", "tenant id")
	event := fs.String("event", "", "paid|unpaid|failed|refund|cancel")
	dsn := fs.String("db", os.Getenv("SPOOL_HUB_DB_DSN"), "postgres DSN (default $SPOOL_HUB_DB_DSN)")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if !msg.ValidTenantID(*tenant) || *event == "" || *dsn == "" {
		return fail(fmt.Errorf("--tenant (valid slug), --event and --db / $SPOOL_HUB_DB_DSN are required"))
	}
	ctx := context.Background()
	st, err := store.OpenPostgres(ctx, *dsn)
	if err != nil {
		return fail(err)
	}
	defer st.Close()
	status, err := billing.Apply(ctx, st, *tenant, *event)
	if err != nil {
		return fail(err)
	}
	fmt.Println(action.JSON(map[string]string{"tenant": *tenant, "event": *event, "billing_status": status}))
	return 0
}

// cmdHubInvite is the operator's way to seat a tenant's first owner where
// bootstrap is off (prd, 010 FR-014 / OQ-A5): the first sign-in whose
// VERIFIED email matches is admitted with --role, once, before --ttl ends.
// It then mails the invitation once (010 FR-016) through the relay named by
// SPOOL_HUB_MAIL_* (transport none = no mail, said in the JSON); --no-mail
// skips it.
func cmdHubInvite(args []string) int {
	fs := flag.NewFlagSet("hub-invite", flag.ContinueOnError)
	tenant := fs.String("tenant", "", "tenant id")
	email := fs.String("email", "", "the invitee's verified sign-in email")
	role := fs.String("role", store.RoleTenantOwner, "a role id (specs/025): "+strings.Join(rbac.RoleIDs, "|")+"; legacy owner|member map to biz_owner|developer")
	ttl := fs.Duration("ttl", 7*24*time.Hour, "how long the invite stays open")
	dsn := fs.String("db", os.Getenv("SPOOL_HUB_DB_DSN"), "postgres DSN (default $SPOOL_HUB_DB_DSN)")
	orderedBy := fs.String("ordered-by", "", "the human who ordered this invite (a HUM-* id, CLE-77778); recorded as provenance")
	orderedVia := fs.String("ordered-via", "", "the agent or channel that carried the order, e.g. CLE-34967 (optional)")
	noMail := fs.Bool("no-mail", false, "write the invite only, send no invitation email")
	mf := inviteMailFlags(fs)
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if !msg.ValidTenantID(*tenant) || *email == "" || *ttl <= 0 || *dsn == "" {
		return fail(fmt.Errorf("--tenant (valid slug), --email, a positive --ttl and --db / $SPOOL_HUB_DB_DSN are required"))
	}
	ctx := context.Background()
	st, err := store.OpenPostgres(ctx, *dsn)
	if err != nil {
		return fail(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	in := store.Invite{TenantID: *tenant, Email: *email, Role: *role, InvitedBy: store.AdmittedOperator,
		ExpiresAt: now.Add(*ttl), OrderedBy: *orderedBy, OrderedVia: *orderedVia}
	if err := st.PutInvite(ctx, in, now); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return fail(fmt.Errorf("tenant %s does not exist (or --ordered-by names no human)", *tenant))
		}
		if errors.Is(err, store.ErrUnknownRole) {
			return fail(fmt.Errorf("role %q is not a role of tenant %s", *role, *tenant))
		}
		return fail(err)
	}
	out := map[string]any{"tenant": *tenant, "role": rbac.Legacy(*role), "expires_at": in.ExpiresAt.Format(time.RFC3339), "status": "invited"}
	if in.OrderedBy != "" {
		out["ordered_by"] = in.OrderedBy
	}
	if in.OrderedVia != "" {
		out["ordered_via"] = in.OrderedVia
	}
	if *noMail {
		out["mail"] = map[string]any{"outcome": "skipped_no_mail_flag"}
		fmt.Println(action.JSON(out))
		return 0
	}
	res, err := mf.send(ctx, st, *tenant, *email)
	out["mail"] = res
	fmt.Println(action.JSON(out))
	if err != nil {
		return fail(err)
	}
	return 0
}

// cmdHubInviteMail (re)sends the invitation email for an existing invite
// (010 FR-016): open invites only, --min-gap / --max-sends enforced in the
// DB. Exit 0 = sent; 3 = not sent (accepted, expired, rate limited, not
// found, or transport none); 1 = error.
func cmdHubInviteMail(args []string) int {
	fs := flag.NewFlagSet("hub-invite-mail", flag.ContinueOnError)
	tenant := fs.String("tenant", "", "tenant id")
	email := fs.String("email", "", "the invitee's email (the invite key)")
	dsn := fs.String("db", os.Getenv("SPOOL_HUB_DB_DSN"), "postgres DSN (default $SPOOL_HUB_DB_DSN)")
	mf := inviteMailFlags(fs)
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if !msg.ValidTenantID(*tenant) || *email == "" || *dsn == "" {
		return fail(fmt.Errorf("--tenant (valid slug), --email and --db / $SPOOL_HUB_DB_DSN are required"))
	}
	ctx := context.Background()
	st, err := store.OpenPostgres(ctx, *dsn)
	if err != nil {
		return fail(err)
	}
	defer st.Close()
	res, err := mf.send(ctx, st, *tenant, *email)
	fmt.Println(action.JSON(map[string]any{"tenant": *tenant, "mail": res}))
	if err != nil {
		return fail(err)
	}
	if res.Outcome != invitemail.Sent && res.Outcome != invitemail.Logged {
		return 3
	}
	return 0
}

type inviteMailOpts struct {
	appURL, locale, defLocale *string
	minGap                    *time.Duration
	maxSends                  *int
}

func inviteMailFlags(fs *flag.FlagSet) inviteMailOpts {
	return inviteMailOpts{
		appURL:    fs.String("app-url", os.Getenv("SPOOL_HUB_AUTH_APP_URL"), "the env's WUI origin https://<fqdn> (default $SPOOL_HUB_AUTH_APP_URL)"),
		locale:    fs.String("locale", "", "mail locale (default: --default-locale; the invitee has none stored)"),
		defLocale: fs.String("default-locale", envOr("SPOOL_HUB_DEFAULT_LOCALE", "en"), "the WUI's unprefixed locale (default $SPOOL_HUB_DEFAULT_LOCALE)"),
		minGap:    fs.Duration("min-gap", invitemail.DefaultMinGap, "least time between two sends of one invite"),
		maxSends:  fs.Int("max-sends", invitemail.DefaultMaxSends, "most sends per invite since it was (re)created"),
	}
}

func envOr(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

// send mails through the SPOOL_HUB_MAIL_* relay. Transport none sends
// nothing and claims nothing ("skipped_no_relay").
func (o inviteMailOpts) send(ctx context.Context, st *store.Postgres, tenant, email string) (invitemail.Result, error) {
	res := invitemail.Result{To: mail.Digest(email)}
	mc, err := mail.Load()
	if err != nil {
		return res, err
	}
	if mc.Transport == mail.TransportNone {
		res.Outcome = "skipped_no_relay"
		return res, nil
	}
	log := logging.New(&config.Config{LogLevel: "info", LogFormat: "json"}).With().Str("component", "cli").Logger()
	return invitemail.Send(ctx, invitemail.Deps{Store: st, Sender: mc.Sender(log), Delivers: mc.Delivers(), Log: log,
		AppURL: *o.appURL, Locale: *o.locale, DefaultLocale: *o.defLocale,
		Limits: store.InviteMailLimits{MinGap: *o.minGap, MaxSends: *o.maxSends}}, tenant, email)
}

// cmdRootKeygen creates a tenant ROOT keypair (the renter's key; it pins and
// revokes box keys). The private key is written 0600 and never printed.
func cmdRootKeygen(args []string) int {
	fs := flag.NewFlagSet("root-keygen", flag.ContinueOnError)
	out := fs.String("out", "", "path for the private key (0600)")
	force := fs.Bool("force", false, "overwrite an existing key")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if *out == "" {
		return fail(fmt.Errorf("--out is required"))
	}
	if _, err := os.Stat(*out); err == nil && !*force {
		return fail(fmt.Errorf("%s exists (use --force to overwrite)", *out))
	}
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		return fail(err)
	}
	if err := os.WriteFile(*out, []byte(base64.StdEncoding.EncodeToString(priv)+"\n"), 0o600); err != nil {
		return fail(err)
	}
	fmt.Println(base64.StdEncoding.EncodeToString(pub))
	return 0
}

// cmdHubPin pins (or with --revoke unpins) a box key at the hub, signed by the
// tenant root key (POST / DELETE /v1/pins).
func cmdHubPin(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("hub-pin", flag.ContinueOnError)
	box := fs.String("box", "", "box id")
	pubkey := fs.String("pubkey", "", "base64 box public key (not with --revoke)")
	rootKey := fs.String("root-key", cfg.TenantRootKey, "the tenant root private key: a file, the key text, or - for stdin (default $SPOOL_TENANT_ROOT_KEY)")
	force := fs.Bool("force", false, "replace a different existing key")
	revoke := fs.Bool("revoke", false, "revoke the box's pin")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	out, err := action.PublishPin(cfg, action.PinArgs{Box: *box, PubKey: *pubkey, RootKey: *rootKey, Force: *force, Revoke: *revoke})
	if err != nil {
		return fail(err)
	}
	fmt.Println(strings.TrimSpace(string(out)))
	return 0
}

func boxClient(cfg *config.Config) (*hubclient.Client, error) {
	if cfg.HubURL == "" {
		return nil, fmt.Errorf("$SPOOL_HUB_URL is not set (hub verbs need hub mode)")
	}
	c := hubclient.New(cfg)
	c.Log = logging.New(cfg).With().Str("component", "hubclient").Str("box", cfg.BoxID).Logger()
	return c, nil
}

// cmdHubSync runs one role=box session and prints what it did.
func cmdHubSync(cfg *config.Config) int {
	c, err := boxClient(cfg)
	if err != nil {
		return fail(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	r, err := c.Sync(ctx)
	fmt.Println(action.JSON(r))
	if err != nil {
		return fail(err)
	}
	return 0
}

// cmdHubRun holds the box session until signalled.
func cmdHubRun(cfg *config.Config) int {
	c, err := boxClient(cfg)
	if err != nil {
		return fail(err)
	}
	// The daemon is the one caller that outlives its deliveries, so it is the
	// one that can take the terminal leg off the read loop. Stop
	// drains what is queued before the process leaves.
	// SPOOL_NOTIFY_ASYNC=0 is the rollback (specs/030 FR-007): no queue, so
	// notify.Deliver falls back to the synchronous path. Stop takes a nil.
	var q *notify.Queue
	if !cfg.NotifyAsyncOff() {
		q = notify.Start(cfg)
	}
	defer q.Stop()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := c.Run(ctx); err != nil {
		return fail(err)
	}
	return 0
}

// cmdHubGetFile downloads one file by id from the hub into the local blob
// store, even when it is already held: a live proof of the file read door
// (do_spl_file_door_probe). Prints {"file_id","fetched"}; a refusal fails
// with the hub's not_found.
func cmdHubGetFile(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("hub-get-file", flag.ContinueOnError)
	id := fs.String("file-id", "", "sha256 file id")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if *id == "" {
		return fail(fmt.Errorf("--file-id is required"))
	}
	c, err := boxClient(cfg)
	if err != nil {
		return fail(err)
	}
	c.Log = zerolog.Nop()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return fail(err)
	}
	defer sess.Close()
	if err := sess.FetchFile(ctx, *id); err != nil {
		return fail(err)
	}
	fmt.Println(action.JSON(map[string]any{"file_id": *id, "fetched": true}))
	return 0
}

// cmdHubTail prints a task's hub topic (human lines, or --json NDJSON of the
// inner v:1); --follow keeps printing new messages until signalled.
func cmdHubTail(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("hub-tail", flag.ContinueOnError)
	task := fs.String("task", "", "task id")
	follow := fs.Bool("follow", false, "keep streaming new messages")
	asJSON := fs.Bool("json", false, "emit the inner v:1 objects as NDJSON")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if *task == "" {
		return fail(fmt.Errorf("--task is required"))
	}
	c, err := boxClient(cfg)
	if err != nil {
		return fail(err)
	}
	c.Log = zerolog.Nop()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return fail(err)
	}
	defer sess.Close()
	_, err = sess.Tail(ctx, *task, *follow, func(e *wire.Envelope) {
		m, err := e.Inner()
		if err != nil {
			return
		}
		if *asJSON {
			raw, _ := msg.Marshal(m)
			fmt.Println(string(raw))
			return
		}
		fmt.Printf("%s  %s@%s -> %s@%s  [%s]  %s\n", m.TS, m.From, e.FromBox, m.To, e.ToBox, m.Kind, m.Body)
	})
	if err != nil {
		return fail(err)
	}
	return 0
}
