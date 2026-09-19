package config

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"strings"
	"testing"

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

// CLE-3403: SPOOL_HUB_DEFAULT_LOCALE defaults to csi-rel's bg, takes any of
// the 19 locales, and refuses anything else at startup.
func TestLoadHubDefaultLocale(t *testing.T) {
	setHubBase(t)
	t.Setenv("SPOOL_HUB_DEFAULT_LOCALE", "") // unset/empty = envDefault
	h, err := LoadHub()
	if err != nil || h.DefaultLocale != "bg" {
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
