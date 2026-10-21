package config

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/cicdlogs"
)

func TestLoadRequiresBoxIDWhenHubURLSet(t *testing.T) {
	root := t.TempDir()
	t.Setenv("SPOOL_ROOT", root)
	t.Setenv("SPOOL_KEYS_DIR", t.TempDir())
	t.Setenv("SPOOL_PINS_DIR", root+"/pins")
	t.Setenv("SPOOL_HUB_URL", "https://acme.example.test")
	t.Setenv("SPOOL_BOX_ID", "")
	t.Setenv("SPOOL_TENANT_ROOT_KEY", "")
	t.Setenv("SPOOL_MIRROR_LOCAL", "")

	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "SPOOL_BOX_ID") {
		t.Fatalf("hub URL without box id: %v", err)
	}
	t.Setenv("SPOOL_BOX_ID", "BOX-A") // agent-id alphabet, not a box id
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "SPOOL_BOX_ID") {
		t.Fatalf("invalid box id: %v", err)
	}
	t.Setenv("SPOOL_BOX_ID", "box-a")
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.BoxID != "box-a" || c.HubURL != "https://acme.example.test" {
		t.Fatalf("got %+v", c)
	}

	t.Setenv("SPOOL_HUB_URL", "")
	t.Setenv("SPOOL_BOX_ID", "")
	c, err = Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.BoxID != "" || c.HubURL != "" {
		t.Fatalf("local mode must allow an empty box id, got %+v", c)
	}
}

func TestLoadTenantRootKey(t *testing.T) {
	t.Setenv("SPOOL_ROOT", t.TempDir())
	t.Setenv("SPOOL_KEYS_DIR", t.TempDir())
	t.Setenv("SPOOL_HUB_URL", "")
	t.Setenv("SPOOL_BOX_ID", "")
	t.Setenv("SPOOL_TENANT_ROOT_KEY", "/secret/root.key")
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.TenantRootKey != "/secret/root.key" {
		t.Fatalf("TenantRootKey = %q", c.TenantRootKey)
	}
}

func TestLoadHubRequiresTenantHostPatternFromEnv(t *testing.T) {
	t.Setenv("SPOOL_HUB_DB_DSN", "postgres://spool@/spool?sslmode=disable")
	t.Setenv("SPOOL_HUB_FILES_DIR", t.TempDir())
	t.Setenv("SPOOL_HUB_FILES_BUCKET", "")
	t.Setenv("SPOOL_HUB_TENANT_HOST_PATTERN", "")
	if _, err := LoadHub(); err == nil {
		t.Fatal("empty SPOOL_HUB_TENANT_HOST_PATTERN was accepted")
	}

	t.Setenv("SPOOL_HUB_TENANT_HOST_PATTERN", "not-a-pattern.example")
	if _, err := LoadHub(); err == nil {
		t.Fatal("pattern without {tenant}. prefix was accepted")
	}

	t.Setenv("SPOOL_HUB_TENANT_HOST_PATTERN", "{tenant}.hub.test")
	h, err := LoadHub()
	if err != nil {
		t.Fatal(err)
	}
	if h.TenantHostPattern != "{tenant}.hub.test" {
		t.Fatalf("pattern = %q", h.TenantHostPattern)
	}
	if strings.Contains(h.TenantHostPattern, "spool-hub") {
		t.Fatal("hub config baked a product hostname")
	}
}

func setHubBase(t *testing.T) {
	t.Helper()
	t.Setenv("SPOOL_HUB_DB_DSN", "memory:")
	t.Setenv("SPOOL_HUB_FILES_DIR", t.TempDir())
	t.Setenv("SPOOL_HUB_FILES_BUCKET", "")
	t.Setenv("SPOOL_HUB_TENANT_HOST_PATTERN", "{tenant}.hub.test")
}

func TestLoadHubCICDOffInPrdWithoutToken(t *testing.T) {
	setHubBase(t)
	t.Setenv("SPOOL_HUB_ENV", "prd")
	t.Setenv("SPOOL_HUB_CICD_LOGS_ENABLED", "false")
	h, err := LoadHub()
	if err != nil {
		t.Fatal(err)
	}
	if h.CICDLogsEnabled {
		t.Fatal("flag defaulted on")
	}
}

func TestLoadHubCICDPrdFailClosed(t *testing.T) {
	setHubBase(t)
	t.Setenv("SPOOL_HUB_ENV", "prd")
	t.Setenv("SPOOL_HUB_CICD_LOGS_ENABLED", "true")
	t.Setenv("SPOOL_HUB_CICD_GITHUB_API", "https://api.example.test")
	if _, err := LoadHub(); !errors.Is(err, cicdlogs.ErrFailClosed) {
		t.Fatalf("got %v", err)
	}
	t.Setenv("SPOOL_HUB_CICD_GITHUB_TOKEN", "CHANGE_ME")
	if _, err := LoadHub(); !errors.Is(err, cicdlogs.ErrFailClosed) {
		t.Fatalf("placeholder: %v", err)
	}
	t.Setenv("SPOOL_HUB_CICD_GITHUB_TOKEN", "test-token-ok")
	if _, err := LoadHub(); err != nil {
		t.Fatal(err)
	}
}

func TestLoadHubCICDEnabledNeedsAPI(t *testing.T) {
	setHubBase(t)
	t.Setenv("SPOOL_HUB_ENV", "lde")
	t.Setenv("SPOOL_HUB_CICD_LOGS_ENABLED", "true")
	t.Setenv("SPOOL_HUB_CICD_GITHUB_TOKEN", "test-token-ok")
	if _, err := LoadHub(); err == nil {
		t.Fatal("enabled without API accepted")
	}
}

// Viewer door: token by default; off only under SPOOL_HUB_ENV=lde; the CORS
// allow-list takes bare origins only (specs/003 contracts/view-v1.md §2-§3).
func TestLoadHubViewDoorAndOrigins(t *testing.T) {
	t.Setenv("SPOOL_HUB_DB_DSN", "postgres://spool@/spool?sslmode=disable")
	t.Setenv("SPOOL_HUB_FILES_DIR", t.TempDir())
	t.Setenv("SPOOL_HUB_FILES_BUCKET", "")
	t.Setenv("SPOOL_HUB_TENANT_HOST_PATTERN", "{tenant}.hub.test")
	t.Setenv("SPOOL_HUB_VIEW_CORS_ORIGINS", "")
	t.Setenv("SPOOL_HUB_ENV", "prd")
	t.Setenv("SPOOL_HUB_VIEW_DOOR", "")
	if h, err := LoadHub(); err != nil || h.ViewDoor != "token" {
		t.Fatalf("default door: %v %+v", err, h)
	}
	t.Setenv("SPOOL_HUB_VIEW_DOOR", "off")
	for _, env := range []string{"prd", "", "stg"} {
		t.Setenv("SPOOL_HUB_ENV", env)
		if _, err := LoadHub(); err == nil {
			t.Fatalf("view door off accepted with SPOOL_HUB_ENV=%q", env)
		}
	}
	t.Setenv("SPOOL_HUB_ENV", "dev")
	if h, err := LoadHub(); err != nil || h.ViewDoor != "off" {
		t.Fatalf("dev off: %v", err)
	}
	t.Setenv("SPOOL_HUB_ENV", "lde")
	if h, err := LoadHub(); err != nil || h.ViewDoor != "off" {
		t.Fatalf("lde off: %v", err)
	}
	t.Setenv("SPOOL_HUB_VIEW_DOOR", "open")
	if _, err := LoadHub(); err == nil {
		t.Fatal("unknown door accepted")
	}
	t.Setenv("SPOOL_HUB_VIEW_DOOR", "token")
	t.Setenv("SPOOL_HUB_VIEW_CORS_ORIGINS", "http://localhost:3000,https://wui.example.test")
	if h, err := LoadHub(); err != nil || len(h.ViewCORSOrigins) != 2 {
		t.Fatalf("origins: %v %+v", err, h)
	}
	for _, bad := range []string{"*", "https://*.example.test", "https://wui.example.test/app", "wui.example.test", "https://wui.example.test/"} {
		t.Setenv("SPOOL_HUB_VIEW_CORS_ORIGINS", bad)
		if _, err := LoadHub(); err == nil {
			t.Fatalf("origin %q accepted", bad)
		}
	}
}

// 014 T010: box-wui key env — off by default, fail fast on every bad combination.
func TestLoadHubWUIDispatch(t *testing.T) {
	setHubBase(t)
	t.Setenv("SPOOL_HUB_ENV", "prd")
	t.Setenv("SPOOL_HUB_WUI_KEY", "")
	t.Setenv("SPOOL_HUB_WUI_KEY_EPHEMERAL", "")
	t.Setenv("SPOOL_HUB_WUI_DISPATCH", "")
	h, err := LoadHub()
	if err != nil {
		t.Fatal(err)
	}
	if k, err := h.WUIPrivateKey(); h.WUIDispatch || k != nil || err != nil {
		t.Fatalf("defaults: dispatch=%v key=%v err=%v", h.WUIDispatch, k != nil, err)
	}
	t.Setenv("SPOOL_HUB_WUI_DISPATCH", "true")
	if _, err := LoadHub(); err == nil {
		t.Fatal("dispatch on without a key was accepted")
	}
	t.Setenv("SPOOL_HUB_WUI_KEY_EPHEMERAL", "true")
	if _, err := LoadHub(); err == nil {
		t.Fatal("ephemeral key accepted in prd")
	}
	t.Setenv("SPOOL_HUB_ENV", "dev")
	h, err = LoadHub()
	if err != nil {
		t.Fatal(err)
	}
	if k, err := h.WUIPrivateKey(); err != nil || len(k) != ed25519.PrivateKeySize {
		t.Fatalf("ephemeral key: %v %d", err, len(k))
	}
	t.Setenv("SPOOL_HUB_ENV", "prd")
	t.Setenv("SPOOL_HUB_WUI_KEY_EPHEMERAL", "")
	t.Setenv("SPOOL_HUB_WUI_KEY", "bm90LWEta2V5")
	if _, err := LoadHub(); err == nil || strings.Contains(err.Error(), "bm90LWEta2V5") {
		t.Fatalf("bad key accepted or echoed: %v", err)
	}
	_, priv, _ := ed25519.GenerateKey(nil)
	t.Setenv("SPOOL_HUB_WUI_KEY", base64.StdEncoding.EncodeToString(priv))
	h, err = LoadHub()
	if err != nil {
		t.Fatal(err)
	}
	if k, _ := h.WUIPrivateKey(); !k.Equal(priv) {
		t.Fatal("SPOOL_HUB_WUI_KEY did not round-trip")
	}
}

// 017 FR-SEC-004: an absent key leaves the address-free controls ON and the
// per-IP limits OFF (they need measured hops); 0 is off; negative is refused.
func TestLoadHubEdgeDefaults(t *testing.T) {
	setHubBase(t)
	h, err := LoadHub()
	if err != nil {
		t.Fatal(err)
	}
	if h.EdgeWSConnsTotal <= 0 || h.WSPingInterval <= 0 || h.WSPingTimeout <= 0 || h.HelloTimeout <= 0 ||
		h.EdgeWSConnsPerIP != 0 || h.EdgeWSHandshakesPerIP != 0 || h.EdgeAuthPerIP != 0 ||
		h.TrustedProxyHops != 0 || h.ClientIPProbe {
		t.Fatalf("edge defaults: %+v", h)
	}
	t.Setenv("SPOOL_HUB_EDGE_AUTH_PER_IP", "120")
	t.Setenv("SPOOL_HUB_EDGE_WS_CONNS_TOTAL", "0")
	t.Setenv("SPOOL_HUB_TRUSTED_PROXY_HOPS", "1")
	if h, err = LoadHub(); err != nil || h.EdgeAuthPerIP != 120 || h.EdgeWSConnsTotal != 0 || h.TrustedProxyHops != 1 {
		t.Fatalf("cnf values, 0 = off, hops 1: %v %+v", err, h)
	}
	for _, k := range []string{"SPOOL_HUB_EDGE_WS_CONNS_PER_IP", "SPOOL_HUB_TRUSTED_PROXY_HOPS"} {
		t.Setenv(k, "-1")
		if _, err := LoadHub(); err == nil {
			t.Fatalf("%s=-1 accepted", k)
		}
		t.Setenv(k, "1")
	}
	t.Setenv("SPOOL_HUB_WS_PING_TIMEOUT", "0s")
	if _, err := LoadHub(); err == nil {
		t.Fatal("SPOOL_HUB_WS_PING_TIMEOUT=0 accepted")
	}
}

// specs/020 FR-002: the writer version knobs default to 1 and fail fast.
func TestMsgVersionKnob(t *testing.T) {
	t.Setenv("SPOOL_ROOT", t.TempDir())
	t.Setenv("SPOOL_KEYS_DIR", t.TempDir())
	t.Setenv("SPOOL_HUB_URL", "")
	c, err := Load()
	if err != nil || c.MsgVersion != 1 || c.WriteVersion() != 1 {
		t.Fatalf("box default: %v %+v", err, c)
	}
	t.Setenv("SPOOL_MSG_VERSION", "2")
	if c, err := Load(); err != nil || c.WriteVersion() != 2 {
		t.Fatalf("box v2: %v", err)
	}
	for _, bad := range []string{"0", "3", "x"} {
		t.Setenv("SPOOL_MSG_VERSION", bad)
		if _, err := Load(); err == nil {
			t.Fatalf("SPOOL_MSG_VERSION=%s accepted", bad)
		}
	}
	if (&Config{}).WriteVersion() != 1 {
		t.Fatal("zero Config does not write v:1")
	}

	setHubBase(t)
	h, err := LoadHub()
	if err != nil || h.MsgVersion != 1 {
		t.Fatalf("hub default: %v", err)
	}
	t.Setenv("SPOOL_HUB_MSG_VERSION", "2")
	if h, err := LoadHub(); err != nil || h.MsgVersion != 2 {
		t.Fatalf("hub v2: %v", err)
	}
	t.Setenv("SPOOL_HUB_MSG_VERSION", "3")
	if _, err := LoadHub(); err == nil || !strings.Contains(err.Error(), "SPOOL_HUB_MSG_VERSION") {
		t.Fatalf("SPOOL_HUB_MSG_VERSION=3: %v", err)
	}
}

// SPOOL_HUB_DEFAULT_LOCALE defaults to en (cnf
// env.i18n.default_locale, owner 2026-09-19), takes any of the 19 locales,
// and refuses anything else at startup.
func TestLoadHubDefaultLocale(t *testing.T) {
	setHubBase(t)
	t.Setenv("SPOOL_HUB_DEFAULT_LOCALE", "") // unset/empty = envDefault
	h, err := LoadHub()
	if err != nil || h.DefaultLocale != "en" {
		t.Fatalf("default: %+v %v", h, err)
	}
	t.Setenv("SPOOL_HUB_DEFAULT_LOCALE", "fi")
	if h, err := LoadHub(); err != nil || h.DefaultLocale != "fi" {
		t.Fatalf("fi: %v", err)
	}
	for _, bad := range []string{"de", "FI", "en-US", " "} {
		t.Setenv("SPOOL_HUB_DEFAULT_LOCALE", bad)
		if _, err := LoadHub(); err == nil || !strings.Contains(err.Error(), "SPOOL_HUB_DEFAULT_LOCALE") {
			t.Fatalf("%q accepted: %v", bad, err)
		}
	}
}

// 027 T010: the pool size is config with a default that fits Cloud SQL
// db-f1-micro, and a nonsense size refuses boot.
func TestLoadHubDBPool(t *testing.T) {
	setHubBase(t)
	h, err := LoadHub()
	if err != nil {
		t.Fatal(err)
	}
	if h.DBMaxConns != 8 || h.DBMinConns != 2 || h.DBMaxConnIdleTime.String() != "5m0s" {
		t.Fatalf("pool defaults %d %d %s, want 8 2 5m", h.DBMaxConns, h.DBMinConns, h.DBMaxConnIdleTime)
	}
	for _, bad := range [][2]string{
		{"SPOOL_HUB_DB_MAX_CONNS", "0"},
		{"SPOOL_HUB_DB_MIN_CONNS", "9"},
		{"SPOOL_HUB_DB_MIN_CONNS", "-1"},
		{"SPOOL_HUB_DB_MAX_CONN_IDLE_TIME", "0s"},
	} {
		t.Run(bad[0]+"="+bad[1], func(t *testing.T) {
			t.Setenv(bad[0], bad[1])
			if _, err := LoadHub(); err == nil {
				t.Fatalf("%s=%s was accepted", bad[0], bad[1])
			}
		})
	}
}

// specs/030 FR-007: SPOOL_NOTIFY_ASYNC rolls the queued terminal leg back.
func TestNotifyAsyncOff(t *testing.T) {
	for v, want := range map[string]bool{
		"": false, "1": false, "true": false, "on": false,
		"0": true, "false": true, "OFF": true, " off ": true,
	} {
		c := &Config{NotifyAsync: v}
		if got := c.NotifyAsyncOff(); got != want {
			t.Errorf("NotifyAsync=%q: NotifyAsyncOff()=%v, want %v", v, got, want)
		}
	}
}

// TestHubRuntimeLimits (CLE-35076): SPOOL_HUB_GOMAXPROCS / SPOOL_HUB_GOMEMLIMIT
// parse into what cmd/spool applies; unset leaves the runtime's own.
func TestHubRuntimeLimits(t *testing.T) {
	for _, c := range []struct {
		procs   int
		mem     string
		wantP   int
		wantB   int64
		wantErr bool
	}{
		{0, "", 0, -1, false},
		{1, "460MiB", 1, 460 << 20, false},
		{2, "1GiB", 2, 1 << 30, false},
		{0, "4096", 0, 4096, false},
		{0, "512KiB", 0, 512 << 10, false},
		{-1, "", 0, 0, true},
		{0, "0MiB", 0, 0, true},
		{0, "lots", 0, 0, true},
		{0, "-5MiB", 0, 0, true},
	} {
		h := &Hub{GoMaxProcs: c.procs, GoMemLimit: c.mem}
		p, b, err := h.RuntimeLimits()
		if (err != nil) != c.wantErr {
			t.Errorf("%d %q: err %v, want error %v", c.procs, c.mem, err, c.wantErr)
			continue
		}
		if !c.wantErr && (p != c.wantP || b != c.wantB) {
			t.Errorf("%d %q: got %d %d, want %d %d", c.procs, c.mem, p, b, c.wantP, c.wantB)
		}
	}
}

// specs/077 FR-004: the demo providers default to google,facebook,linkedin
// (linkedin: owner, t1 msg fafec44f), and a password (or any other) provider
// can never open the demo.
func TestLoadHubDemoProviders(t *testing.T) {
	setHubBase(t)
	h, err := LoadHub()
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(h.DemoProviders, ",") != "google,facebook,linkedin" || h.DemoTenant() != "" {
		t.Fatalf("defaults: providers %v, demo %q (want off)", h.DemoProviders, h.DemoTenant())
	}
	for _, good := range []string{"linkedin", "google,facebook,linkedin"} {
		t.Setenv("SPOOL_HUB_DEMO_PROVIDERS", good)
		if _, err := LoadHub(); err != nil {
			t.Fatalf("SPOOL_HUB_DEMO_PROVIDERS=%s was refused: %v", good, err)
		}
	}
	for _, bad := range []string{"password", "google,password", "microsoft", "xai", "linkedin,xai"} {
		t.Setenv("SPOOL_HUB_DEMO_PROVIDERS", bad)
		if _, err := LoadHub(); err == nil {
			t.Fatalf("SPOOL_HUB_DEMO_PROVIDERS=%s was accepted", bad)
		}
	}
}

// specs/077 T008: the live demo cap defaults to the owner's 9; below 1 the
// hub refuses to start (0 must never read as unlimited).
func TestLoadHubDemoMaxStay(t *testing.T) {
	setHubBase(t)
	h, err := LoadHub()
	if err != nil || h.DemoMaxStay != 3*time.Hour {
		t.Fatalf("default: %v %v, want 3h", h, err)
	}
	for _, bad := range []string{"59s", "0", "-1h", "three hours"} {
		t.Setenv("SPOOL_HUB_DEMO_MAX_STAY", bad)
		if _, err := LoadHub(); err == nil {
			t.Fatalf("SPOOL_HUB_DEMO_MAX_STAY=%s was accepted", bad)
		}
	}
	t.Setenv("SPOOL_HUB_DEMO_MAX_STAY", "1m")
	if h, err := LoadHub(); err != nil || h.DemoMaxStay != time.Minute {
		t.Fatalf("1m: %v", err)
	}
}

// specs/077 T012: a demo_user posts 10 a minute and 200 a day by default;
// below 1 the hub refuses to start (0 must never read as unlimited).
func TestLoadHubDemoPosts(t *testing.T) {
	setHubBase(t)
	h, err := LoadHub()
	if err != nil || h.DemoPostsPerMinute != 10 || h.DemoPostsPerDay != 200 {
		t.Fatalf("default: %v %v, want 10 and 200", h, err)
	}
	for _, k := range []string{"SPOOL_HUB_DEMO_POSTS_PER_MINUTE", "SPOOL_HUB_DEMO_POSTS_PER_DAY"} {
		for _, bad := range []string{"0", "-1", "ten"} {
			t.Setenv(k, bad)
			if _, err := LoadHub(); err == nil {
				t.Fatalf("%s=%s was accepted", k, bad)
			}
		}
		t.Setenv(k, "3")
	}
	if h, err := LoadHub(); err != nil || h.DemoPostsPerMinute != 3 || h.DemoPostsPerDay != 3 {
		t.Fatalf("3 and 3: %v", err)
	}
}

// specs/077 T010: 2 demo visits per account and 3 new demo accounts per
// client IP a day by default; below 1 the hub refuses to start.
func TestLoadHubDemoAdmissionLimits(t *testing.T) {
	setHubBase(t)
	h, err := LoadHub()
	if err != nil || h.DemoVisitsPerDay != 2 || h.DemoSignupsPerIP != 3 {
		t.Fatalf("default: %v %v, want 2 and 3", h, err)
	}
	for _, k := range []string{"SPOOL_HUB_DEMO_VISITS_PER_DAY", "SPOOL_HUB_DEMO_SIGNUPS_PER_IP"} {
		for _, bad := range []string{"0", "-1", "two"} {
			t.Setenv(k, bad)
			if _, err := LoadHub(); err == nil {
				t.Fatalf("%s=%s was accepted", k, bad)
			}
		}
		t.Setenv(k, "5")
	}
	if h, err := LoadHub(); err != nil || h.DemoVisitsPerDay != 5 || h.DemoSignupsPerIP != 5 {
		t.Fatalf("5 and 5: %v", err)
	}
}

func TestLoadHubDemoMaxLive(t *testing.T) {
	setHubBase(t)
	h, err := LoadHub()
	if err != nil || h.DemoMaxLive != 9 {
		t.Fatalf("default: %v %v, want 9", h, err)
	}
	for _, bad := range []string{"0", "-1", "nine"} {
		t.Setenv("SPOOL_HUB_DEMO_MAX_LIVE", bad)
		if _, err := LoadHub(); err == nil {
			t.Fatalf("SPOOL_HUB_DEMO_MAX_LIVE=%s was accepted", bad)
		}
	}
	t.Setenv("SPOOL_HUB_DEMO_MAX_LIVE", "3")
	if h, err := LoadHub(); err != nil || h.DemoMaxLive != 3 {
		t.Fatalf("3: %v", err)
	}
}

// specs/121 T103: the embed is off by default with section 6's limits and
// a 30-day sliding / 180-day token; a bad value refuses to start.
func TestLoadHubEmbed(t *testing.T) {
	setHubBase(t)
	h, err := LoadHub()
	if err != nil {
		t.Fatal(err)
	}
	if h.EmbedEnabled || h.EmbedVisitorsPerIPHour != 5 || h.EmbedVisitorsPerIPDay != 20 ||
		h.EmbedPostsPerMinute != 6 || h.EmbedPostsPerDay != 100 || h.EmbedMessageMaxBytes != 4096 ||
		h.EmbedTurnsPerDay != 10 || h.EmbedLiveVisitorsMax != 200 ||
		h.EmbedChallengeAfterHits != 3 || h.EmbedBanAfterHits != 5 ||
		h.EmbedHitsWindow != 24*time.Hour || h.EmbedBanFor != 24*time.Hour ||
		h.EmbedTokenIdleTTL != 30*24*time.Hour || h.EmbedTokenMaxAge != 180*24*time.Hour {
		t.Fatalf("embed defaults: %+v", h)
	}
	// each key is put back to its default before the next, so one bad value
	// is tested at a time
	for _, c := range []struct {
		k, good string
		bads    []string
	}{
		{"SPOOL_HUB_EMBED_ENABLED", "false", []string{"maybe"}},
		{"SPOOL_HUB_EMBED_VISITORS_PER_IP_HOUR", "5", []string{"0", "-1", "five"}},
		{"SPOOL_HUB_EMBED_VISITORS_PER_IP_DAY", "20", []string{"0"}},
		{"SPOOL_HUB_EMBED_POSTS_PER_MINUTE", "6", []string{"0"}},
		{"SPOOL_HUB_EMBED_POSTS_PER_DAY", "100", []string{"0"}},
		{"SPOOL_HUB_EMBED_MESSAGE_MAX_BYTES", "4096", []string{"0", "4KB"}},
		{"SPOOL_HUB_EMBED_TURNS_PER_DAY", "10", []string{"0"}},
		{"SPOOL_HUB_EMBED_LIVE_VISITORS_MAX", "200", []string{"0"}},
		{"SPOOL_HUB_EMBED_CHALLENGE_AFTER_HITS", "3", []string{"0", "6"}},
		{"SPOOL_HUB_EMBED_BAN_AFTER_HITS", "5", []string{"0", "2"}},
		{"SPOOL_HUB_EMBED_HITS_WINDOW", "24h", []string{"59s", "one day"}},
		{"SPOOL_HUB_EMBED_BAN_FOR", "24h", []string{"0"}},
		{"SPOOL_HUB_EMBED_TOKEN_IDLE_TTL", "720h", []string{"0", "4321h"}},
		{"SPOOL_HUB_EMBED_TOKEN_MAX_AGE", "4320h", []string{"30s", "719h"}},
	} {
		for _, bad := range c.bads {
			t.Setenv(c.k, bad)
			if _, err := LoadHub(); err == nil {
				t.Fatalf("%s=%s was accepted", c.k, bad)
			}
		}
		t.Setenv(c.k, c.good)
	}
	t.Setenv("SPOOL_HUB_EMBED_ENABLED", "true")
	t.Setenv("SPOOL_HUB_EMBED_TOKEN_IDLE_TTL", "1h")
	if h, err := LoadHub(); err != nil || !h.EmbedEnabled || h.EmbedTokenIdleTTL != time.Hour {
		t.Fatalf("on, 1h: %v", err)
	}
}

// TestConfigInCodeDefaults: a Config built in code (no env) falls back to
// SPOOL_ID_QUARANTINE_H's 24 h and the 10 s notify timeout; a positive value
// wins.
func TestConfigInCodeDefaults(t *testing.T) {
	quarantine := []struct {
		h    int
		want time.Duration
	}{
		{0, 24 * time.Hour},
		{-3, 24 * time.Hour},
		{1, time.Hour},
		{48, 48 * time.Hour},
	}
	for _, c := range quarantine {
		if got := (&Config{IDQuarantineH: c.h}).IDQuarantine(); got != c.want {
			t.Errorf("IDQuarantineH=%d: IDQuarantine()=%s, want %s", c.h, got, c.want)
		}
	}
	notify := []struct {
		d, want time.Duration
	}{
		{0, 10 * time.Second},
		{-time.Second, 10 * time.Second},
		{250 * time.Millisecond, 250 * time.Millisecond},
		{time.Minute, time.Minute},
	}
	for _, c := range notify {
		if got := (&Config{NotifyTimeout: c.d}).NotifyTimeoutOr(); got != c.want {
			t.Errorf("NotifyTimeout=%s: NotifyTimeoutOr()=%s, want %s", c.d, got, c.want)
		}
	}
}

func TestChannelList(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"", nil},
		{" , ,", nil},
		{"lobby", []string{"lobby"}},
		{" Lobby , OPS,,dev-ci ", []string{"lobby", "ops", "dev-ci"}},
	}
	for _, c := range cases {
		got := (&Config{Channels: c.in}).ChannelList()
		if strings.Join(got, "|") != strings.Join(c.want, "|") || len(got) != len(c.want) {
			t.Errorf("Channels=%q: ChannelList()=%q, want %q", c.in, got, c.want)
		}
	}
}

func TestMirror(t *testing.T) {
	for v, want := range map[string]bool{"": false, "0": false, "false": false, "FALSE": false, "1": true, "true": true, "True": true} {
		got, err := (&Config{MirrorLocal: v}).Mirror()
		if err != nil || got != want {
			t.Errorf("MirrorLocal=%q: Mirror()=%v,%v, want %v,nil", v, got, err, want)
		}
	}
	for _, bad := range []string{"yes", "2", "on", " 1"} {
		if _, err := (&Config{MirrorLocal: bad}).Mirror(); err == nil || !strings.Contains(err.Error(), "SPOOL_MIRROR_LOCAL") {
			t.Errorf("MirrorLocal=%q: err=%v, want a SPOOL_MIRROR_LOCAL error", bad, err)
		}
	}
}

// TestTenantIDEdges adds the branches tenant_test.go leaves out: a mixed-case
// SPOOL_TENANT, an unparseable URL and a first label that is no tenant id.
func TestTenantIDEdges(t *testing.T) {
	cases := []struct {
		tenant, hubURL, want string
	}{
		{"Acme", "https://api.example.test", "acme"},
		{"", "https://ACME.example.test:8443", "acme"},
		{"", "https://bad_label.example.test", ""},
		{"", "", ""},
		{"", "://bad", ""},
	}
	for _, c := range cases {
		if got := (&Config{Tenant: c.tenant, HubURL: c.hubURL}).TenantID(); got != c.want {
			t.Errorf("Tenant=%q HubURL=%q: TenantID()=%q, want %q", c.tenant, c.hubURL, got, c.want)
		}
	}
}

// TestDirResolvers: HubDir, FilesDir and the submit socket all live under
// SpoolRoot; SPOOL_SUBMIT_SOCKET=off (any case, padded) turns the socket off
// and a path overrides it.
func TestDirResolvers(t *testing.T) {
	root := filepath.Join("/", "var", "spool-test")
	c := &Config{SpoolRoot: root}
	if got, want := c.HubDir(), filepath.Join(root, ".hub"); got != want {
		t.Errorf("HubDir()=%q, want %q", got, want)
	}
	if got, want := c.FilesDir(), filepath.Join(root, "files"); got != want {
		t.Errorf("FilesDir()=%q, want %q", got, want)
	}
	cases := []struct {
		socket, path string
		off          bool
	}{
		{"", filepath.Join(root, ".hub", "submit.sock"), false},
		{"   ", filepath.Join(root, ".hub", "submit.sock"), false},
		{"off", "", true},
		{" OFF ", "", true},
		{"/run/spool/s.sock", "/run/spool/s.sock", false},
		{" /run/spool/s.sock ", "/run/spool/s.sock", false},
	}
	for _, s := range cases {
		c := &Config{SpoolRoot: root, SubmitSocket: s.socket}
		if got := c.SubmitOff(); got != s.off {
			t.Errorf("SubmitSocket=%q: SubmitOff()=%v, want %v", s.socket, got, s.off)
		}
		if got := c.SubmitPath(); got != s.path {
			t.Errorf("SubmitSocket=%q: SubmitPath()=%q, want %q", s.socket, got, s.path)
		}
	}
}

// setBoxBase clears the box env a test machine may carry, so Load sees only
// what the test sets.
func setBoxBase(t *testing.T, root string) {
	t.Helper()
	for _, k := range []string{
		"SPOOL_KEYS_DIR", "SPOOL_PINS_DIR", "SPOOL_HUB_URL", "SPOOL_TENANT", "SPOOL_BOX_ID",
		"SPOOL_MIRROR_LOCAL", "SPOOL_MSG_VERSION", "SPOOL_NOTIFY_TIMEOUT", "SPOOL_ID_QUARANTINE_H",
		"SPOOL_CHANNELS", "SPOOL_SUBMIT_SOCKET", "SPOOL_LOG_LEVEL", "SPOOL_LOG_FORMAT",
	} {
		t.Setenv(k, "")
	}
	t.Setenv("SPOOL_ROOT", root)
}

// TestLoadEnvDefaultsAndOverrides: Load fills the documented defaults
// ($HOME/.spool/keys, <root>/pins, 10s, 24 h, info/console) and an env value
// overrides each.
func TestLoadEnvDefaultsAndOverrides(t *testing.T) {
	root := t.TempDir()
	home := t.TempDir()
	setBoxBase(t, root)
	t.Setenv("HOME", home)
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.KeysDir != filepath.Join(home, ".spool", "keys") || c.PinsDir != filepath.Join(root, "pins") {
		t.Errorf("dir defaults: KeysDir=%q PinsDir=%q", c.KeysDir, c.PinsDir)
	}
	if c.NotifyTimeoutOr() != 10*time.Second || c.IDQuarantine() != 24*time.Hour ||
		c.LogLevel != "info" || c.LogFormat != "console" || c.ChannelList() != nil {
		t.Errorf("value defaults: %+v", c)
	}

	t.Setenv("SPOOL_KEYS_DIR", filepath.Join(home, "k"))
	t.Setenv("SPOOL_PINS_DIR", filepath.Join(home, "p"))
	t.Setenv("SPOOL_NOTIFY_TIMEOUT", "3s")
	t.Setenv("SPOOL_ID_QUARANTINE_H", "6")
	t.Setenv("SPOOL_CHANNELS", "Ops,dev")
	t.Setenv("SPOOL_LOG_LEVEL", "debug")
	t.Setenv("SPOOL_LOG_FORMAT", "json")
	t.Setenv("SPOOL_SUBMIT_SOCKET", "off")
	c, err = Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.KeysDir != filepath.Join(home, "k") || c.PinsDir != filepath.Join(home, "p") ||
		c.NotifyTimeoutOr() != 3*time.Second || c.IDQuarantine() != 6*time.Hour ||
		strings.Join(c.ChannelList(), ",") != "ops,dev" || c.LogLevel != "debug" ||
		c.LogFormat != "json" || !c.SubmitOff() {
		t.Errorf("overrides: %+v", c)
	}
}

// TestLoadFailsFast: every unparseable or illegal env value is refused,
// naming its field (a parse error) or its variable.
func TestLoadFailsFast(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
		want string
	}{
		{"notify-timeout", map[string]string{"SPOOL_NOTIFY_TIMEOUT": "ten"}, `"NotifyTimeout"`},
		{"quarantine", map[string]string{"SPOOL_ID_QUARANTINE_H": "x"}, `"IDQuarantineH"`},
		{"hub-url-scheme", map[string]string{"SPOOL_HUB_URL": "ftp://acme.example.test", "SPOOL_BOX_ID": "box-a"}, "SPOOL_HUB_URL"},
		{"hub-url-host", map[string]string{"SPOOL_HUB_URL": "https://", "SPOOL_BOX_ID": "box-a"}, "SPOOL_HUB_URL"},
		{"tenant", map[string]string{"SPOOL_HUB_URL": "https://api.example.test", "SPOOL_BOX_ID": "box-a", "SPOOL_TENANT": "Not A Tenant"}, "SPOOL_TENANT"},
		{"mirror", map[string]string{"SPOOL_HUB_URL": "https://api.example.test", "SPOOL_BOX_ID": "box-a", "SPOOL_MIRROR_LOCAL": "yes"}, "SPOOL_MIRROR_LOCAL"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			setBoxBase(t, t.TempDir())
			t.Setenv("SPOOL_KEYS_DIR", t.TempDir())
			for k, v := range c.env {
				t.Setenv(k, v)
			}
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err=%v, want one naming %s", err, c.want)
			}
		})
	}
	// local mode ignores the mirror flag
	setBoxBase(t, t.TempDir())
	t.Setenv("SPOOL_KEYS_DIR", t.TempDir())
	t.Setenv("SPOOL_MIRROR_LOCAL", "yes")
	if _, err := Load(); err != nil {
		t.Fatalf("local mode with SPOOL_MIRROR_LOCAL=yes: %v", err)
	}
}

// TestResolvePath: a path that does not exist yet is returned absolute and
// cleaned, with symlinks resolved on the part that does.
func TestResolvePath(t *testing.T) {
	base := t.TempDir()
	real, err := filepath.EvalSymlinks(base)
	if err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(base, "link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	cases := []struct{ in, want string }{
		{base, real},
		{filepath.Join(base, "a", "b"), filepath.Join(real, "a", "b")},
		{filepath.Join(link, "a", "..", "c"), filepath.Join(real, "c")},
	}
	for _, c := range cases {
		if got, err := resolvePath(c.in); err != nil || got != c.want {
			t.Errorf("resolvePath(%q)=%q,%v, want %q", c.in, got, err, c.want)
		}
	}
}
