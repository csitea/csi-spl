package store

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// spec 072 A45: the heads compare by name, as Migrate applies them.
func TestSchemaHeadCompare(t *testing.T) {
	for _, c := range []struct {
		h             SchemaHead
		behind, ahead bool
	}{
		{SchemaHead{Bundled: "0112_x.sql", Applied: "0112_x.sql"}, false, false},
		{SchemaHead{Bundled: "0112_x.sql", Applied: "0111_y.sql"}, true, false},
		{SchemaHead{Bundled: "0112_x.sql", Applied: ""}, true, false},
		{SchemaHead{Bundled: "0111_y.sql", Applied: "0112_x.sql"}, false, true},
	} {
		if c.h.Behind() != c.behind || c.h.Ahead() != c.ahead {
			t.Fatalf("%+v: behind=%v ahead=%v", c.h, c.h.Behind(), c.h.Ahead())
		}
	}
	msg := SchemaHead{Bundled: "0112_x.sql"}.BehindError().Error()
	for _, want := range []string{"newest applied migration none", "the image bundles 0112_x.sql", "spool migrate", "docker compose up hub-init"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("BehindError %q lacks %q", msg, want)
		}
	}
}

func TestBundledHead(t *testing.T) {
	dir := t.TempDir()
	if h, err := BundledHead(dir); err != nil || h != "" {
		t.Fatalf("empty dir: %q %v", h, err)
	}
	for _, n := range []string{"0021_tenant_rbac.sql", "0112_x.sql", "0021_rls_fail_closed.sql", "README.md"} {
		if err := os.WriteFile(filepath.Join(dir, n), []byte("SELECT 1;\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if h, err := BundledHead(dir); err != nil || h != "0112_x.sql" {
		t.Fatalf("BundledHead = %q %v, want 0112_x.sql", h, err)
	}
}
