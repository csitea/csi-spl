package config

import (
	"strings"
	"testing"
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
