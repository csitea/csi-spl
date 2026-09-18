package config

import (
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
	t.Setenv("SPOOL_HUB_ENV", "dev")
	t.Setenv("SPOOL_HUB_VIEW_DOOR", "")
	if h, err := LoadHub(); err != nil || h.ViewDoor != "token" {
		t.Fatalf("default door: %v %+v", err, h)
	}
	t.Setenv("SPOOL_HUB_VIEW_DOOR", "off")
	if _, err := LoadHub(); err == nil {
		t.Fatal("view door off accepted outside lde")
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
