// Package config loads the spool's runtime configuration from the environment,
// failing fast on a malformed value and resolving documented defaults. It
// follows the pas-psf pattern (caarlos0/env), scoped to the on-box spool.
package config

import (
	"crypto/ed25519"
	"encoding/base64"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/caarlos0/env/v10"

	"github.com/csitea/csi-spl/spool-hub-api/internal/cicdlogs"
	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// Config is the resolved on-box spool configuration. Every value is an env var
// with a documented default (Constitution II/VI); nothing else is baked in.
type Config struct {
	// SpoolRoot is the on-box message tree: a pre-created system dir, separate
	// from any other tool's message tree (owner decision 2026-09-18).
	SpoolRoot string `env:"SPOOL_ROOT" envDefault:"/var/spool-hub"`
	// KeysDir holds the box PRIVATE key, strictly outside SpoolRoot. Empty here
	// means "$HOME/.spool/keys", resolved in Load.
	KeysDir string `env:"SPOOL_KEYS_DIR"`
	// PinsDir holds shared PUBLIC box pins. Empty here means "<SpoolRoot>/pins".
	PinsDir string `env:"SPOOL_PINS_DIR"`
	// BoxID names this box for its keypair and hub routing. No default: local
	// mode never needs it, and keygen/pin fail fast when it is unset.
	BoxID string `env:"SPOOL_BOX_ID"`
	// LogLevel is a zerolog level name (trace|debug|info|warn|error).
	LogLevel string `env:"SPOOL_LOG_LEVEL" envDefault:"info"`
	// LogFormat is "console" (CLI) or "json" (deployed).
	LogFormat string `env:"SPOOL_LOG_FORMAT" envDefault:"console"`
	// HubURL switches the box into hub mode (spec 003): the api host
	// https://api.<domain> (specs/026); a legacy https://<tenant>.<domain> still
	// works. Unset = the unchanged local 002 path.
	HubURL string `env:"SPOOL_HUB_URL"`
	// Tenant is the box's tenant, sent as X-Spool-Tenant (specs/026 §4) and
	// proven by the box's pin. Unset = derived from a legacy tenant HubURL.
	Tenant string `env:"SPOOL_TENANT"`
	// TenantRootKey is the path to the tenant root PRIVATE key used by spool-pin
	// to POST/DELETE /v1/pins. Empty = local pin file only (002).
	TenantRootKey string `env:"SPOOL_TENANT_ROOT_KEY"`
	// MirrorLocal also hub-sends same-box mail: unset/0/false (default) or 1/true.
	MirrorLocal string `env:"SPOOL_MIRROR_LOCAL"`
	// Channels is the box's channel subscriptions (comma list of slugs) sent in
	// hub hello/announce (specs/003 channels-v1 §3). Unset = #lobby only.
	Channels string `env:"SPOOL_CHANNELS"`
	// NotifyCmd is the terminal leg (specs/028): the command run after a v:1
	// message lands in a LOCAL agent's inbox, so the agent's tmux pane SHOWS
	// it. On a box this is csi-spl-orc's spool-notify.sh, exported by
	// spool-harness for the agent session and for the hub-run sidecar it
	// starts. Unset (a hub, CI, a test) or "off" = no terminal leg. Split on
	// whitespace into argv; no shell is involved.
	NotifyCmd string `env:"SPOOL_NOTIFY_CMD"`
	// NotifyTimeout bounds that command. It can never fail a delivery: the
	// file is already written when it runs (002).
	NotifyTimeout time.Duration `env:"SPOOL_NOTIFY_TIMEOUT" envDefault:"10s"`
	// NotifyAsync is the rollback for the queued terminal leg (specs/030
	// FP-1, FR-007). Unset/"1" = hub-run queues each poke on a per-recipient
	// lane off the read loop; "0"/"false"/"off" = every poke runs synchronously
	// on the delivering goroutine, exactly as before 030. It never turns the
	// terminal leg itself off - that is SPOOL_NOTIFY_CMD=off.
	NotifyAsync string `env:"SPOOL_NOTIFY_ASYNC"`
	// SubmitSocket is the box-local listener the hub-run sidecar opens so a
	// `spool send` hands its signed envelope to the sidecar's ALREADY-WARM hub
	// session instead of dialling a new one (specs/030 FP-2). Measured
	// 2026-09-21: a cold dial to the live dev hub costs 220.6 ms p50 / 266.5 ms
	// p95 (n=20) before the hello even starts, and the sidecar is holding an
	// authenticated socket to that same hub the whole time.
	//
	// Unset = SubmitPath() below (inside HubDir). "off" = no listener and no
	// client attempt: every send dials as it did before 030, which is the
	// rollback (spec FR-007).
	SubmitSocket string `env:"SPOOL_SUBMIT_SOCKET"`
	// MsgVersion is the schema version this box WRITES (specs/020
	// contracts/migration.md §5): 1 until every reader is deployed. Readers
	// accept 1 and 2 whatever this says. 0 (a Config built in code) = msg.Version.
	MsgVersion int `env:"SPOOL_MSG_VERSION" envDefault:"1"`
}

// NotifyTimeoutOr is NotifyTimeout, or 10s for a Config built in code.
func (c *Config) NotifyTimeoutOr() time.Duration {
	if c.NotifyTimeout <= 0 {
		return 10 * time.Second
	}
	return c.NotifyTimeout
}

// WriteVersion is the v a message composed on this box carries.
func (c *Config) WriteVersion() int {
	if c.MsgVersion == 0 {
		return msg.Version
	}
	return c.MsgVersion
}

// Load parses the environment and resolves defaults that depend on $HOME or
// SpoolRoot. It fails fast on an unparseable env value.
func Load() (*Config, error) {
	var c Config
	if err := env.Parse(&c); err != nil {
		return nil, fmt.Errorf("parse spool config: %w", err)
	}
	if c.SpoolRoot == "" {
		return nil, fmt.Errorf("SPOOL_ROOT resolved empty")
	}
	if !msg.IsSupported(c.MsgVersion) {
		return nil, fmt.Errorf("SPOOL_MSG_VERSION %d must be 1 or 2", c.MsgVersion)
	}
	if c.KeysDir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, fmt.Errorf("resolve $HOME for keys dir: %w", err)
		}
		c.KeysDir = filepath.Join(home, ".spool", "keys")
	}
	if c.PinsDir == "" {
		c.PinsDir = filepath.Join(c.SpoolRoot, "pins")
	}
	if c.HubURL != "" {
		// Local mode ignores the mirror flag (trust-modes §6), so only hub mode
		// fails fast on an illegal value.
		if _, err := c.Mirror(); err != nil {
			return nil, err
		}
		u, err := url.Parse(c.HubURL)
		if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
			return nil, fmt.Errorf("SPOOL_HUB_URL %q must be an http(s) URL", c.HubURL)
		}
		if c.Tenant != "" && !msg.ValidTenantID(c.Tenant) {
			return nil, fmt.Errorf("SPOOL_TENANT %q is not a tenant id", c.Tenant)
		}
		// FR-002 / 004 T002: hub mode is a box identity; no silent empty box_id.
		if !msg.ValidBoxID(c.BoxID) {
			return nil, fmt.Errorf("SPOOL_BOX_ID must be a valid box id when SPOOL_HUB_URL is set")
		}
	}
	return &c, nil
}

// TenantID is the tenant a hub-mode box names (specs/026 §4): SPOOL_TENANT,
// else the first label of a legacy tenant HubURL (<tenant>.<domain>), else ""
// (the api host with no SPOOL_TENANT: the hub then answers 400 tenant_required).
func (c *Config) TenantID() string {
	if c.Tenant != "" {
		return strings.ToLower(c.Tenant)
	}
	u, err := url.Parse(c.HubURL)
	if err != nil {
		return ""
	}
	host := strings.ToLower(u.Hostname())
	label, rest, ok := strings.Cut(host, ".")
	if !ok || rest == "" || net.ParseIP(host) != nil || !msg.ValidTenantID(label) {
		return ""
	}
	return label
}

// ChannelList is $SPOOL_CHANNELS split on commas, trimmed, lower-cased,
// empties dropped. The hub ignores slugs it does not know.
func (c *Config) ChannelList() []string {
	var out []string
	for _, s := range strings.Split(c.Channels, ",") {
		if s = strings.ToLower(strings.TrimSpace(s)); s != "" {
			out = append(out, s)
		}
	}
	return out
}

// Mirror reports $SPOOL_MIRROR_LOCAL; any value but unset/0/false/1/true fails
// fast (trust-modes §6).
func (c *Config) Mirror() (bool, error) {
	switch strings.ToLower(c.MirrorLocal) {
	case "", "0", "false":
		return false, nil
	case "1", "true":
		return true, nil
	}
	return false, fmt.Errorf("SPOOL_MIRROR_LOCAL %q must be unset, 0, false, 1 or true", c.MirrorLocal)
}

// HubDir is the box's private hub state: roster cache, pending and rejected
// envelopes. Hidden, so the $SPOOL_ROOT/*/ agent scan never sees it.
func (c *Config) HubDir() string { return filepath.Join(c.SpoolRoot, ".hub") }

// NotifyAsyncOff reports that the 030 queued terminal leg is rolled back.
func (c *Config) NotifyAsyncOff() bool {
	switch strings.ToLower(strings.TrimSpace(c.NotifyAsync)) {
	case "0", "false", "off":
		return true
	}
	return false
}

// SubmitOff reports that the 030 submit path is disabled by cnf.
func (c *Config) SubmitOff() bool { return strings.EqualFold(strings.TrimSpace(c.SubmitSocket), "off") }

// SubmitPath is the box-local submit socket (specs/030 FP-2), or "" when it is
// off. It lives in HubDir, beside the pending envelopes it short-circuits, so
// one box root carries one sidecar's worth of state and two roots on one
// machine never share a listener.
func (c *Config) SubmitPath() string {
	if c.SubmitOff() {
		return ""
	}
	if p := strings.TrimSpace(c.SubmitSocket); p != "" {
		return p
	}
	return filepath.Join(c.HubDir(), "submit.sock")
}

// Hub is the hub process configuration (`spool serve`, spec 003). The names are
// the infra lane's (csi-spl-cnf all.env.yaml env.hub); nothing is baked in.
type Hub struct {
	ListenAddr string `env:"SPOOL_HUB_LISTEN_ADDR" envDefault:":8080"`
	Port       string `env:"PORT"` // Cloud Run: wins over ListenAddr
	Env        string `env:"SPOOL_HUB_ENV"`
	DBDSN      string `env:"SPOOL_HUB_DB_DSN"`
	// The pgx pool (specs/027 T010). Cloud SQL db-f1-micro allows 25
	// connections, 3 reserved for superusers: two instances overlapping in a
	// roll at 8 each leave room for operator sessions. A DSN pool_* wins.
	DBMaxConns        int           `env:"SPOOL_HUB_DB_MAX_CONNS" envDefault:"8"`
	DBMinConns        int           `env:"SPOOL_HUB_DB_MIN_CONNS" envDefault:"2"`
	DBMaxConnIdleTime time.Duration `env:"SPOOL_HUB_DB_MAX_CONN_IDLE_TIME" envDefault:"5m"`
	// Exactly one blob store: a GCS bucket (prod) or a local dir (tests / lde).
	FilesBucket string `env:"SPOOL_HUB_FILES_BUCKET"`
	FilesDir    string `env:"SPOOL_HUB_FILES_DIR"`
	// TenantHostPattern is "{tenant}.<fqdn>"; the tenant comes from the Host.
	TenantHostPattern string        `env:"SPOOL_HUB_TENANT_HOST_PATTERN"`
	AllowTextOnly     bool          `env:"SPOOL_HUB_ALLOW_TEXT_ONLY_WHEN_FILE_MISSING" envDefault:"false"`
	QueueTTL          time.Duration `env:"SPOOL_HUB_QUEUE_TTL" envDefault:"168h"`
	QueueMaxPerBox    int           `env:"SPOOL_HUB_QUEUE_MAX_PER_BOX" envDefault:"1000"`
	RetentionAlerts   time.Duration `env:"SPOOL_HUB_RETENTION_ALERTS" envDefault:"168h"`
	RetentionChannels time.Duration `env:"SPOOL_HUB_RETENTION_CHANNELS" envDefault:"720h"`
	HelloSkew         time.Duration `env:"SPOOL_HUB_HELLO_SKEW" envDefault:"300s"`
	UploadTokenTTL    time.Duration `env:"SPOOL_HUB_UPLOAD_TOKEN_TTL" envDefault:"5m"`
	// Quota fields: 0 = unlimited (tests / internal). Production values live in cnf.
	QuotaMessagesPerMonth int           `env:"SPOOL_HUB_QUOTA_MESSAGES_PER_MONTH" envDefault:"0"`
	QuotaPins             int           `env:"SPOOL_HUB_QUOTA_PINS" envDefault:"0"`
	QuotaFileBytes        int64         `env:"SPOOL_HUB_QUOTA_FILE_BYTES" envDefault:"0"`
	BillingGrace          time.Duration `env:"SPOOL_HUB_BILLING_GRACE" envDefault:"168h"`
	GracefulShutdown      time.Duration `env:"SPOOL_HUB_GRACEFUL_SHUTDOWN" envDefault:"10s"`
	LogLevel              string        `env:"SPOOL_HUB_LOG_LEVEL" envDefault:"info"`
	LogFormat             string        `env:"SPOOL_HUB_LOG_FORMAT" envDefault:"json"`
	MigrationsDir         string        `env:"SPOOL_HUB_MIGRATIONS_DIR"`
	// 008 CI/CD logs (M1 stub, flagged off). Token/key are secrets, never logged.
	CICDLogsEnabled   bool   `env:"SPOOL_HUB_CICD_LOGS_ENABLED" envDefault:"false"`
	CICDGitHubAPI     string `env:"SPOOL_HUB_CICD_GITHUB_API"`
	CICDGitHubToken   string `env:"SPOOL_HUB_CICD_GITHUB_TOKEN"`
	CICDTenantTokens  string `env:"SPOOL_HUB_CICD_TENANT_TOKENS"`
	CICDRepoAllowlist string `env:"SPOOL_HUB_CICD_REPO_ALLOWLIST"`
	CICDFromBox       string `env:"SPOOL_HUB_CICD_FROM_BOX" envDefault:"hub"`
	CICDFromID        string `env:"SPOOL_HUB_CICD_FROM_ID" envDefault:"CI-0"`
	CICDHubBoxKey     string `env:"SPOOL_HUB_CICD_HUB_BOX_KEY"`
	// Viewer API (specs/003 contracts/view-v1.md). ViewDoor "off" is lde/dev
	// only; "session" = member sessions only + credentialed CORS (010 FR-009).
	ViewDoor        string   `env:"SPOOL_HUB_VIEW_DOOR" envDefault:"token"`
	ViewCORSOrigins []string `env:"SPOOL_HUB_VIEW_CORS_ORIGINS" envSeparator:","`
	// SPL-959 tenant hosts: the WUI of tenant <t> is https://<t>.<fqdn>
	// (TenantHostPattern), and the hub serves a browser request as the tenant
	// its Origin names (member-only), with credentialed CORS for those hosts.
	// WUIApexTenant is the tenant of the apex https://<fqdn> ("" = the
	// session's tenant there, as before). Both off by default.
	WUITenantHosts bool   `env:"SPOOL_HUB_WUI_TENANT_HOSTS" envDefault:"false"`
	WUIApexTenant  string `env:"SPOOL_HUB_WUI_APEX_TENANT"`
	// #general lobby task id (specs/003 contracts/wui-live-ws.md §1); "" = off.
	LobbyTaskID string `env:"SPOOL_HUB_LOBBY_TASK_ID"`
	// AuthBootstrapOwner: the first human to sign in to a tenant with zero
	// members becomes its owner (010 FR-014, OQ-A5). A trust change: dev only
	// until the owner decides; prd admits by operator invite.
	AuthBootstrapOwner bool `env:"SPOOL_HUB_AUTH_BOOTSTRAP_OWNER" envDefault:"false"`
	// 014 WUI dispatch (specs/014 contracts/wui-dispatch.md §1). WUIKey is the
	// base64 box-wui Ed25519 PRIVATE key (Secret Manager): never logged.
	WUIDispatch     bool   `env:"SPOOL_HUB_WUI_DISPATCH" envDefault:"false"`
	WUIKey          string `env:"SPOOL_HUB_WUI_KEY"`
	WUIKeyEphemeral bool   `env:"SPOOL_HUB_WUI_KEY_EPHEMERAL" envDefault:"false"`
	// 017 FR-SEC-006: how many proxies in front of the hub append to
	// X-Forwarded-For; the client IP every per-IP limit keys on (edge and
	// native auth) is the hops-th entry from the right. MEASURED per env with
	// csi-spl-orc do_spl_probe_client_ip, never assumed. 0 = the TCP peer.
	TrustedProxyHops int  `env:"SPOOL_HUB_TRUSTED_PROXY_HOPS" envDefault:"0"`
	ClientIPProbe    bool `env:"SPOOL_HUB_CLIENT_IP_PROBE" envDefault:"false"`
	// 017 FR-SEC-004 in-app edge limits (no LB / Cloud Armor, owner
	// 2026-09-19). 0 turns one limit off. The address-free controls (global
	// socket cap, hello + ping timeouts) default ON, csi-rel's rule that a
	// forgotten key must not fail open. The PER-IP limits default OFF: keyed
	// on a wrong address (hops not yet measured, so every caller shares the
	// front end's) they would be an outage, not a limit; cnf sets them
	// together with SPOOL_HUB_TRUSTED_PROXY_HOPS.
	EdgeWindow            time.Duration `env:"SPOOL_HUB_EDGE_WINDOW" envDefault:"1m"`
	EdgeWSConnsPerIP      int           `env:"SPOOL_HUB_EDGE_WS_CONNS_PER_IP" envDefault:"0"`
	EdgeWSConnsTotal      int           `env:"SPOOL_HUB_EDGE_WS_CONNS_TOTAL" envDefault:"900"`
	EdgeWSHandshakesPerIP int           `env:"SPOOL_HUB_EDGE_WS_HANDSHAKES_PER_IP" envDefault:"0"`
	EdgeAuthPerIP         int           `env:"SPOOL_HUB_EDGE_AUTH_PER_IP" envDefault:"0"`
	HelloTimeout          time.Duration `env:"SPOOL_HUB_HELLO_TIMEOUT" envDefault:"10s"`
	WSPingInterval        time.Duration `env:"SPOOL_HUB_WS_PING_INTERVAL" envDefault:"30s"`
	WSPingTimeout         time.Duration `env:"SPOOL_HUB_WS_PING_TIMEOUT" envDefault:"15s"`
	// MsgVersion is the schema version the hub WRITES for the messages it
	// composes itself (WUI posts, dispatch, CI-logs notes), specs/020
	// contracts/migration.md §5: 1 until every reader is deployed.
	MsgVersion int `env:"SPOOL_HUB_MSG_VERSION" envDefault:"1"`
	// DefaultLocale (CLE-3403) is the locale a request that names none gets
	// (X-Locale > Accept-Language > this), the mail locale of last resort, and
	// the one locale WUI links carry no /<loc> prefix for. cnf env.i18n, the
	// same value the WUI builds with; one of the 19 i18n.Supported codes.
	DefaultLocale string `env:"SPOOL_HUB_DEFAULT_LOCALE" envDefault:"en"`
}

// WUIPrivateKey returns the box-wui signing key: decoded from SPOOL_HUB_WUI_KEY,
// freshly generated when SPOOL_HUB_WUI_KEY_EPHEMERAL (lde/dev), else nil.
func (h *Hub) WUIPrivateKey() (ed25519.PrivateKey, error) {
	if k := strings.TrimSpace(h.WUIKey); k != "" {
		raw, err := base64.StdEncoding.DecodeString(k)
		if err != nil || len(raw) != ed25519.PrivateKeySize {
			return nil, fmt.Errorf("SPOOL_HUB_WUI_KEY is not a base64 ed25519 private key")
		}
		return ed25519.PrivateKey(raw), nil
	}
	if h.WUIKeyEphemeral {
		_, priv, err := ed25519.GenerateKey(nil)
		return priv, err
	}
	return nil, nil
}

// LoadHub parses the hub environment and fails fast on a missing or
// contradictory value.
func LoadHub() (*Hub, error) {
	var h Hub
	if err := env.Parse(&h); err != nil {
		return nil, fmt.Errorf("parse hub config: %w", err)
	}
	if h.Port != "" {
		h.ListenAddr = ":" + h.Port
	}
	if h.DBDSN == "" {
		return nil, fmt.Errorf("SPOOL_HUB_DB_DSN must be set (no default)")
	}
	if h.DBMaxConns < 1 || h.DBMinConns < 0 || h.DBMinConns > h.DBMaxConns || h.DBMaxConnIdleTime <= 0 {
		return nil, fmt.Errorf("SPOOL_HUB_DB_MAX_CONNS must be >= 1, SPOOL_HUB_DB_MIN_CONNS 0..MAX_CONNS, SPOOL_HUB_DB_MAX_CONN_IDLE_TIME positive")
	}
	if (h.FilesBucket == "") == (h.FilesDir == "") {
		return nil, fmt.Errorf("exactly one of SPOOL_HUB_FILES_BUCKET or SPOOL_HUB_FILES_DIR must be set")
	}
	if !strings.HasPrefix(h.TenantHostPattern, "{tenant}.") || len(h.TenantHostPattern) <= len("{tenant}.") {
		return nil, fmt.Errorf("SPOOL_HUB_TENANT_HOST_PATTERN %q must look like {tenant}.<fqdn> (no default)", h.TenantHostPattern)
	}
	if h.QueueTTL <= 0 || h.HelloSkew <= 0 || h.UploadTokenTTL <= 0 || h.QueueMaxPerBox <= 0 ||
		h.RetentionAlerts <= 0 || h.RetentionChannels <= 0 || h.BillingGrace <= 0 {
		return nil, fmt.Errorf("hub durations and SPOOL_HUB_QUEUE_MAX_PER_BOX must be positive")
	}
	if h.TrustedProxyHops < 0 || h.EdgeWSConnsPerIP < 0 || h.EdgeWSConnsTotal < 0 ||
		h.EdgeWSHandshakesPerIP < 0 || h.EdgeAuthPerIP < 0 || h.WSPingInterval < 0 {
		return nil, fmt.Errorf("SPOOL_HUB_TRUSTED_PROXY_HOPS, SPOOL_HUB_EDGE_* and SPOOL_HUB_WS_PING_INTERVAL must be zero (off) or positive")
	}
	if h.EdgeWindow <= 0 || h.HelloTimeout <= 0 || h.WSPingTimeout <= 0 {
		return nil, fmt.Errorf("SPOOL_HUB_EDGE_WINDOW, SPOOL_HUB_HELLO_TIMEOUT and SPOOL_HUB_WS_PING_TIMEOUT must be positive")
	}
	if !msg.IsSupported(h.MsgVersion) {
		return nil, fmt.Errorf("SPOOL_HUB_MSG_VERSION %d must be 1 or 2", h.MsgVersion)
	}
	if err := i18n.Validate("SPOOL_HUB_DEFAULT_LOCALE", h.DefaultLocale); err != nil {
		return nil, err
	}
	if h.QuotaMessagesPerMonth < 0 || h.QuotaPins < 0 || h.QuotaFileBytes < 0 {
		return nil, fmt.Errorf("hub quotas must be zero (unlimited) or positive")
	}
	if err := cicdlogs.ValidateHubEnv(h.CICDLogsEnabled, h.Env, h.CICDGitHubToken, h.CICDTenantTokens, h.CICDRepoAllowlist, h.CICDGitHubAPI, h.CICDFromBox, h.CICDFromID); err != nil {
		return nil, err
	}
	switch h.ViewDoor {
	case "token", "session":
	case "off":
		// Open reads in lde and dev (ORC decision 2026-09-18); prd, and any
		// unnamed env, stay fail-closed.
		if h.Env != "lde" && h.Env != "dev" {
			return nil, fmt.Errorf("SPOOL_HUB_VIEW_DOOR=off is allowed only with SPOOL_HUB_ENV=lde or dev (got %q)", h.Env)
		}
	default:
		return nil, fmt.Errorf("SPOOL_HUB_VIEW_DOOR %q must be token, session or off", h.ViewDoor)
	}
	if h.LobbyTaskID != "" && !uuidRe.MatchString(h.LobbyTaskID) {
		return nil, fmt.Errorf("SPOOL_HUB_LOBBY_TASK_ID %q must be a lowercase UUID", h.LobbyTaskID)
	}
	if h.WUIApexTenant != "" && (!h.WUITenantHosts || !tenantIDRe.MatchString(h.WUIApexTenant)) {
		return nil, fmt.Errorf("SPOOL_HUB_WUI_APEX_TENANT %q needs SPOOL_HUB_WUI_TENANT_HOSTS=true and a tenant id", h.WUIApexTenant)
	}
	for _, o := range h.ViewCORSOrigins {
		if err := checkOrigin(o); err != nil {
			return nil, err
		}
	}
	if h.WUIKeyEphemeral && h.Env != "lde" && h.Env != "dev" {
		return nil, fmt.Errorf("SPOOL_HUB_WUI_KEY_EPHEMERAL=true is allowed only with SPOOL_HUB_ENV=lde or dev (got %q)", h.Env)
	}
	if strings.TrimSpace(h.WUIKey) != "" {
		if _, err := h.WUIPrivateKey(); err != nil {
			return nil, err
		}
	}
	if h.WUIDispatch && strings.TrimSpace(h.WUIKey) == "" && !h.WUIKeyEphemeral {
		return nil, fmt.Errorf("SPOOL_HUB_WUI_DISPATCH=true needs SPOOL_HUB_WUI_KEY (or SPOOL_HUB_WUI_KEY_EPHEMERAL=true in lde/dev)")
	}
	return &h, nil
}

// CheckKeysDir refuses a KeysDir that is SpoolRoot or lies inside it (FR-009,
// NFR-002: the box private key never enters the shared root). Both paths are
// made absolute and symlinks are resolved on their longest existing prefix, so
// neither `..` nor a symlink hides a key dir inside the root.
func (c *Config) CheckKeysDir() error {
	root, err := resolvePath(c.SpoolRoot)
	if err != nil {
		return fmt.Errorf("resolve SPOOL_ROOT: %w", err)
	}
	keys, err := resolvePath(c.KeysDir)
	if err != nil {
		return fmt.Errorf("resolve SPOOL_KEYS_DIR: %w", err)
	}
	rel, err := filepath.Rel(root, keys)
	if err != nil {
		return nil // different volumes: outside
	}
	if rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))) {
		return fmt.Errorf("SPOOL_KEYS_DIR %q is inside SPOOL_ROOT %q: the box private key must live outside the spool root (default $HOME/.spool/keys)", c.KeysDir, c.SpoolRoot)
	}
	return nil
}

// resolvePath returns p absolute and cleaned, with symlinks resolved on its
// longest existing prefix (the rest need not exist yet).
func resolvePath(p string) (string, error) {
	abs, err := filepath.Abs(p)
	if err != nil {
		return "", err
	}
	rest := ""
	for cur := abs; ; {
		if real, err := filepath.EvalSymlinks(cur); err == nil {
			return filepath.Join(real, rest), nil
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return abs, nil
		}
		rest = filepath.Join(filepath.Base(cur), rest)
		cur = parent
	}
}

// FilesDir is the shared content-addressed blob store.
func (c *Config) FilesDir() string { return filepath.Join(c.SpoolRoot, "files") }

// checkOrigin accepts a bare browser origin: http(s)://host[:port], no path,
// no wildcard (FR-021).
func checkOrigin(o string) error {
	u, err := url.Parse(o)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" ||
		strings.Contains(o, "*") || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.User != nil ||
		strings.HasSuffix(o, "/") {
		return fmt.Errorf("SPOOL_HUB_VIEW_CORS_ORIGINS entry %q must be http(s)://host[:port] (no path, no wildcard)", o)
	}
	return nil
}

var tenantIDRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)

var uuidRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
