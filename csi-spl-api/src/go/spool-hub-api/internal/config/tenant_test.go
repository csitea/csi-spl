package config

import "testing"

// specs/026 §4: SPOOL_TENANT wins; a legacy tenant URL still names its tenant;
// the api host (a reserved label), an IP or a bare host names none.
func TestTenantID(t *testing.T) {
	for _, c := range []struct{ url, tenant, want string }{
		{"https://api.example.test", "csitea", "csitea"},
		{"https://api.example.test", "", ""},
		{"https://dev.api.example.test", "", ""},
		{"https://t1.example.test", "", "t1"},
		{"https://t1.example.test", "e2e", "e2e"},
		{"http://t1.localhost:58080", "", "t1"},
		{"http://localhost:58080", "", ""},
		{"http://127.0.0.1:58080", "", ""},
		{"https://www.example.test", "", ""},
	} {
		cfg := &Config{HubURL: c.url, Tenant: c.tenant}
		if got := cfg.TenantID(); got != c.want {
			t.Errorf("TenantID(%q, SPOOL_TENANT=%q) = %q, want %q", c.url, c.tenant, got, c.want)
		}
	}
}

func TestLoadRejectsBadTenant(t *testing.T) {
	root := t.TempDir()
	t.Setenv("SPOOL_ROOT", root)
	t.Setenv("SPOOL_KEYS_DIR", t.TempDir())
	t.Setenv("SPOOL_PINS_DIR", root+"/pins")
	t.Setenv("SPOOL_HUB_URL", "https://api.example.test")
	t.Setenv("SPOOL_BOX_ID", "box-a")
	t.Setenv("SPOOL_TENANT", "Not A Tenant")
	if _, err := Load(); err == nil {
		t.Fatal("a malformed SPOOL_TENANT loaded")
	}
	t.Setenv("SPOOL_TENANT", "acme")
	c, err := Load()
	if err != nil || c.TenantID() != "acme" {
		t.Fatalf("SPOOL_TENANT=acme: %v %+v", err, c)
	}
}
