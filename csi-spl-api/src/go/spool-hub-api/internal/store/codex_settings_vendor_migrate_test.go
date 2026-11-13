package store

import (
	"context"
	"strings"
	"testing"
	"time"
)

// rdb 0282 (SPL-5454): codex is a vendor in every workspace setting that
// names the other agent vendors. Postgres only.
//
// Catalog (n=1 per table): every CHECK of the five setting tables whose
// text names 'mistral' also names 'codex', except the 0178 secret-class
// CHECK, which must NOT (the data rule, spec 161 5.1). A constraint 0282
// failed to drop (a wrong auto-generated name) would still list five
// vendors and fail here.
//
// Round trips (n=1 each): the flat split with codex 15 is stored and read
// back; a codex cap of 2 is stored and read back.
func TestCodexSettingsVendor0282(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()

	rows, err := pg.pool.Query(ctx, `SELECT c.conrelid::regclass::text, c.conname, pg_get_constraintdef(c.oid)
		FROM pg_constraint c
		WHERE c.contype = 'c' AND c.conrelid::regclass::text IN
		      ('tenants', 'tenant_agent_split_kind', 'tenant_agent_caps', 'workspace_vendor_keys', 'workspace_vendor_key_audit')`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	seen := map[string]bool{}
	for rows.Next() {
		var rel, name, def string
		if err := rows.Scan(&rel, &name, &def); err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(def, "'mistral'") {
			continue
		}
		seen[rel] = true
		hasCodex := strings.Contains(def, "'codex'")
		if name == "tenant_agent_split_kind_secret_vendors" {
			if hasCodex {
				t.Errorf("%s.%s names codex: the data rule keeps it out of secret-class work: %s", rel, name, def)
			}
			continue
		}
		if !hasCodex {
			t.Errorf("%s.%s lists the vendors without codex: %s", rel, name, def)
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	// tenants' vendor list is fleet_agent_kinds_off (0238); the others are 0282's.
	for _, rel := range []string{"tenants", "tenant_agent_split_kind", "tenant_agent_caps", "workspace_vendor_keys", "workspace_vendor_key_audit"} {
		if !seen[rel] {
			t.Errorf("%s: no CHECK names the vendors; the catalog query read nothing", rel)
		}
	}

	tid := newTenant(t, pg)
	split := AgentSplit{Claude: 30, Grok: 0, Agy: 5, Qwen: 10, Mistral: 40, Codex: 15}
	if err := pg.SetTenantConfig(ctx, tid, TenantConfigPatch{AgentSplit: &split}); err != nil {
		t.Fatalf("set split with codex: %v", err)
	}
	cfg, err := pg.TenantConfig(ctx, tid)
	if err != nil || cfg.AgentSplit != split {
		t.Fatalf("split = %+v, %v; want %+v", cfg.AgentSplit, err, split)
	}

	caps, err := pg.SetAgentCaps(ctx, tid, map[string]*int{"codex": capOf(2)}, capOperator, time.Now().UTC())
	if err != nil {
		t.Fatalf("codex cap: %v", err)
	}
	if got, ok := caps.Caps["codex"]; !ok || got != 2 {
		t.Fatalf("codex cap = %v, want 2 (%+v)", got, caps)
	}
}
